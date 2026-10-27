use strict;
use warnings;

use Test::More;
use JSON::PP;

use FakeArray;
use PVE::SAN::Array::Hitachi;

my $GIB = 1024 ** 3;
my $B = qr{^/ConfigurationManager/v1/objects/storages/886000412345};

my %st = (hgs => { 'CL1-A' => [], 'CL2-A' => [ { hostGroupNumber => 0, hostGroupName => '2A-G00' } ] },
    wwns => {}, ldevs => {}, luns => [], jobs => 0);
my $job = sub {
    my ($res, $state) = @_;
    (202, { jobId => ++$st{jobs}, status => 'Completed', state => $state // 'Succeeded',
        affectedResources => [ $res ], ($state ? (error => { messageId => 'KART30000-E', message => 'failed' }) : ()) });
};
my ($drv, $calls) = FakeArray::driver('PVE::SAN::Array::Hitachi', { target_ports => 'CL1-A,CL2-A' }, [
    [ GET => qr{^/ConfigurationManager/v1/objects/storages$}, sub { (200, { data => [ { storageDeviceId => '886000412345' } ] }) } ],
    [ POST => qr{$B/sessions$}, sub { (200, { token => 'T1', sessionId => 7 }) } ],
    [ GET => qr{$B$}, sub { (200, { storageDeviceId => '886000412345', model => 'VSP E990', serialNumber => 412345, dkcMicroVersion => '93-06-21' }) } ],
    [ GET => qr{$B/pools$}, sub { (200, { data => [ { poolId => 3, poolName => 'DP_POOL', poolStatus => 'POLN', totalPoolCapacity => 1048576, availableVolumeCapacity => 524288 } ] }) } ],
    [ GET => qr{$B/host-groups$}, sub { (200, { data => $st{hgs}->{$_[1]->{portId}} }) } ],
    [ POST => qr{$B/host-groups$}, sub {
        my $b = $_[2]; my $n = scalar(@{$st{hgs}->{$b->{portId}}}) + 1;
        push @{$st{hgs}->{$b->{portId}}}, { hostGroupNumber => $n, %$b };
        $job->("/ConfigurationManager/v1/objects/host-groups/$b->{portId},$n") } ],
    [ GET => qr{$B/host-wwns$}, sub { (200, { data => [ map { { hostWwn => $_ } } @{$st{wwns}->{"$_[1]->{portId},$_[1]->{hostGroupNumber}"} // []} ] }) } ],
    [ POST => qr{$B/host-wwns$}, sub { push @{$st{wwns}->{"$_[2]->{portId},$_[2]->{hostGroupNumber}"}}, $_[2]->{hostWwn}; $job->('/x') } ],
    [ POST => qr{$B/ldevs$}, sub {
        $st{ldevs}->{513} = { ldevId => 513, poolId => $_[2]->{poolId}, blockCapacity => 100 * $GIB / 512, req => $_[2] };
        $job->('/ConfigurationManager/v1/objects/ldevs/513') } ],
    [ PUT => qr{$B/ldevs/(\d+)$}, sub { $st{ldevs}->{$_[0]->[0]}->{label} = $_[2]->{label}; $job->('/x') } ],
    [ GET => qr{$B/ldevs/(\d+)$}, sub {
        my $l = { %{$st{ldevs}->{$_[0]->[0]}} };
        $l->{naaId} = '60060e8012a0c40050412a0c40000201' if grep { $_->{ldevId} == $l->{ldevId} } @{$st{luns}}; # only with an LU path
        (200, $l) } ],
    [ PUT => qr{$B/ldevs/(\d+)/actions/expand/invoke$}, sub {
        my ($n) = $_[2]->{parameters}->{additionalByteFormatCapacity} =~ /^(\d+)G$/;
        $st{ldevs}->{$_[0]->[0]}->{blockCapacity} += $n * $GIB / 512; $job->('/x') } ],
    [ DELETE => qr{$B/ldevs/(\d+)$}, sub {
        return $job->('/x', 'Failed') if grep { $_->{ldevId} == $_[0]->[0] } @{$st{luns}};
        delete $st{ldevs}->{$_[0]->[0]}; $job->('/x') } ],
    [ POST => qr{$B/luns$}, sub {
        push @{$st{luns}}, { lunId => "$_[2]->{portId},$_[2]->{hostGroupNumber},0", lun => 0, %{$_[2]} }; $job->('/x') } ],
    [ GET => qr{$B/luns$}, sub {
        (200, { data => [ grep { $_->{portId} eq $_[1]->{portId} && $_->{hostGroupNumber} == $_[1]->{hostGroupNumber} } @{$st{luns}} ] }) } ],
    [ DELETE => qr{$B/luns/(.+)$}, sub { $st{luns} = [ grep { $_->{lunId} ne $_[0]->[0] } @{$st{luns}} ]; $job->('/x') } ],
]);

eval { PVE::SAN::Array::Hitachi->new(address => 'a', username => 'u', password => 'p', fingerprint => 'sha256$0') };
like($@, qr/'target-ports' is required/, 'Hitachi: target ports required');

my $info = $drv->system_info();
is($info->{product}, 'Hitachi VSP E990', 'model');
ok(FakeArray::find_call($calls, 'GET', qr{/objects/storages$}), 'storage device id discovered');
is($calls->[-1]->{headers}->{Authorization}, 'Session T1', 'session token header');
is($drv->pools->[0]->{free}, 512 * $GIB, 'pool capacity in MB converted');

my $res = $drv->ensure_hostcluster('pvelab', {
    pvenode01 => ['50:00:00:00:00:00:00:01'], pvenode02 => ['50:00:00:00:00:00:00:05'] }, sub {});
my @hg = grep { $_->{method} eq 'POST' && $_->{url} =~ m{/host-groups$} } @$calls;
is(scalar(@hg), 2, 'one host group per target port');
is_deeply($hg[0]->{body}, { portId => 'CL1-A', hostGroupName => 'pvelab', hostMode => 'LINUX/IRIX' }, 'host group body');
is($hg[0]->{headers}->{'Response-Job-Status'}, 'Completed;', 'changes wait for their job');
is(scalar(grep { $_->{method} eq 'POST' && $_->{url} =~ m{/host-wwns$} } @$calls), 4, 'each WWN on each port');
is_deeply(FakeArray::find_call($calls, 'POST', qr{/host-wwns$})->{body},
    { hostWwn => '5000000000000001', portId => 'CL1-A', hostGroupNumber => 1 }, 'host-wwns body');

my $n = scalar(@$calls);
$drv->ensure_hostcluster('pvelab', { pvenode01 => ['5000000000000001'], pvenode02 => ['5000000000000005'] }, sub {});
is(scalar(grep { $_->{method} eq 'POST' } @{$calls}[$n .. $#$calls]), 0, 'idempotent');

ok($drv->wwid_after_map, 'NAA ID only after mapping');
my $v = $drv->create_volume(name => 'gold_01', pool => 'DP_POOL', size_gib => 100);
is_deeply($st{ldevs}->{513}->{req}, { poolId => 3, byteFormatCapacity => '100G', isParallelExecutionEnabled => JSON::PP::true },
    'LDEV create body');
is($st{ldevs}->{513}->{label}, 'gold_01', 'label set');
is($v->{wwid}, undef, 'no WWID before an LU path');

$drv->map_to_hostcluster($v->{id}, 'pvelab');
is(scalar(@{$st{luns}}), 2, 'LU path on each port');
is($drv->volume($v->{id})->{wwid}, '360060e8012a0c40050412a0c40000201', 'WWID after mapping');

$drv->expand_volume($v->{id}, 50 * $GIB);
is($drv->volume($v->{id})->{capacity}, 150 * $GIB, 'expand by additionalByteFormatCapacity');

eval { $drv->delete_volume($v->{id}) };
like($@, qr/state Failed: KART30000-E failed/, 'failed job is reported with the array message');
$drv->unmap_from_hostcluster($v->{id}, 'pvelab');
is_deeply($st{luns}, [], 'LU paths removed on every port');
$drv->delete_volume($v->{id});
ok(!$st{ldevs}->{513}, 'LDEV deleted');

done_testing();
