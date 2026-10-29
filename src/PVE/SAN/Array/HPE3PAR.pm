package PVE::SAN::Array::HPE3PAR;

# Driver for HPE Primera, Alletra 9000 and 3PAR StoreServ through the Web
# Services API (WSAPI, /api/v1). Primera and Alletra 9000 serve it on port
# 443; 3PAR StoreServ (3PAR OS 3.x) on 8080 (set the port when adding it).
#
# Checked against HPE's python-3parclient (hpe3parclient/client.py, http.py,
# exceptions.py) and OpenStack Cinder's 3PAR driver
# (cinder/volume/drivers/hpe/hpe_3par_common.py, hpe_3par_fc.py):
#   session    POST credentials {user, password} -> {key}; then header
#              X-HP3PAR-WSAPI-SessionKey: <key>; DELETE credentials/<key>;
#              401/403 -> log in again (http.py _cs_request)
#   errors     {code, desc[, ref]} ('message' on some replies, exceptions.py)
#   system     GET system -> {id, name, model, serialNumber, systemVersion}
#   CPGs       GET cpgs -> members [{name, SDGrowth.limitMiB, UsrUsage/SAUsage/
#              SDUsage.totalMiB}] (Cinder get_volume_stats)
#   hosts      GET hosts -> members [{id, name, FCPaths [{wwn}]}]
#              POST hosts {name, FCWWNs, persona: 2 (Generic-ALUA)}
#              PUT hosts/<name> {pathOperation: 1 (add), FCWWNs}; DELETE hosts/<name>
#   host sets  GET hostsets -> members [{name, id, setmembers}]
#              POST hostsets {name}; PUT hostsets/<name> {action: 1 add | 2 remove, setmembers}
#   volumes    POST volumes {name, cpg, sizeMiB, tpvv}; GET volumes/<name>
#              GET volumes?query="wwn EQ <WWN>"; DELETE volumes/<name>
#              PUT volumes/<name> {action: 3 (grow), sizeMiB: growth}
#   VLUNs      POST vluns {volumeName, lun: 0, autoLun, maxAutoLun: 0,
#              hostname: "set:<host set>"} (a host set export: the same LUN on
#              every member); GET vluns?query="volumeName EQ <name>";
#              DELETE vluns/<volume>,<lun>,set:<host set>
#   ports      GET ports -> members [{portWWN, protocol 1 = FC, mode 2 = target,
#              linkState 4 = ready}]
#   snapshots  POST volumes/<name> {action: createSnapshot, parameters: {name,
#              comment, readOnly}}; GET volumes?query="copyOf EQ <name>" ->
#              copyType 3 = virtual copy (getVolumeSnapshots)
#   groups     POST volumesets {name, setmembers}; PUT volumesets/<name>
#              {action: 1, setmembers}; POST volumesets/<name> {action:
#              createSnapshot, parameters: {name: "<base>-@count@", ...}}
#              (Cinder create_group_snapshot)
#   clone      POST volumes/<snapshot> {action: createPhysicalCopy, parameters:
#              {destVolume, destCPG, online: true, tpvv: true}} -> {taskid}
#   restore    PUT volumes/<snapshot> {action: 4 (promote virtual copy),
#              online: true} -> {taskid}; GET tasks/<id> -> {status: 1 done,
#              2 active, 3 cancelled, 4 failed}
# The volume's 'wwn' field and the "wwn EQ" query are also used by LXD's
# Alletra driver and forklift's HPE importer; host set VLUN names
# ("set:<name>") by CloudStack's Primera adapter.
#
# Objects are addressed by name, so a volume's id is its name. WSAPI names
# are at most 31 characters (volumes, hosts) and 27 for sets.
#
# A snapshot is a virtual copy volume. pvesan's snapshot name (up to 40
# characters) does not fit into its 31, so the virtual copy gets a short
# name and carries the pvesan name in its comment ({"pvesan":"<name>"});
# virtual copies without it (the array's own schedules) are not listed.
# Several volumes are snapshotted together through a volume set
# "pvesan-<first volume>"; each member of such a set is an ordinary virtual
# copy of its volume and is deleted, cloned and restored on its own.

use strict;
use warnings;

use JSON::PP ();

use base qw(PVE::SAN::Array::Base);

my $API = '/api/v1';
my $MIB = 1024 * 1024;
my $SESSION_HEADER = 'X-HP3PAR-WSAPI-SessionKey';

my $PERSONA_GENERIC_ALUA = 2;
my $SET_MEM_ADD = 1;
my $SET_MEM_REMOVE = 2;
my $HOST_EDIT_ADD = 1;
my $GROW_VOLUME = 3;
my $PROMOTE_VIRTUAL_COPY = 4;
my $VIRTUAL_COPY = 3;
my %TASK_STATE = (1 => 'done', 2 => 'active', 3 => 'cancelled', 4 => 'failed');

sub description { return 'HPE Primera / Alletra 9000 / 3PAR'; }
sub default_port { return 443; }
sub max_name_length { return 31; }
sub max_set_name_length { return 27; }

sub valid_name {
    my ($class, $name) = @_;
    return defined($name) && $name =~ /^[A-Za-z0-9_.-]{1,31}$/;
}

sub valid_hostcluster_name {
    my ($class, $name) = @_;
    return defined($name) && $name =~ /^[A-Za-z0-9_.-]{1,27}$/;
}

sub object_name_for {
    my ($class, $name) = @_;
    $name =~ s/[^A-Za-z0-9_.-]/_/g;
    return substr($name, 0, 27);
}

*short = \&PVE::SAN::Array::Base::short;

sub error_text {
    my ($content) = @_;
    my $d = PVE::SAN::Array::Base::decode($content);
    if (ref($d) eq 'HASH') {
        my $m = join(': ', grep { defined && length } $d->{code}, $d->{desc} // $d->{message});
        $m .= " ($d->{ref})" if length($m) && defined($d->{ref}) && length($d->{ref});
        return $m if length($m);
    }
    return short($content);
}

sub login {
    my ($self) = @_;
    my ($code, $content) = $self->request('POST', "$API/credentials", {},
        { user => $self->{username}, password => $self->{password} });
    die "HPE 3PAR login to $self->{address} failed (HTTP $code): " . error_text($content) . "\n"
        if $code < 200 || $code >= 300;
    my $d = PVE::SAN::Array::Base::decode($content);
    die "HPE 3PAR login: no session key in response\n" if ref($d) ne 'HASH' || !$d->{key};
    $self->{session_key} = $d->{key};
}

sub logout {
    my ($self) = @_;
    my $key = delete $self->{session_key} or return;
    $self->request('DELETE', "$API/credentials/$key", { $SESSION_HEADER => $key }, undef);
}

sub DESTROY {
    my ($self) = @_;
    return if !$self->{session_key};
    local ($@, $!, $?);
    eval { $self->logout() };
}

# One WSAPI call below /api/v1; returns (code, content, headers).
sub raw {
    my ($self, $method, $path, $query, $body) = @_;
    $self->login() if !$self->{session_key};
    my $url = "$API$path" . PVE::SAN::Array::Base::query_string($query);
    my ($code, $content, $h);
    for my $attempt (1, 2) {
        ($code, $content, $h) = $self->request($method, $url, { $SESSION_HEADER => $self->{session_key} }, $body);
        last if ($code != 401 && $code != 403) || $attempt == 2;
        $self->login(); # session expired or was removed on the array
    }
    return ($code, $content, $h);
}

sub call {
    my ($self, $method, $path, $query, $body) = @_;
    my ($code, $content) = $self->raw($method, $path, $query, $body);
    die "HPE 3PAR $method $path failed (HTTP $code): " . error_text($content) . "\n" if $code < 200 || $code >= 300;
    return PVE::SAN::Array::Base::decode($content);
}

# GET that returns undef for a missing object
sub get_optional {
    my ($self, $path) = @_;
    my ($code, $content) = $self->raw('GET', $path);
    return undef if $code == 404;
    die "HPE 3PAR GET $path failed (HTTP $code): " . error_text($content) . "\n" if $code < 200 || $code >= 300;
    return PVE::SAN::Array::Base::decode($content);
}

sub members {
    my ($self, $path, $query) = @_;
    my $d = $self->call('GET', $path, $query);
    return ref($d) eq 'HASH' ? ($d->{members} // []) : [];
}

sub wsapi_query {
    my ($field, $value) = @_;
    return { query => qq("$field EQ $value") };
}

# Wait for a WSAPI task (online copy, promote).
sub wait_task {
    my ($self, $id, $what) = @_;
    return if !defined($id);
    my $deadline = time() + ($self->{task_timeout} // 3600);
    while (1) {
        my $t = $self->call('GET', "/tasks/$id") // {};
        my $st = $TASK_STATE{$t->{status} // 0} // 'status ' . ($t->{status} // 'unknown');
        return if $st eq 'done';
        die "HPE 3PAR $what: task $id $st" . ($t->{detailedStatus} ? ": $t->{detailedStatus}" : '') . "\n"
            if $st ne 'active';
        die "HPE 3PAR $what: task $id still active after timeout\n" if time() > $deadline;
        sleep($self->{poll_interval} // 5);
    }
}

sub system_info {
    my ($self) = @_;
    my $s = $self->call('GET', '/system') // {};
    return {
        name => $s->{name},
        product => ($s->{model} // q(3PAR)) =~ /^HPE/ ? $s->{model} : q(HPE ) . ($s->{model} // q(3PAR)),
        code_level => $s->{systemVersion},
        id => $s->{serialNumber} // $s->{id},
    };
}

# CPGs grow on demand: capacity is only known when the CPG has a growth
# limit (Cinder get_volume_stats does the same).
sub pools {
    my ($self) = @_;
    return [ map {
        my $c = $_;
        my $limit = ref($c->{SDGrowth}) eq 'HASH' ? $c->{SDGrowth}->{limitMiB} : undef;
        my $used = 0;
        $used += (ref($c->{$_}) eq 'HASH' ? $c->{$_}->{totalMiB} // 0 : 0) for qw(UsrUsage SAUsage SDUsage);
        {
            name => $c->{name},
            status => 'online',
            capacity => defined($limit) ? $limit * $MIB : undef,
            free => defined($limit) ? ($limit - $used) * $MIB : undef,
        }
    } @{$self->members('/cpgs')} ];
}

sub host_sets {
    my ($self) = @_;
    return $self->members('/hostsets');
}

sub host_clusters {
    my ($self) = @_;
    return [ map { { id => $_->{id}, name => $_->{name} } } @{$self->host_sets} ];
}

sub hosts {
    my ($self) = @_;
    my %in;
    for my $s (@{$self->host_sets}) { $in{$_} //= $s->{name} for @{$s->{setmembers} // []}; }
    return [ map {
        my $h = $_;
        {
            id => $h->{name},
            name => $h->{name},
            hostcluster => $in{$h->{name}},
            wwpns => [ sort grep { defined } map { PVE::SAN::Array::Base::norm_wwpn($_->{wwn}) } @{$h->{FCPaths} // []} ],
        }
    } @{$self->members('/hosts')} ];
}

sub create_hostcluster {
    my ($self, $name) = @_;
    $self->call('POST', '/hostsets', undef, { name => $name });
}

sub create_host {
    my ($self, $name, $wwpns) = @_;
    $self->call('POST', '/hosts', undef, { name => $name, FCWWNs => [ @$wwpns ], persona => $PERSONA_GENERIC_ALUA });
    return { id => $name, name => $name, hostcluster => undef, wwpns => [ @$wwpns ] };
}

sub add_host_ports {
    my ($self, $host, $wwpns) = @_;
    $self->call('PUT', "/hosts/$host->{name}", undef, { pathOperation => $HOST_EDIT_ADD, FCWWNs => [ @$wwpns ] });
}

sub add_to_hostcluster {
    my ($self, $hcname, $host) = @_;
    $self->call('PUT', "/hostsets/$hcname", undef, { action => $SET_MEM_ADD, setmembers => [ $host->{name} ] });
}

sub remove_host {
    my ($self, $host, $hcname) = @_;
    $self->call('PUT', "/hostsets/$hcname", undef, { action => $SET_MEM_REMOVE, setmembers => [ $host->{name} ] })
        if ($host->{hostcluster} // '') eq $hcname;
    $self->call('DELETE', "/hosts/$host->{name}");
}

sub target_ports {
    my ($self) = @_;
    return [ sort grep { defined } map { PVE::SAN::Array::Base::norm_wwpn($_->{portWWN}) }
        grep { ($_->{protocol} // 0) == 1 && ($_->{mode} // 0) == 2 && ($_->{linkState} // 0) == 4 }
        @{$self->members('/ports')} ];
}

sub volume_from {
    my ($v) = @_;
    return {
        id => $v->{name},
        name => $v->{name},
        pool => $v->{userCPG},
        capacity => defined($v->{sizeMiB}) ? $v->{sizeMiB} * $MIB : undef,
        uid => $v->{wwn},
        wwid => PVE::SAN::Array::Base::naa_to_wwid($v->{wwn}),
    };
}

sub volume {
    my ($self, $id) = @_;
    return volume_from($self->call('GET', "/volumes/$id"));
}

sub find_volume_by_wwid {
    my ($self, $wwid) = @_;
    return undef if ($wwid // '') !~ /^3(6[0-9a-f]{31})$/;
    my ($v) = @{$self->members('/volumes', wsapi_query('wwn', uc($1)))};
    return $v ? volume_from($v) : undef;
}

sub create_volume {
    my ($self, %p) = @_;
    die "invalid volume name '$p{name}' (at most 31 letters, digits, '_', '.', '-')\n" if !$self->valid_name($p{name});
    die "size must be a whole number of GiB\n" if $p{size_gib} !~ /^\d+$/ || $p{size_gib} < 1;
    die "no CPG given\n" if !defined($p{pool}) || !length($p{pool});
    # Primera and Alletra only have thin volumes; tpvv: false is a full
    # volume on 3PAR StoreServ and refused there.
    my $thin = defined($p{thin}) ? $p{thin} : 1;
    $self->call('POST', '/volumes', undef, {
        name => $p{name},
        cpg => $p{pool},
        sizeMiB => $p{size_gib} * 1024,
        tpvv => $thin ? JSON::PP::true : JSON::PP::false,
    });
    return $self->volume($p{name});
}

# The host set's VLUN template(s) of a volume (not the per-path active VLUNs).
sub set_vluns {
    my ($self, $vol, $hcname) = @_;
    return [ grep { ($_->{hostname} // '') eq "set:$hcname" && !$_->{active} }
        @{$self->members('/vluns', wsapi_query('volumeName', $vol))} ];
}

sub map_to_hostcluster {
    my ($self, $vol, $hcname) = @_;
    return if @{$self->set_vluns($vol, $hcname)};
    $self->call('POST', '/vluns', undef, {
        volumeName => $vol,
        lun => 0,
        autoLun => JSON::PP::true,
        maxAutoLun => 0,
        hostname => "set:$hcname",
    });
}

sub unmap_from_hostcluster {
    my ($self, $vol, $hcname) = @_;
    my %seen;
    for my $l (grep { !$seen{$_->{lun}}++ } @{$self->set_vluns($vol, $hcname)}) {
        $self->call('DELETE', "/vluns/$vol,$l->{lun},set:$hcname");
    }
}

sub expand_volume {
    my ($self, $vol, $add_bytes) = @_;
    die "expansion must be a positive multiple of 1 MiB\n" if $add_bytes <= 0 || $add_bytes % $MIB;
    $self->call('PUT', "/volumes/$vol", undef, { action => $GROW_VOLUME, sizeMiB => int($add_bytes / $MIB) });
}

# Take the volume out of the volume sets pvesan made for group snapshots
# first (an empty set is removed).
sub delete_volume {
    my ($self, $vol) = @_;
    for my $s (@{$self->members('/volumesets')}) {
        next if ($s->{name} // '') !~ /^pvesan-/ || !grep { $_ eq $vol } @{$s->{setmembers} // []};
        if (@{$s->{setmembers}} == 1) {
            $self->call('DELETE', "/volumesets/$s->{name}");
        } else {
            $self->call('PUT', "/volumesets/$s->{name}", undef, { action => $SET_MEM_REMOVE, setmembers => [ $vol ] });
        }
    }
    $self->call('DELETE', "/volumes/$vol");
}

# --- snapshots ---

sub supports_snapshots { return 1; }
sub supports_group_snapshots { return 1; }

sub snapshot_from {
    my ($v) = @_;
    my $c = PVE::SAN::Array::Base::decode($v->{comment});
    return undef if ref($c) ne 'HASH' || !defined($c->{pvesan});
    return {
        id => $v->{name},
        name => $c->{pvesan},
        volume => $v->{copyOf},
        created => $v->{creationTimeSec},
        size => defined($v->{sizeMiB}) ? $v->{sizeMiB} * $MIB : undef,
    };
}

sub snapshots {
    my ($self, $vols) = @_;
    my @res;
    for my $vol (@$vols) {
        push @res, grep { defined } map { snapshot_from($_) }
            grep { ($_->{copyType} // 0) == $VIRTUAL_COPY && ($_->{copyOf} // '') eq $vol }
            @{$self->members('/volumes', wsapi_query('copyOf', $vol))};
    }
    return [ sort { ($a->{created} // 0) <=> ($b->{created} // 0) || $a->{id} cmp $b->{id} } @res ];
}

# Short array name for a virtual copy: <volume (18)>.<epoch hex>, with
# "-<n>" appended per member of a volume set snapshot (at most 31).
sub snapshot_base {
    my ($self, $vol) = @_;
    return sprintf('%s.%x', substr($vol, 0, 18), $self->{now} // time());
}

sub vset_name {
    my ($self, $vols) = @_;
    return substr("pvesan-$vols->[0]", 0, $self->max_set_name_length);
}

sub ensure_vset {
    my ($self, $vols) = @_;
    my $name = $self->vset_name($vols);
    my $s = $self->get_optional("/volumesets/$name");
    if (!$s) {
        print "creating volume set '$name'\n";
        $self->call('POST', '/volumesets', undef, { name => $name, setmembers => [ @$vols ] });
        return $name;
    }
    my %in = map { $_ => 1 } @{$s->{setmembers} // []};
    my @add = grep { !$in{$_} } @$vols;
    if (@add) {
        print "adding @add to volume set '$name'\n";
        $self->call('PUT', "/volumesets/$name", undef, { action => $SET_MEM_ADD, setmembers => \@add });
    }
    return $name;
}

sub snapshot_create {
    my ($self, $vols, $name) = @_;
    $self->check_snapshot_args($vols, $name);
    my $params = {
        comment => PVE::SAN::Array::Base::json()->encode({ pvesan => $name }),
        readOnly => JSON::PP::false,
    };
    my $base = $self->snapshot_base($vols->[0]);
    if (@$vols > 1) {
        my $set = $self->ensure_vset($vols);
        $self->call('POST', "/volumesets/$set", undef,
            { action => 'createSnapshot', parameters => { %$params, name => "$base-\@count\@" } });
    } else {
        $self->call('POST', "/volumes/$vols->[0]", undef,
            { action => 'createSnapshot', parameters => { %$params, name => $base } });
    }
    return [ grep { $_->{name} eq $name } @{$self->snapshots($vols)} ];
}

sub snapshot_delete {
    my ($self, $snap) = @_;
    $self->call('DELETE', "/volumes/$snap->{id}");
}

# Online physical copy: the new volume is usable at once while the array
# copies the data in the background.
sub snapshot_clone {
    my ($self, $snap, $name) = @_;
    die "invalid volume name '$name' (at most 31 letters, digits, '_', '.', '-')\n" if !$self->valid_name($name);
    my $cpg = $self->volume($snap->{volume})->{pool} // die "HPE 3PAR: no CPG for volume '$snap->{volume}'\n";
    $self->call('POST', "/volumes/$snap->{id}", undef, {
        action => 'createPhysicalCopy',
        parameters => { destVolume => $name, destCPG => $cpg, online => JSON::PP::true, tpvv => JSON::PP::true },
    });
    return $self->volume($name);
}

# Promote the virtual copy onto its base volume. 'online' lets it run while
# the volume is still exported (pvesan has taken it out of use on every node).
sub snapshot_restore {
    my ($self, $vol, $snap) = @_;
    die "snapshot '$snap->{id}' is not of volume '$vol'\n" if ($snap->{volume} // '') ne $vol;
    my $r = $self->call('PUT', "/volumes/$snap->{id}", undef, { action => $PROMOTE_VIRTUAL_COPY, online => JSON::PP::true });
    $self->wait_task(ref($r) eq 'HASH' ? $r->{taskid} : undef, "promoting '$snap->{id}' onto '$vol'");
}

1;
