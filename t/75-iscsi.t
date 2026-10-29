use strict;
use warnings;

use Test::More;
use JSON::PP;

use FakeArray;
use SanFixture;
use StubPVE;

use PVE::SAN::Array;
use PVE::SAN::Array::Base;
use PVE::SAN::ISCSI;

my $IQN1 = 'iqn.1993-08.org.debian:01:pvenode01';
my $IQN2 = 'iqn.1993-08.org.debian:01:pvenode02';
my $quiet = sub {};

# ---------------- iSCSI names ----------------

is(PVE::SAN::Array::Base::norm_iqn('IQN.1993-08.org.Debian:01:ABC'), 'iqn.1993-08.org.debian:01:abc', 'IQN in lower case');
is(PVE::SAN::Array::Base::norm_iqn('iqn.2010-06.com.purestorage:flasharray.1,t,0x1'), 'iqn.2010-06.com.purestorage:flasharray.1',
    'target portal group suffix dropped');
is(PVE::SAN::Array::Base::norm_iqn('eui.02004567A425678D'), 'eui.02004567a425678d', 'EUI name');
is(PVE::SAN::Array::Base::norm_iqn('21:00:00:24:ff:3d:5e:10'), undef, 'a WWPN is not an IQN');
is(PVE::SAN::Array::Base::norm_iqn('iqn.foo'), undef, 'malformed IQN refused');
# 'iqn.2005-03.com.ab:cdef0' has exactly 16 hex digits once letters are stripped
is(PVE::SAN::Array::Base::norm_wwpn('iqn.2005-03.com.ab:cdef0'), undef, 'an IQN is never taken for a WWPN');
my ($w, $i) = PVE::SAN::Array::Base::split_ports(['21:00:00:24:ff:3d:5e:10', uc($IQN1), $IQN1, 'junk']);
is_deeply([$w, $i], [ ['21000024FF3D5E10'], [$IQN1] ], 'ports split by kind, normalised, deduplicated');

# ---------------- node side ----------------

{
    my $root = SanFixture::build();
    local $ENV{PVESAN_SYSFS_ROOT} = $root;
    is(PVE::SAN::ISCSI::initiator(), $IQN1, 'initiator name read from /etc/iscsi/initiatorname.iscsi');
    unlink($root . '/etc/iscsi/initiatorname.iscsi');
    is(PVE::SAN::ISCSI::initiator(), undef, 'no file: no initiator');
}

is(PVE::SAN::ISCSI::norm_portal('10.0.0.5'), '10.0.0.5:3260', 'default port');
is(PVE::SAN::ISCSI::norm_portal('10.0.0.5:3261,1'), '10.0.0.5:3261', 'port kept, portal group tag dropped');
is(PVE::SAN::ISCSI::norm_portal('fd00::5'), '[fd00::5]:3260', 'bare IPv6 address bracketed');
is(PVE::SAN::ISCSI::norm_portal('[fd00::5]:3260'), '[fd00::5]:3260', 'bracketed IPv6');
eval { PVE::SAN::ISCSI::norm_portal('10.0.0.5; rm -rf /') };
like($@, qr/invalid iSCSI portal/, 'junk portal refused');

is_deeply(PVE::SAN::ISCSI::parse_sessions(
    "tcp: [1] 10.0.0.5:3260,1 iqn.2010-06.com.example:t1 (non-flash)\n"
    . "tcp: [2] [fd00::5]:3260,2 IQN.2010-06.com.example:T1 (non-flash)\n"),
    [ { sid => 1, portal => '10.0.0.5:3260', target => 'iqn.2010-06.com.example:t1' },
      { sid => 2, portal => '[fd00::5]:3260', target => 'iqn.2010-06.com.example:t1' } ], 'sessions parsed');
is_deeply(PVE::SAN::ISCSI::parse_discovery("10.0.0.5:3260,1 iqn.2010-06.com.example:t1\n10.0.1.5:3260,2 iqn.2010-06.com.example:t1\n"),
    [ { portal => '10.0.0.5:3260', target => 'iqn.2010-06.com.example:t1' },
      { portal => '10.0.1.5:3260', target => 'iqn.2010-06.com.example:t1' } ], 'discovery parsed');

{
    my (@cmds, $session_out, @recorded, $cfg);
    my %fail; # "portal" => 1: login fails
    no warnings qw(redefine once);
    local *PVE::SAN::ISCSI::iscsiadm_present = sub { 1 };
    local *PVE::SAN::ISCSI::run_cmd = sub {
        my ($cmd) = @_;
        push @cmds, join(' ', @$cmd);
        my $c = join(' ', @$cmd);
        return $session_out if $c eq 'iscsiadm -m session';
        return "10.0.0.5:3260,1 iqn.2010-06.com.example:t1\n10.0.1.5:3260,2 iqn.2010-06.com.example:t1\n10.0.0.5:3260,1 iqn.2010-06.com.example:t2\n"
            if $c =~ /-m discovery/;
        die "iscsiadm: login failed\n" if $c =~ /--login$/ && grep { $c =~ /-p \Q$_\E / } keys %fail;
        return '';
    };
    local *PVE::SAN::ISCSI::record_portal = sub { push @recorded, [ @_ ] };

    open(my $out, '>', \my $printed);
    my $old = select($out);

    $session_out = "tcp: [1] 10.0.0.5:3260,1 iqn.2010-06.com.example:t1 (non-flash)\n";
    my $r = PVE::SAN::ISCSI::login(portal => '10.0.0.5', target => 'iqn.2010-06.com.example:t1', array => 'pure1');
    is_deeply([ grep { !/-m session/ } @cmds ], [
        'iscsiadm -m discovery -t sendtargets -p 10.0.0.5:3260',
        'iscsiadm -m node -T iqn.2010-06.com.example:t1 -p 10.0.0.5:3260 --op update -n node.startup -v automatic',
        'iscsiadm -m node -T iqn.2010-06.com.example:t1 -p 10.0.1.5:3260 --op update -n node.startup -v automatic',
        'iscsiadm -m node -T iqn.2010-06.com.example:t1 -p 10.0.1.5:3260 --login',
    ], 'discovery, node.startup=automatic on every record, login only where no session exists');
    is_deeply($r->{already}, [ '10.0.0.5:3260 iqn.2010-06.com.example:t1' ], 'existing session left alone');
    is_deeply($r->{logged_in}, [ '10.0.1.5:3260 iqn.2010-06.com.example:t1' ], 'second portal logged in');
    is($r->{targets}, 'iqn.2010-06.com.example:t1', 'target filter applied');
    is_deeply(\@recorded, [ [ '10.0.0.5:3260', 'iqn.2010-06.com.example:t1', 'pure1' ] ], 'portal recorded for boot');

    # second run: everything already logged in - nothing but discovery and updates
    @cmds = ();
    $session_out .= "tcp: [2] 10.0.1.5:3260,2 iqn.2010-06.com.example:t1 (non-flash)\n";
    $r = PVE::SAN::ISCSI::login(portal => '10.0.0.5', target => 'iqn.2010-06.com.example:t1');
    is(scalar(grep { /--login/ } @cmds), 0, 'idempotent: no login when sessions exist');
    is(scalar(@{$r->{already}}), 2, 'both sessions reported');

    # no target given: every discovered target; one portal failing is not fatal
    @cmds = ();
    $session_out = '';
    %fail = ('10.0.1.5:3260' => 1);
    $r = PVE::SAN::ISCSI::login(portal => '10.0.0.5:3260');
    is(scalar(grep { /--login$/ } @cmds), 3, 'all three discovered records tried');
    is_deeply($r->{failed}, [ '10.0.1.5:3260 iqn.2010-06.com.example:t1' ], 'failed portal reported');
    is(scalar(@{$r->{logged_in}}), 2, 'others logged in');

    %fail = ('10.0.0.5:3260' => 1, '10.0.1.5:3260' => 1);
    eval { PVE::SAN::ISCSI::login(portal => '10.0.0.5:3260') };
    like($@, qr/no iSCSI session to portal 10.0.0.5:3260/, 'nothing logged in: error');

    eval { PVE::SAN::ISCSI::login(portal => '10.0.0.5', target => 'iqn.2010-06.com.example:nope') };
    like($@, qr/offers no target named/, 'unknown target refused');

    # restore at boot: only portals without a session
    %fail = ();
    @cmds = ();
    @recorded = ();
    local *PVE::SAN::ISCSI::recorded_portals = sub { {
        '10.0.0.5:3260' => { target => 'iqn.2010-06.com.example:t1', array => 'pure1' },
        '10.0.2.5:3260' => { array => 'other' },
    } };
    $session_out = "tcp: [1] 10.0.0.5:3260,1 iqn.2010-06.com.example:t1 (non-flash)\n";
    $r = PVE::SAN::ISCSI::restore();
    is_deeply([ grep { /discovery/ } @cmds ], [ 'iscsiadm -m discovery -t sendtargets -p 10.0.2.5:3260' ],
        'restore discovers only the portal without a session');
    is_deeply($r->{ok}, [ '10.0.0.5:3260', '10.0.2.5:3260' ], 'both portals fine afterwards');
    is_deeply(\@recorded, [], 'restore does not rewrite the config');

    select($old);
}

# ---------------- node ports per protocol ----------------

{
    no warnings qw(redefine once);
    my @asked;
    local *PVE::SAN::Cluster::on_nodes = sub {
        my ($nodes, $desc, $method, $path) = @_;
        push @asked, $path;
        return { map { $_ => [ { transport => 'fc', wwpn => '21:00:00:24:ff:3d:5e:1' . substr($_, -1) },
            { transport => 'iscsi', wwpn => 'iqn.x' } ] } @$nodes } if $path eq 'adapters';
        return { n1 => { initiator => uc($IQN1) }, n2 => { initiator => undef } } if $path eq 'iscsi';
    };
    is_deeply(PVE::SAN::Array::node_ports('fc', ['n1', 'n2']),
        { n1 => ['21000024FF3D5E11'], n2 => ['21000024FF3D5E12'] }, 'fc: WWPNs only');
    is_deeply(PVE::SAN::Array::node_ports('iscsi', ['n1', 'n2']), { n1 => [$IQN1], n2 => [] }, 'iscsi: initiator names only');
    is_deeply(PVE::SAN::Array::node_ports('both', ['n1', 'n2']),
        { n1 => ['21000024FF3D5E11', $IQN1], n2 => ['21000024FF3D5E12'] }, 'both');
    is_deeply(\@asked, [qw(adapters iscsi adapters iscsi)], 'nodes asked only for what the protocol needs');
}

# ---------------- shared registration logic ----------------

package FakeNoIscsi {
    use parent -norequire, 'PVE::SAN::Array::Base';
    sub description { 'Fake array' }
    sub host_clusters { [] }
    sub create_hostcluster { $_[0]->{created}++ }
}
{
    my $drv = bless {}, 'FakeNoIscsi';
    eval { $drv->ensure_hostcluster('pvelab', { n1 => [$IQN1] }, $quiet) };
    is($@, "Fake array: iSCSI host registration is not supported yet by the pvesan driver\n", 'driver without iSCSI refuses IQNs');
    ok(!$drv->{created}, 'nothing changed on the array');
    eval { $drv->ensure_hostcluster('pvelab', { n1 => [] }, $quiet) };
    like($@, qr/node 'n1' has no FC ports or iSCSI initiator name/, 'node without ports refused');
    eval { FakeNoIscsi->check_protocol('iscsi') };
    like($@, qr/iSCSI host registration is not supported yet/, 'protocol setting checked when the array is added');
    eval { FakeNoIscsi->check_protocol('fc') };
    is($@, '', 'fc is always fine');
    eval { FakeNoIscsi->check_protocol('nvme') };
    like($@, qr/unknown protocol/, 'unknown protocol refused');
    is_deeply(PVE::SAN::Array::Base::protocols({ protocol => 'both' }), ['fc', 'iscsi'], 'both = fc + iscsi');
    is_deeply(PVE::SAN::Array::Base::protocols({}), ['fc'], 'default fc');
}

for my $type (qw(fujitsu-eternus)) {
    my $class = PVE::SAN::Array::driver_class($type);
    ok(!$class->supports_iscsi, "$type: no verified iSCSI calls");
}
{
    require PVE::SAN::Array::Eternus;
    my $drv = PVE::SAN::Array::Eternus->new(address => 'x', username => 'u', password => 'p', transport => sub { (404, '') });
    eval { $drv->ensure_hostcluster('pvelab', { n1 => ['5000000000000001', $IQN1] }, $quiet) };
    like($@, qr/^Fujitsu ETERNUS DX\/AF: iSCSI host registration is not supported yet/, 'ETERNUS refuses IQNs');
}

my $json = JSON::PP->new->canonical;

# ---------------- Pure FlashArray ----------------
{
    require PVE::SAN::Array::Pure;
    my %st = (hosts => [ { name => 'pvenode01', wwns => [], iqns => [ uc($IQN1) ], host_group => { name => '' } } ], groups => []);
    my $b = qr{^/api/2\.10};
    my ($drv, $calls) = FakeArray::driver('PVE::SAN::Array::Pure', { token => 'T', api_version => '2.10' }, [
        [ GET => qr{$b/hosts$}, sub { (200, { items => $st{hosts} }) } ],
        [ GET => qr{$b/host-groups$}, sub { (200, { items => [ map { { name => $_ } } @{$st{groups}} ] }) } ],
        [ POST => qr{$b/host-groups$}, sub { push @{$st{groups}}, $_[1]->{names}; (200, { items => [] }) } ],
        [ POST => qr{$b/hosts$}, sub { push @{$st{hosts}}, { name => $_[1]->{names}, %{$_[2]} }; (200, { items => [] }) } ],
        [ PATCH => qr{$b/hosts$}, sub { (200, { items => [] }) } ],
        [ POST => qr{$b/host-groups/hosts$}, sub { (200, { items => [] }) } ],
        [ GET => qr{$b/ports$}, sub { (200, { items => [
            { name => 'CT0.FC0', wwn => '52:4A:93:7D:F3:5D:A0:00', iqn => undef, portal => undef },
            { name => 'CT0.ETH4', iqn => 'iqn.2010-06.com.purestorage:flasharray.3ea6f7b2', portal => '10.0.0.10:3260', wwn => undef },
            { name => 'CT1.ETH4', iqn => 'iqn.2010-06.com.purestorage:flasharray.3ea6f7b2', portal => '[fd00::11]:3260', wwn => undef },
        ] }) } ],
    ]);
    ok($drv->supports_iscsi, 'Pure: iSCSI supported');
    $drv->ensure_hostcluster('pvelab', { pvenode01 => [$IQN1, '50:00:00:00:00:00:00:01'], pvenode02 => [$IQN2] }, $quiet);
    is_deeply(FakeArray::find_call($calls, 'PATCH', qr{/hosts\?names=pvenode01})->{body},
        { add_wwns => ['5000000000000001'] }, 'Pure: existing iSCSI host found by IQN, missing WWPN added');
    is_deeply(FakeArray::find_call($calls, 'POST', qr{/hosts\?names=pvenode02})->{body}, { iqns => [$IQN2] }, 'Pure: HostPost iqns');
    $drv->add_host_ports({ name => 'pvenode02' }, [], ['iqn.2024-01.com.example:x']);
    is_deeply($calls->[-1]->{body}, { add_iqns => ['iqn.2024-01.com.example:x'] }, 'Pure: HostPatch add_iqns');
    is_deeply($drv->hosts()->[0]->{iqns}, [$IQN1], 'Pure: host IQNs reported in lower case');
    is_deeply($drv->target_portals(), [
        { address => '10.0.0.10', port => 3260, iqn => 'iqn.2010-06.com.purestorage:flasharray.3ea6f7b2' },
        { address => 'fd00::11', port => 3260, iqn => 'iqn.2010-06.com.purestorage:flasharray.3ea6f7b2' },
    ], 'Pure: portals from GET ports (FC ports skipped)');
}

# ---------------- IBM Spectrum Virtualize ----------------
{
    require PVE::SAN::Array::IBMSV;
    my (@calls, %h);
    my $transport = sub {
        my ($path, $headers, $body) = @_;
        push @calls, { path => $path, body => $body };
        return (200, '{"token":"t"}') if $path eq '/auth';
        my %r = (
            '/lshost' => [ { id => 0, name => 'pvenode01', host_cluster_name => '' } ],
            '/lshost/0' => [ { id => 0, name => 'pvenode01', iscsi_name => uc($IQN1) }, { iscsi_name => 'IQN.1993-08.org.debian:01:second' } ],
            '/lshostcluster' => [ { id => 0, name => 'pvelab' } ],
            '/lsnode' => [ { id => 1, name => 'node1', status => 'online', iscsi_name => 'iqn.1986-03.com.ibm:2145.fs9100.node1' },
                           { id => 2, name => 'node2', status => 'offline', iscsi_name => 'iqn.1986-03.com.ibm:2145.fs9100.node2' } ],
            '/lsportip' => [ { node_id => 1, IP_address => '10.0.0.20', IP_address_6 => '', host => 'yes', state => 'configured' },
                             { node_id => 1, IP_address => '10.0.0.21', IP_address_6 => '', host => 'no', state => 'configured' },
                             { node_id => 2, IP_address => '10.0.0.22', IP_address_6 => '', host => 'yes', state => 'configured' } ],
        );
        return (500, 'CMMVC5709E lsip not known') if $path eq '/lsip';
        return (200, $json->encode($r{$path} // {}));
    };
    my $drv = PVE::SAN::Array::IBMSV->new(address => 'fs', username => 'u', password => 'p', transport => $transport);
    my $hosts = $drv->hosts();
    is_deeply($hosts->[0]->{iqns}, [ $IQN1, 'iqn.1993-08.org.debian:01:second' ], 'IBM: lshost iscsi_name values');
    $drv->ensure_hostcluster('pvelab', { pvenode02 => ['5000000000000005', $IQN2] }, $quiet);
    my ($mk) = grep { $_->{path} eq '/mkhost' } @calls;
    is_deeply($mk->{body}, { name => 'pvenode02', fcwwpn => '5000000000000005', force => JSON::PP::true }, 'IBM: mkhost with the FC ports');
    my ($add) = grep { $_->{path} eq '/addhostport/pvenode02' } @calls;
    is_deeply($add->{body}, { iscsiname => $IQN2, force => JSON::PP::true }, 'IBM: then addhostport -iscsiname');
    @calls = ();
    $drv->create_host('pvenode03', [], [ $IQN1, $IQN2 ]);
    is_deeply($calls[-1]->{body}, { name => 'pvenode03', iscsiname => "$IQN1,$IQN2", force => JSON::PP::true },
        'IBM: iSCSI-only host, names comma separated');
    is_deeply($drv->target_portals(), [ { address => '10.0.0.20', port => 3260, iqn => 'iqn.1986-03.com.ibm:2145.fs9100.node1' } ],
        'IBM: lsportip fallback, host-attach ports of online nodes only');
}

# ---------------- Dell PowerStore ----------------
{
    require PVE::SAN::Array::PowerStore;
    my %st = (hosts => [ { id => 'h1', name => 'pvenode01', host_initiators => [ { port_name => uc($IQN1), port_type => 'iSCSI' } ] } ]);
    my ($drv, $calls) = FakeArray::driver('PVE::SAN::Array::PowerStore', { token => 'T' }, [
        [ GET => qr{^/api/rest/host_group$}, sub { (200, []) } ],
        [ GET => qr{^/api/rest/host$}, sub { (200, $st{hosts}) } ],
        [ POST => qr{^/api/rest/host$}, sub { (201, { id => 'h2' }) } ],
        [ PATCH => qr{^/api/rest/host/(\w+)$}, sub { (204, '') } ],
        [ POST => qr{^/api/rest/host_group$}, sub { (201, { id => 'g1' }) } ],
        [ GET => qr{^/api/rest/ip_pool_address$}, sub {
            my $q = $_[1];
            return (400, 'bad filter') if ($q->{purposes} // '') ne 'cs.{Storage_Iscsi_Target}' || ($q->{select} // '') ne 'address,ip_port(target_iqn)';
            (200, [ { address => '10.0.0.30', ip_port => { target_iqn => 'iqn.2015-10.com.dell:dellemc-powerstore-fnm00190700000-a-1c2d3e4f' } },
                    { address => '10.0.0.31', ip_port => { target_iqn => 'iqn.2015-10.com.dell:dellemc-powerstore-fnm00190700000-b-1c2d3e4f' } } ]);
        } ],
    ]);
    is_deeply($drv->hosts()->[0]->{iqns}, [$IQN1], 'PowerStore: iSCSI initiators reported');
    $drv->ensure_hostcluster('pvelab', { pvenode01 => [$IQN1], pvenode02 => [$IQN2, '50:00:00:00:00:00:00:02'] }, $quiet);
    is_deeply(FakeArray::find_call($calls, 'POST', qr{^/api/rest/host$})->{body},
        { name => 'pvenode02', os_type => 'Linux', initiators => [
            { port_name => '50:00:00:00:00:00:00:02', port_type => 'FC' }, { port_name => $IQN2, port_type => 'iSCSI' } ] },
        'PowerStore: host with FC and iSCSI initiators');
    $drv->add_host_ports({ id => 'h1' }, [], ['iqn.2024-01.com.example:x']);
    is_deeply($calls->[-1]->{body}, { add_initiators => [ { port_name => 'iqn.2024-01.com.example:x', port_type => 'iSCSI' } ] },
        'PowerStore: add_initiators with port_type iSCSI');
    is_deeply([ map { $_->{address} } @{$drv->target_portals()} ], ['10.0.0.30', '10.0.0.31'], 'PowerStore: iSCSI target addresses');
    is($drv->target_portals()->[1]->{iqn}, 'iqn.2015-10.com.dell:dellemc-powerstore-fnm00190700000-b-1c2d3e4f', 'PowerStore: target IQN per port');
}

# ---------------- INFINIDAT InfiniBox ----------------
{
    require PVE::SAN::Array::Infinidat;
    my $env = sub { (200, { result => $_[0], error => undef, metadata => { ready => JSON::PP::true, page => 1, pages_total => 1 } }) };
    my @hosts = ({ id => 5, name => 'pvenode01', ports => [ { type => 'ISCSI', address => uc($IQN1) } ] });
    my ($drv, $calls) = FakeArray::driver('PVE::SAN::Array::Infinidat', {}, [
        [ GET => qr{^/api/rest/hosts$}, sub { $env->(\@hosts) } ],
        [ GET => qr{^/api/rest/clusters$}, sub { $env->([ { id => 9, name => 'pvelab', hosts => [] } ]) } ],
        [ POST => qr{^/api/rest/hosts$}, sub { $env->({ id => 6, name => $_[2]->{name} }) } ],
        [ POST => qr{^/api/rest/hosts/(\d+)/ports$}, sub { $env->($_[2]) } ],
        [ POST => qr{^/api/rest/clusters/9/hosts$}, sub { $env->({}) } ],
        [ GET => qr{^/api/rest/network/spaces$}, sub { $env->([
            { id => 1, name => 'nas', service => 'NAS_SERVICE', ips => [ { ip_address => '10.0.0.40', enabled => JSON::PP::true } ] },
            { id => 2, name => 'iscsi', service => 'ISCSI_SERVICE',
              properties => { iscsi_iqn => 'iqn.2009-11.com.infinidat:storage:infinibox-sn-1234', iscsi_tcp_port => 3260 },
              ips => [ { ip_address => '10.0.0.41', enabled => JSON::PP::true }, { ip_address => '10.0.0.42', enabled => JSON::PP::false } ] },
        ]) } ],
    ]);
    is_deeply($drv->hosts()->[0]->{iqns}, [$IQN1], 'InfiniBox: iscsi host ports reported');
    $drv->ensure_hostcluster('pvelab', { pvenode02 => [$IQN2] }, $quiet);
    is_deeply(FakeArray::find_call($calls, 'POST', qr{^/api/rest/hosts/6/ports})->{body}, { type => 'iscsi', address => $IQN2 },
        'InfiniBox: port {type: iscsi, address}');
    is_deeply($drv->target_portals(), [ { address => '10.0.0.41', port => 3260, iqn => 'iqn.2009-11.com.infinidat:storage:infinibox-sn-1234' } ],
        'InfiniBox: enabled addresses of the ISCSI_SERVICE network space');
}

# ---------------- NetApp ONTAP ----------------
{
    require PVE::SAN::Array::ONTAP;
    my $ig;
    my ($drv, $calls) = FakeArray::driver('PVE::SAN::Array::ONTAP', { svm => 'svm_san' }, [
        [ GET => qr{^/api/protocols/san/igroups$}, sub { (200, { records => $ig ? [ $ig ] : [] }) } ],
        [ POST => qr{^/api/protocols/san/igroups$}, sub { $ig = { uuid => 'u1', %{$_[2]} }; (201, {}) } ],
        [ POST => qr{^/api/protocols/san/igroups/u1/initiators$}, sub { push @{$ig->{initiators}}, @{$_[2]->{records}}; (201, {}) } ],
        [ GET => qr{^/api/protocols/san/iscsi/services$}, sub {
            (200, { records => [ { svm => { name => $_[1]->{'svm.name'} }, target => { name => 'iqn.1992-08.com.netapp:sn.0123:vs.4' } } ] }) } ],
        [ GET => qr{^/api/network/ip/interfaces$}, sub {
            return (200, { records => [] }) if ($_[1]->{services} // '') ne 'data_iscsi' || ($_[1]->{fields} // '') ne 'ip.address,enabled';
            (200, { records => [ { ip => { address => '10.0.0.50' }, enabled => JSON::PP::true },
                                 { ip => { address => '10.0.0.51' }, enabled => JSON::PP::false } ] });
        } ],
    ]);
    $drv->ensure_hostcluster('pvelab', { pvenode01 => [$IQN1], pvenode02 => [$IQN2] }, $quiet);
    is($ig->{protocol}, 'iscsi', 'ONTAP: iSCSI-only cluster gets an iscsi igroup');
    is_deeply($ig->{initiators}, [ { name => $IQN1 }, { name => $IQN2 } ], 'ONTAP: IQNs as initiator names');
    $drv->ensure_hostcluster('pvelab', { pvenode03 => ['iqn.2024-01.com.example:n3'] }, $quiet);
    is_deeply($calls->[-1]->{body}, { records => [ { name => 'iqn.2024-01.com.example:n3' } ] }, 'ONTAP: IQN added to the igroup');
    eval { $drv->ensure_hostcluster('pvelab', { pvenode01 => ['50:00:00:00:00:00:00:01'] }, $quiet) };
    like($@, qr/protocol 'iscsi', which cannot hold FC initiators/, 'ONTAP: FC initiators refused in an iscsi igroup');

    $ig = undef;
    $drv->ensure_hostcluster('pvelab', { pvenode01 => [$IQN1, '50:00:00:00:00:00:00:01'] }, $quiet);
    is($ig->{protocol}, 'mixed', 'ONTAP: FC and iSCSI ports give a mixed igroup');
    is_deeply($ig->{initiators}, [ { name => '50:00:00:00:00:00:00:01' }, { name => $IQN1 } ], 'ONTAP: both kinds of initiators');
    $ig = { uuid => 'u1', name => 'pvelab', protocol => 'fcp', initiators => [] };
    eval { $drv->ensure_hostcluster('pvelab', { pvenode01 => [$IQN1] }, $quiet) };
    like($@, qr/protocol 'fcp', which cannot hold iSCSI initiators/, 'ONTAP: an existing fcp igroup cannot take IQNs');

    is_deeply($drv->target_portals(), [ { address => '10.0.0.50', port => 3260, iqn => 'iqn.1992-08.com.netapp:sn.0123:vs.4' } ],
        'ONTAP: enabled data_iscsi LIFs with the SVM target name');
    like(FakeArray::find_call($calls, 'GET', qr{/network/ip/interfaces})->{url}, qr/svm\.name=svm_san/, 'ONTAP: LIFs of the SVM');
}

# ---------------- NetApp E-Series ----------------
{
    require PVE::SAN::Array::ESeries;
    my @hosts = ({ id => 'H1', name => 'pvenode01', clusterRef => '0000000000000000000000000000000000000000',
        hostSidePorts => [ { type => 'iscsi', address => uc($IQN1), label => 'pvenode01-p0' } ] });
    my $b = qr{^/devmgr/v2/storage-systems/1};
    my ($drv, $calls) = FakeArray::driver('PVE::SAN::Array::ESeries', { host_type => 28 }, [
        [ GET => qr{$b/hosts$}, sub { (200, \@hosts) } ],
        [ GET => qr{$b/host-groups$}, sub { (200, [ { id => 'C1', name => 'pvelab' } ]) } ],
        [ POST => qr{$b/hosts$}, sub { (200, { id => 'H2', name => $_[2]->{name} }) } ],
        [ POST => qr{$b/hosts/(\w+)$}, sub { (200, {}) } ],
        [ POST => qr{$b/hosts/(\w+)/move$}, sub { (200, {}) } ],
        [ GET => qr{$b/graph/xpath-filter$}, sub {
            return (404, '') if ($_[1]->{query} // '') ne '/storagePoolBundle/target';
            (200, [ { nodeName => { ioInterfaceType => 'iscsi', iscsiNodeName => 'iqn.1992-08.com.netapp:2800.600a098000a1b2c3' } } ]);
        } ],
        [ GET => qr{$b/graph$}, sub { (200, { ioInterface => [
            { channelType => 'hostside', ioInterfaceTypeData => { interfaceType => 'iscsi', iscsi => {
                ipv4Enabled => JSON::PP::true, interfaceData => { type => 'ethernet' },
                ipv4Data => { ipv4AddressData => { ipv4Address => '10.0.0.60' } } } } },
            { channelType => 'hostside', ioInterfaceTypeData => { interfaceType => 'iscsi', iscsi => {
                ipv4Enabled => JSON::PP::false, interfaceData => { type => 'ethernet' },
                ipv4Data => { ipv4AddressData => { ipv4Address => '10.0.0.61' } } } } },
            { channelType => 'hostside', ioInterfaceTypeData => { interfaceType => 'fibre', fibre => {} } },
            { channelType => 'driveside', ioInterfaceTypeData => { interfaceType => 'sas', sas => {} } },
        ] }) } ],
    ]);
    is_deeply($drv->hosts()->[0]->{iqns}, [$IQN1], 'E-Series: iscsi host side ports reported');
    $drv->ensure_hostcluster('pvelab', { pvenode01 => [$IQN1, '50:00:00:00:00:00:00:01'], pvenode02 => [$IQN2] }, $quiet);
    is_deeply(FakeArray::find_call($calls, 'POST', qr{$b/hosts/H1$})->{body},
        { ports => [ { type => 'fc', port => '5000000000000001', label => 'pvenode01-p1' } ] }, 'E-Series: new port label after the existing one');
    is_deeply(FakeArray::find_call($calls, 'POST', qr{$b/hosts$})->{body}->{ports},
        [ { type => 'iscsi', port => $IQN2, label => 'pvenode02-p0' } ], 'E-Series: host port {type: iscsi, port: IQN}');
    is_deeply($drv->target_portals(), [ { address => '10.0.0.60', port => 3260, iqn => 'iqn.1992-08.com.netapp:2800.600a098000a1b2c3' } ],
        'E-Series: enabled host side iSCSI interfaces');
}

# ---------------- Hitachi VSP ----------------
{
    require PVE::SAN::Array::Hitachi;
    my $B = qr{^/ConfigurationManager/v1/objects/storages/886000412345};
    my %hg = ('CL1-A' => [], 'CL3-B' => []);
    my %init;
    my %ports = ('CL1-A' => { portId => 'CL1-A', portType => 'FIBRE' },
                 'CL3-B' => { portId => 'CL3-B', portType => 'ISCSI', ipv4Address => '10.0.0.70', tcpPort => 3260 });
    my $job = sub { (202, { jobId => 1, status => 'Completed', state => 'Succeeded', affectedResources => [ $_[0] ] }) };
    my ($drv, $calls) = FakeArray::driver('PVE::SAN::Array::Hitachi',
        { target_ports => 'CL1-A,CL3-B', system_id => '886000412345', token => 'T', protocol => 'iscsi', hostcluster => 'pvelab' }, [
        [ GET => qr{$B/ports/([\w-]+)$}, sub { (200, $ports{$_[0]->[0]}) } ],
        [ GET => qr{$B/host-groups$}, sub { (200, { data => $hg{$_[1]->{portId}} }) } ],
        [ POST => qr{$B/host-groups$}, sub {
            my $b = $_[2];
            push @{$hg{$b->{portId}}}, { hostGroupNumber => 1, hostGroupName => $b->{hostGroupName},
                iscsiName => 'iqn.1994-04.jp.co.hitachi:rsd.h8m.i.120a3b.3b001' };
            $job->("/ConfigurationManager/v1/objects/host-groups/$b->{portId},1");
        } ],
        [ GET => qr{$B/host-iscsis$}, sub { (200, { data => [ map { { iscsiName => $_ } } @{$init{"$_[1]->{portId},$_[1]->{hostGroupNumber}"} // []} ] }) } ],
        [ POST => qr{$B/host-iscsis$}, sub {
            my $b = $_[2]; push @{$init{"$b->{portId},$b->{hostGroupNumber}"}}, $b->{iscsiName};
            $job->("/ConfigurationManager/v1/objects/host-iscsis/$b->{portId},$b->{hostGroupNumber}") } ],
        [ POST => qr{$B/luns$}, sub { $job->('/ConfigurationManager/v1/objects/luns/x') } ],
    ]);
    my @log;
    $drv->ensure_hostcluster('pvelab', { pvenode01 => [$IQN1], pvenode02 => [$IQN2] }, sub { push @log, $_[0] });
    is_deeply($hg{'CL1-A'}, [], 'Hitachi: FC port left alone with protocol iscsi');
    ok(grep({ /skipping FC port CL1-A/ } @log), 'Hitachi: skip logged');
    is_deeply([ map { $_->{body} } grep { $_->{method} eq 'POST' && $_->{url} =~ /host-iscsis/ } @$calls ], [
        { iscsiName => $IQN1, portId => 'CL3-B', hostGroupNumber => 1 },
        { iscsiName => $IQN2, portId => 'CL3-B', hostGroupNumber => 1 },
    ], 'Hitachi: host-iscsis {iscsiName, portId, hostGroupNumber}');
    my $n = @$calls;
    $drv->ensure_hostcluster('pvelab', { pvenode01 => [$IQN1], pvenode02 => [$IQN2] }, $quiet);
    is(scalar(grep { $_->{method} eq 'POST' } @$calls[$n .. $#$calls]), 0, 'Hitachi: second run changes nothing');
    is_deeply($drv->target_portals(), [ { address => '10.0.0.70', port => 3260, iqn => 'iqn.1994-04.jp.co.hitachi:rsd.h8m.i.120a3b.3b001' } ],
        'Hitachi: iSCSI port address and the host group target name');
    $drv->map_to_hostcluster(5, 'pvelab');
    is_deeply([ map { $_->{body}->{portId} } grep { $_->{url} =~ m{/luns$} } @$calls ], ['CL3-B'], 'Hitachi: LU path only on the iSCSI port');
}

# ---------------- Dell PowerMax ----------------
{
    require PVE::SAN::Array::PowerMax;
    my $base = qr{^/univmax/restapi/100/sloprovisioning/symmetrix/000197900123};
    my %hosts = (pvenode01 => { initiator => [ $IQN1 ], hostGroup => ['pvelab'] });
    my ($drv, $calls) = FakeArray::driver('PVE::SAN::Array::PowerMax',
        { system_id => '000197900123', portgroup => 'pve_iscsi_PG', api_version => '100' }, [
        [ GET => qr{$base/host$}, sub { (200, { hostId => [ sort keys %hosts ] }) } ],
        [ GET => qr{$base/host/(\w+)$}, sub { (200, $hosts{$_[0]->[0]}) } ],
        [ POST => qr{$base/host$}, sub { $hosts{$_[2]->{hostId}} = { initiator => $_[2]->{initiatorId} }; (201, {}) } ],
        [ PUT => qr{$base/host/(\w+)$}, sub { (200, {}) } ],
        [ PUT => qr{$base/host/(w+)$}, sub { (200, {}) } ],
        [ GET => qr{$base/portgroup/pve_iscsi_PG$}, sub { (200, { portGroupId => 'pve_iscsi_PG',
            symmetrixPortKey => [ { directorId => 'SE-1E', portId => '000' }, { directorId => 'FA-1D', portId => '4' } ] }) } ],
        [ GET => qr{^/univmax/restapi/100/system/symmetrix/000197900123/director/SE-1E/port/000$}, sub {
            (200, { symmetrixPort => { identifier => 'iqn.1992-04.com.emc:600009700bcbb70e3287017400000000,t,0x0001',
                ip_addresses => [ '10.0.0.80' ] } }) } ],
        [ GET => qr{^/univmax/restapi/100/system/symmetrix/000197900123/director/FA-1D/port/4$}, sub {
            (200, { symmetrixPort => { identifier => '5000097300123401' } }) } ],
    ]);
    is_deeply($drv->hosts()->[0]->{iqns}, [$IQN1], 'PowerMax: IQN initiators reported');
    is_deeply($drv->hosts()->[0]->{wwpns}, [], 'PowerMax: ... not as WWPNs');
    $drv->create_host('pvenode02', [], [$IQN2]);
    is_deeply($calls->[-1]->{body}, { hostId => 'pvenode02', initiatorId => [$IQN2] }, 'PowerMax: host with an IQN initiator');
    $drv->add_host_ports({ name => 'pvenode02' }, ['5000000000000001'], ['iqn.2024-01.com.example:x']);
    is_deeply($calls->[-1]->{body}->{editHostActionParam}->{addInitiatorParam}->{initiator},
        [ '5000000000000001', 'iqn.2024-01.com.example:x' ], 'PowerMax: addInitiatorParam takes both kinds');
    is_deeply($drv->target_portals(), [ { address => '10.0.0.80', port => 3260, iqn => 'iqn.1992-04.com.emc:600009700bcbb70e3287017400000000' } ],
        'PowerMax: iSCSI ports of the port group (FC ports skipped)');
}

done_testing();
