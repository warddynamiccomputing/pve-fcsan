use strict;
use warnings;

use Test::More;
use JSON::PP;

use StubPVE;
use FakeArray;
use PVE::SAN::Array;
use PVE::SAN::Array::Nimble;

my $GIB = 1024 ** 3;
my $MIB = 1024 ** 2;

my $C = 'PVE::SAN::Array::Nimble';

# ---------------- registration and name rules ----------------
is(PVE::SAN::Array::driver_class('hpe-nimble'), $C, 'hpe-nimble registered');
ok(grep({ $_ eq 'hpe-nimble' } @{PVE::SAN::Array::types()}), 'hpe-nimble listed in types');
is($C->default_port, 5392, 'NimOS REST port');
is($C->default_no_path_retry, 12, 'no_path_retry set (multipath-tools queues forever)');
ok($C->supports_snapshots && $C->supports_group_snapshots, 'snapshots and group snapshots offered');
ok(!$C->supports_replication, 'replication not offered yet');
ok(!$C->supports_disk_volumes, 'per-disk volumes not offered yet');
ok($C->valid_name('gold-01.a'), 'name with - and . ok');
ok(!$C->valid_name('gold_01'), 'no underscore');
ok(!$C->valid_name('1gold'), 'must start with a letter');
is($C->volume_name_for('gold_01'), 'gold-01', 'storage ID adapted');
is(PVE::SAN::Array::Nimble::serial_to_wwid('2EE4231F34E21D4B6C9CE900966EE6FE'), '22ee4231f34e21d4b6c9ce900966ee6fe',
    'WWID = 2 + serial (EUI-64)');
is(PVE::SAN::Array::Nimble::wwid_to_serial('22ee4231f34e21d4b6c9ce900966ee6fe'), '2ee4231f34e21d4b6c9ce900966ee6fe', 'serial from WWID');
ok(!defined(PVE::SAN::Array::Nimble::wwid_to_serial('36' . ('0' x 31))), 'NAA WWID is not a Nimble volume');

# ---------------- a stateful fake NimOS array ----------------
my %st;
my $n = 0;
my $json = JSON::PP->new->canonical;

sub reset_state {
    %st = (
        token => undef, logins => 0,
        igroups => { ig0 => { id => 'ig0', name => 'other', access_protocol => 'fc',
            fc_initiators => [ { wwpn => '50:00:00:00:00:00:00:99' } ] } },
        vols => {}, acrs => {}, snaps => {}, volcolls => {}, snapcolls => {}, jobs => {}, restored => [],
        async_delete => 1,
    );
}

sub msg {
    my ($code, $text) = @_;
    return { messages => [ { code => $code, severity => 'error', text => $text } ] };
}

sub nid { my ($p) = @_; return $p . ++$n; }

sub paged {
    my ($list, $q, $size) = @_;
    my $start = $q->{startRow} // 0;
    my @all = @$list;
    my @page = grep { defined } @all[$start .. ($size ? $start + $size - 1 : $#all)];
    return (200, { startRow => $start, endRow => $start + @page, totalRows => scalar(@all), data => \@page });
}

sub filtered {
    my ($objs, $q, @keys) = @_;
    return [ sort { $a->{id} cmp $b->{id} } grep {
        my $o = $_; !grep { defined($q->{$_}) && ($o->{$_} // '') ne $q->{$_} } @keys
    } values %$objs ];
}

sub async {
    my $j = nid('job');
    $st{jobs}->{$j} = 0;
    return (202, { messages => [ { code => 'SM_async_job_id', severity => 'info', arguments => { job_id => $j } } ] });
}

sub vol_view {
    my ($v) = @_;
    my @acr = grep { $_->{vol_id} eq $v->{id} } values %{$st{acrs}};
    my $vc = $v->{volcoll_id} ? $st{volcolls}->{$v->{volcoll_id}} : undef;
    return { %$v, volcoll_name => $vc ? $vc->{name} : '', access_control_records => @acr ? \@acr : undef };
}

sub vc_view {
    my ($vc) = @_;
    my @vols = map { { id => $_->{id}, name => $_->{name} } } grep { ($_->{volcoll_id} // '') eq $vc->{id} } values %{$st{vols}};
    return { %$vc, volume_list => \@vols, volume_count => scalar(@vols) };
}

sub new_snap {
    my ($vol, $name, %extra) = @_;
    my $id = nid('snap');
    $st{snaps}->{$id} = { id => $id, name => $name, vol_id => $vol, vol_name => $st{vols}->{$vol}->{name},
        size => $st{vols}->{$vol}->{size} * $MIB, creation_time => 1700000000 + $n, online => JSON::PP::false, %extra };
    return $st{snaps}->{$id};
}

sub new_vol {
    my (%v) = @_;
    my $id = nid('vol');
    my $k = $n;
    $st{vols}->{$id} = { id => $id, online => JSON::PP::true, volcoll_id => '',
        serial_number => sprintf('%016x6c9ce900%08x', 0xabc0000 + $k, $k), %v };
    return $st{vols}->{$id};
}

# Every request but the login needs the session token.
sub auth {
    my ($h) = @_;
    return sub {
        my ($cap, $q, $body, $headers) = @_;
        return (401, msg('SM_http_unauthorized', 'Unauthorized'))
            if !$st{token} || ($headers->{'X-Auth-Token'} // '') ne $st{token};
        return $h->(@_);
    };
}

my $routes = [
    [ POST => qr{^/v1/tokens$}, sub {
        my (undef, undef, $b) = @_;
        my $d = $b->{data} // {};
        return (401, msg('SM_http_unauthorized', 'Invalid credentials')) if ($d->{password} // '') ne 'secret';
        $st{logins}++;
        $st{token} = "tok$st{logins}";
        (201, { data => { id => 'sess1', session_token => $st{token}, username => $d->{username} } }) } ],
    [ GET => qr{^/v1/jobs/(\w+)$}, auth(sub { (200, { data => { id => $_[0]->[0], state => 'done', result => 'complete' } }) }) ],
    [ GET => qr{^/v1/groups/detail$}, auth(sub { paged([ { id => 'grp1', name => 'nimble-grp', version_current => '6.1.2.0-1234' } ], $_[1]) }) ],
    [ GET => qr{^/v1/arrays/detail$}, auth(sub { paged([ { id => 'arr1', name => 'a1', model => 'AF40', extended_model => 'AF40-4F-11T' } ], $_[1]) }) ],
    [ GET => qr{^/v1/pools/detail$}, auth(sub {
        paged([ { id => 'pool1', name => 'default', capacity => 100 * $GIB, free_space => 60 * $GIB },
            { id => 'pool2', name => 'fast', capacity => 10 * $GIB, free_space => 9 * $GIB } ], $_[1]) }) ],

    [ GET => qr{^/v1/initiator_groups/detail$}, auth(sub { paged(filtered($st{igroups}, $_[1], 'name'), $_[1]) }) ],
    [ POST => qr{^/v1/initiator_groups$}, auth(sub {
        my $d = $_[2]->{data}; my $id = nid('ig');
        $st{igroups}->{$id} = { id => $id, %$d };
        (201, { data => $st{igroups}->{$id} }) }) ],
    [ POST => qr{^/v1/initiators$}, auth(sub {
        my $d = $_[2]->{data};
        my $g = $st{igroups}->{$d->{initiator_group_id}} or return (404, msg('SM_enoent', 'No such object'));
        push @{$g->{fc_initiators}}, { wwpn => $d->{wwpn} };
        (201, { data => { id => nid('ini'), %$d } }) }) ],

    [ GET => qr{^/v1/volumes/detail$}, auth(sub {
        paged([ map { vol_view($_) } @{filtered($st{vols}, $_[1], 'name', 'serial_number')} ], $_[1], 2) }) ],
    [ POST => qr{^/v1/volumes/(\w+)/actions/restore$}, auth(sub {
        my ($cap, undef, $b) = @_;
        my $v = $st{vols}->{$cap->[0]};
        return (409, msg('SM_vol_online', 'Volume must be offline')) if $v->{online};
        return (400, msg('SM_invalid_arg', 'id mismatch')) if ($b->{data}->{id} // '') ne $v->{id};
        push @{$st{restored}}, "$v->{id}<-$b->{data}->{base_snap_id}";
        (200, { data => {} }) }) ],
    [ GET => qr{^/v1/volumes/(\w+)$}, auth(sub {
        my $v = $st{vols}->{$_[0]->[0]} or return (404, msg('SM_enoent', 'No such object'));
        (200, { data => { %{vol_view($v)}, vol_usage_uncompressed_bytes => 30 * $GIB, vol_usage_compressed_bytes => 10 * $GIB } }) }) ],
    [ POST => qr{^/v1/volumes$}, auth(sub {
        my $d = $_[2]->{data};
        return (409, msg('SM_eexist', 'Object exists')) if grep { $_->{name} eq $d->{name} } values %{$st{vols}};
        my $v;
        if ($d->{clone}) {
            my $s = $st{snaps}->{$d->{base_snap_id}} or return (404, msg('SM_enoent', 'No such object'));
            $v = new_vol(name => $d->{name}, size => $s->{size} / $MIB, pool_name => $st{vols}->{$s->{vol_id}}->{pool_name},
                clone => JSON::PP::true, base_snap_id => $s->{id}, parent_vol_id => $s->{vol_id}, req => $d);
            if (!defined($d->{inherit_acl}) || $d->{inherit_acl}) {
                for my $a (grep { $_->{vol_id} eq $s->{vol_id} } values %{$st{acrs}}) {
                    my $id = nid('acr'); $st{acrs}->{$id} = { %$a, id => $id, vol_id => $v->{id} };
                }
            }
        } else {
            my ($pool) = grep { $_ eq ($d->{pool_id} // '') } qw(pool1 pool2) or return (400, msg('SM_invalid_arg', 'bad pool'));
            $v = new_vol(name => $d->{name}, size => $d->{size}, pool_name => $pool eq 'pool1' ? 'default' : 'fast', req => $d);
        }
        (201, { data => vol_view($v) }) }) ],
    [ PUT => qr{^/v1/volumes/(\w+)$}, auth(sub {
        my ($cap, undef, $b) = @_;
        my $v = $st{vols}->{$cap->[0]} or return (404, msg('SM_enoent', 'No such object'));
        my $d = $b->{data};
        if (exists($d->{online})) {
            return (409, msg('SM_state', "Volume $v->{name} is already in requested state"))
                if !!$d->{online} == !!$v->{online};
            return (409, msg('SM_vol_has_acl', 'Volume is in use; use force')) if !$d->{online} && !$d->{force};
            $v->{online} = $d->{online};
        }
        $v->{size} = $d->{size} if exists($d->{size});
        $v->{volcoll_id} = $d->{volcoll_id} if exists($d->{volcoll_id});
        (200, { data => vol_view($v) }) }) ],
    [ DELETE => qr{^/v1/volumes/(\w+)$}, auth(sub {
        my $v = $st{vols}->{$_[0]->[0]} or return (404, msg('SM_enoent', 'No such object'));
        return (409, msg('SM_vol_online', "Volume $v->{name} is online")) if $v->{online};
        delete $st{vols}->{$v->{id}};
        delete $st{acrs}->{$_->{id}} for grep { $_->{vol_id} eq $v->{id} } values %{$st{acrs}};
        return async() if $st{async_delete};
        (200, {}) }) ],

    [ POST => qr{^/v1/access_control_records$}, auth(sub {
        my $d = $_[2]->{data};
        return (409, msg('SM_eexist', 'Object exists'))
            if grep { $_->{vol_id} eq $d->{vol_id} && $_->{initiator_group_id} eq $d->{initiator_group_id} } values %{$st{acrs}};
        my $id = nid('acr');
        $st{acrs}->{$id} = { id => $id, lun => 0 + keys %{$st{acrs}}, %$d };
        (201, { data => $st{acrs}->{$id} }) }) ],
    [ GET => qr{^/v1/access_control_records/detail$}, auth(sub {
        paged(filtered($st{acrs}, $_[1], 'vol_id', 'initiator_group_id'), $_[1]) }) ],
    [ DELETE => qr{^/v1/access_control_records/(\w+)$}, auth(sub {
        delete($st{acrs}->{$_[0]->[0]}) or return (404, msg('SM_enoent', 'No such object')); (200, {}) }) ],

    [ POST => qr{^/v1/snapshots$}, auth(sub {
        my $d = $_[2]->{data};
        return (404, msg('SM_enoent', 'No such object')) if !$st{vols}->{$d->{vol_id}};
        (201, { data => new_snap($d->{vol_id}, $d->{name}) }) }) ],
    [ GET => qr{^/v1/snapshots/detail$}, auth(sub {
        return (400, msg('SM_missing_arg', 'vol_id or vol_name required')) if !$_[1]->{vol_id};
        paged(filtered($st{snaps}, $_[1], 'vol_id'), $_[1]) }) ],
    [ PUT => qr{^/v1/snapshots/(\w+)$}, auth(sub {
        my $s = $st{snaps}->{$_[0]->[0]} or return (404, msg('SM_enoent', 'No such object'));
        $s->{online} = $_[2]->{data}->{online}; (200, { data => $s }) }) ],
    [ DELETE => qr{^/v1/snapshots/(\w+)$}, auth(sub {
        my $s = $st{snaps}->{$_[0]->[0]} or return (404, msg('SM_enoent', 'No such object'));
        return (409, msg('SM_snap_online', 'Snapshot is online')) if $s->{online};
        return (409, msg('SM_has_clone', "Snapshot $s->{name} has a clone"))
            if grep { ($_->{base_snap_id} // '') eq $s->{id} } values %{$st{vols}};
        delete $st{snaps}->{$s->{id}}; (200, {}) }) ],

    [ GET => qr{^/v1/volume_collections/detail$}, auth(sub {
        paged([ map { vc_view($_) } @{filtered($st{volcolls}, $_[1], 'name')} ], $_[1]) }) ],
    [ GET => qr{^/v1/volume_collections/(\w+)$}, auth(sub {
        my $vc = $st{volcolls}->{$_[0]->[0]} or return (404, msg('SM_enoent', 'No such object'));
        (200, { data => vc_view($vc) }) }) ],
    [ POST => qr{^/v1/volume_collections$}, auth(sub {
        my $d = $_[2]->{data}; my $id = nid('vc');
        $st{volcolls}->{$id} = { id => $id, %$d };
        (201, { data => vc_view($st{volcolls}->{$id}) }) }) ],
    [ DELETE => qr{^/v1/volume_collections/(\w+)$}, auth(sub {
        my $vc = $st{volcolls}->{$_[0]->[0]} or return (404, msg('SM_enoent', 'No such object'));
        return (409, msg('SM_busy', 'Volume collection has volumes')) if vc_view($vc)->{volume_count};
        delete $st{volcolls}->{$vc->{id}}; (200, {}) }) ],
    [ POST => qr{^/v1/snapshot_collections$}, auth(sub {
        my $d = $_[2]->{data};
        my $vc = $st{volcolls}->{$d->{volcoll_id}} or return (404, msg('SM_enoent', 'No such object'));
        my $id = nid('sc');
        $st{snapcolls}->{$id} = { id => $id, name => $d->{name}, volcoll_id => $vc->{id} };
        new_snap($_->{id}, $d->{name}, snap_collection_id => $id, snap_collection_name => $d->{name})
            for sort { $a->{id} cmp $b->{id} } grep { ($_->{volcoll_id} // '') eq $vc->{id} } values %{$st{vols}};
        (201, { data => $st{snapcolls}->{$id} }) }) ],
    [ DELETE => qr{^/v1/snapshot_collections/(\w+)$}, auth(sub {
        my $sc = delete($st{snapcolls}->{$_[0]->[0]}) or return (404, msg('SM_enoent', 'No such object'));
        delete $st{snaps}->{$_->{id}} for grep { ($_->{snap_collection_id} // '') eq $sc->{id} } values %{$st{snaps}};
        (200, {}) }) ],
];

reset_state();
my ($drv, $calls) = FakeArray::driver($C, {}, $routes);

# ---------------- auth ----------------
eval { $C->new(address => 'a', password => 'p', fingerprint => 'sha256$0') };
like($@, qr/username missing/, 'username required');

my $info = $drv->system_info;
is($st{logins}, 1, 'logged in once');
my $login = FakeArray::find_call($calls, 'POST', qr{^/v1/tokens$});
is_deeply($login->{body}, { data => { username => 'pvesan', password => 'secret', app_name => 'pve-fcsan' } },
    'login: POST /v1/tokens with {data: {username, password}}');
is(FakeArray::find_call($calls, 'GET', qr{^/v1/groups/detail})->{headers}->{'X-Auth-Token'}, 'tok1', 'token sent as X-Auth-Token');
is_deeply([ @$info{qw(name code_level id)} ], [ 'nimble-grp', '6.1.2.0-1234', 'grp1' ], 'system info from the group');
like($info->{product}, qr/AF40-4F-11T/, 'array model in the product');

$st{token} = 'expired';
is($drv->pools->[1]->{free}, 9 * $GIB, 'pools with free space');
is($st{logins}, 2, 'expired session: logged in again and retried');

{
    my ($d2) = FakeArray::driver($C, { password => 'wrong' }, $routes);
    eval { $d2->pools };
    like($@, qr/Nimble login to array failed \(HTTP 401\): SM_http_unauthorized: Invalid credentials/, 'bad password: clear error');
}

# ---------------- registration ----------------
my $res = $drv->ensure_hostcluster('pvelab', {
    node1 => ['50:00:00:00:00:00:00:01', '5000000000000002'], node2 => ['50:00:00:00:00:00:00:05'] }, sub {});
my $igc = FakeArray::find_call($calls, 'POST', qr{^/v1/initiator_groups$});
is_deeply($igc->{body}, { data => { name => 'pvelab', access_protocol => 'fc', fc_initiators => [
    { wwpn => '50:00:00:00:00:00:00:01' }, { wwpn => '50:00:00:00:00:00:00:02' }, { wwpn => '50:00:00:00:00:00:00:05' } ] } },
    'one FC initiator group with every node WWPN');
ok($res->{node1}->{joined} && $res->{node2}->{joined}, 'every node joined');
my ($ig) = grep { $_->{name} eq 'pvelab' } values %{$st{igroups}};

$res = $drv->ensure_hostcluster('pvelab', { node1 => ['5000000000000001', '5000000000000002'], node3 => ['5000000000000007'] }, sub {});
is_deeply(FakeArray::find_call($calls, 'POST', qr{^/v1/initiators$})->{body},
    { data => { access_protocol => 'fc', initiator_group_id => $ig->{id}, wwpn => '50:00:00:00:00:00:00:07' } },
    'missing initiator added to the group');
is_deeply($res->{node3}->{added_ports}, ['5000000000000007'], 'new node: port reported as added');
is_deeply($res->{node1}->{added_ports}, [], 'registered node: nothing added');
my $before = @$calls;
$drv->ensure_hostcluster('pvelab', { node1 => ['5000000000000001'] }, sub {});
ok(!grep({ $_->{method} ne 'GET' } @$calls[$before .. $#$calls]), 'registration is idempotent');

eval { $drv->ensure_hostcluster('pvelab', { node4 => ['5000000000000099'] }, sub {}) };
like($@, qr/5000000000000099 \(other\) already in other initiator groups/, 'port in another group refused');
eval { $drv->ensure_hostcluster('pvelab', { node4 => [] }, sub {}) };
like($@, qr/node 'node4' has no FC ports/, 'node without FC ports refused');
$st{igroups}->{ig9} = { id => 'ig9', name => 'iscsi', access_protocol => 'iscsi' };
eval { $drv->ensure_hostcluster('iscsi', { node5 => ['50000000000000AA'] }, sub {}) };
like($@, qr/access protocol 'iscsi', not fc/, 'iSCSI group of that name refused');
delete $st{igroups}->{ig9};

my ($h) = grep { $_->{name} eq 'pvelab' } @{$drv->hosts};
is_deeply([ $h->{hostcluster}, $h->{wwpns} ],
    [ 'pvelab', [ qw(5000000000000001 5000000000000002 5000000000000005 5000000000000007) ] ],
    'hosts: the group with all its WWPNs');
ok(grep({ $_->{name} eq 'pvelab' } @{$drv->host_clusters}), 'host_clusters: the initiator group');

# ---------------- volume lifecycle ----------------
my $v = $drv->create_volume(name => 'gold-01', pool => 'default', size_gib => 100, thin => 1);
my $vc_call = FakeArray::find_call($calls, 'POST', qr{^/v1/volumes$});
is_deeply($vc_call->{body}, { data => { name => 'gold-01', size => 102400, pool_id => 'pool1', reserve => 0, online => JSON::PP::true } },
    'create: size in MiB, pool ID, thin = reserve 0');
is($v->{capacity}, 100 * $GIB, 'capacity in bytes');
like($v->{wwid}, qr/^2[0-9a-f]{16}6c9ce900[0-9a-f]{8}$/, 'WWID derived from the serial');
my $thick = $drv->create_volume(name => 'thick-01', pool => 'fast', size_gib => 1, thin => 0);
is($st{vols}->{$thick->{id}}->{req}->{reserve}, 100, 'thick = reserve 100');
eval { $drv->create_volume(name => 'x', pool => 'nope', size_gib => 1, thin => 1) };
like($@, qr/Nimble pool 'nope' not found/, 'unknown pool refused');
eval { $drv->create_volume(name => 'bad_name', pool => 'default', size_gib => 1, thin => 1) };
like($@, qr/invalid Nimble volume name/, 'invalid name refused');
eval { $drv->create_volume(name => 'gold-01', pool => 'default', size_gib => 1, thin => 1) };
like($@, qr/Nimble POST \/volumes failed \(HTTP 409\): SM_eexist: Object exists/, 'array error text shown');

is_deeply($drv->volume($v->{id}), $v, 'volume by ID');
new_vol(name => "filler$_", size => 1) for 1 .. 3; # several pages of /volumes/detail
my $found = $drv->find_volume_by_wwid($v->{wwid});
is($found->{id}, $v->{id}, 'find by WWID');
ok(FakeArray::find_call($calls, 'GET', qr{^/v1/volumes/detail\?serial_number=}), 'looked up by serial_number');
is($drv->find_volume_by_wwid('3' . substr($v->{wwid}, 1)), undef, 'NAA WWID not looked up');
is(scalar(@{$drv->records('/volumes/detail')}), 5, 'all pages of a list read');
ok(FakeArray::find_call($calls, 'GET', qr{^/v1/volumes/detail\?startRow=4$}), 'next page from startRow');

$drv->map_to_hostcluster($v->{id}, 'pvelab');
is_deeply(FakeArray::find_call($calls, 'POST', qr{^/v1/access_control_records$})->{body},
    { data => { apply_to => 'both', vol_id => $v->{id}, initiator_group_id => $ig->{id} } }, 'map: access control record');
eval { $drv->map_to_hostcluster($v->{id}, 'nogroup') };
like($@, qr/initiator group 'nogroup' not found/, 'map to unknown group refused');

$drv->expand_volume($v->{id}, 50 * $GIB);
is_deeply(FakeArray::find_call($calls, 'PUT', qr{^/v1/volumes/$v->{id}$})->{body}, { data => { size => 153600 } }, 'expand: new size in MiB');
eval { $drv->expand_volume($v->{id}, 512) };
like($@, qr/multiple of 1 MiB/, 'expansion below 1 MiB refused');

my $space = $drv->volume_space([ $v->{id} ])->[0];
is_deeply([ @$space{qw(provisioned written reduction)} ], [ 150 * $GIB, 30 * $GIB, 3 ], 'volume space and compression');

# ---------------- snapshots ----------------
my $s1 = $drv->snapshot_create([ $v->{id} ], 'before-upgrade');
is_deeply(FakeArray::find_call($calls, 'POST', qr{^/v1/snapshots$})->{body}, { data => { name => 'before-upgrade', vol_id => $v->{id} } },
    'snapshot: POST /v1/snapshots {name, vol_id}');
is_deeply([ map { @$_{qw(name volume size)} } @$s1 ], [ 'before-upgrade', $v->{id}, 150 * $GIB ], 'snapshot returned');
ok($s1->[0]->{created} > 1700000000, 'creation time (epoch)');
eval { $drv->snapshot_create([ $v->{id} ], 'before-upgrade') };
like($@, qr/already exists/, 'duplicate snapshot name refused');
eval { $drv->snapshot_create([ $v->{id} ], 'bad_name') };
like($@, qr/invalid snapshot name/, 'invalid snapshot name refused');

new_snap($v->{id}, 'gold-sched-2026', schedule_name => 'daily', schedule_id => 'sch1');
new_snap($v->{id}, 'replica-1', is_replica => JSON::PP::true);
is_deeply([ map { $_->{name} } @{$drv->snapshots([ $v->{id} ])} ], [ 'before-upgrade' ], 'schedule snapshots and replicas not listed');

my $clone = $drv->snapshot_clone($s1->[0], 'gold-01-copy');
my ($cc) = grep { $_->{method} eq 'POST' && $_->{url} eq '/v1/volumes' && $_->{body}->{data}->{clone} } @$calls;
is_deeply($cc->{body}, { data => { name => 'gold-01-copy', clone => JSON::PP::true, base_snap_id => $s1->[0]->{id},
    online => JSON::PP::true, inherit_acl => JSON::PP::false } }, 'clone: {clone, base_snap_id, inherit_acl false}');
isnt($clone->{wwid}, $v->{wwid}, 'clone has its own WWID');
is($clone->{capacity}, 150 * $GIB, 'clone has the snapshot size');
ok(!grep({ $_->{vol_id} eq $clone->{id} } values %{$st{acrs}}), 'clone is not mapped');

eval { $drv->snapshot_delete($s1->[0]) };
like($@, qr/has a clone/, 'snapshot with a clone: array error passed on');
$drv->delete_volume($clone->{id});

$drv->snapshot_restore($v->{id}, $s1->[0]);
is_deeply($st{restored}, [ "$v->{id}<-$s1->[0]->{id}" ], 'restore: POST actions/restore {id, base_snap_id}');
ok($st{vols}->{$v->{id}}->{online}, 'volume online again after the restore');
my @puts = map { $_->{body}->{data} } grep { $_->{method} eq 'PUT' && $_->{url} eq "/v1/volumes/$v->{id}" } @$calls;
is_deeply([ @puts[-2, -1] ], [ { online => JSON::PP::false, force => JSON::PP::true }, { online => JSON::PP::true } ],
    'restore: offline (forced), then online');
{
    my $bogus = { %{$s1->[0]}, id => 'nosuch' };
    # a failed restore still brings the volume back online
    my ($d3) = FakeArray::driver($C, {}, [ [ POST => qr{/actions/restore$}, sub { (500, msg('SM_fail', 'restore failed')) } ], @$routes ]);
    eval { $d3->snapshot_restore($v->{id}, $bogus) };
    like($@, qr/SM_fail: restore failed/, 'failed restore reported');
    ok($st{vols}->{$v->{id}}->{online}, 'volume online again after a failed restore');
}

$drv->snapshot_delete($s1->[0]);
my @sp = map { $_->{body}->{data} } grep { $_->{method} eq 'PUT' && $_->{url} eq "/v1/snapshots/$s1->[0]->{id}" } @$calls;
is_deeply($sp[-1], { online => JSON::PP::false }, 'snapshot set offline before delete');
ok(!$st{snaps}->{$s1->[0]->{id}}, 'snapshot deleted');

# ---------------- several volumes: volume collection ----------------
my $v2 = $drv->create_volume(name => 'gold-02', pool => 'default', size_gib => 10, thin => 1);
my $set = $drv->snapshot_create([ $v->{id}, $v2->{id} ], 'nightly');
my ($vc) = values %{$st{volcolls}};
is($vc->{name}, 'pvesan-gold-01', 'volume collection named after the first volume');
is_deeply(FakeArray::find_call($calls, 'POST', qr{^/v1/volume_collections$})->{body},
    { data => { name => 'pvesan-gold-01', description => 'pve-fcsan datastore' } }, 'volume collection created');
is_deeply([ map { $_->{body}->{data} } grep { $_->{method} eq 'PUT' && defined($_->{body}->{data}->{volcoll_id}) } @$calls ],
    [ { volcoll_id => $vc->{id} }, { volcoll_id => $vc->{id} } ], 'both volumes put in the collection');
is_deeply(FakeArray::find_call($calls, 'POST', qr{^/v1/snapshot_collections$})->{body},
    { data => { name => 'nightly', volcoll_id => $vc->{id} } }, 'snapshot collection of the volume collection');
is_deeply([ sort map { $_->{volume} } @$set ], [ sort $v->{id}, $v2->{id} ], 'one member per volume');
ok($set->[0]->{group} && $set->[0]->{group} eq $set->[1]->{group}, 'members share the snapshot collection');
is_deeply([ map { $_->{name} } @$set ], [ 'nightly', 'nightly' ], 'members carry the set name');

$before = @$calls;
$drv->snapshot_create([ $v->{id}, $v2->{id} ], 'nightly2');
ok(!grep({ $_->{method} eq 'POST' && $_->{url} eq '/v1/volume_collections' } @$calls[$before .. $#$calls]), 'collection reused');
is(scalar(grep { $_->{group} } @{$drv->snapshots([ $v->{id}, $v2->{id} ])}), 4, 'two sets listed');

$drv->snapshot_delete($set->[0]);
ok(FakeArray::find_call($calls, 'DELETE', qr{^/v1/snapshot_collections/$set->[0]->{group}$}), 'set deleted as a whole');
is(scalar(grep { $_->{name} eq 'nightly' } values %{$st{snaps}}), 0, 'members gone with the collection');

my $other = new_vol(name => 'elsewhere', size => 1);
$st{volcolls}->{vcx} = { id => 'vcx', name => 'app-coll' };
$other->{volcoll_id} = 'vcx';
eval { $drv->snapshot_create([ $other->{id}, $v->{id} ], 'mixed') };
like($@, qr/already in volume collection 'app-coll'/, 'volume in another collection refused');
ok(!grep({ $_->{name} eq 'pvesan-elsewhere' } values %{$st{volcolls}}), 'no collection left behind after the refusal');

# ---------------- unmap and delete ----------------
$drv->unmap_from_hostcluster($v->{id}, 'pvelab');
ok(!grep({ $_->{vol_id} eq $v->{id} } values %{$st{acrs}}), 'unmap: access control record deleted');
ok(FakeArray::find_call($calls, 'GET', qr{^/v1/access_control_records/detail\?initiator_group_id=$ig->{id}&vol_id=$v->{id}$}),
    'unmap: record looked up by volume and group');

$drv->snapshot_delete($_) for grep { $_->{group} } @{$drv->snapshots([ $v->{id} ])};
$drv->delete_volume($v2->{id});
ok($st{volcolls}->{$vc->{id}}, 'collection kept while it has volumes');
$st{async_delete} = 0;
$drv->delete_volume($v->{id});
ok(!$st{vols}->{$v->{id}}, 'volume deleted');
ok(!$st{volcolls}->{$vc->{id}}, 'empty pvesan collection deleted with the last volume');
ok(FakeArray::find_call($calls, 'GET', qr{^/v1/jobs/job\d+$}), 'asynchronous delete: job awaited');
my ($off) = grep { $_->{method} eq 'PUT' && $_->{url} eq "/v1/volumes/$v2->{id}" && exists($_->{body}->{data}->{online}) } @$calls;
is_deeply($off->{body}, { data => { online => JSON::PP::false, force => JSON::PP::true } }, 'delete: volume offline first');

my $already = new_vol(name => 'already-off', size => 1, online => JSON::PP::false);
$drv->delete_volume($already->{id});
ok(!$st{vols}->{$already->{id}}, 'already offline volume deleted');
eval { $drv->volume('nosuch') };
like($@, qr/Nimble GET \/volumes\/nosuch failed \(HTTP 404\): SM_enoent: No such object/, 'missing volume: array error');

# ---------------- error formats ----------------
is(PVE::SAN::Array::Nimble::error_text($json->encode({ messages => [
    { code => 'SM_http_bad_request', severity => 'error', text => 'Bad request' },
    { code => 'SM_invalid_arg_value', severity => 'error', text => 'Invalid value for size' } ] })),
    'SM_http_bad_request: Bad request; SM_invalid_arg_value: Invalid value for size', 'every message shown');
is(PVE::SAN::Array::Nimble::error_text('<html>oops</html>'), '<html>oops</html>', 'non-JSON error shown as is');

done_testing();
