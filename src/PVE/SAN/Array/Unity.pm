package PVE::SAN::Array::Unity;

# Driver for Dell Unity XT (and Unity) through the Unisphere Management REST
# API (UnityOS 4.2 or later for thin clones).
#
# Checked against Dell's storops (storops/connection/connector.py,
# storops/unity/client.py, resp.py, enums.py, resource/lun.py, host.py,
# snap.py, cg.py, lib/thinclone_helper.py before 1.2.13, and the request /
# response fixtures in storops_test/unity/rest_data) and OpenStack Cinder's
# Unity driver (cinder/volume/drivers/dell_emc/unity/client.py, adapter.py,
# utils.py):
#   auth       HTTP Basic on every request plus "X-EMC-REST-CLIENT: true";
#              GET /api/types/user/instances returns the EMC-CSRF-TOKEN
#              header (and the session cookie) that POST and DELETE need;
#              401 on a write -> fetch a new token and retry
#   lists      GET /api/types/<type>/instances?fields=...&filter=...&compact=true
#              -> {entries: [{content}], links: [{rel: next, href: "&page=N"}]}
#   instance   GET /api/instances/<type>/<id>?fields=... -> {content}
#   errors     {error: {errorCode, httpStatusCode, messages: [{"en-US"}]}}
#   pools      pool {id, name, sizeTotal, sizeFree, health}
#   hosts      POST /api/types/host/instances {type: 1 (manual), name, osType}
#              hostInitiator {id, type (1 = FC), initiatorId, nodeWWN, portWWN,
#              parentHost}; POST /api/types/hostInitiator/instances {host,
#              initiatorType: 1, initiatorWWNorIqn: "WWNN:WWPN"}; an initiator
#              the array already knows (logged in) is moved with
#              POST /api/instances/hostInitiator/<id>/action/modify {host}
#   LUN        POST /api/types/storageResource/action/createLun {name,
#              lunParameters: {pool, size, isThinEnabled}} -> {storageResource}
#              lun {id, name, sizeTotal, sizeAllocated, wwn, isThinEnabled,
#              storageResource, hostAccess: [{host, accessMask}]}
#              POST /api/instances/storageResource/<lun>/action/modifyLun
#              {lunParameters: {size | hostAccess: [{host, accessMask: 1}]}}
#              DELETE /api/instances/storageResource/<id> {forceSnapDeletion}
#   CG         POST /api/types/storageResource/action/createConsistencyGroup
#              {name, lunAdd: [{lun}]}; .../<cg>/action/modifyConsistencyGroup
#              {lunAdd | lunRemove | lunModify: [{lun, lunParameters}]} (a
#              member LUN is changed through its group, not with modifyLun)
#   snapshots  POST /api/types/snap/instances {storageResource, name,
#              isAutoDelete: false}; snap {id, name, creationTime, size, lun,
#              snapGroup, storageResource}; DELETE /api/instances/snap/<id>
#              POST /api/instances/snap/<id>/action/restore {} -> {backup}
#   clone      POST /api/instances/storageResource/<lun>/action/createLunThinClone
#              {name, snap} -> {storageResource} (thin LUNs, not CG members)
#
# Mapping model: Unity has no host groups. Every node is one Unity host with
# its FC initiators, and each LUN's host access list names the host of every
# node. The "host cluster" is that set of hosts.
#
# Unity identifies an FC initiator by WWNN:WWPN. pvesan reuses initiators the
# array has already seen log in (zoning done first) and otherwise takes the
# node's WWNN from the node's adapter list.

use strict;
use warnings;

use JSON::PP ();

use base qw(PVE::SAN::Array::Base);

my $GIB = $PVE::SAN::Array::Base::GIB;

my $PRODUCTION = 1; # HostLUNAccessEnum.PRODUCTION
my $HOST_MANUAL = 1; # HostTypeEnum.HOST_MANUAL
my $FC = 1; # HostInitiatorTypeEnum.FC
my $SR_CG = 2; # StorageResourceTypeEnum.CONSISTENCY_GROUP

sub description { return 'Dell Unity XT'; }

sub valid_hostcluster_name {
    my ($class, $name) = @_;
    return defined($name) && length($name); # not an array object
}

*short = \&PVE::SAN::Array::Base::short;

sub error_text {
    my ($content) = @_;
    my $d = PVE::SAN::Array::Base::decode($content);
    if (ref($d) eq 'HASH' && ref($d->{error}) eq 'HASH') {
        my $e = $d->{error};
        my @m = map { $_->{'en-US'} // (values %$_)[0] } grep { ref($_) eq 'HASH' } @{$e->{messages} // []};
        return join('. ', @m) if @m;
        return "error code $e->{errorCode}" if defined($e->{errorCode});
    }
    return short($content);
}

sub headers {
    my ($self, $write) = @_;
    my %h = (Authorization => $self->basic_auth, 'X-EMC-REST-CLIENT' => 'true');
    $h{Cookie} = $self->{cookie} if $self->{cookie};
    $h{'EMC-CSRF-TOKEN'} = $self->{csrf} if $write && $self->{csrf};
    return \%h;
}

sub keep_cookies {
    my ($self, $h) = @_;
    my $set = $h->{'set-cookie'} or return;
    my %c = map { /^\s*([^=;\s]+)=([^;]*)/ ? ($1 => $2) : () } split(/,\s*(?=[^=;,\s]+=)/, $set);
    my %have = map { /^([^=]+)=(.*)$/ ? ($1 => $2) : () } split(/; /, $self->{cookie} // '');
    %have = (%have, %c);
    $self->{cookie} = join('; ', map { "$_=$have{$_}" } sort keys %have) if %have;
}

# The CSRF token belongs to the session the cookie names.
sub login {
    my ($self) = @_;
    delete $self->{cookie};
    my ($code, $content, $h) = $self->request('GET', '/api/types/user/instances?compact=true', $self->headers(0), undef);
    die "Unity login to $self->{address} failed (HTTP $code): " . error_text($content) . "\n" if $code != 200;
    $self->keep_cookies($h);
    $self->{csrf} = $h->{'emc-csrf-token'} // die "Unity login: no EMC-CSRF-TOKEN in response\n";
}

sub call {
    my ($self, $method, $path, $query, $body) = @_;

    my $write = $method ne 'GET';
    $self->login() if $write && !$self->{csrf};
    my $url = $path . PVE::SAN::Array::Base::query_string({ compact => 'true', %{$query // {}} });
    my ($code, $content, $h);
    for my $attempt (1, 2) {
        ($code, $content, $h) = $self->request($method, $url, $self->headers($write), $body);
        $self->keep_cookies($h);
        last if $code != 401 || !$write || $attempt == 2;
        $self->login(); # token expired with the session
    }
    my $d = PVE::SAN::Array::Base::decode($content);
    die "Unity $method $path failed (HTTP $code): " . error_text($content) . "\n"
        if $code < 200 || $code >= 300 || (ref($d) eq 'HASH' && $d->{error});
    return $d;
}

sub instance {
    my ($self, $type, $id, $fields) = @_;
    my $d = $self->call('GET', "/api/instances/$type/" . PVE::SAN::Array::Base::escape($id), { fields => $fields });
    return $d->{content} // {};
}

# All instances of a type, following the next-page links.
sub list {
    my ($self, $type, $fields, $filter) = @_;
    my (@all, $page);
    while (1) {
        my $d = $self->call('GET', "/api/types/$type/instances",
            { fields => $fields, (defined($filter) ? (filter => $filter) : ()), ($page ? (page => $page) : ()) });
        push @all, map { $_->{content} // {} } @{$d->{entries} // []};
        my ($next) = grep { ($_->{rel} // '') eq 'next' } @{$d->{links} // []};
        my ($n) = (($next // {})->{href} // '') =~ /page=(\d+)/;
        last if !$n || ($page && $n <= $page);
        $page = $n;
    }
    return \@all;
}

sub ref_id { return ref($_[0]) eq 'HASH' ? $_[0]->{id} : undef; }

sub system_info {
    my ($self) = @_;
    my ($s) = @{$self->list('system', 'id,name,model,serialNumber')};
    my ($b) = @{(eval { $self->list('basicSystemInfo', 'id,model,name,softwareVersion') }) // []};
    return {
        name => $s->{name},
        product => 'Dell ' . ($s->{model} // ($b ? $b->{model} : undef) // 'Unity'),
        code_level => $b ? $b->{softwareVersion} : undef,
        id => $s->{serialNumber},
    };
}

sub pools {
    my ($self) = @_;
    return [ map { {
        id => $_->{id}, name => $_->{name}, capacity => $_->{sizeTotal}, free => $_->{sizeFree},
        status => ($_->{health} && ($_->{health}->{value} // 0) == 5) ? 'online' : 'degraded',
    } } @{$self->list('pool', 'id,name,sizeTotal,sizeFree,health')} ];
}

# --- hosts: one Unity host per node ---

sub fc_initiators {
    my ($self) = @_;
    return [ map {
        my $port = $_->{portWWN} // substr($_->{initiatorId} // '', -23);
        { id => $_->{id}, wwpn => PVE::SAN::Array::Base::norm_wwpn($port), host => ref_id($_->{parentHost}) }
    } grep { ($_->{type} // $FC) == $FC } @{$self->list('hostInitiator', 'id,type,initiatorId,nodeWWN,portWWN,parentHost')} ];
}

# { node => [WWPN, ...] } of the cluster; set by ensure_hostcluster or read
# from the nodes.
sub cluster_wwpns {
    my ($self) = @_;
    return $self->{node_wwpns} //= do { require PVE::SAN::Array; PVE::SAN::Array::node_wwpns() };
}

# { WWPN => WWNN } of the cluster's HBA ports
sub cluster_wwnns {
    my ($self) = @_;
    return $self->{node_wwnns} //= do { require PVE::SAN::Array; PVE::SAN::Array::node_wwnns() };
}

sub host_clusters {
    my ($self) = @_;
    my $hc = $self->{hostcluster} // 'pve';
    return [ { name => $hc, id => $hc } ];
}

sub create_hostcluster { } # virtual: the set of the nodes' hosts
sub add_to_hostcluster { }

# Hosts with their FC ports; a host that owns a cluster node's port is in
# the (virtual) host cluster.
sub hosts {
    my ($self) = @_;
    my %ours;
    my $nw = $self->cluster_wwpns;
    $ours{$_} = 1 for grep { defined } map { PVE::SAN::Array::Base::norm_wwpn($_) } map { @{$nw->{$_}} } keys %$nw;
    my %ports;
    for my $i (@{$self->fc_initiators}) {
        push @{$ports{$i->{host}}}, $i->{wwpn} if defined($i->{host}) && $i->{wwpn};
    }
    return [ map {
        my @w = sort @{$ports{$_->{id}} // []};
        { id => $_->{id}, name => $_->{name}, wwpns => \@w,
          hostcluster => (grep { $ours{$_} } @w) ? ($self->{hostcluster} // 'pve') : undef }
    } @{$self->list('host', 'id,name,type')} ];
}

sub ensure_hostcluster {
    my ($self, $hcname, $node_wwpns, $log) = @_;
    $self->{node_wwpns} = $node_wwpns;
    $self->{hostcluster} = $hcname;
    return $self->SUPER::ensure_hostcluster($hcname, $node_wwpns, $log);
}

sub create_host {
    my ($self, $name, $wwpns) = @_;
    my $d = $self->call('POST', '/api/types/host/instances', undef, { type => $HOST_MANUAL, name => $name, osType => 'Linux' });
    my $id = ref_id($d->{content}) // die "Unity: no ID for new host '$name'\n";
    my $host = { id => $id, name => $name, hostcluster => undef, wwpns => [] };
    $self->add_host_ports($host, $wwpns);
    $host->{wwpns} = [ @$wwpns ];
    return $host;
}

sub add_host_ports {
    my ($self, $host, $wwpns) = @_;
    my %known = map { $_->{wwpn} => $_ } grep { $_->{wwpn} } @{$self->fc_initiators};
    my $wwnn = $self->cluster_wwnns;
    for my $w (@$wwpns) {
        if (my $i = $known{$w}) {
            die "Unity initiator $w already belongs to another host\n" if defined($i->{host}) && $i->{host} ne $host->{id};
            next if defined($i->{host});
            $self->call('POST', "/api/instances/hostInitiator/$i->{id}/action/modify", undef, { host => { id => $host->{id} } });
            next;
        }
        my $nn = PVE::SAN::Array::Base::norm_wwpn($wwnn->{$w})
            // die "no WWNN known for port $w - zone it to the Unity so the array sees it log in, then retry\n";
        $self->call('POST', '/api/types/hostInitiator/instances', undef, {
            host => { id => $host->{id} }, initiatorType => $FC,
            initiatorWWNorIqn => uc(PVE::SAN::Array::Base::colon_wwpn($nn) . ':' . PVE::SAN::Array::Base::colon_wwpn($w)),
        });
    }
}

# Unity hosts of the cluster nodes; every node's ports must be registered.
sub cluster_hosts {
    my ($self, $hcname) = @_;
    $self->{hostcluster} = $hcname if defined($hcname);
    my $hosts = $self->hosts;
    my %owner;
    for my $h (@$hosts) { $owner{$_} = $h for @{$h->{wwpns}}; }
    my (%ids, @missing);
    my $nw = $self->cluster_wwpns;
    for my $node (sort keys %$nw) {
        for my $w (grep { defined } map { PVE::SAN::Array::Base::norm_wwpn($_) } @{$nw->{$node}}) {
            if (my $h = $owner{$w}) { $ids{$h->{id}} = $h; } else { push @missing, "$node:$w"; }
        }
    }
    die "WWPNs not registered on the Unity: @missing - register the cluster first\n" if @missing;
    die "no cluster hosts on the Unity\n" if !%ids;
    return [ map { $ids{$_} } sort keys %ids ];
}

# --- volumes (id = LUN ID, e.g. sv_12) ---

my $LUN_FIELDS = 'id,name,sizeTotal,sizeAllocated,wwn,isThinEnabled,pool,storageResource,hostAccess';

sub volume_from {
    my ($l) = @_;
    return {
        id => $l->{id},
        name => $l->{name},
        pool => ref_id($l->{pool}),
        capacity => $l->{sizeTotal},
        uid => $l->{wwn},
        wwid => PVE::SAN::Array::Base::naa_to_wwid($l->{wwn}),
        thin => $l->{isThinEnabled} ? 1 : 0,
        sr => ref_id($l->{storageResource}) // $l->{id},
        access => [ map { { host => ref_id($_->{host}), mask => $_->{accessMask} } } @{$l->{hostAccess} // []} ],
    };
}

sub lun {
    my ($self, $id) = @_;
    return volume_from($self->instance('lun', $id, $LUN_FIELDS));
}

sub volume {
    my ($self, $id) = @_;
    my $v = $self->lun($id);
    delete $v->{$_} for qw(access sr thin);
    return $v;
}

sub volume_space {
    my ($self, $ids) = @_;
    return [ map {
        my $l = $self->instance('lun', $_, 'id,sizeTotal,sizeAllocated');
        { id => $_, provisioned => $l->{sizeTotal}, written => $l->{sizeAllocated} }
    } @$ids ];
}

sub find_volume_by_wwid {
    my ($self, $wwid) = @_;
    for my $l (@{$self->list('lun', 'id,name,sizeTotal,wwn')}) {
        my $v = volume_from($l);
        return $self->volume($v->{id}) if ($v->{wwid} // '') eq $wwid;
    }
    return undef;
}

sub create_volume {
    my ($self, %p) = @_;
    die "invalid Unity LUN name '$p{name}'\n" if !$self->valid_name($p{name});
    die "size must be a whole number of GiB\n" if $p{size_gib} !~ /^\d+$/ || $p{size_gib} < 1;
    my ($pool) = grep { $_->{name} eq $p{pool} || $_->{id} eq $p{pool} } @{$self->pools()};
    die "Unity pool '$p{pool}' not found\n" if !$pool;
    my $d = $self->call('POST', '/api/types/storageResource/action/createLun', undef, {
        name => $p{name},
        lunParameters => {
            pool => { id => $pool->{id} },
            size => $p{size_gib} * $GIB,
            isThinEnabled => (defined($p{thin}) && !$p{thin}) ? JSON::PP::false : JSON::PP::true,
        },
    });
    my $id = ref_id(($d->{content} // {})->{storageResource}) // die "Unity: no ID for new LUN '$p{name}'\n";
    return $self->volume($id);
}

# Change one LUN's parameters, through its consistency group if it has one.
sub modify_lun {
    my ($self, $lun, $params) = @_;
    if ($lun->{sr} ne $lun->{id}) {
        $self->call('POST', "/api/instances/storageResource/$lun->{sr}/action/modifyConsistencyGroup", undef,
            { lunModify => [ { lun => { id => $lun->{id} }, lunParameters => $params } ] });
    } else {
        $self->call('POST', "/api/instances/storageResource/$lun->{id}/action/modifyLun", undef, { lunParameters => $params });
    }
}

sub access_list {
    my ($entries) = @_;
    return [ map { { host => { id => $_->{host} }, accessMask => $_->{mask} + 0 } } @$entries ];
}

sub map_to_hostcluster {
    my ($self, $id, $hcname) = @_;
    my $hosts = $self->cluster_hosts($hcname);
    my $lun = $self->lun($id);
    my %have = map { $_->{host} => 1 } grep { $_->{mask} & $PRODUCTION } @{$lun->{access}};
    my @add = grep { !$have{$_->{id}} } @$hosts;
    return if !@add;
    my %add = map { $_->{id} => 1 } @add;
    my @keep = grep { !$add{$_->{host}} } @{$lun->{access}}; # other hosts as they are
    $self->modify_lun($lun, { hostAccess => access_list([ @keep, map { { host => $_->{id}, mask => $PRODUCTION } } @add ]) });
}

sub unmap_from_hostcluster {
    my ($self, $id, $hcname) = @_;
    my %ours = map { $_->{id} => 1 } @{$self->cluster_hosts($hcname)};
    my $lun = $self->lun($id);
    my @keep = grep { !$ours{$_->{host}} } @{$lun->{access}};
    return if @keep == @{$lun->{access}};
    $self->modify_lun($lun, { hostAccess => access_list(\@keep) });
}

sub expand_volume {
    my ($self, $id, $add_bytes) = @_;
    die "expansion must be a positive multiple of 1 MiB\n" if $add_bytes <= 0 || $add_bytes % (1024 * 1024);
    my $lun = $self->lun($id);
    $self->modify_lun($lun, { size => $lun->{capacity} + $add_bytes });
}

# Snapshots are kept: a LUN that still has some is refused by the array.
sub delete_volume {
    my ($self, $id) = @_;
    my $lun = $self->lun($id);
    if ($lun->{sr} ne $lun->{id}) {
        my $cg = $lun->{sr};
        $self->call('POST', "/api/instances/storageResource/$cg/action/modifyConsistencyGroup", undef,
            { lunRemove => [ { lun => { id => $id } } ] });
        $lun = $self->lun($id);
        my $left = $self->instance('storageResource', $cg, 'id,luns');
        if (!@{$left->{luns} // []}) {
            eval { $self->call('DELETE', "/api/instances/storageResource/$cg", undef, { forceSnapDeletion => JSON::PP::false }) };
            print "warning: empty Unity consistency group $cg not deleted: $@" if $@;
        }
    }
    $self->call('DELETE', "/api/instances/storageResource/$lun->{sr}", undef,
        { forceSnapDeletion => JSON::PP::false, forceVvolDeletion => JSON::PP::false });
}

# --- snapshots ---
#
# One LUN: a snapshot of the LUN, named "<LUN name>.<snapshot>". Several
# LUNs: they are put into a consistency group "pvesan-<first LUN name>"
# whose snapshots ("<group name>.<snapshot>") cover all members at one
# point in time; the member snapshots are the set. Unity cannot thin-clone
# a member snapshot, so copies of multi-LUN snapshots are not offered.

sub supports_snapshots { return 1; }
sub supports_group_snapshots { return 1; }

# "2016-03-01T03:21:38.000Z" -> epoch
sub parse_timestamp {
    my ($ts) = @_;
    my ($y, $mo, $d, $h, $mi, $s) = ($ts // '') =~ /^(\d{4})-(\d\d)-(\d\d)T(\d\d):(\d\d):(\d\d)(?:\.\d+)?Z?$/ or return undef;
    require Time::Local;
    return Time::Local::timegm($s, $mi, $h, $d, $mo - 1, $y);
}

my $SNAP_FIELDS = 'id,name,creationTime,size,lun,snapGroup,storageResource,state';

sub snap_list {
    my ($self, $sr) = @_;
    return $self->list('snap', $SNAP_FIELDS, qq{storageResource eq "$sr"});
}

# pvesan snapshots of one storage resource whose names start with "$prefix."
sub sr_snapshots {
    my ($self, $sr, $prefix, $vols) = @_;
    my %want = map { $_ => 1 } @$vols;
    my $all = $self->snap_list($sr);
    my (%sets, @single);
    for my $s (@$all) {
        next if ref_id($s->{snapGroup}) || ($s->{name} // '') !~ /^\Q$prefix\E\.(.+)$/;
        $sets{$s->{id}} = { %$s, short => $1 };
    }
    my @res;
    for my $s (@$all) {
        my $g = ref_id($s->{snapGroup});
        my $lun = ref_id($s->{lun});
        if (defined($g)) {
            my $set = $sets{$g} or next;
            next if !$want{$lun // ''};
            push @res, { id => $s->{id}, name => $set->{short}, volume => $lun, group => $g,
                created => parse_timestamp($s->{creationTime} // $set->{creationTime}), size => $s->{size} };
        } elsif ($sets{$s->{id}} && $sr eq ($lun // '')) { # a LUN's own snapshot
            push @res, { id => $s->{id}, name => $sets{$s->{id}}->{short}, volume => $lun,
                created => parse_timestamp($s->{creationTime}), size => $s->{size} };
        }
    }
    return \@res;
}

sub snapshots {
    my ($self, $vols) = @_;
    my (%by_sr, %prefix);
    for my $id (@$vols) {
        my $l = $self->lun($id);
        push @{$by_sr{$l->{sr}}}, $id;
        $prefix{$l->{sr}} //= $l->{sr} eq $l->{id} ? $l->{name} : undef;
    }
    my @res;
    for my $sr (sort keys %by_sr) {
        my $p = $prefix{$sr} // $self->instance('storageResource', $sr, 'id,name')->{name};
        push @res, @{$self->sr_snapshots($sr, $p, $by_sr{$sr})};
    }
    return [ sort { ($a->{created} // 0) <=> ($b->{created} // 0) || $a->{volume} cmp $b->{volume} } @res ];
}

# The volumes' consistency group, created or completed as needed.
sub ensure_cg {
    my ($self, $vols) = @_;
    my @luns = map { $self->lun($_) } @$vols;
    my %cgs = map { $_->{sr} => 1 } grep { $_->{sr} ne $_->{id} } @luns;
    die "Unity: the volumes are in different consistency groups (" . join(', ', sort keys %cgs) . ")\n" if keys %cgs > 1;
    my @out = grep { $_->{sr} eq $_->{id} } @luns;
    if (my ($cg) = keys %cgs) {
        if (@out) {
            print "adding " . join(' ', map { $_->{name} } @out) . " to Unity consistency group $cg\n";
            $self->call('POST', "/api/instances/storageResource/$cg/action/modifyConsistencyGroup", undef,
                { lunAdd => [ map { { lun => { id => $_->{id} } } } @out ] });
        }
        return { id => $cg, name => $self->instance('storageResource', $cg, 'id,name')->{name} };
    }
    my $name = substr("pvesan-$luns[0]->{name}", 0, $self->max_name_length);
    print "creating Unity consistency group '$name'\n";
    my $d = $self->call('POST', '/api/types/storageResource/action/createConsistencyGroup', undef,
        { name => $name, lunAdd => [ map { { lun => { id => $_->{id} } } } @luns ] });
    my $id = ref_id(($d->{content} // {})->{storageResource}) // die "Unity: no ID for consistency group '$name'\n";
    return { id => $id, name => $name };
}

sub snapshot_create {
    my ($self, $vols, $name) = @_;
    $self->check_snapshot_args($vols, $name);
    my ($sr, $prefix);
    if (@$vols > 1) {
        my $cg = $self->ensure_cg($vols);
        ($sr, $prefix) = ($cg->{id}, $cg->{name});
    } else {
        my $l = $self->lun($vols->[0]);
        die "Unity LUN '$l->{name}' is in consistency group $l->{sr} - snapshot the whole datastore\n" if $l->{sr} ne $l->{id};
        ($sr, $prefix) = ($l->{id}, $l->{name});
    }
    $self->call('POST', '/api/types/snap/instances', undef,
        { storageResource => { id => $sr }, name => "$prefix.$name", isAutoDelete => JSON::PP::false });
    return [ grep { $_->{name} eq $name } @{$self->sr_snapshots($sr, $prefix, $vols)} ];
}

# A member of a group set goes with its whole set.
sub snapshot_delete {
    my ($self, $snap) = @_;
    $self->call('DELETE', '/api/instances/snap/' . ($snap->{group} // $snap->{id}), undef, undef);
}

sub snapshot_clone {
    my ($self, $snap, $name) = @_;
    die "invalid Unity LUN name '$name'\n" if !$self->valid_name($name);
    die $self->description . ": copies of a consistency group snapshot (several LUNs) are not supported by the array\n"
        if $snap->{group};
    my $d = $self->call('POST', "/api/instances/storageResource/$snap->{volume}/action/createLunThinClone", undef,
        { name => $name, snap => { id => $snap->{id} } });
    my $id = ref_id(($d->{content} // {})->{storageResource}) // die "Unity: no ID for thin clone '$name'\n";
    return $self->volume($id);
}

# Unity takes a backup snapshot of the current state first; like Cinder,
# pvesan deletes it once the restore has worked. A member of a group set
# restores the whole group, once.
sub snapshot_restore {
    my ($self, $vol, $snap) = @_;
    my $id = $snap->{group} // $snap->{id};
    return if $snap->{group} && ($self->{restored_set} // '') eq $id;
    my $d = $self->call('POST', "/api/instances/snap/$id/action/restore", undef, {});
    $self->{restored_set} = $id if $snap->{group};
    if (my $backup = ref_id((($d // {})->{content} // {})->{backup})) {
        eval { $self->call('DELETE', "/api/instances/snap/$backup", undef, undef) };
        print "warning: Unity backup snapshot $backup not deleted: $@" if $@;
    }
}

1;
