use strict;
use warnings;

use Test::More;
use JSON::PP;

use StubPVE;
use FakeArray;
use PVE::SAN::Monitor;
use PVE::SAN::Multipath;
use PVE::SAN::Array::Pure;
use PVE::SAN::Array::Infinidat;
use PVE::SAN::Array::PowerStore;
use PVE::SAN::Array::IBMSV;
use PVE::SAN::Array::ONTAP;
use PVE::SAN::Array::Hitachi;

my $GIB = 1024 ** 3;
my $M = 'PVE::SAN::Monitor';

# ---------------- I/O rates ----------------
{
    my $a = PVE::SAN::Monitor::parse_stat('    1000 0 80000 2000 500 0 40000 5000 3 4000 7000 0 0 0 0');
    my $b = PVE::SAN::Monitor::parse_stat('    1200 0 96000 2400 900 0 72000 9000 1 5000 9000 0 0 0 0');
    is($a->{w_ios}, 500, 'stat fields parsed');
    is(PVE::SAN::Monitor::parse_stat('1 2 3'), undef, 'short stat line refused');
    my $r = PVE::SAN::Monitor::io_rates($a, $b, 2);
    is_deeply($r, { r_iops => 100, w_iops => 200, r_bps => 4096000, w_bps => 8192000,
        r_lat_ms => 2, w_lat_ms => 10, util => 50, in_flight => 1 }, 'IOPS, throughput, latency, utilisation');
    is(PVE::SAN::Monitor::io_rates($b, $a, 2), undef, 'counter reset gives no rates');
    is(PVE::SAN::Monitor::io_rates($a, $a, 2)->{r_lat_ms}, 0, 'no I/O, no latency');
}

# ---------------- path health ----------------
{
    my $watch = { '3600a1' => 'gold', '3600a2' => 'gold', '3600a3' => 'silver' };
    my $devs = [
        { wwid => '3600a1', name => 'gold', alias => 'gold', paths_active => 4, paths_total => 4 },
        { wwid => '3600a2', name => 'gold-01', paths_active => 2, paths_total => 4 },
        { wwid => '3600ff', name => 'other', paths_active => 0, paths_total => 2 },
    ];
    my ($p, $exp) = PVE::SAN::Monitor::path_problems($devs, $watch, { '3600a1' => 8, gone => 4 });
    is_deeply([ sort keys %$p ], [ 'degraded:3600a1', 'degraded:3600a2', 'missing:3600a3' ], 'problems found');
    like($p->{'degraded:3600a1'}, qr/4 of 8 paths/, 'fewer paths than learned before');
    like($p->{'degraded:3600a2'}, qr/2 of 4 paths/, 'paths down');
    like($p->{'missing:3600a3'}, qr/datastore 'silver' is not visible/, 'missing LUN');
    is_deeply($exp, { '3600a1' => 8, '3600a2' => 4 }, 'learned counts kept, unwatched forgotten');
    $devs->[1]->{paths_active} = 0;
    ($p) = PVE::SAN::Monitor::path_problems($devs, $watch, {});
    like($p->{'dead:3600a2'}, qr/no active path/, 'dead LUN');
    ok(!$p->{'degraded:3600ff'} && !$p->{'dead:3600ff'}, 'LUNs outside datastores are not watched');
}

{
    my ($new, $resolved) = PVE::SAN::Monitor::diff_problems({ a => 'A', b => 'B' }, { b => 'B', c => 'C' });
    is_deeply($new, [ 'C' ], 'new problem');
    is_deeply($resolved, [ 'A' ], 'resolved problem');
    is_deeply([ PVE::SAN::Monitor::diff_problems(undef, {}) ], [ [], [] ], 'nothing to report');
}

{
    my $v = { storage => 'gold', array => 'fa1', pools => [ { name => 'p1', used_pct => 91.5 }, { name => 'p2', used_pct => 40 } ],
        health => { status => 'warning', alerts => [ { severity => 'warning', summary => 'controller CT1 degraded' }, { severity => 'info', summary => 'x' } ] } };
    my $p = PVE::SAN::Monitor::view_problems($v, 85);
    is_deeply([ sort keys %$p ], [ 'health:fa1', 'pool:fa1:p1' ], 'pool over threshold and array health');
    like($p->{'health:fa1'}, qr/reports warning: controller CT1 degraded$/, 'only warning and critical alerts quoted');
    is_deeply(PVE::SAN::Monitor::view_problems({ storage => 'gold', array => 'fa1', error => 'timeout' }, 85),
        { 'array-error:gold' => "array 'fa1' could not be read for datastore 'gold': timeout" }, 'failed array call');
}

# ---------------- zoning ----------------
{
    my $expected = [ '52:4a:93:7a:00:00:00:01', '524A937A00000002' ];
    my $logins = {
        n1 => [
            { adapter => 'host1', adapter_wwpn => '21:00:00:00:00:00:00:01', wwpn => '52:4a:93:7a:00:00:00:01', state => 'Online', roles => 'FCP Target' },
            { adapter => 'host2', adapter_wwpn => '21:00:00:00:00:00:00:02', wwpn => '52:4a:93:7a:00:00:00:02', state => 'Online', roles => 'FCP Target' },
        ],
        n2 => [
            { adapter => 'host1', adapter_wwpn => '21:00:00:00:00:00:00:03', wwpn => '52:4a:93:7a:00:00:00:01', state => 'Online', roles => 'FCP Target' },
            { adapter => 'host2', adapter_wwpn => '21:00:00:00:00:00:00:04', wwpn => '52:4a:93:7a:00:00:00:02', state => 'Blocked', roles => 'FCP Target' },
            { adapter => 'host2', adapter_wwpn => '21:00:00:00:00:00:00:04', wwpn => '50:00:00:00:00:00:00:99', state => 'Online', roles => 'FCP Target' },
        ],
        n3 => [],
    };
    my ($rows, $hints) = PVE::SAN::Monitor::zoning_rows($expected, $logins);
    is_deeply([ map { "$_->{node}/$_->{adapter}=$_->{seen}/$_->{expected}" } @$rows ],
        [ 'n1/host1=1/2', 'n1/host2=1/2', 'n2/host1=1/2', 'n2/host2=0/2' ], 'logins per adapter');
    is(scalar(@$hints), 3, 'three hints');
    like($hints->[0], qr/^n2 host2 .* logged in to none of the array's ports/, 'adapter without array logins');
    like($hints->[1], qr/^n2 sees no path to array port\(s\) 524A937A00000002/, 'node missing one array port');
    like($hints->[2], qr/^n3 has no FC adapter logged in/, 'node without logins');
}

# ---------------- node join and leave ----------------
{
    my $hosts = [
        { name => 'pve1', hostcluster => 'lab', wwpns => [ '2100000000000001' ] },
        { name => 'old-node', hostcluster => 'lab', wwpns => [ '2100000000000009' ] },
        { name => 'esx1', hostcluster => 'vmware', wwpns => [ '2100000000000077' ] },
        { name => 'pve2', hostcluster => 'lab', wwpns => [ '2100000000000020' ] }, # offline member
    ];
    my $wwpns = { pve1 => [ '21:00:00:00:00:00:00:01' ], pve3 => [ '21:00:00:00:00:00:00:03' ] };
    is_deeply(PVE::SAN::Monitor::unregistered_nodes($hosts, $wwpns), [ 'pve3' ], 'new node found');
    is_deeply([ map { $_->{name} } @{PVE::SAN::Monitor::stale_hosts($hosts, 'lab', $wwpns, [ 'pve1', 'pve2', 'pve3' ])} ],
        [ 'old-node' ], 'host of a removed node; other host clusters and members untouched');
}

# ---------------- guest configs ----------------
{
    my $raw = "scsi0: gold:vm-100-disk-0,size=32G\nide2: none,media=cdrom\nefidisk0: gold:vm-100-disk-1,size=4M\n"
        . "scsi1: local-lvm:vm-100-disk-2,size=8G\nmp0: volume=gold:subvol-100-disk-3,mp=/data\n[snap]\nscsi0: gold:old\n";
    is_deeply([ map { "$_->{key}=$_->{volume}" } @{PVE::SAN::Monitor::config_disks($raw, 'gold')} ],
        [ 'scsi0=vm-100-disk-0', 'efidisk0=vm-100-disk-1', 'mp0=subvol-100-disk-3' ], 'disks on one datastore');
    is(scalar(@{PVE::SAN::Monitor::config_disks($raw)}), 4, 'all disks of a guest');
    is(PVE::SAN::Monitor::config_disks($raw, 'gold')->[0]->{size}, '32G', 'size kept');
}

# ---------------- no_path_retry ----------------
{
    ok(PVE::SAN::Multipath::valid_no_path_retry($_), "no_path_retry '$_' valid") for qw(12 0 queue fail);
    ok(!PVE::SAN::Multipath::valid_no_path_retry($_), "no_path_retry '$_' refused") for ('', '-1', 'forever', '12345');
    my $conf = PVE::SAN::Multipath::render_conf({
        '3600a1' => { alias => 'gold', policy => 'alua', no_path_retry => 12 },
        '3600a2' => { no_path_retry => 'queue' },
        '3600a3' => { alias => 'x', no_path_retry => 'bad;value' },
    });
    like($conf, qr/alias gold\n(?:\t\t[^\n]*\n)*\t\tno_path_retry 12\n\t\}/, 'no_path_retry rendered after the policy');
    like($conf, qr/wwid 3600a2\n\t\tno_path_retry queue\n/, 'no_path_retry alone is enough for an entry');
    unlike($conf, qr/bad;value/, 'invalid value never reaches multipath.conf');
    is(PVE::SAN::Array::IBMSV->default_no_path_retry, 12, 'IBM: bounded instead of queue forever');
    is(PVE::SAN::Array::ONTAP->default_no_path_retry, 12, 'ONTAP: bounded');
    is(PVE::SAN::Array::Infinidat->default_no_path_retry, 12, 'InfiniBox: bounded');
    is(PVE::SAN::Array::Pure->default_no_path_retry, undef, 'Pure: multipath-tools default kept');
    is(PVE::SAN::Array::Hitachi->default_no_path_retry, undef, 'Hitachi: multipath-tools default kept');
}

# ---------------- driver monitoring primitives ----------------
{
    my $items = sub { (200, { items => $_[0] }) };
    my ($drv, $calls) = FakeArray::driver('PVE::SAN::Array::Pure', {}, [
        [ GET => qr{^/api/api_version$}, sub { (200, { version => ['2.10'] }) } ],
        [ POST => qr{^/api/2\.10/login$}, sub { (200, { items => [] }, { 'x-auth-token' => 'S' }) } ],
        [ GET => qr{^/api/2\.10/volumes$}, sub {
            $items->([ map { { name => $_, provisioned => 100 * $GIB, space => { virtual => 40 * $GIB, data_reduction => 3.25 } } }
                split(/,/, $_[1]->{names}) ]) } ],
        [ GET => qr{^/api/2\.10/alerts$}, sub {
            $items->([ { severity => 'warning', summary => 'Fan degraded', state => 'open' }, { severity => 'info', summary => 'x' } ]) } ],
        [ GET => qr{^/api/2\.10/ports$}, sub {
            $items->([ { name => 'CT0.FC0', wwn => '52:4A:93:7A:00:00:00:01' }, { name => 'CT0.ETH0', wwn => undef } ]) } ],
        [ DELETE => qr{^/api/2\.10/host-groups/hosts$}, sub { $items->([]) } ],
        [ DELETE => qr{^/api/2\.10/hosts$}, sub { $items->([]) } ],
    ]);
    is_deeply($drv->volume_space([ 'gold', 'gold2' ]), [
        { id => 'gold', provisioned => 100 * $GIB, written => 40 * $GIB, reduction => 3.25 },
        { id => 'gold2', provisioned => 100 * $GIB, written => 40 * $GIB, reduction => 3.25 } ], 'Pure: space per volume');
    like(FakeArray::find_call($calls, 'GET', qr{/volumes\?})->{url}, qr/names=gold%2Cgold2/, 'Pure: one call for all volumes');
    my $h = $drv->health();
    is($h->{status}, 'warning', 'Pure: health from open alerts');
    like(FakeArray::find_call($calls, 'GET', qr{/alerts})->{url}, qr/filter=state%3D%27open%27/, 'Pure: open alerts only');
    is_deeply($drv->target_ports(), [ '524A937A00000001' ], 'Pure: FC target ports');
    $drv->remove_host({ name => 'old-node', hostcluster => 'lab' }, 'lab');
    is($calls->[-2]->{url}, '/api/2.10/host-groups/hosts?group_names=lab&member_names=old-node', 'Pure: host leaves the host group');
    is($calls->[-1]->{url}, '/api/2.10/hosts?names=old-node', 'Pure: host deleted');
}
{
    my $res = sub { (200, { result => $_[0], error => undef, metadata => { ready => JSON::PP::true } }) };
    my ($drv, $calls) = FakeArray::driver('PVE::SAN::Array::Infinidat', {}, [
        [ GET => qr{^/api/rest/volumes/(\d+)$}, sub { $res->({ id => $_[0]->[0], size => 10 * $GIB, used => 3 * $GIB, capacity_savings => $GIB }) } ],
        [ GET => qr{^/api/rest/clusters$}, sub { $res->([ { id => 5, name => 'lab', hosts => [ { id => 9 } ] } ]) } ],
        [ DELETE => qr{^/api/rest/clusters/5/hosts/9$}, sub { $res->(undef) } ],
        [ DELETE => qr{^/api/rest/hosts/9$}, sub { $res->(undef) } ],
    ]);
    is_deeply($drv->volume_space([ 7 ]), [ { id => 7, provisioned => 10 * $GIB, written => 3 * $GIB, saved => $GIB } ],
        'InfiniBox: used and capacity savings');
    is($drv->health(), undef, 'InfiniBox: health not reported');
    $drv->remove_host({ id => 9, name => 'old', hostcluster => 'lab' }, 'lab');
    like($calls->[-2]->{url}, qr{^/api/rest/clusters/5/hosts/9\?approved=true$}, 'InfiniBox: host leaves the cluster');
    like($calls->[-1]->{url}, qr{^/api/rest/hosts/9\?approved=true$}, 'InfiniBox: host deleted');
}
{
    my $new_api = 1;
    my ($drv, $calls) = FakeArray::driver('PVE::SAN::Array::PowerStore', {}, [
        [ GET => qr{^/api/rest/login_session$}, sub { (200, [ {} ], { 'dell-emc-token' => 'TOK' }) } ],
        [ GET => qr{^/api/rest/volume/(\w+)$}, sub {
            return (400, { messages => [ { code => '0xE04040010005', message_l10n => 'Invalid select field logical_used' } ] })
                if !$new_api && $_[1]->{select} =~ /logical_used/;
            (200, { id => $_[0]->[0], size => 10 * $GIB, ($new_api ? (logical_used => 2 * $GIB) : ()) }) } ],
        [ GET => qr{^/api/rest/host_group$}, sub { (200, [ { id => 'g1', name => 'lab' } ]) } ],
        [ PATCH => qr{^/api/rest/host_group/g1$}, sub { (204, '') } ],
        [ DELETE => qr{^/api/rest/host/h9$}, sub { (204, '') } ],
    ]);
    is_deeply($drv->volume_space([ 'v1' ]), [ { id => 'v1', provisioned => 10 * $GIB, written => 2 * $GIB } ], 'PowerStore: logical_used');
    $new_api = 0;
    is_deeply($drv->volume_space([ 'v1' ]), [ { id => 'v1', provisioned => 10 * $GIB, written => undef } ],
        'PowerStore: older PowerStoreOS without logical_used');
    $drv->remove_host({ id => 'h9', name => 'old', hostcluster => 'lab' }, 'lab');
    is_deeply($calls->[-2]->{body}, { remove_host_ids => [ 'h9' ] }, 'PowerStore: host leaves the host group');
    is($calls->[-1]->{method}, 'DELETE', 'PowerStore: host deleted');
}
{
    my $drv = bless { address => 'x' }, 'PVE::SAN::Array::Hitachi';
    eval { $drv->remove_host({ name => 'h' }, 'lab') };
    like($@, qr/removing hosts is not supported yet/, 'other drivers: clear error');
    is($drv->health(), undef, 'other drivers: no health');
    is($drv->target_ports(), undef, 'other drivers: no port list');
}

# ---------------- array view and the monitor run ----------------

package FakeMonDriver {
    use parent -norequire, 'PVE::SAN::Array::Base';
    sub description { 'Fake' }
    sub volume { { id => $_[1], name => "vol$_[1]", capacity => 100, pool => 'p1' } }
    sub pools { [ { name => 'p1', capacity => 1000, free => 100 }, { name => 'p2', capacity => 1000, free => 900 } ] }
    sub hosts { $_[0]->{hosts} }
    sub ensure_hostcluster { push @{$_[0]->{registered}}, sort keys %{$_[2]}; {} }
}

my $mdrv = bless { hosts => [ { name => 'n1', hostcluster => 'lab', wwpns => [ '2100000000000001' ] } ] }, 'FakeMonDriver';
my $cfg = {
    datastores => { gold => { array => 'a1', volumes => [ { id => 1, name => 'vol1', wwid => '3600a1' } ] } },
    arrays => { a1 => { type => 'fake' } },
};
my ($cache, @notes, $state) = ({});
{
    no warnings qw(redefine once);
    *PVE::SAN::Config::load = sub { $cfg };
    *PVE::SAN::Array::driver = sub { $mdrv };
    *PVE::SAN::Array::config = sub { {} };
    *PVE::SAN::Array::hostcluster = sub { 'lab' };
    *PVE::SAN::Array::node_wwpns = sub { { n1 => [ '21:00:00:00:00:00:00:01' ], n2 => [ '21:00:00:00:00:00:00:02' ] } };
    *PVE::SAN::Cluster::local_node = sub { 'n1' };
    *PVE::SAN::Cluster::all_nodes = sub { [ 'n1', 'n2' ] };
    *PVE::SAN::Monitor::read_cache = sub { JSON::PP->new->decode(JSON::PP->new->encode($cache)) };
    *PVE::SAN::Monitor::update_cache = sub { my $c = JSON::PP->new->decode(JSON::PP->new->encode($cache)); my $r = $_[0]->($c); $cache = $c; $r };
    *PVE::SAN::Monitor::notify = sub { push @notes, [ @_ ] };
    *PVE::SAN::Monitor::path_health = sub { { node => 'n1', problems => { 'dead:3600a1' => 'LUN gold has no active path' }, expected => { '3600a1' => 4 } } };
    *PVE::SAN::Monitor::read_state = sub { $state // {} };
    *PVE::SAN::Monitor::write_state = sub { $state = $_[0] };
}

my $view = PVE::SAN::Monitor::collect_view('gold', $cfg->{datastores}->{gold});
is_deeply($view->{pools}, [ { name => 'p1', capacity => 1000, free => 100, used_pct => 90 } ], 'only the pool of the volume');
is_deeply($view->{volumes}, [ { id => 1, name => 'vol1', provisioned => 100 } ], 'provisioned size from any driver');
is($view->{health}, undef, 'health not reported');

my $av = PVE::SAN::Monitor::array_view(storage => 'gold');
is($av->{cached}, 0, 'first view read from the array');
is(PVE::SAN::Monitor::array_view(storage => 'gold')->{cached}, 1, 'then from the cache');
eval { PVE::SAN::Monitor::array_view(storage => 'nope') };
like($@, qr/not linked to an array/, 'unlinked datastore refused');

open(my $out, '>', \my $printed);
my $old = select($out);
my $r = PVE::SAN::Monitor::run();
select($old);
is_deeply($r->{paths}->{new}, [ 'LUN gold has no active path' ], 'path problem reported');
is($r->{arrays}, 1, 'lease taken, arrays read');
is_deeply($mdrv->{registered}, [ 'n2' ], 'new node registered on the array');
is_deeply($r->{array_problems}->{new}, [ "pool 'p1' on array 'a1' is 90% full (threshold 85%)" ], 'pool alert');
is(scalar(@notes), 3, 'three notifications: path, registration, pool');
is($notes[0]->[0], 'warning', 'problems are warnings');

@notes = ();
$mdrv->{registered} = [];
select($out);
$r = PVE::SAN::Monitor::run();
select($old);
is(scalar(@notes), 0, 'unchanged problems are not sent again');
is_deeply($mdrv->{registered}, [], 'registration only when membership changes');

$cfg->{monitor}->{pool_threshold} = 95;
$state->{problems} = {};
{
    no warnings 'redefine';
    local *PVE::SAN::Monitor::path_health = sub { { node => 'n1', problems => {}, expected => {} } };
    select($out);
    $r = PVE::SAN::Monitor::run();
    select($old);
}
is_deeply($r->{array_problems}->{resolved}, [ "pool 'p1' on array 'a1' is 90% full (threshold 85%)" ], 'resolved after raising the threshold');
is($notes[-1]->[0], 'info', 'resolution is info');

$cache->{lease} = { node => 'n2', time => time() };
select($out);
$r = PVE::SAN::Monitor::run();
select($old);
ok(!$r->{arrays}, 'another node holds the lease');

done_testing();
