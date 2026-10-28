use strict;
use warnings;

use Test::More;
use JSON::PP;

use FakeArray;
use PVE::SAN::Array::Eternus;

my $GIB = 1024 ** 3;
my $A = qr{^/api/v1};

my %st = (
    hosts => { 7 => { host_id => 7, type => 'FC', name => 'HBA#1', wwn => '5000000000000001' },
               9 => { host_id => 9, type => 'FC', name => 'other', wwn => '10000000c9aaaaaa' } },
    vols => {}, conns => { 7 => { 40 => 0 } }, jobs => {}, next_job => 100, logins => 0, deleted_jobs => [],
    fail_delete => 0,
);
my $job = sub {
    my ($href, $err) = @_;
    my $id = $st{next_job}++;
    $st{jobs}->{$id} = $err
        ? { job_id => $id, status => 'Error', error_code => '0049', error_message => 'Resource is busy (volume)',
            operation_list => [ { result => 'Failed', operation => 'delete volume -volume-number 1' } ] }
        : { job_id => $id, status => 'Success', resource_href_list => $href ? [ $href ] : [] };
    (202, { job_id => $id, job_href => "/api/v1/job/$id" });
};
my $conn = sub {
    my ($h, $v) = @_;
    { connection_href => "/api/v1/connection/host/$h/volume/$v", host_href => "/api/v1/host/$h",
      volume_href => "/api/v1/volume/$v", hlun => $st{conns}->{$h}->{$v}, caport_href_list => [ '/api/v1/caport/0000' ] };
};
my ($drv, $calls) = FakeArray::driver('PVE::SAN::Array::Eternus', {
    hostcluster => 'pvelab', poll_interval => 0,
    node_wwpns => { pvenode01 => ['50:00:00:00:00:00:00:01', '50:00:00:00:00:00:00:02'],
                    'pve-very-long-node-name' => ['5000000000000005'] },
}, [
    [ POST => qr{$A/session$}, sub {
        $st{logins}++;
        return (401, { error_code => '0001', message => 'Authentication failed' }) if $_[2]->{password} ne 'secret';
        (200, { session_id => 100001, token => "T$st{logins}", lifetime => 1800 }) } ],
    [ DELETE => qr{$A/session/(\d+)$}, sub { (200, {}) } ],
    [ GET => qr{$A/job/(\d+)$}, sub { (200, $st{jobs}->{$_[0]->[0]}) } ],
    [ DELETE => qr{$A/job/(\d+)$}, sub { push @{$st{deleted_jobs}}, $_[0]->[0]; (200, {}) } ],
    [ GET => qr{$A/storagesystem$}, sub {
        return (401, {}) if $_[3]->{Authorization} eq 'Bearer T1' && $st{expire}; # token expired
        (200, { storage_system_name => 'DX200-LAB', model_name => 'ET203SAU', serial_number => '4601234567',
            firmware_version => 'V11L40-0000' }) } ],
    [ GET => qr{$A/tpp$}, sub {
        (200, { total_count => 1, list_count => 1, tpp_list => [ { tpp_id => 2, name => 'TPP_GOLD', status => 'Normal',
            physical_capacity => 1048576, used_capacity => 262144 } ] }) } ],
    [ GET => qr{$A/host$}, sub {
        my @h = map { $st{hosts}->{$_} } sort { $a <=> $b } keys %{$st{hosts}};
        return (200, { host_list => [ @h[0 .. 0] ], next_href => '/api/v1/host?type=FC&last_get_id=7' })
            if !$_[1]->{last_get_id};
        (200, { host_list => [ @h[1 .. $#h] ] }) } ],
    [ POST => qr{$A/host$}, sub {
        my $id = 256 + scalar(keys %{$st{hosts}});
        $st{hosts}->{$id} = { host_id => $id, type => 'FC', %{$_[2]} };
        $job->("/api/v1/host/$id") } ],
    [ POST => qr{$A/volume$}, sub {
        $st{vols}->{1001} = { volume_id => 1001, name => $_[2]->{name}, capacity => $_[2]->{capacity},
            uid => '600000e00d3100000031234500010000', req => $_[2] };
        $job->('/api/v1/volume/1001') } ],
    [ GET => qr{$A/volume/(\d+)$}, sub { $st{vols}->{$_[0]->[0]} ? (200, $st{vols}->{$_[0]->[0]}) : (404, {}) } ],
    [ GET => qr{$A/volume$}, sub { (200, { volume_list => [ values %{$st{vols}} ] }) } ],
    [ POST => qr{$A/volume/(\d+)/expand$}, sub { $st{vols}->{$_[0]->[0]}->{capacity} = $_[2]->{new_capacity}; $job->() } ],
    [ DELETE => qr{$A/volume/(\d+)$}, sub {
        return $job->(undef, 1) if grep { exists $_->{$_[0]->[0]} } values %{$st{conns}};
        delete $st{vols}->{$_[0]->[0]}; $job->() } ],
    [ GET => qr{$A/connection/host/(\d+)$}, sub {
        my $h = $_[0]->[0];
        (200, { connection_list => [ map { $conn->($h, $_) } sort keys %{$st{conns}->{$h} // {}} ] }) } ],
    [ GET => qr{$A/connection/host/(\d+)/volume/(\d+)$}, sub {
        my ($h, $v) = @{$_[0]};
        defined($st{conns}->{$h}->{$v}) ? (200, $conn->($h, $v)) : (404, { error_code => '0110', message => 'not found' }) } ],
    [ POST => qr{$A/connection/host/(\d+)/volume/(\d+)$}, sub {
        my ($h, $v) = @{$_[0]};
        $st{conns}->{$h}->{$v} = $_[2]->{hlun};
        $job->("/api/v1/connection/host/$h/volume/$v") } ],
    [ GET => qr{$A/connection/volume/(\d+)$}, sub {
        my $v = $_[0]->[0];
        (200, { volume_id => $v, connection_href_list => [ map { "/api/v1/connection/host/$_/volume/$v" }
            sort grep { defined $st{conns}->{$_}->{$v} } keys %{$st{conns}} ] }) } ],
    [ DELETE => qr{$A/connection/host/(\d+)/volume/(\d+)$}, sub {
        delete $st{conns}->{$_[0]->[0]}->{$_[0]->[1]}; $st{last_force} = $_[1]->{force}; $job->() } ],
]);

is(PVE::SAN::Array::Eternus->default_port, 5665, 'RESTful API port 5665');

my $info = $drv->system_info();
is($info->{product}, 'Fujitsu ETERNUS ET203SAU', 'model');
is($info->{code_level}, 'V11L40-0000', 'firmware');
is_deeply(FakeArray::find_call($calls, 'POST', qr{/session$})->{body}, { user_name => 'pvesan', password => 'secret' },
    'session login body');
is($calls->[-1]->{headers}->{Authorization}, 'Bearer T1', 'bearer token');

$st{expire} = 1;
$drv->system_info();
is($st{logins}, 2, 'logs in again when the token has expired');
is($calls->[-1]->{headers}->{Authorization}, 'Bearer T2', 'new token used');

my $pool = $drv->pools->[0];
is($pool->{capacity}, 1024 * $GIB, 'pool capacity from MB');
is($pool->{free}, 768 * $GIB, 'pool free = physical - used');

# --- registration: one host per WWN ---
my $res = $drv->ensure_hostcluster('pvelab', $drv->{node_wwpns}, sub {});
my @created = map { $_->{body} } grep { $_->{method} eq 'POST' && $_->{url} =~ m{/host$} } @$calls;
is_deeply(\@created, [
    { type => 'FC', name => 'pve-very-long_1', wwn => '5000000000000005' },
    { type => 'FC', name => 'pvenode01_1', wwn => '5000000000000002' },
], 'missing WWNs registered as FC hosts, names within 16 characters');
ok(FakeArray::find_call($calls, 'GET', qr{/host\?.*last_get_id=7}), 'host list follows next_href');
is($res->{pvenode01}->{host}, 'HBA#1+pvenode01_1', 'existing host reused');
is_deeply($res->{pvenode01}->{added_ports}, ['5000000000000002'], 'only the missing port added');
ok(@{$st{deleted_jobs}} >= 2, 'finished jobs are deleted');

my $n = scalar(@$calls);
$drv->ensure_hostcluster('pvelab', $drv->{node_wwpns}, sub {});
is(scalar(grep { $_->{method} eq 'POST' } @{$calls}[$n .. $#$calls]), 0, 'registration is idempotent');

my %hosts = map { $_->{name} => $_ } @{$drv->hosts()};
is_deeply([ sort @{$hosts{'HBA#1+pvenode01_1'}->{wwpns}} ], ['5000000000000001', '5000000000000002'],
    'a node\'s WWN hosts show as one host');
is($hosts{'HBA#1+pvenode01_1'}->{hostcluster}, 'pvelab', 'cluster hosts are in the host cluster');
is($hosts{other}->{hostcluster}, undef, 'foreign host is not');

# --- volumes ---
my $v = $drv->create_volume(name => 'gold_01', pool => 'TPP_GOLD', size_gib => 100);
is_deeply($st{vols}->{1001}->{req}, { name => 'gold_01', capacity => 102400, tpp_id => 2,
    is_thick_provisioned => JSON::PP::false }, 'volume create body (MB, thin)');
is($v->{id}, 1001, 'volume id from the job');
is($v->{wwid}, '3600000e00d3100000031234500010000', 'WWID from the volume UID');
is($v->{capacity}, 100 * $GIB, 'capacity from MB');
eval { $drv->create_volume(name => 'bad,name', pool => 'TPP_GOLD', size_gib => 1) };
like($@, qr/invalid ETERNUS volume name/, 'name rules');

$drv->map_to_hostcluster($v->{id}, 'pvelab');
my @hl = map { $st{conns}->{$_}->{1001} } grep { $_ != 9 } sort keys %{$st{hosts}};
is_deeply(\@hl, [1, 1, 1], 'connected to every cluster host with one free host LUN');
ok(!defined($st{conns}->{9}->{1001}), 'foreign host not connected');

$n = scalar(@$calls);
$drv->map_to_hostcluster($v->{id}, 'pvelab');
is(scalar(grep { $_->{method} eq 'POST' } @{$calls}[$n .. $#$calls]), 0, 'mapping is idempotent');

$drv->expand_volume($v->{id}, 50 * $GIB);
is($drv->volume($v->{id})->{capacity}, 150 * $GIB, 'expand by new_capacity');

eval { $drv->delete_volume($v->{id}) };
like($@, qr/job \d+ error: 0049 Resource is busy \(volume\) \(delete volume -volume-number 1\)/,
    'failed job is reported with the array message');

$drv->unmap_from_hostcluster($v->{id}, 'pvelab');
ok(!grep({ exists $_->{1001} } values %{$st{conns}}), 'all connections of the volume removed');
is($st{last_force}, 'true', 'connections deleted with force');
$drv->delete_volume($v->{id});
ok(!$st{vols}->{1001}, 'volume deleted');

# a host that shares its LUN group with a host outside the cluster
$st{hosts}->{7}->{is_shared_host_exist} = JSON::PP::true;
$conn = do { my $old = $conn; sub { my $c = $old->(@_); $c->{shared_host_href_list} = [ '/api/v1/host/9' ]; $c } };
$st{vols}->{1002} = { volume_id => 1002, name => 'x', capacity => 1024, uid => '600000e00d3100000031234500020000' };
eval { $drv->map_to_hostcluster(1002, 'pvelab') };
like($@, qr/shares its LUN group with hosts outside this cluster/, 'shared LUN group outside the cluster refused');

undef $drv;
ok(FakeArray::find_call($calls, 'DELETE', qr{/session/100001$}), 'session closed');

done_testing();
