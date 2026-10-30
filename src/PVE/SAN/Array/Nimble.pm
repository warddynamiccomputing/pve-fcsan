package PVE::SAN::Array::Nimble;

# Driver for HPE Alletra 5000 / 6000 and Nimble Storage arrays through the
# NimOS REST API (port 5392, /v1).
#
# Checked against HPE's nimble-python-sdk (nimbleclient/v1/restclient.py,
# client.py, api/volumes.py, initiator_groups.py, initiators.py,
# access_control_records.py, snapshots.py, volume_collections.py,
# snapshot_collections.py, pools.py, groups.py, arrays.py) and OpenStack
# Cinder's driver (cinder/volume/drivers/hpe/nimble.py, NimbleRestAPIExecutor):
#   login      POST /v1/tokens {data: {username, password, app_name}}
#              -> data.session_token, sent as X-Auth-Token; an expired
#              session answers SM_http_unauthorized, then log in again
#   bodies     every POST / PUT body is {data: {...}}; replies are {data};
#              errors are {messages: [{code, severity, text}]}
#   lists      GET /v1/<objects>/detail?<attr>=<value>, paged with startRow
#              until endRow = totalRows
#   jobs       HTTP 202 with messages[0].code SM_async_job_id: poll
#              GET /v1/jobs/<job_id> until state "done"
#   igroup     POST /v1/initiator_groups {name, access_protocol fc,
#              fc_initiators [{wwpn}]}; POST /v1/initiators {access_protocol,
#              initiator_group_id, wwpn}
#   volume     POST /v1/volumes {name, size (MiB), pool_id, reserve, online};
#              PUT /v1/volumes/<id> {size}; delete: PUT {online false,
#              force true}, then DELETE /v1/volumes/<id>
#   map        POST /v1/access_control_records {apply_to both, vol_id,
#              initiator_group_id}; unmap DELETE /v1/access_control_records/<id>
#   snapshots  POST /v1/snapshots {name, vol_id}; delete: PUT
#              /v1/snapshots/<id> {online false}, then DELETE
#   groups     POST /v1/volume_collections {name, description}; PUT
#              /v1/volumes/<id> {volcoll_id}; POST /v1/snapshot_collections
#              {name, volcoll_id}; DELETE /v1/snapshot_collections/<id>;
#              DELETE /v1/volume_collections/<id>
#   clone      POST /v1/volumes {name, clone true, base_snap_id, online,
#              inherit_acl false}
#   restore    PUT {online false, force true}, POST
#              /v1/volumes/<id>/actions/restore {id, base_snap_id}, PUT
#              {online true}
#
# The cluster is one FC initiator group holding every node's WWPNs (like
# ONTAP's igroup). Volume sizes are in MiB; volumes are thin with reserve 0,
# thick with reserve 100 (as Cinder does).
#
# Multipath WWID: 2 + serial_number. The serial is the volume's EUI-64
# designator (vpd_ieee0 + vpd_ieee1, with Nimble's OUI 6c9ce9), and Linux
# prefixes the EUI-64 id type 2. HPE's common-host-libs (linux/device.go)
# strips that one character from the dm UUID and compares the rest with the
# NimOS serial_number; Cinder's driver does not use the WWID.

use strict;
use warnings;

use JSON::PP ();

use base qw(PVE::SAN::Array::Base);

our $MIB = 1024 * 1024;

sub description { return 'HPE Alletra 5000/6000 (Nimble)'; }
sub default_port { return 5392; }

# multipath-tools queues I/O on these LUNs forever when all paths are gone
sub default_no_path_retry { return 12; }

# letters, digits, '-' and '.'
sub valid_name {
    my ($class, $name) = @_;
    return defined($name) && length($name) <= 63 && $name =~ /^[A-Za-z][A-Za-z0-9.-]*$/;
}

sub object_name_for {
    my ($class, $name) = @_;
    $name =~ s/[^A-Za-z0-9.-]/-/g;
    $name = "pve-$name" if $name !~ /^[A-Za-z]/;
    return substr($name, 0, 59);
}

*short = \&PVE::SAN::Array::Base::short;

sub error_text {
    my ($content) = @_;
    my $d = PVE::SAN::Array::Base::decode($content);
    if (ref($d) eq 'HASH' && ref($d->{messages}) eq 'ARRAY') {
        my @m = grep { length } map { join(': ', grep { defined && length } $_->{code}, $_->{text}) }
            grep { ref($_) eq 'HASH' } @{$d->{messages}};
        return join('; ', @m) if @m;
    }
    return short($content);
}

sub login {
    my ($self) = @_;
    my ($code, $content) = $self->request('POST', '/v1/tokens', {},
        { data => { username => $self->{username}, password => $self->{password}, app_name => 'pve-fcsan' } });
    die "Nimble login to $self->{address} failed (HTTP $code): " . error_text($content) . "\n"
        if $code != 200 && $code != 201;
    my $d = PVE::SAN::Array::Base::decode($content);
    $self->{token} = (ref($d) eq 'HASH' && ref($d->{data}) eq 'HASH' ? $d->{data}->{session_token} : undef)
        // die "Nimble login: no session token in response\n";
}

sub unauthorized {
    my ($code, $content) = @_;
    return $code == 401 || ($code >= 400 && ($content // '') =~ /SM_http_unauthorized/);
}

# One HTTP request with the session token; logs in again once when the
# session has expired. Returns (code, content).
sub send_request {
    my ($self, $method, $url, $body) = @_;
    $self->login() if !$self->{token};
    my ($code, $content);
    for my $attempt (1, 2) {
        ($code, $content) = $self->request($method, $url, { 'X-Auth-Token' => $self->{token} },
            defined($body) ? { data => $body } : undef);
        last if !unauthorized($code, $content) || $attempt == 2;
        $self->login();
    }
    return ($code, $content);
}

# Returns the decoded reply ('data' unwrapped), after waiting for an
# asynchronous job.
sub call {
    my ($self, $method, $path, $query, $body) = @_;
    my ($code, $content) = $self->send_request($method, "/v1$path" . PVE::SAN::Array::Base::query_string($query), $body);
    die "Nimble $method $path failed (HTTP $code): " . error_text($content) . "\n" if $code < 200 || $code >= 300;
    my $d = PVE::SAN::Array::Base::decode($content);
    if ($code == 202 && ref($d) eq 'HASH' && ref($d->{messages}) eq 'ARRAY') {
        my ($m) = grep { ref($_) eq 'HASH' && ($_->{code} // '') eq 'SM_async_job_id' } @{$d->{messages}};
        if ($m) {
            $self->wait_job((ref($m->{arguments}) eq 'HASH' ? $m->{arguments}->{job_id} : undef)
                // die "Nimble: asynchronous job without job_id\n");
            return undef;
        }
    }
    return ref($d) eq 'HASH' && exists($d->{data}) ? $d->{data} : $d;
}

sub wait_job {
    my ($self, $id) = @_;
    for (1 .. 300) {
        my $j = $self->call('GET', "/jobs/$id") // {};
        return $j if ($j->{state} // '') eq 'done';
        sleep(2);
    }
    die "Nimble job $id did not finish in 10 minutes\n";
}

# Every record of a list, all pages.
sub records {
    my ($self, $path, $query) = @_;
    my @res;
    for (1 .. 1000) {
        my %q = (%{$query // {}}, @res ? (startRow => scalar(@res)) : ());
        my ($code, $content) = $self->send_request('GET', "/v1$path" . PVE::SAN::Array::Base::query_string(\%q), undef);
        die "Nimble GET $path failed (HTTP $code): " . error_text($content) . "\n" if $code < 200 || $code >= 300;
        my $d = PVE::SAN::Array::Base::decode($content);
        $d = {} if ref($d) ne 'HASH';
        my $page = ref($d->{data}) eq 'ARRAY' ? $d->{data} : [];
        push @res, @$page;
        last if !@$page || !defined($d->{totalRows}) || ($d->{endRow} // 0) >= $d->{totalRows};
    }
    return \@res;
}

sub system_info {
    my ($self) = @_;
    my ($g) = @{$self->records('/groups/detail')};
    $g //= {};
    my @models = map { $_->{extended_model} // $_->{model} }
        grep { $_->{model} || $_->{extended_model} } @{(eval { $self->records('/arrays/detail') }) // []};
    return {
        name => $g->{name},
        product => 'HPE Alletra 5000/6000 (Nimble)' . (@models ? ' ' . join(', ', @models) : ''),
        code_level => $g->{version_current},
        id => $g->{id},
    };
}

sub pools {
    my ($self) = @_;
    return [ map {
        { name => $_->{name}, id => $_->{id}, status => 'online', capacity => $_->{capacity}, free => $_->{free_space} }
    } @{$self->records('/pools/detail')} ];
}

# --- cluster registration: one FC initiator group ---

sub igroups {
    my ($self, $name) = @_;
    return $self->records('/initiator_groups/detail', defined($name) ? { name => $name } : undef);
}

sub igroup {
    my ($self, $name) = @_;
    my ($g) = grep { $_->{name} eq $name } @{$self->igroups($name)};
    return $g;
}

sub igroup_wwpns {
    my ($g) = @_;
    return [ sort grep { defined } map { PVE::SAN::Array::Base::norm_wwpn($_->{wwpn}) } @{$g->{fc_initiators} // []} ];
}

sub fc_igroups {
    my ($self) = @_;
    return [ grep { ($_->{access_protocol} // 'fc') eq 'fc' } @{$self->igroups()} ];
}

sub host_clusters {
    my ($self) = @_;
    return [ map { { id => $_->{id}, name => $_->{name} } } @{$self->fc_igroups} ];
}

# Each FC initiator group is one "host" in the group of the same name, so
# every node whose ports are in the cluster's group shows as registered.
sub hosts {
    my ($self) = @_;
    return [ map { { id => $_->{id}, name => $_->{name}, hostcluster => $_->{name}, wwpns => igroup_wwpns($_) } }
        @{$self->fc_igroups} ];
}

sub ensure_hostcluster {
    my ($self, $hcname, $node_wwpns, $log) = @_;
    $log //= sub { print "$_[0]\n" };

    die "invalid initiator group name '$hcname'\n" if !$self->valid_hostcluster_name($hcname);

    my %want; # WWPN => node
    for my $node (sort keys %$node_wwpns) {
        my @w = grep { defined } map { PVE::SAN::Array::Base::norm_wwpn($_) } @{$node_wwpns->{$node}};
        die "node '$node' has no FC ports\n" if !@w;
        $want{$_} = $node for @w;
    }

    my %result = map { $_ => { host => "initiator group $hcname", created => 0, added_ports => [], joined => 0 } } keys %$node_wwpns;

    # ports already in another group: an admin decision on the array
    my (%elsewhere, $g);
    for my $ig (@{$self->igroups()}) {
        if ($ig->{name} eq $hcname) { $g = $ig; next; }
        $elsewhere{$_} = $ig->{name} for grep { $want{$_} } @{igroup_wwpns($ig)};
    }
    die "WWPN(s) " . join(', ', map { "$_ ($elsewhere{$_})" } sort keys %elsewhere)
        . " already in other initiator groups - remove them there first\n" if %elsewhere;

    if (!$g) {
        $log->("creating FC initiator group '$hcname' with " . scalar(keys %want) . " initiators");
        $self->call('POST', '/initiator_groups', undef, {
            name => $hcname,
            access_protocol => 'fc',
            fc_initiators => [ map { { wwpn => PVE::SAN::Array::Base::colon_wwpn($_) } } sort keys %want ],
        });
        $_->{joined} = 1 for values %result;
        return \%result;
    }

    die "initiator group '$hcname' exists with access protocol '$g->{access_protocol}', not fc\n"
        if ($g->{access_protocol} // 'fc') ne 'fc';
    my %have = map { $_ => 1 } @{igroup_wwpns($g)};
    for my $w (sort grep { !$have{$_} } keys %want) {
        $log->("adding initiator $w to initiator group '$hcname'");
        $self->call('POST', '/initiators', undef,
            { access_protocol => 'fc', initiator_group_id => $g->{id}, wwpn => PVE::SAN::Array::Base::colon_wwpn($w) });
        push @{$result{$want{$w}}->{added_ports}}, $w;
    }
    return \%result;
}

# --- volumes (id = NimOS volume ID) ---

sub serial_to_wwid {
    my ($serial) = @_;
    my $s = lc($serial // '');
    return $s =~ /^[0-9a-f]{32}$/ ? "2$s" : undef;
}

sub wwid_to_serial {
    my ($wwid) = @_;
    return lc($wwid // '') =~ /^2([0-9a-f]{32})$/ ? $1 : undef;
}

sub volume_from {
    my ($v) = @_;
    return {
        id => $v->{id},
        name => $v->{name},
        pool => $v->{pool_name},
        capacity => defined($v->{size}) ? $v->{size} * $MIB : undef,
        uid => $v->{serial_number},
        wwid => serial_to_wwid($v->{serial_number}),
        volcoll_id => $v->{volcoll_id} || undef,
        volcoll_name => $v->{volcoll_name} || undef,
    };
}

sub volume_raw {
    my ($self, $id) = @_;
    my $v = $self->call('GET', "/volumes/$id");
    die "Nimble volume $id not found\n" if ref($v) ne 'HASH' || !$v->{id};
    return $v;
}

sub volume {
    my ($self, $id) = @_;
    return volume_from($self->volume_raw($id));
}

sub volume_by_name_raw {
    my ($self, $name) = @_;
    my ($v) = grep { $_->{name} eq $name } @{$self->records('/volumes/detail', { name => $name })};
    return $v;
}

sub find_volume_by_wwid {
    my ($self, $wwid) = @_;
    my $serial = wwid_to_serial($wwid) // return undef;
    my ($v) = grep { lc($_->{serial_number} // '') eq $serial }
        @{$self->records('/volumes/detail', { serial_number => $serial })};
    return $v ? volume_from($v) : undef;
}

# written = uncompressed data in the volume, reduction = its compression
sub volume_space {
    my ($self, $ids) = @_;
    return [ map {
        my $v = $self->volume_raw($_);
        my ($u, $c) = @$v{qw(vol_usage_uncompressed_bytes vol_usage_compressed_bytes)};
        {
            id => $_,
            provisioned => defined($v->{size}) ? $v->{size} * $MIB : undef,
            written => $u,
            reduction => ($u && $c) ? $u / $c : undef,
        }
    } @$ids ];
}

sub pool_id {
    my ($self, $name) = @_;
    my ($p) = grep { $_->{name} eq $name } @{$self->pools()};
    die "Nimble pool '$name' not found\n" if !$p;
    return $p->{id};
}

sub create_volume {
    my ($self, %p) = @_;
    die "invalid Nimble volume name '$p{name}' (letters, digits, '-', '.')\n" if !$self->valid_name($p{name});
    die "size must be a whole number of GiB\n" if $p{size_gib} !~ /^\d+$/ || $p{size_gib} < 1;
    my $r = $self->call('POST', '/volumes', undef, {
        name => $p{name},
        size => $p{size_gib} * 1024,
        pool_id => $self->pool_id($p{pool}),
        reserve => $p{thin} ? 0 : 100,
        online => JSON::PP::true,
    });
    my $v = (ref($r) eq 'HASH' && $r->{id}) ? $r : $self->volume_by_name_raw($p{name});
    die "Nimble: volume '$p{name}' not found after creation\n" if !$v;
    return volume_from($v);
}

sub igroup_id {
    my ($self, $hcname) = @_;
    my $g = $self->igroup($hcname) // die "Nimble initiator group '$hcname' not found\n";
    return $g->{id};
}

sub map_to_hostcluster {
    my ($self, $vol, $hcname) = @_;
    $self->call('POST', '/access_control_records', undef,
        { apply_to => 'both', vol_id => $vol, initiator_group_id => $self->igroup_id($hcname) });
}

sub unmap_from_hostcluster {
    my ($self, $vol, $hcname) = @_;
    my $gid = $self->igroup_id($hcname);
    my @acr = grep { ($_->{vol_id} // '') eq $vol && ($_->{initiator_group_id} // '') eq $gid }
        @{$self->records('/access_control_records/detail', { vol_id => $vol, initiator_group_id => $gid })};
    $self->call('DELETE', "/access_control_records/$_->{id}", undef, undef) for @acr;
}

sub expand_volume {
    my ($self, $vol, $add_bytes) = @_;
    die "expansion must be a positive multiple of 1 MiB\n" if $add_bytes <= 0 || $add_bytes % $MIB;
    my $cur = $self->volume($vol);
    $self->call('PUT', "/volumes/$vol", undef, { size => ($cur->{capacity} + $add_bytes) / $MIB });
}

sub set_online {
    my ($self, $vol, $online) = @_;
    eval {
        $self->call('PUT', "/volumes/$vol", undef,
            { online => $online ? JSON::PP::true : JSON::PP::false, $online ? () : (force => JSON::PP::true) });
    };
    die $@ if $@ && $@ !~ /already in requested state/;
}

# NimOS deletes only offline volumes. A volume collection pvesan made for
# the datastore goes with its last volume.
sub delete_volume {
    my ($self, $vol) = @_;
    my $cur = $self->volume($vol);
    $self->set_online($vol, 0);
    $self->call('DELETE', "/volumes/$vol", undef, undef);
    if ($cur->{volcoll_id} && ($cur->{volcoll_name} // '') =~ /^pvesan-/) {
        my $vc = eval { $self->call('GET', "/volume_collections/$cur->{volcoll_id}") };
        if (ref($vc) eq 'HASH' && !@{$vc->{volume_list} // []} && !$vc->{volume_count}) {
            print "deleting volume collection '$cur->{volcoll_name}'\n";
            $self->call('DELETE', "/volume_collections/$cur->{volcoll_id}", undef, undef);
        }
    }
}

# --- snapshots ---
#
# A volume's own snapshot is named like the pvesan snapshot. Datastores on
# several volumes put them in a volume collection "pvesan-<first volume
# name>" and take a snapshot collection of it: one point in time for all
# members, deleted as a whole. Snapshots taken by the array's protection
# schedules and incoming replicas are not listed.

sub supports_snapshots { return 1; }
sub supports_group_snapshots { return 1; }

sub snapshot_from {
    my ($s) = @_;
    my $group = $s->{snap_collection_id};
    return {
        id => $s->{id},
        name => ($group && $s->{snap_collection_name}) ? $s->{snap_collection_name} : $s->{name},
        volume => $s->{vol_id},
        created => $s->{creation_time},
        size => $s->{size},
        ($group ? (group => $group) : ()),
    };
}

sub snapshots {
    my ($self, $vols) = @_;
    my @res;
    for my $vol (@$vols) {
        push @res, map { snapshot_from($_) }
            grep { !$_->{schedule_name} && !$_->{schedule_id} && !$_->{is_replica} && ($_->{vol_id} // '') eq $vol }
            @{$self->records('/snapshots/detail', { vol_id => $vol })};
    }
    return [ sort { ($a->{created} // 0) <=> ($b->{created} // 0) } @res ];
}

sub volcoll_name {
    my ($self, $vols) = @_;
    return substr('pvesan-' . $self->volume($vols->[0])->{name}, 0, 63);
}

sub volcoll_by_name {
    my ($self, $name) = @_;
    my ($vc) = grep { $_->{name} eq $name } @{$self->records('/volume_collections/detail', { name => $name })};
    return $vc;
}

sub ensure_volcoll {
    my ($self, $vols) = @_;
    my $name = $self->volcoll_name($vols);
    my $vc = $self->volcoll_by_name($name);
    my @members = map { $self->volume($_) } @$vols;
    for my $v (grep { $_->{volcoll_id} && !($vc && $_->{volcoll_id} eq $vc->{id}) } @members) {
        die "Nimble volume '$v->{name}' is already in volume collection '" . ($v->{volcoll_name} // $v->{volcoll_id})
            . "' - a volume can be in one collection only\n";
    }
    if (!$vc) {
        print "creating volume collection '$name'\n";
        $vc = $self->call('POST', '/volume_collections', undef, { name => $name, description => 'pve-fcsan datastore' });
        $vc = $self->volcoll_by_name($name) if ref($vc) ne 'HASH' || !$vc->{id};
        die "Nimble: volume collection '$name' not found after creation\n" if !$vc;
    }
    for my $v (grep { ($_->{volcoll_id} // '') ne $vc->{id} } @members) {
        print "adding volume '$v->{name}' to volume collection '$name'\n";
        $self->call('PUT', "/volumes/$v->{id}", undef, { volcoll_id => $vc->{id} });
    }
    return $vc->{id};
}

sub snapshot_create {
    my ($self, $vols, $name) = @_;
    $self->check_snapshot_args($vols, $name);
    die "a snapshot '$name' already exists\n" if grep { $_->{name} eq $name } @{$self->snapshots($vols)};
    if (@$vols > 1) {
        my $vc = $self->ensure_volcoll($vols);
        $self->call('POST', '/snapshot_collections', undef, { name => $name, volcoll_id => $vc });
        return [ grep { $_->{name} eq $name && $_->{group} } @{$self->snapshots($vols)} ];
    }
    $self->call('POST', '/snapshots', undef, { name => $name, vol_id => $vols->[0] });
    return [ grep { $_->{name} eq $name && !$_->{group} } @{$self->snapshots($vols)} ];
}

# A snapshot collection goes as a whole.
sub snapshot_delete {
    my ($self, $snap) = @_;
    if ($snap->{group}) {
        $self->call('DELETE', "/snapshot_collections/$snap->{group}", undef, undef);
        return;
    }
    $self->call('PUT', "/snapshots/$snap->{id}", undef, { online => JSON::PP::false });
    $self->call('DELETE', "/snapshots/$snap->{id}", undef, undef);
}

# A clone gets its own serial number and none of the parent's access
# control records.
sub snapshot_clone {
    my ($self, $snap, $name) = @_;
    die "invalid Nimble volume name '$name' (letters, digits, '-', '.')\n" if !$self->valid_name($name);
    my $r = $self->call('POST', '/volumes', undef, {
        name => $name,
        clone => JSON::PP::true,
        base_snap_id => $snap->{id},
        online => JSON::PP::true,
        inherit_acl => JSON::PP::false,
    });
    my $v = (ref($r) eq 'HASH' && $r->{id}) ? $r : $self->volume_by_name_raw($name);
    die "Nimble: clone '$name' not found after creation\n" if !$v;
    return volume_from($v);
}

# The volume is offline during the restore and online again afterwards,
# also when the restore fails. Each member of a set restores its own volume.
sub snapshot_restore {
    my ($self, $vol, $snap) = @_;
    $self->set_online($vol, 0);
    eval { $self->call('POST', "/volumes/$vol/actions/restore", undef, { id => $vol, base_snap_id => $snap->{id} }) };
    if (my $err = $@) {
        eval { $self->set_online($vol, 1) };
        die $err;
    }
    $self->set_online($vol, 1);
}

1;
