use strict;
use warnings;

use Test::More;
use JSON::PP;

use StubPVE;
use FakeArray;

use PVE::SAN::Zoning;
use PVE::SAN::Fabric;
use PVE::SAN::Fabric::Brocade;
use PVE::SAN::Fabric::Cisco;
use PVE::SAN::Array::IBMSV;
use PVE::SAN::Array::Infinidat;

my $json = JSON::PP->new->canonical;

# node ports: n1 and n2 have one port on each fabric; n3 is cabled to fabric A only
my %W = (
    n1a => '100000109B000001', n1b => '100000109B000002',
    n2a => '100000109B000003', n2b => '100000109B000004',
    n3a => '100000109B000005', n3x => '100000109B0000FF', # n3x: logged in nowhere
    t1 => '500507680C110001', t2 => '500507680C120001', # array ports on fabric A
    t3 => '500507680C210001', t4 => '500507680C220001', # array ports on fabric B
    t5 => '500507680C310001',                          # array port on no fabric
);
my $ns = sub { [ map { { wwpn => $W{$_}, role => '' } } @_ ] };
my $nodes = { n1 => [ $W{n1a}, $W{n1b} ], n2 => [ $W{n2a}, $W{n2b} ], n3 => [ $W{n3a}, $W{n3x} ] };
my $targets = [ map { $W{$_} } qw(t1 t2 t3 t4 t5) ];

sub fabric_a {
    my (%o) = @_;
    return {
        fabric => 'fa', type => 'brocade', zoneset => $o{zoneset},
        ns => $ns->(qw(n1a n2a n3a t1 t2)),
        zoning => {
            active_cfg => exists($o{active_cfg}) ? $o{active_cfg} : 'prod_a',
            cfgs => { prod_a => [ 'legacy_n1', 'pve_lab_n2_' . lc($W{n2a}) . '_fs1' ] },
            # n1's port is already covered by an admin-made zone; n2 has a pvesan zone missing t2
            zones => { legacy_n1 => [ $W{n1a}, $W{t1}, $W{t2} ],
                       'pve_lab_n2_' . lc($W{n2a}) . '_fs1' => [ $W{n2a}, $W{t1} ] },
            active_zones => $o{active_zones} // { legacy_n1 => [ $W{n1a}, $W{t1}, $W{t2} ],
                       'pve_lab_n2_' . lc($W{n2a}) . '_fs1' => [ $W{n2a}, $W{t1} ] },
            busy => $o{busy},
        },
    };
}
sub fabric_b {
    return {
        fabric => 'fb', type => 'cisco',
        ns => $ns->(qw(n1b n2b t3 t4)),
        zoning => { active_cfg => 'zs_b', cfgs => { zs_b => [] }, zones => {}, active_zones => {} },
    };
}

# ---------------- planning ----------------
{
    my $p = PVE::SAN::Zoning::compute({ array => 'fs1', hostcluster => 'lab', nodes => $nodes, targets => $targets,
        fabrics => [ fabric_a(), fabric_b() ] });
    my %row = map { ("$_->{fabric}:$_->{node}" => $_) } @{$p->{rows}};

    is($row{'fa:n1'}->{action}, 'exists', 'port already covered by an active zone is left alone');
    is($row{'fa:n1'}->{zone}, 'legacy_n1', 'the covering zone is named');
    is($row{'fa:n2'}->{action}, 'extend', 'pvesan zone missing a target is extended');
    is($row{'fa:n3'}->{action}, 'create', 'unzoned port gets a zone');
    is($row{'fb:n1'}->{action}, 'create', 'second fabric: zone created');
    ok(!$row{'fb:n3'}, 'no zone on a fabric the node is not cabled to');
    is($p->{changes}, 4, 'four zone changes');

    my ($fa) = grep { $_->{fabric} eq 'fa' } @{$p->{fabrics}};
    my ($fb) = grep { $_->{fabric} eq 'fb' } @{$p->{fabrics}};
    is($fa->{zoneset}, 'prod_a', 'zones go into the active zone set by default');
    ok(!$fa->{blocked} && !$fb->{blocked}, 'nothing blocks');
    my %z = map { ($_->{name} => $_) } @{$fa->{zones}};
    my $n2 = 'pve_lab_n2_' . lc($W{n2a}) . '_fs1';
    my $n3 = 'pve_lab_n3_' . lc($W{n3a}) . '_fs1';
    is_deeply($z{$n2}->{members}, [ $W{t2} ], 'extend adds only the missing member');
    ok(!$z{$n2}->{add_to_cfg}, 'zone already in the zone set is not added again');
    is_deeply($z{$n3}->{members}, [ $W{n3a}, $W{t1}, $W{t2} ], 'new zone: the initiator and the fabric\'s array ports');
    ok($z{$n3}->{add_to_cfg}, 'new zone added to the zone set');
    my ($fbz) = grep { $_->{name} =~ /_n1_/ } @{$fb->{zones}};
    is_deeply($fbz->{members}, [ $W{n1b}, $W{t3}, $W{t4} ], 'fabric B zone holds only fabric B array ports');
    ok(PVE::SAN::Fabric::Base::valid_zone_name($_->{name}), "zone name $_->{name} valid on both switch types")
        for @{$fa->{zones}}, @{$fb->{zones}};

    my $warn = join("\n", @{$p->{warnings}});
    like($warn, qr/node port\(s\) logged in to none of the fabrics: n3 10:00:00:10:9b:00:00:ff/, 'unplaced node port reported');
    like($warn, qr/array port\(s\) logged in to none of the fabrics: 50:05:07:68:0c:31:00:01/, 'unplaced array port reported');
    like($warn, qr/only one fabric reaches node\(s\) n3/, 'missing fabric redundancy reported');

    is(PVE::SAN::Zoning::zone_name('my.cluster-with-a-long-name', 'node-with-a-very-long-name', $W{n1a}, 'array.one'),
        'pve_my_cluster_w_node_with_a_very_' . lc($W{n1a}) . '_array_one', 'names sanitised and shortened');
    ok(length(PVE::SAN::Zoning::zone_name('x' x 40, 'y' x 40, $W{n1a}, 'z' x 40)) <= 64, 'names stay within 64 characters');
}

# blocked fabrics
{
    my $p = PVE::SAN::Zoning::compute({ array => 'fs1', hostcluster => 'lab', nodes => $nodes, targets => $targets,
        fabrics => [ fabric_a(busy => 'a zoning transaction is open on the fabric (token 7)') ] });
    like($p->{fabrics}->[0]->{blocked}, qr/transaction is open/, 'open transaction on the switch blocks');

    $p = PVE::SAN::Zoning::compute({ array => 'fs1', hostcluster => 'lab', nodes => $nodes, targets => $targets,
        fabrics => [ fabric_a(active_cfg => undef) ] });
    like($p->{fabrics}->[0]->{blocked}, qr/no zone set is active/, 'no active zone set and no setting blocks');

    $p = PVE::SAN::Zoning::compute({ array => 'fs1', hostcluster => 'lab', nodes => $nodes, targets => $targets,
        fabrics => [ fabric_a(active_cfg => undef, zoneset => 'prod_a') ] });
    ok(!$p->{fabrics}->[0]->{blocked}, 'zoneset setting used when none is active');

    $p = PVE::SAN::Zoning::compute({ array => 'fs1', hostcluster => 'lab', nodes => $nodes, targets => $targets,
        fabrics => [ fabric_a(active_zones => { legacy_n1 => [ $W{n1a}, $W{t1}, $W{t2} ] }) ] });
    like($p->{fabrics}->[0]->{blocked}, qr/saved changes that are not active/, 'unactivated saved changes block');

    $p = PVE::SAN::Zoning::compute({ array => 'fs1', hostcluster => 'lab', nodes => $nodes, targets => [ $W{t5} ],
        fabrics => [ fabric_a() ] });
    like($p->{fabrics}->[0]->{warnings}->[0], qr/none of the array's ports is logged in/, 'array absent from a fabric');
    is($p->{changes}, 0, 'then nothing to do there');
}

# ---------------- Brocade FOS REST ----------------
{
    my (%zones, %cfg, @patch);
    my $checksum = 'abc123';
    my $fail_enable = 0;
    my $auth = sub { my ($h) = @_; ($h->{Authorization} // '') eq 'Custom_Basic c2Vzcw==' };
    my ($drv, $calls) = FakeArray::driver('PVE::SAN::Fabric::Brocade', { vf_id => 10 }, [
        [ 'POST', qr{^/rest/login$}, sub { my (undef, undef, undef, $h) = @_;
            return ($h->{Authorization} =~ /^Basic / ? 200 : 401, '', { authorization => 'Custom_Basic c2Vzcw==' }) } ],
        [ 'POST', qr{^/rest/logout$}, sub { (204, '') } ],
        [ 'GET', qr{^/rest/running/brocade-fabric/fabric-switch$}, sub {
            (200, { Response => { 'fabric-switch' => [ { 'switch-user-friendly-name' => 'sw-a', 'firmware-version' => 'v9.1.1', principal => 1 } ] } }) } ],
        [ 'GET', qr{^/rest/running/brocade-name-server/fibrechannel-name-server$}, sub { my (undef, undef, undef, $h) = @_;
            return (401, 'no session') if !$auth->($h);
            (200, { Response => { 'fibrechannel-name-server' => [
                { 'port-name' => '10:00:00:10:9b:00:00:01', 'node-name' => '20:00:00:10:9b:00:00:01', 'fc4-features' => 'FCP-Initiator', 'port-symbolic-name' => 'QLE2772 FW:v9 DVR:v10' },
                { 'port-name' => '50:05:07:68:0c:11:00:01', 'name-server-device-type' => 'Physical Target', 'node-symbolic-name' => 'IBM 2145' },
            ] } }) } ],
        [ 'GET', qr{^/rest/running/brocade-zone/defined-configuration$}, sub {
            (200, { Response => { 'defined-configuration' => {
                cfg => { 'cfg-name' => 'prod_a', 'member-zone' => { 'zone-name' => [ 'z_old' ] } },
                zone => [ { 'zone-name' => 'z_old', 'zone-type' => 0, 'member-entry' => { 'entry-name' => [ 'host_x', '50:05:07:68:0c:11:00:01', '1,4' ] } } ],
                alias => { 'alias-name' => 'host_x', 'member-entry' => { 'alias-entry-name' => '10:00:00:10:9b:00:00:09' } },
            } } }) } ],
        [ 'GET', qr{^/rest/running/brocade-zone/effective-configuration$}, sub {
            (200, { Response => { 'effective-configuration' => { 'cfg-name' => 'prod_a', checksum => $checksum, 'transaction-token' => 0,
                'enabled-zone' => { 'zone-name' => 'z_old', 'member-entry' => { 'entry-name' => [ '10:00:00:10:9b:00:00:09', '50:05:07:68:0c:11:00:01' ] } } } } }) } ],
        [ 'POST', qr{^/rest/running/brocade-zone/defined-configuration/zone/zone-name/(\w+)$}, sub { my ($c, undef, $b) = @_;
            push @{$zones{$c->[0]}}, @{$b->{'member-entry'}->{'entry-name'}}; (201, '') } ],
        [ 'POST', qr{^/rest/running/brocade-zone/defined-configuration/cfg/cfg-name/(\w+)$}, sub { my ($c, undef, $b) = @_;
            push @{$cfg{$c->[0]}}, @{$b->{'member-zone'}->{'zone-name'}}; (201, '') } ],
        [ 'PATCH', qr{^/rest/running/brocade-zone/effective-configuration/(cfg-name/\w+|cfg-action/\d)$}, sub { my ($c, undef, $b) = @_;
            push @patch, [ $c->[0], $b->{checksum} ];
            return (400, { errors => { error => { 'error-message' => 'Zone DB too large' } } }) if $fail_enable && $c->[0] =~ /^cfg-name/;
            (204, '') } ],
    ]);

    my $info = $drv->system_info();
    is($info->{name}, 'sw-a', 'Brocade: switch name');
    ok((grep { $_->{url} =~ m{^/rest/running/brocade-fabric/fabric-switch\?vf-id=10$} } @$calls), 'Brocade: vf-id on every request');
    ok((grep { $_->{url} eq '/rest/logout' } @$calls), 'Brocade: session logged out');

    my $n = $drv->name_server();
    is_deeply([ map { "$_->{wwpn}:$_->{role}" } @$n ], [ '100000109B000001:initiator', '500507680C110001:target' ], 'Brocade: name server entries and roles');
    like($n->[0]->{symbolic}, qr/QLE2772/, 'Brocade: symbolic name kept');

    my $z = $drv->zoning();
    is($z->{active_cfg}, 'prod_a', 'Brocade: active cfg');
    is_deeply($z->{cfgs}, { prod_a => [ 'z_old' ] }, 'Brocade: single cfg (not a list) parsed');
    is_deeply($z->{zones}->{z_old}, [ '100000109B000009', '500507680C110001' ], 'Brocade: alias resolved, domain,port member skipped');
    is_deeply($z->{active_zones}->{z_old}, [ '100000109B000009', '500507680C110001' ], 'Brocade: effective zones');
    ok(!$z->{busy}, 'Brocade: no open transaction');
    ok(!PVE::SAN::Zoning::pending_changes($z, 'prod_a'), 'Brocade: defined matches effective');

    my $log = $drv->apply_zones('prod_a', [
        { name => 'pve_new', members => [ '100000109B000001', '500507680C110001' ], add_to_cfg => 1 },
        { name => 'z_old', members => [ '500507680C120001' ], add_to_cfg => 0 },
    ]);
    is_deeply($zones{pve_new}, [ '10:00:00:10:9b:00:00:01', '50:05:07:68:0c:11:00:01' ], 'Brocade: zone created with colon WWPNs');
    is_deeply($zones{z_old}, [ '50:05:07:68:0c:12:00:01' ], 'Brocade: existing zone extended');
    is_deeply($cfg{prod_a}, [ 'pve_new' ], 'Brocade: only the new zone added to the cfg');
    is_deeply($patch[-1], [ 'cfg-name/prod_a', 'abc123' ], 'Brocade: cfg saved and enabled with the checksum');
    like($log->[-1], qr/saved and enabled/, 'Brocade: log');

    $fail_enable = 1;
    eval { $drv->apply_zones('prod_a', [ { name => 'pve_new2', members => [ '100000109B000001' ], add_to_cfg => 1 } ]) };
    like($@, qr/Zone DB too large.*transaction aborted/s, 'Brocade: failed enable reported and the transaction aborted');
    is($patch[-1]->[0], 'cfg-action/4', 'Brocade: abort sent');
}

# ---------------- Cisco MDS NX-API ----------------
{
    my (@conf, $fail);
    my $show = {
        'show version' => { host_name => 'mds-b', chassis_id => 'MDS 9148T 32G Multilayer Fabric Switch', sys_ver_str => '9.4(1a)' },
        'show fcns database detail vsan 20' => { TABLE_fcns_vsan => { ROW_fcns_vsan => { vsan_id => '20', TABLE_fcns_database => { ROW_fcns_database => [
            { fcid => '0x010000', pwwn => '10:00:00:10:9b:00:00:02', nwwn => '20:00:00:10:9b:00:00:02', 'fc4_types_fc4_features' => 'scsi-fcp:init', symbolic_port_name => 'QLE2772' },
            { fcid => '0x010100', pwwn => '50:05:07:68:0c:21:00:01', 'fc4_types_fc4_features' => 'scsi-fcp:target', symbolic_node_name => 'IBM 2145' },
        ] } } } },
        'show zone vsan 20' => { TABLE_zone => { ROW_zone => [
            { zone_name => 'z_b_old', zone_vsan => '20', TABLE_zone_member => { ROW_zone_member => [ { type => 'pwwn', wwn => '10:00:00:10:9b:00:00:09' } ] } },
        ] } },
        'show zoneset vsan 20' => { TABLE_zoneset => { ROW_zoneset => { zoneset_name => 'zs_b', zoneset_vsan_id => '20',
            TABLE_zone => { ROW_zone => { zone_name => 'z_b_old', TABLE_zone_member => { ROW_zone_member => { type => 'pwwn', wwn => '10:00:00:10:9b:00:00:09' } } } } } } },
        'show zoneset active vsan 20' => { TABLE_zoneset => { ROW_zoneset => { zoneset_name => 'zs_b', zoneset_vsan_id => '20',
            TABLE_zone => { ROW_zone => { zone_name => 'z_b_old', TABLE_zone_member => { ROW_zone_member => { type => 'pwwn', wwn => '10:00:00:10:9b:00:00:09', fcid => '0x010200' } } } } } } },
        'show zone status vsan 20' => { TABLE_zone_status => { ROW_zone_status => { vsan_id => '20', mode => 'enhanced', session => 'none' } } },
    };
    my ($drv) = FakeArray::driver('PVE::SAN::Fabric::Cisco', { vsan => 20 }, [
        [ 'POST', qr{^/ins$}, sub { my (undef, undef, $b, $h) = @_;
            return (401, 'auth') if ($h->{Authorization} // '') !~ /^Basic /;
            my $a = $b->{ins_api};
            my @cmds = split(/ ;/, $a->{input});
            my @out;
            if ($a->{type} eq 'cli_conf') {
                push @conf, [ @cmds ];
                @out = map { ($fail && $_ =~ /activate/) ? { input => $_, code => '400', msg => 'CLI execution error', clierror => 'zoneset activation failed' }
                    : { input => $_, code => '200', msg => 'Success', body => {} } } @cmds;
            } else {
                @out = map { { input => $_, code => '200', msg => 'Success', body => $show->{$_} // {} } } @cmds;
            }
            return (200, { ins_api => { outputs => { output => @out == 1 ? $out[0] : \@out } } });
        } ],
    ]);

    is($drv->system_info()->{version}, '9.4(1a)', 'Cisco: version');
    my $n = $drv->name_server();
    is_deeply([ map { "$_->{wwpn}:$_->{role}" } @$n ], [ '100000109B000002:initiator', '500507680C210001:target' ], 'Cisco: name server and roles');
    is($n->[0]->{wwnn}, '200000109B000002', 'Cisco: node name');

    my $z = $drv->zoning();
    is($z->{mode}, 'enhanced', 'Cisco: enhanced zoning mode');
    is($z->{active_cfg}, 'zs_b', 'Cisco: active zone set');
    is_deeply($z->{cfgs}, { zs_b => [ 'z_b_old' ] }, 'Cisco: defined zone set');
    is_deeply($z->{zones}->{z_b_old}, [ '100000109B000009' ], 'Cisco: zone members');
    is_deeply($z->{active_zones}->{z_b_old}, [ '100000109B000009' ], 'Cisco: active zone members');
    ok(!$z->{busy}, 'Cisco: no open session');

    $drv->apply_zones('zs_b', [ { name => 'pve_new', members => [ '100000109B000002', '500507680C210001' ], add_to_cfg => 1 } ]);
    is_deeply($conf[0], [
        'zone name pve_new vsan 20', 'member pwwn 10:00:00:10:9b:00:00:02', 'member pwwn 50:05:07:68:0c:21:00:01',
        'zoneset name zs_b vsan 20', 'member pve_new',
        'zoneset activate name zs_b vsan 20', 'zone commit vsan 20',
    ], 'Cisco: zone, zone set membership, activation and commit');

    $fail = 1;
    eval { $drv->apply_zones('zs_b', [ { name => 'pve_x', members => [ '100000109B000002' ], add_to_cfg => 1 } ]) };
    like($@, qr/zoneset activation failed.*changes discarded/s, 'Cisco: failed activation reported and discarded');
    is_deeply($conf[-1], [ 'no zone commit vsan 20' ], 'Cisco: enhanced-mode changes discarded');

    $show->{'show zone status vsan 20'} = { TABLE_zone_status => { ROW_zone_status => { mode => 'enhanced', session => 'cli [admin]' } } };
    like($drv->zoning()->{busy}, qr/session is open on VSAN 20 \(cli \[admin\]\)/, 'Cisco: open session reported');

    eval { PVE::SAN::Fabric::Cisco->new(address => 'x', username => 'u', password => 'p', transport => sub {}) };
    like($@, qr/'vsan' is required/, 'Cisco: VSAN required');
}

# ---------------- array target ports ----------------
{
    my $rows = [
        { WWPN => '500507680C110001', host_io_permitted => 'no', virtualized => 'no' },
        { WWPN => '500507680C150001', host_io_permitted => 'yes', virtualized => 'yes', protocol => 'scsi' },
        { WWPN => '500507680C160001', host_io_permitted => 'yes', virtualized => 'yes', protocol => 'nvme' },
        { WWPN => '500507680C120001', host_io_permitted => 'yes', virtualized => 'no' },
    ];
    my $ibm = PVE::SAN::Array::IBMSV->new(address => 'fs', username => 'u', password => 'p', transport => sub {
        my ($path) = @_;
        return (200, '{"token":"t"}') if $path eq '/auth';
        return (200, $json->encode($rows)) if $path eq '/lstargetportfc';
        return (500, 'CMMVC5709E unknown');
    });
    is_deeply($ibm->target_ports(), [ '500507680C150001' ], 'IBM: NPIV host ports, SCSI only');
    $rows = [ map { { %$_, virtualized => 'no' } } @$rows[0, 3] ];
    is_deeply($ibm->target_ports(), [ '500507680C120001' ], 'IBM: physical host ports without NPIV');

    my ($inf) = FakeArray::driver('PVE::SAN::Array::Infinidat', {}, [
        [ 'GET', qr{^/api/rest/components/nodes$}, sub { my (undef, $q) = @_;
            return (400, 'fields') if ($q->{fields} // '') ne 'fc_ports';
            (200, { result => [
                { id => 1, fc_ports => [ { wwpn => '57:42:b0:f0:00:75:21:11', link_state => 'UP', state => 'OK' },
                                         { wwpn => '57:42:b0:f0:00:75:21:12', link_state => 'DOWN', state => 'OK' } ] },
                { id => 2, fc_ports => [ { wwpn => '57:42:b0:f0:00:75:22:11', link_state => 'Up', state => 'OK' } ] },
            ], metadata => { pages_total => 1 } }) } ],
    ]);
    is_deeply($inf->target_ports(), [ '5742B0F000752111', '5742B0F000752211' ], 'InfiniBox: FC ports that are up');
}

done_testing();
