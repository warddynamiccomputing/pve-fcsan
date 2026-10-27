use strict;
use warnings;

use Test::More;
use JSON::PP;

use PVE::SAN::Array::IBMSV;

my $json = JSON::PP->new->canonical;

# A tiny fake Spectrum Virtualize REST endpoint. Each handler gets
# (object, params) and returns (code, perl data or text).
sub fake_array {
    my (%handlers) = @_;
    my @calls;
    my $state = { token_ok => 1 };
    my $transport = sub {
        my ($path, $headers, $body) = @_;
        push @calls, { path => $path, headers => $headers, body => $body };
        if ($path eq '/auth') {
            return (403, 'bad credentials') if ($headers->{'X-Auth-Password'} // '') ne 'secret';
            $state->{token_ok} = 1;
            return (200, '{"token":"tok123"}');
        }
        return (403, 'expired') if !$state->{token_ok} || ($headers->{'X-Auth-Token'} // '') ne 'tok123';
        my ($cmd, $obj) = $path =~ m|^/([^/]+)(?:/(.+))?$|;
        my $h = $handlers{$cmd} // return (500, "CMMVC5709E unknown command $cmd");
        my ($code, $data) = $h->($obj, $body, $state);
        return ($code, ref($data) ? $json->encode($data) : ($data // ''));
    };
    my $drv = PVE::SAN::Array::IBMSV->new(
        address => 'fs9100', username => 'pvesan', password => 'secret', transport => $transport);
    return ($drv, \@calls, $state);
}

# --- transport, auth, errors ---
{
    my ($drv, $calls, $state) = fake_array(
        lssystem => sub { (200, { name => 'FS9100-LAB', product_name => 'IBM FlashSystem 9100', code_level => '8.6.0.4 (build 1)' }) },
    );
    my $info = $drv->system_info();
    is($info->{name}, 'FS9100-LAB', 'system name');
    is($calls->[0]->{path}, '/auth', 'logs in first');
    is($calls->[0]->{headers}->{'X-Auth-Username'}, 'pvesan', 'username header');
    is($calls->[1]->{headers}->{'X-Auth-Token'}, 'tok123', 'token header on commands');
    is_deeply($calls->[1]->{body}, {}, 'empty JSON body');

    $state->{token_ok} = 0; # token expired
    $drv->system_info();
    is(scalar(grep { $_->{path} eq '/auth' } @$calls), 2, 're-login after 403');

    eval { $drv->cmd('nosuch') };
    like($@, qr/'nosuch' failed \(HTTP 500\): CMMVC5709E/, 'array error text is reported');

    is(PVE::SAN::Array::IBMSV->new(address => '2001:db8::5', username => 'u', password => 'p',
        fingerprint => 'sha256$00')->base_url, 'https://[2001:db8::5]:7443/rest/v1', 'IPv6 URL and default port');
    eval { PVE::SAN::Array::IBMSV->new(address => 'x', username => 'u', password => 'p') };
    like($@, qr/fingerprint missing/, 'refuses to connect without a pinned fingerprint');
}
{
    my $drv = PVE::SAN::Array::IBMSV->new(address => 'a', username => 'u', password => 'wrong',
        transport => (fake_array())[0]->{transport});
    eval { $drv->login() };
    like($@, qr/login to a failed \(HTTP 403\)/, 'bad password');
}

# --- WWPN extraction across reply shapes ---
is_deeply(PVE::SAN::Array::IBMSV::extract_wwpns({ id => 1, WWPN => ['5000000000000001', '5000000000000002'] }),
    ['5000000000000001', '5000000000000002'], 'WWPN array');
is_deeply(PVE::SAN::Array::IBMSV::extract_wwpns({ nodes => [ { WWPN => '5000000000000005', state => 'active' },
    { WWPN => '5000000000000006' }, { iscsi_name => 'iqn.x' } ] }),
    ['5000000000000005', '5000000000000006'], 'nested port objects');
is_deeply(PVE::SAN::Array::IBMSV::extract_wwpns({ WWPN => 'not-a-wwpn' }), [], 'junk ignored');

# --- volumes ---
{
    my ($drv, $calls) = fake_array(
        mkvolume => sub { (200, { id => '42', message => 'Volume, id [42], successfully created' }) },
        lsvdisk => sub {
            my ($obj, $body) = @_;
            return (200, [ { id => '7', name => 'old', vdisk_UID => '6005076810810261F800000000000007',
                capacity => '107374182400', mdisk_grp_name => 'Pool0' } ]) if !defined($obj);
            return (200, { id => '42', name => 'ds01', vdisk_UID => '6005076810810261F80000000000002A',
                capacity => '1099511627776', mdisk_grp_name => 'Pool0' });
        },
        mkvolumehostclustermap => sub { (200, { id => '0' }) },
        expandvdisksize => sub { (200, '') },
        rmvolumehostclustermap => sub { (200, '') },
        rmvolume => sub { (200, '') },
    );

    my $v = $drv->create_volume(name => 'ds01', pool => 'Pool0', size_gib => 1024, thin => 1);
    my ($mk) = grep { $_->{path} eq '/mkvolume' } @$calls;
    is_deeply($mk->{body}, { name => 'ds01', pool => 'Pool0', size => '1024', unit => 'gb', thin => JSON::PP::true },
        'mkvolume body');
    is($v->{wwid}, '36005076810810261f80000000000002a', 'multipath WWID from vdisk_UID');
    is($v->{capacity}, 1099511627776, 'capacity in bytes');
    is($calls->[-1]->{path}, '/lsvdisk/42', 'reads back the new volume by id');

    eval { $drv->create_volume(name => '1bad', pool => 'Pool0', size_gib => 1) };
    like($@, qr/invalid volume name/, 'name rules enforced before calling the array');

    $drv->map_to_hostcluster('42', 'pvelab');
    is_deeply([ $calls->[-1]->{path}, $calls->[-1]->{body} ],
        [ '/mkvolumehostclustermap/42', { hostcluster => 'pvelab' } ], 'map to host cluster');

    $drv->expand_volume('42', 100 * 1024 ** 3);
    is_deeply($calls->[-1]->{body}, { size => '107374182400', unit => 'b' }, 'expand by delta in bytes');
    eval { $drv->expand_volume('42', 0) };
    like($@, qr/positive multiple/, 'zero expansion refused');

    $drv->unmap_from_hostcluster('42', 'pvelab');
    is($calls->[-1]->{path}, '/rmvolumehostclustermap/42', 'unmap');
    $drv->delete_volume('42');
    is($calls->[-1]->{path}, '/rmvolume/42', 'delete');

    my $found = $drv->find_volume_by_wwid('36005076810810261f800000000000007');
    is($calls->[-1]->{body}->{filtervalue}, 'vdisk_UID=6005076810810261F800000000000007', 'lookup by UID filter');
    is($found->{name}, 'old', 'volume found by WWID');
    is($drv->find_volume_by_wwid('2abc'), undef, 'non-NAA WWID is not an array volume');
}

# --- host cluster registration ---
{
    # array state: host "pvenode01" owns both ports of node 1 already, in no cluster;
    # node 2 has one port on host "esx-old" (in another cluster) -> must fail;
    # node 3 is unknown -> host created.
    my @hosts = (
        { id => 0, name => 'pvenode01', host_cluster_name => '', wwpns => ['5000000000000001', '5000000000000002'] },
        { id => 1, name => 'esx-old', host_cluster_name => 'vmware', wwpns => ['2100000000000002'] },
    );
    my @clusters;
    my ($drv, $calls) = fake_array(
        lshostcluster => sub { (200, [ map { { id => $_, name => $clusters[$_] } } 0 .. $#clusters ]) },
        mkhostcluster => sub { push @clusters, $_[1]->{name}; (200, { id => $#clusters }) },
        lshost => sub {
            my ($obj) = @_;
            return (200, [ map { { id => $_->{id}, name => $_->{name}, host_cluster_name => $_->{host_cluster_name} } } @hosts ])
                if !defined($obj);
            my ($h) = grep { $_->{id} eq $obj } @hosts;
            return (200, { id => $h->{id}, name => $h->{name}, nodes => [ map { { WWPN => $_ } } @{$h->{wwpns}} ] });
        },
        mkhost => sub {
            my (undef, $b) = @_;
            push @hosts, { id => scalar(@hosts), name => $b->{name}, host_cluster_name => '', wwpns => [ split(/:/, $b->{fcwwpn}) ] };
            (200, { id => $#hosts });
        },
        addhostport => sub { (200, '') },
        addhostclustermember => sub { (200, '') },
    );

    my @log;
    my $res = $drv->ensure_hostcluster('pvelab', {
        pvenode01 => ['50:00:00:00:00:00:00:01', '50:00:00:00:00:00:00:02', '50:00:00:00:00:00:00:03'],
        pvenode03 => ['50:00:00:00:00:00:00:04'],
    }, sub { push @log, $_[0] });

    is_deeply(\@clusters, ['pvelab'], 'host cluster created');
    is($res->{pvenode01}->{host}, 'pvenode01', 'existing host reused');
    is($res->{pvenode01}->{created}, 0, 'not recreated');
    is_deeply($res->{pvenode01}->{added_ports}, ['5000000000000003'], 'missing port added');
    my ($addport) = grep { $_->{path} =~ m|^/addhostport/| } @$calls;
    is_deeply([ $addport->{path}, $addport->{body} ],
        [ '/addhostport/pvenode01', { fcwwpn => '5000000000000003', force => JSON::PP::true } ], 'addhostport call');
    is($res->{pvenode03}->{created}, 1, 'new host created for unknown node');
    my ($mkhost) = grep { $_->{path} eq '/mkhost' } @$calls;
    is_deeply($mkhost->{body}, { name => 'pvenode03', fcwwpn => '5000000000000004', force => JSON::PP::true },
        'mkhost with forced ports');
    my @joins = map { $_->{body}->{host} } grep { $_->{path} eq '/addhostclustermember/pvelab' } @$calls;
    is_deeply([ sort @joins ], [ 'pvenode01', 'pvenode03' ], 'both hosts joined the host cluster');

    # second run is a no-op
    @$calls = ();
    $hosts[0]->{host_cluster_name} = 'pvelab';
    $hosts[2]->{host_cluster_name} = 'pvelab';
    push @{$hosts[0]->{wwpns}}, '5000000000000003';
    $drv->ensure_hostcluster('pvelab', {
        pvenode01 => ['5000000000000001', '5000000000000002', '5000000000000003'],
        pvenode03 => ['5000000000000004'],
    }, sub {});
    is(scalar(grep { $_->{path} =~ m{^/(?:mk|add)} } @$calls), 0, 'idempotent: nothing created on second run');

    # a node whose port belongs to a host in another host cluster
    eval { $drv->ensure_hostcluster('pvelab', { pvenode02 => ['2100000000000002'] }, sub {}) };
    like($@, qr/already belongs to host cluster 'vmware'/, 'refuses to steal a host from another cluster');

    # ports split across two hosts
    eval { $drv->ensure_hostcluster('pvelab', { pvenode09 => ['5000000000000001', '2100000000000002'] }, sub {}) };
    like($@, qr/split across array hosts/, 'refuses split ports');
}

done_testing();
