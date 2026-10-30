use strict;
use warnings;

use Test::More;
use JSON::PP;

use StubPVE;
use FakeArray;
use PVE::SAN::Array;
use PVE::SAN::Array::Unity;

my $GIB = 1024 ** 3;
my $I = qr{^/api/instances};
my $T = qr{^/api/types};

my %st = (
    logins => 0,
    hosts => { Host_1 => { id => 'Host_1', name => 'pvenode01', type => 1 },
               Host_2 => { id => 'Host_2', name => 'esx01', type => 1 } },
    inits => {
        HostInitiator_1 => { id => 'HostInitiator_1', type => 1, parentHost => { id => 'Host_1' },
            initiatorId => '20:00:00:00:00:00:00:01:50:00:00:00:00:00:00:01', portWWN => '50:00:00:00:00:00:00:01' },
        HostInitiator_2 => { id => 'HostInitiator_2', type => 1, # logged in, not registered yet
            initiatorId => '20:00:00:00:00:00:00:05:50:00:00:00:00:00:00:05', portWWN => '50:00:00:00:00:00:00:05' },
        HostInitiator_3 => { id => 'HostInitiator_3', type => 1, parentHost => { id => 'Host_2' },
            initiatorId => '20:00:00:00:00:00:00:99:10:00:00:00:C9:AA:AA:AA', portWWN => '10:00:00:00:C9:AA:AA:AA' },
        HostInitiator_4 => { id => 'HostInitiator_4', type => 2, parentHost => { id => 'Host_2' },
            initiatorId => 'iqn.1993-08.org.debian:01:abcdef' },
    },
    luns => {}, cgs => {}, snaps => {}, n => 10,
);

my $err = sub {
    my ($http, $msg, $code) = @_;
    return ($http, { error => { errorCode => $code // 131149829, httpStatusCode => $http,
        messages => [ { 'en-US' => $msg } ], created => '2026-10-29T08:00:00.000Z' } });
};
my $entries = sub { (200, { entries => [ map { { content => $_ } } @_ ], links => [ { rel => 'self', href => '&page=1' } ] }) };
my $filter_sr = sub { ($_[0]->{filter} // '') =~ /^storageResource eq "([^"]+)"$/ ? $1 : undef };

# writes need the CSRF token of the session the cookie names
my $w = sub {
    my ($h) = @_;
    return sub {
        my $hd = $_[3];
        return $err->(401, 'Unauthorized') if ($hd->{'EMC-CSRF-TOKEN'} // '') ne "C$st{logins}"
            || ($hd->{Cookie} // '') !~ /mod_sec_emc=S$st{logins}\b/ || $st{expire_csrf};
        return $h->(@_);
    };
};
my $lun_new = sub {
    my ($name, $size, $thin, $pool) = @_;
    my $id = 'sv_' . ++$st{n};
    $st{luns}->{$id} = { id => $id, name => $name, sizeTotal => $size, sizeAllocated => 0, isThinEnabled => $thin,
        pool => { id => $pool }, storageResource => { id => $id }, hostAccess => [],
        wwn => join(':', '60:06:01:60:00:00:00:00:00:00:00:00:00:00:AB', sprintf('%02X', $st{n})) };
    return $id;
};
my $set_lun = sub {
    my ($l, $p) = @_;
    if (exists $p->{size}) {
        return $err->(422, 'The LUN cannot be shrunk. (Error Code:0x6000c17)') if $p->{size} < $l->{sizeTotal};
        $l->{sizeTotal} = $p->{size};
    }
    $l->{hostAccess} = [ map { { %$_ } } @{$p->{hostAccess}} ] if exists $p->{hostAccess};
    return (200, {});
};

my ($drv, $calls) = FakeArray::driver('PVE::SAN::Array::Unity', {
    hostcluster => 'pvelab',
    node_wwpns => { pvenode01 => ['50:00:00:00:00:00:00:01', '50:00:00:00:00:00:00:02'],
                    pvenode02 => ['5000000000000005', '5000000000000006'] },
    node_wwnns => { '5000000000000002' => '2000000000000002', '5000000000000006' => '2000000000000006' },
}, [
    [ GET => qr{$T/user/instances$}, sub {
        $st{logins}++;
        return $err->(401, 'Unauthorized') if $_[3]->{Authorization} ne 'Basic ' . MIME::Base64::encode_base64('pvesan:secret', '');
        delete $st{expire_csrf};
        (200, { entries => [] }, { 'emc-csrf-token' => "C$st{logins}",
            'set-cookie' => "mod_sec_emc=S$st{logins}; path=/; secure; HttpOnly, LOGIN_TICKET=x$st{logins}; Expires=Thu, 29 Oct 2026 10:00:00 GMT; path=/" }) } ],
    [ GET => qr{$T/system/instances$}, sub {
        $entries->({ id => '0', name => 'unity-lab', model => 'Unity 480F', serialNumber => 'APM00000000001' }) } ],
    [ GET => qr{$T/basicSystemInfo/instances$}, sub { $entries->({ id => '0', model => 'Unity 480F', softwareVersion => '5.4.0' }) } ],
    [ GET => qr{$T/pool/instances$}, sub {
        $entries->({ id => 'pool_1', name => 'Pool0', sizeTotal => 10240 * $GIB, sizeFree => 4096 * $GIB, health => { value => 5 } },
                   { id => 'pool_2', name => 'Pool1', sizeTotal => 1024 * $GIB, sizeFree => 0, health => { value => 20 } }) } ],
    [ GET => qr{$T/host/instances$}, sub {
        my @h = map { $st{hosts}->{$_} } sort keys %{$st{hosts}};
        return (200, { entries => [ { content => $h[0] } ], links => [ { rel => 'next', href => '&page=2' } ] })
            if !$_[1]->{page};
        $entries->(@h[1 .. $#h]) } ],
    [ POST => qr{$T/host/instances$}, $w->(sub {
        my $id = 'Host_' . ++$st{n};
        $st{hosts}->{$id} = { id => $id, name => $_[2]->{name}, type => $_[2]->{type}, req => $_[2] };
        (201, { content => { id => $id } }) }) ],
    [ GET => qr{$T/hostInitiator/instances$}, sub { $entries->(map { $st{inits}->{$_} } sort keys %{$st{inits}}) } ],
    [ POST => qr{$T/hostInitiator/instances$}, $w->(sub {
        my $b = $_[2];
        return $err->(409, 'The initiator already exists. (Error Code:0x6000c18)')
            if grep { $_->{initiatorId} eq $b->{initiatorWWNorIqn} } values %{$st{inits}};
        my $id = 'HostInitiator_' . ++$st{n};
        $st{inits}->{$id} = { id => $id, type => $b->{initiatorType}, initiatorId => $b->{initiatorWWNorIqn},
            portWWN => substr($b->{initiatorWWNorIqn}, 24), parentHost => $b->{host} };
        (201, { content => { id => $id } }) }) ],
    [ POST => qr{$I/hostInitiator/([^/]+)/action/modify$}, $w->(sub {
        $st{inits}->{$_[0]->[0]}->{parentHost} = $_[2]->{host}; (200, {}) }) ],

    [ POST => qr{$T/storageResource/action/createLun$}, $w->(sub {
        my $b = $_[2];
        return $err->(409, 'The LUN name is already in use. (Error Code:0x6000c11)')
            if grep { $_->{name} eq $b->{name} } values %{$st{luns}};
        my $p = $b->{lunParameters};
        my $id = $lun_new->($b->{name}, $p->{size}, $p->{isThinEnabled} ? JSON::PP::true : JSON::PP::false, $p->{pool}->{id});
        $st{luns}->{$id}->{req} = $b;
        (200, { content => { storageResource => { id => $id } } }) }) ],
    [ GET => qr{$I/lun/([^/]+)$}, sub {
        my $l = $st{luns}->{$_[0]->[0]} or return $err->(404, 'The requested resource does not exist. (Error Code:0x7d13005)');
        (200, { content => { map { $_ => $l->{$_} } grep { $_ ne 'req' } keys %$l } }) } ],
    [ GET => qr{$T/lun/instances$}, sub { $entries->(map { $st{luns}->{$_} } sort keys %{$st{luns}}) } ],
    [ POST => qr{$I/storageResource/([^/]+)/action/modifyLun$}, $w->(sub {
        my $l = $st{luns}->{$_[0]->[0]} or return $err->(404, 'not found');
        return $err->(400, 'This LUN is a member of a consistency group.') if $l->{storageResource}->{id} ne $l->{id};
        $set_lun->($l, $_[2]->{lunParameters}) }) ],
    [ POST => qr{$T/storageResource/action/createConsistencyGroup$}, $w->(sub {
        my $id = 'res_' . ++$st{n};
        $st{cgs}->{$id} = { id => $id, name => $_[2]->{name}, type => 2, luns => [] };
        for (@{$_[2]->{lunAdd}}) { push @{$st{cgs}->{$id}->{luns}}, { id => $_->{lun}->{id} };
            $st{luns}->{$_->{lun}->{id}}->{storageResource} = { id => $id } }
        (200, { content => { storageResource => { id => $id } } }) }) ],
    [ POST => qr{$I/storageResource/([^/]+)/action/modifyConsistencyGroup$}, $w->(sub {
        my ($cid, $b) = ($_[0]->[0], $_[2]);
        my $cg = $st{cgs}->{$cid} or return $err->(404, 'not found');
        push @{$st{cg_log}}, $b;
        for (@{$b->{lunAdd} // []}) { push @{$cg->{luns}}, { id => $_->{lun}->{id} };
            $st{luns}->{$_->{lun}->{id}}->{storageResource} = { id => $cid } }
        for my $r (@{$b->{lunRemove} // []}) { $cg->{luns} = [ grep { $_->{id} ne $r->{lun}->{id} } @{$cg->{luns}} ];
            $st{luns}->{$r->{lun}->{id}}->{storageResource} = { id => $r->{lun}->{id} } }
        for my $m (@{$b->{lunModify} // []}) {
            my @r = $set_lun->($st{luns}->{$m->{lun}->{id}}, $m->{lunParameters});
            return @r if $r[0] != 200;
        }
        (200, {}) }) ],
    [ GET => qr{$I/storageResource/([^/]+)$}, sub {
        my $c = $st{cgs}->{$_[0]->[0]} or return $err->(404, 'not found'); (200, { content => $c }) } ],
    [ DELETE => qr{$I/storageResource/([^/]+)$}, $w->(sub {
        my $id = $_[0]->[0];
        push @{$st{deleted}}, [ $id, $_[2] ];
        if (my $cg = $st{cgs}->{$id}) { delete $st{cgs}->{$id}; return (204, '') }
        my $l = $st{luns}->{$id} or return $err->(404, 'not found');
        return $err->(409, 'The LUN has snapshots. (Error Code:0x6000c0f)', 1903001603)
            if grep { ($_->{storageResource}->{id} // '') eq $id } values %{$st{snaps}};
        delete $st{luns}->{$id}; (204, '') }) ],

    [ POST => qr{$T/snap/instances$}, $w->(sub {
        my $b = $_[2];
        my $sr = $b->{storageResource}->{id};
        return $err->(409, 'Specified snapshot name is already in use. (Error Code:0x716d8005)', 1903001605)
            if grep { $_->{name} eq $b->{name} } values %{$st{snaps}};
        my $sid = ++$st{n} + 38654705000;
        my $ts = sprintf('2026-10-29T09:%02d:00.123Z', $st{n} % 60);
        $st{snaps}->{$sid} = { id => "$sid", name => $b->{name}, creationTime => $ts, size => 0, state => 2,
            storageResource => { id => $sr }, isAutoDelete => $b->{isAutoDelete},
            ($st{luns}->{$sr} ? (lun => { id => $sr }) : ()) };
        if (my $cg = $st{cgs}->{$sr}) {
            for my $m (@{$cg->{luns}}) {
                my $mid = ++$st{n} + 38654705000;
                $st{snaps}->{$mid} = { id => "$mid", name => "$mid", creationTime => $ts, size => 0, state => 2,
                    storageResource => { id => $sr }, lun => { id => $m->{id} }, snapGroup => { id => "$sid" } };
            }
        }
        (201, { content => { id => "$sid" } }) }) ],
    [ GET => qr{$T/snap/instances$}, sub {
        my $sr = $filter_sr->($_[1]);
        $entries->(map { $st{snaps}->{$_} } grep { $st{snaps}->{$_}->{storageResource}->{id} eq $sr } sort keys %{$st{snaps}}) } ],
    [ DELETE => qr{$I/snap/(\d+)$}, $w->(sub {
        my $id = $_[0]->[0];
        push @{$st{snap_deleted}}, $id;
        delete $st{snaps}->{$_} for grep { (($st{snaps}->{$_}->{snapGroup} // {})->{id} // '') eq $id } keys %{$st{snaps}};
        delete $st{snaps}->{$id} or return $err->(404, 'not found');
        (204, '') }) ],
    [ POST => qr{$I/snap/(\d+)/action/restore$}, $w->(sub {
        my $s = $st{snaps}->{$_[0]->[0]} or return $err->(404, 'not found');
        push @{$st{restored}}, $s->{id};
        my $bid = ++$st{n} + 38654705000;
        $st{snaps}->{$bid} = { id => "$bid", name => "backup-$bid", creationTime => '2026-10-29T10:00:00.000Z',
            storageResource => $s->{storageResource} };
        (200, { content => { backup => { id => "$bid" } } }) }) ],
    [ POST => qr{$I/storageResource/([^/]+)/action/createLunThinClone$}, $w->(sub {
        my ($base, $b) = ($_[0]->[0], $_[2]);
        my $s = $st{snaps}->{$b->{snap}->{id}} or return $err->(404, 'not found');
        return $err->(400, 'Snapshot does not belong to the LUN.') if ($s->{lun}->{id} // '') ne $base;
        return $err->(400, 'Thin clone needs a thin LUN.') if !$st{luns}->{$base}->{isThinEnabled};
        my $l = $st{luns}->{$base};
        my $id = $lun_new->($b->{name}, $l->{sizeTotal}, JSON::PP::true, $l->{pool}->{id});
        $st{luns}->{$id}->{req} = $b;
        (200, { content => { storageResource => { id => $id } } }) }) ],
]);

require MIME::Base64;

ok(grep({ $_ eq 'dell-unity' } @{PVE::SAN::Array::types()}), 'dell-unity registered');
is(PVE::SAN::Array::driver_class('dell-unity'), 'PVE::SAN::Array::Unity', 'driver class');
is(PVE::SAN::Array::Unity->default_port, 443, 'Unisphere on port 443');

# --- auth ---
my $info = $drv->system_info();
is_deeply($info, { name => 'unity-lab', product => 'Dell Unity 480F', code_level => '5.4.0', id => 'APM00000000001' },
    'system info');
my $g = $calls->[0];
is($g->{headers}->{'X-EMC-REST-CLIENT'}, 'true', 'X-EMC-REST-CLIENT header');
like($g->{headers}->{Authorization}, qr/^Basic /, 'Basic auth');
like($g->{url}, qr{compact=true}, 'compact responses');
like($g->{url}, qr{fields=id%2Cname%2Cmodel%2CserialNumber}, 'fields requested');
is($st{logins}, 0, 'reads need no CSRF token');

my $pools = $drv->pools();
is_deeply([ map { [ $_->{id}, $_->{name}, $_->{capacity}, $_->{free}, $_->{status} ] } @$pools ],
    [ [ 'pool_1', 'Pool0', 10240 * $GIB, 4096 * $GIB, 'online' ], [ 'pool_2', 'Pool1', 1024 * $GIB, 0, 'degraded' ] ],
    'pools');

# --- registration: one host per node, FC initiators WWNN:WWPN ---
my $res = $drv->ensure_hostcluster('pvelab', $drv->{node_wwpns}, sub {});
is($st{logins}, 1, 'CSRF token fetched before the first write');
my $first_write = (grep { $_->{method} ne 'GET' } @$calls)[0];
is($first_write->{headers}->{'EMC-CSRF-TOKEN'}, 'C1', 'CSRF token sent on writes');
like($first_write->{headers}->{Cookie}, qr/mod_sec_emc=S1/, 'session cookie sent with it');
like($first_write->{headers}->{Cookie}, qr/LOGIN_TICKET=x1/, 'every cookie kept');
ok(FakeArray::find_call($calls, 'GET', qr{/host/instances\?.*page=2}), 'host list follows the next link');

is($res->{pvenode01}->{host}, 'pvenode01', 'existing host reused');
is_deeply($res->{pvenode01}->{added_ports}, ['5000000000000002'], 'missing port added');
ok($res->{pvenode02}->{created}, 'new host for pvenode02');
my ($new) = grep { $_->{name} eq 'pvenode02' } values %{$st{hosts}};
is_deeply($new->{req}, { type => 1, name => 'pvenode02', osType => 'Linux' }, 'host create body');
my @made = map { $_->{body} } grep { $_->{method} eq 'POST' && $_->{url} =~ m{/hostInitiator/instances} } @$calls;
is_deeply(\@made, [
    { host => { id => 'Host_1' }, initiatorType => 1, initiatorWWNorIqn => '20:00:00:00:00:00:00:02:50:00:00:00:00:00:00:02' },
    { host => { id => $new->{id} }, initiatorType => 1, initiatorWWNorIqn => '20:00:00:00:00:00:00:06:50:00:00:00:00:00:00:06' },
], 'FC initiators created as WWNN:WWPN');
is($st{inits}->{HostInitiator_2}->{parentHost}->{id}, $new->{id}, 'logged-in initiator moved to the new host');
is_deeply(FakeArray::find_call($calls, 'POST', qr{/hostInitiator/HostInitiator_2/action/modify})->{body},
    { host => { id => $new->{id} } }, 'initiator modify body');

my $n = scalar(@$calls);
$drv->ensure_hostcluster('pvelab', $drv->{node_wwpns}, sub {});
is(scalar(grep { $_->{method} ne 'GET' } @{$calls}[$n .. $#$calls]), 0, 'registration is idempotent');

my %hosts = map { $_->{name} => $_ } @{$drv->hosts()};
is_deeply($hosts{pvenode02}->{wwpns}, ['5000000000000005', '5000000000000006'], 'host ports from its FC initiators');
is($hosts{pvenode01}->{hostcluster}, 'pvelab', 'node hosts are in the host cluster');
is($hosts{esx01}->{hostcluster}, undef, 'foreign host is not');
is_deeply($hosts{esx01}->{wwpns}, ['10000000C9AAAAAA'], 'iSCSI initiators ignored');

{
    my ($d2) = FakeArray::driver('PVE::SAN::Array::Unity', { node_wwpns => { pvenode03 => ['5000000000000009'] }, node_wwnns => {} },
        [ [ GET => qr{$T/(host|hostInitiator)/instances$}, sub { $entries->() } ],
          [ GET => qr{$T/user/instances$}, sub { (200, {}, { 'emc-csrf-token' => 'x' }) } ],
          [ POST => qr{$T/host/instances$}, sub { (201, { content => { id => 'Host_9' } }) } ] ]);
    eval { $d2->ensure_hostcluster('pvelab', $d2->{node_wwpns}, sub {}) };
    like($@, qr/no WWNN known for port 5000000000000009/, 'unknown WWNN reported');
}

# --- volumes ---
my $v = $drv->create_volume(name => 'gold_01', pool => 'Pool0', size_gib => 100);
is_deeply($st{luns}->{$v->{id}}->{req}, { name => 'gold_01',
    lunParameters => { pool => { id => 'pool_1' }, size => 100 * $GIB, isThinEnabled => JSON::PP::true } },
    'createLun body (bytes, thin)');
is($v->{wwid}, '36006016000000000000000000000ab' . sprintf('%02x', $st{n}), 'WWID from the LUN wwn');
is($v->{capacity}, 100 * $GIB, 'capacity');
is_deeply([ sort keys %$v ], [ qw(capacity id name pool uid wwid) ], 'volume record');
my $thick = $drv->create_volume(name => 'thick_01', pool => 'Pool0', size_gib => 1, thin => 0);
ok(!$st{luns}->{$thick->{id}}->{req}->{lunParameters}->{isThinEnabled}, 'thick LUN');
eval { $drv->create_volume(name => 'gold_01', pool => 'Pool0', size_gib => 1) };
like($@, qr/^Unity POST .*createLun failed \(HTTP 409\): The LUN name is already in use\. \(Error Code:0x6000c11\)$/,
    'error format: the array message');
eval { $drv->create_volume(name => 'x', pool => 'nope', size_gib => 1) };
like($@, qr/Unity pool 'nope' not found/, 'unknown pool');
eval { $drv->create_volume(name => 'bad,name', pool => 'Pool0', size_gib => 1) };
like($@, qr/invalid Unity LUN name/, 'name rules');

is_deeply($drv->find_volume_by_wwid($v->{wwid}), $v, 'found by WWID');
is($drv->find_volume_by_wwid('36000000000000000000000000000000f'), undef, 'unknown WWID');

$st{luns}->{$v->{id}}->{hostAccess} = [ { host => { id => 'Host_2' }, accessMask => 3 } ];
$drv->map_to_hostcluster($v->{id}, 'pvelab');
my $ml = FakeArray::find_call($calls, 'POST', qr{/storageResource/\Q$v->{id}\E/action/modifyLun});
is_deeply($ml->{body}, { lunParameters => { hostAccess => [
    { host => { id => 'Host_2' }, accessMask => 3 },
    { host => { id => 'Host_1' }, accessMask => 1 },
    { host => { id => $new->{id} }, accessMask => 1 },
] } }, 'modifyLun: every node host added, other hosts kept');

$n = scalar(@$calls);
$drv->map_to_hostcluster($v->{id}, 'pvelab');
is(scalar(grep { $_->{method} ne 'GET' } @{$calls}[$n .. $#$calls]), 0, 'mapping is idempotent');

$st{expire_csrf} = 1;
$drv->expand_volume($v->{id}, 50 * $GIB);
is($st{luns}->{$v->{id}}->{sizeTotal}, 150 * $GIB, 'expanded by modifyLun size');
is($st{logins}, 2, 'new CSRF token after a 401');
eval { $drv->expand_volume($v->{id}, 1000) };
like($@, qr/multiple of 1 MiB/, 'expansion granularity');

$drv->unmap_from_hostcluster($v->{id}, 'pvelab');
is_deeply($st{luns}->{$v->{id}}->{hostAccess}, [ { host => { id => 'Host_2' }, accessMask => 3 } ],
    'unmap removes only the cluster hosts');

is_deeply($drv->volume_space([ $v->{id} ]), [ { id => $v->{id}, provisioned => 150 * $GIB, written => 0 } ], 'volume space');

# --- snapshots of one LUN ---
ok($drv->supports_snapshots && $drv->supports_group_snapshots, 'snapshots offered');
my $s = $drv->snapshot_create([ $v->{id} ], 'before-upgrade');
my $mk = FakeArray::find_call($calls, 'POST', qr{/snap/instances});
is_deeply($mk->{body}, { storageResource => { id => $v->{id} }, name => 'gold_01.before-upgrade', isAutoDelete => JSON::PP::false },
    'snapshot body');
is(scalar(@$s), 1, 'one snapshot');
is_deeply([ @{$s->[0]}{qw(name volume size)} ], [ 'before-upgrade', $v->{id}, 0 ], 'snapshot record');
like($s->[0]->{created}, qr/^\d+$/, 'creation time parsed');
is(PVE::SAN::Array::Unity::parse_timestamp('2016-03-01T03:21:38.000Z'), 1456802498, 'creationTime to epoch');

eval { $drv->snapshot_create([ $v->{id} ], 'before-upgrade') };
like($@, qr/Specified snapshot name is already in use/, 'array error passed on');

$st{snaps}->{1} = { id => '1', name => 'hourly', creationTime => '2026-10-29T08:00:00.000Z', storageResource => { id => $v->{id} },
    lun => { id => $v->{id} } };
is_deeply([ map { $_->{name} } @{$drv->snapshots([ $v->{id} ])} ], [ 'before-upgrade' ], 'only pvesan snapshots listed');
delete $st{snaps}->{1};

my $c = $drv->snapshot_clone($s->[0], 'gold_copy');
my $tc = FakeArray::find_call($calls, 'POST', qr{/createLunThinClone});
like($tc->{url}, qr{/api/instances/storageResource/\Q$v->{id}\E/action/createLunThinClone}, 'thin clone of the source LUN');
is_deeply($tc->{body}, { name => 'gold_copy', snap => { id => $s->[0]->{id} } }, 'thin clone body');
is($c->{name}, 'gold_copy', 'clone volume');
is_deeply($st{luns}->{$c->{id}}->{hostAccess}, [], 'clone unmapped');

$drv->snapshot_restore($v->{id}, $s->[0]);
is_deeply($st{restored}, [ $s->[0]->{id} ], 'snapshot restored');
is_deeply(FakeArray::find_call($calls, 'POST', qr{/action/restore})->{body}, {}, 'restore body');
is(scalar(grep { $_->{name} =~ /^backup-/ } values %{$st{snaps}}), 0, 'backup snapshot deleted afterwards');

eval { $drv->delete_volume($v->{id}) };
like($@, qr/The LUN has snapshots/, 'LUN with snapshots is refused by the array');
is_deeply($st{deleted}->[-1]->[1], { forceSnapDeletion => JSON::PP::false, forceVvolDeletion => JSON::PP::false },
    'delete body keeps snapshots');
$drv->snapshot_delete($s->[0]);
is_deeply($drv->snapshots([ $v->{id} ]), [], 'snapshot deleted');

# --- consistency group snapshots ---
my $v2 = $drv->create_volume(name => 'gold_02', pool => 'Pool0', size_gib => 10);
my $set = $drv->snapshot_create([ $v->{id}, $v2->{id} ], 'nightly');
my $cg = FakeArray::find_call($calls, 'POST', qr{/createConsistencyGroup});
is_deeply($cg->{body}, { name => 'pvesan-gold_01', lunAdd => [ { lun => { id => $v->{id} } }, { lun => { id => $v2->{id} } } ] },
    'consistency group created with both LUNs');
my ($cgid) = keys %{$st{cgs}};
is_deeply((grep { $_->{url} =~ m{/snap/instances} && $_->{method} eq 'POST' } @$calls)[-1]->{body},
    { storageResource => { id => $cgid }, name => 'pvesan-gold_01.nightly', isAutoDelete => JSON::PP::false },
    'snapshot of the consistency group');
is_deeply([ sort map { $_->{volume} } @$set ], [ sort $v->{id}, $v2->{id} ], 'a member snapshot per LUN');
is_deeply([ map { $_->{name} } @$set ], [ 'nightly', 'nightly' ], 'members carry the set name');
ok($set->[0]->{group} && $set->[0]->{group} eq $set->[1]->{group}, 'members name their group snapshot');
is_deeply([ map { $_->{name} } @{$drv->snapshots([ $v->{id}, $v2->{id} ])} ], [ 'nightly', 'nightly' ], 'set listed');

$drv->expand_volume($v2->{id}, $GIB);
is_deeply($st{cg_log}->[-1], { lunModify => [ { lun => { id => $v2->{id} }, lunParameters => { size => 11 * $GIB } } ] },
    'member LUN expanded through its group');
$drv->map_to_hostcluster($v2->{id}, 'pvelab');
is(scalar(@{$st{luns}->{$v2->{id}}->{hostAccess}}), 2, 'member LUN mapped through its group');

my $v3 = $drv->create_volume(name => 'gold_03', pool => 'Pool0', size_gib => 10);
$drv->snapshot_create([ $v->{id}, $v2->{id}, $v3->{id} ], 'weekly');
is_deeply($st{cg_log}->[-1], { lunAdd => [ { lun => { id => $v3->{id} } } ] }, 'new LUN added to the group');
is(scalar(keys %{$st{cgs}}), 1, 'still one group');

eval { $drv->snapshot_clone($set->[0], 'nope') };
like($@, qr/copies of a consistency group snapshot .* not supported/, 'member snapshots cannot be copied');
eval { $drv->snapshot_create([ $v->{id} ], 'one') };
like($@, qr/is in consistency group/, 'a single member is not snapshotted alone');

@{$st{restored}} = ();
$drv->snapshot_restore($_->{volume}, $_) for @$set;
is_deeply($st{restored}, [ $set->[0]->{group} ], 'group restored once for the whole set');

$drv->snapshot_delete($set->[0]);
is_deeply([ map { $_->{name} } @{$drv->snapshots([ $v->{id}, $v2->{id}, $v3->{id} ])} ], [ ('weekly') x 3 ],
    'the set went as a whole');
$drv->snapshot_delete($_) for grep { $_->{volume} eq $v->{id} } @{$drv->snapshots([ $v->{id} ])};
is_deeply($drv->snapshots([ $v->{id}, $v2->{id}, $v3->{id} ]), [], 'all sets deleted');

$drv->delete_volume($v3->{id});
is_deeply($st{cg_log}->[-1], { lunRemove => [ { lun => { id => $v3->{id} } } ] }, 'member removed from its group first');
ok(!$st{luns}->{$v3->{id}}, 'member LUN deleted');
$drv->delete_volume($_) for $v2->{id}, $v->{id};
ok(!%{$st{cgs}}, 'empty consistency group deleted');
ok(!$st{luns}->{$v->{id}} && !$st{luns}->{$v2->{id}}, 'LUNs deleted');

# --- error format ---
is(PVE::SAN::Array::Unity::error_text('{"error":{"errorCode":1903001605,"httpStatusCode":409,"messages":[{"en-US":"A."},{"en-US":"B."}]}}'),
    'A.. B.', 'messages joined');
is(PVE::SAN::Array::Unity::error_text('{"error":{"errorCode":131149829}}'), 'error code 131149829', 'code when no message');
is(PVE::SAN::Array::Unity::error_text('<html>busy</html>'), '<html>busy</html>', 'non-JSON body as it is');

done_testing();
