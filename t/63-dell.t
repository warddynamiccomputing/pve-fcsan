use strict;
use warnings;

use Test::More;
use JSON::PP;

use FakeArray;
use PVE::SAN::Array::PowerStore;
use PVE::SAN::Array::PowerMax;

my $GIB = 1024 ** 3;

# ---------------- PowerStore ----------------
{
    my %st = (hosts => [ { id => 'h1', name => 'pvenode01', host_group_id => undef,
        host_initiators => [ { port_name => '50:00:00:00:00:00:00:01', port_type => 'FC' } ] } ],
        groups => [], vols => {}, attached => {});
    my $vid = 0;
    my ($drv, $calls) = FakeArray::driver('PVE::SAN::Array::PowerStore', {}, [
        [ GET => qr{^/api/rest/login_session$}, sub {
            my (undef, undef, undef, $h) = @_;
            return (401, '{"messages":[{"code":"0xE09040040001","message_l10n":"Unauthorized"}]}')
                if ($h->{Authorization} // '') !~ /^Basic /;
            return (200, [ { id => 's1', idle_timeout => 3600 } ], { 'dell-emc-token' => 'TOK', 'set-cookie' => 'auth_cookie=CK; Path=/' });
        } ],
        [ GET => qr{^/api/rest/cluster$}, sub { (200, [ { id => '0', name => 'PS-500T' } ]) } ],
        [ GET => qr{^/api/rest/software_installed$}, sub { (200, [ { release_version => '4.1.0.0' } ]) } ],
        [ GET => qr{^/api/rest/host_group$}, sub { (200, $st{groups}) } ],
        [ GET => qr{^/api/rest/host$}, sub { (200, $st{hosts}) } ],
        [ POST => qr{^/api/rest/host$}, sub {
            my (undef, undef, $b) = @_;
            push @{$st{hosts}}, { id => 'h' . (@{$st{hosts}} + 1), name => $b->{name}, host_initiators => $b->{initiators} };
            (201, { id => $st{hosts}->[-1]->{id} });
        } ],
        [ PATCH => qr{^/api/rest/host/(\w+)$}, sub {
            my ($c, undef, $b) = @_;
            my ($h) = grep { $_->{id} eq $c->[0] } @{$st{hosts}};
            push @{$h->{host_initiators}}, @{$b->{add_initiators}};
            (204, '');
        } ],
        [ POST => qr{^/api/rest/host_group$}, sub {
            my (undef, undef, $b) = @_;
            push @{$st{groups}}, { id => 'g1', name => $b->{name} };
            $_->{host_group_id} = 'g1' for grep { my $h = $_; grep { $_ eq $h->{id} } @{$b->{host_ids}} } @{$st{hosts}};
            (201, { id => 'g1' });
        } ],
        [ PATCH => qr{^/api/rest/host_group/(\w+)$}, sub {
            my ($c, undef, $b) = @_;
            $_->{host_group_id} = $c->[0] for grep { my $h = $_; grep { $_ eq $h->{id} } @{$b->{add_host_ids}} } @{$st{hosts}};
            (204, '');
        } ],
        [ POST => qr{^/api/rest/volume$}, sub {
            my (undef, undef, $b) = @_;
            my $id = 'v' . ++$vid;
            $st{vols}->{$id} = { id => $id, name => $b->{name}, size => $b->{size}, wwn => 'naa.68ccf09800e8f8d6a9a5c7f1b2c3d4e5' };
            (201, { id => $id });
        } ],
        [ GET => qr{^/api/rest/volume/(\w+)$}, sub { (200, $st{vols}->{$_[0]->[0]}) } ],
        [ GET => qr{^/api/rest/volume$}, sub {
            my (undef, $q) = @_;
            (200, [ grep { 'eq.' . $_->{wwn} eq ($q->{wwn} // '') } values %{$st{vols}} ]);
        } ],
        [ PATCH => qr{^/api/rest/volume/(\w+)$}, sub { $st{vols}->{$_[0]->[0]}->{size} = $_[2]->{size}; (204, '') } ],
        [ POST => qr{^/api/rest/volume/(\w+)/(attach|detach)$}, sub {
            my ($c, undef, $b) = @_;
            $st{attached}->{"$c->[0]/$b->{host_group_id}"} = $c->[1] eq 'attach' ? 1 : 0;
            (204, '');
        } ],
        [ DELETE => qr{^/api/rest/volume/(\w+)$}, sub { delete $st{vols}->{$_[0]->[0]}; (204, '') } ],
    ]);

    is($drv->system_info->{name}, 'PS-500T', 'PowerStore: cluster name');
    is($drv->system_info->{code_level}, '4.1.0.0', 'PowerStore: release');
    my $login = FakeArray::find_call($calls, 'GET', qr{login_session});
    ok($login, 'PowerStore: logs in via login_session');
    my $later = $calls->[-1];
    is($later->{headers}->{'DELL-EMC-TOKEN'}, 'TOK', 'PowerStore: token header on later calls');
    is($later->{headers}->{Cookie}, 'auth_cookie=CK', 'PowerStore: auth cookie on later calls');

    my $res = $drv->ensure_hostcluster('pvelab', {
        pvenode01 => ['50:00:00:00:00:00:00:01', '50:00:00:00:00:00:00:02'],
        pvenode02 => ['50:00:00:00:00:00:00:05'],
    }, sub {});
    is_deeply($res->{pvenode01}->{added_ports}, ['5000000000000002'], 'PowerStore: missing initiator added');
    is_deeply(FakeArray::find_call($calls, 'PATCH', qr{/host/h1$})->{body},
        { add_initiators => [ { port_name => '50:00:00:00:00:00:00:02', port_type => 'FC' } ] }, 'PowerStore: add_initiators body');
    is_deeply(FakeArray::find_call($calls, 'POST', qr{/api/rest/host$})->{body},
        { name => 'pvenode02', os_type => 'Linux', initiators => [ { port_name => '50:00:00:00:00:00:00:05', port_type => 'FC' } ] },
        'PowerStore: host created with FC initiator');
    is_deeply(FakeArray::find_call($calls, 'POST', qr{/host_group$})->{body}, { name => 'pvelab', host_ids => ['h1'] },
        'PowerStore: host group created with its first host');
    is_deeply(FakeArray::find_call($calls, 'PATCH', qr{/host_group/g1$})->{body}, { add_host_ids => ['h2'] },
        'PowerStore: second host added with add_host_ids');

    my $v = $drv->create_volume(name => 'gold-01', pool => 'default', size_gib => 100);
    is_deeply(FakeArray::find_call($calls, 'POST', qr{/api/rest/volume$})->{body}, { name => 'gold-01', size => 100 * $GIB },
        'PowerStore: volume create body');
    is($v->{wwid}, '368ccf09800e8f8d6a9a5c7f1b2c3d4e5', 'PowerStore: WWID from naa wwn');
    $drv->map_to_hostcluster($v->{id}, 'pvelab');
    is_deeply(FakeArray::find_call($calls, 'POST', qr{/attach$})->{body}, { host_group_id => 'g1' }, 'PowerStore: attach to host group');
    $drv->expand_volume($v->{id}, 50 * $GIB);
    is($drv->volume($v->{id})->{capacity}, 150 * $GIB, 'PowerStore: PATCH size = new total');
    is($drv->find_volume_by_wwid($v->{wwid})->{id}, $v->{id}, 'PowerStore: lookup by wwn filter');
    $drv->unmap_from_hostcluster($v->{id}, 'pvelab');
    is($st{attached}->{"$v->{id}/g1"}, 0, 'PowerStore: detached');
    $drv->delete_volume($v->{id});
    ok(!$st{vols}->{$v->{id}}, 'PowerStore: deleted');
}

# ---------------- PowerMax ----------------
{
    my $base = qr{^/univmax/restapi/100/sloprovisioning/symmetrix/000197900123};
    my %st = (hosts => { pvenode01 => { initiator => ['5000000000000001'], hostGroup => [] } },
        hgs => {}, sgs => {}, mvs => {}, vols => {});
    my $dev = 0x100;
    my ($drv, $calls) = FakeArray::driver('PVE::SAN::Array::PowerMax',
        { system_id => '000197900123', portgroup => 'pve_PG', hostcluster => 'pvelab' }, [
        [ GET => qr{^/univmax/restapi/version$}, sub { (200, { version => 'T10.0.0.1', api_version => '100' }) } ],
        [ GET => qr{^/univmax/restapi/100/system/symmetrix/(\w+)$}, sub { (200, { symmetrixId => $_[0]->[0], model => 'PowerMax_2000', ucode => '6079.225' }) } ],
        [ GET => qr{$base/host$}, sub { (200, { hostId => [ sort keys %{$st{hosts}} ] }) } ],
        [ GET => qr{$base/host/(\w+)$}, sub { (200, $st{hosts}->{$_[0]->[0]}) } ],
        [ POST => qr{$base/host$}, sub { $st{hosts}->{$_[2]->{hostId}} = { initiator => $_[2]->{initiatorId}, hostGroup => [] }; (201, {}) } ],
        [ PUT => qr{$base/host/(\w+)$}, sub {
            push @{$st{hosts}->{$_[0]->[0]}->{initiator}}, @{$_[2]->{editHostActionParam}->{addInitiatorParam}->{initiator}}; (200, {}) } ],
        [ GET => qr{$base/hostgroup$}, sub { (200, { hostGroupId => [ sort keys %{$st{hgs}} ] }) } ],
        [ POST => qr{$base/hostgroup$}, sub {
            my $b = $_[2]; $st{hgs}->{$b->{hostGroupId}} = 1;
            push @{$st{hosts}->{$_}->{hostGroup}}, $b->{hostGroupId} for @{$b->{hostId}}; (201, {}) } ],
        [ PUT => qr{$base/hostgroup/(\w+)$}, sub {
            push @{$st{hosts}->{$_}->{hostGroup}}, $_[0]->[0] for @{$_[2]->{editHostGroupActionParam}->{addHostParam}->{host}}; (200, {}) } ],
        [ GET => qr{$base/storagegroup$}, sub { (200, { storageGroupId => [ sort keys %{$st{sgs}} ] }) } ],
        [ POST => qr{$base/storagegroup$}, sub { $st{sgs}->{$_[2]->{storageGroupId}} = $_[2]; (201, {}) } ],
        [ GET => qr{$base/maskingview$}, sub { (200, { maskingViewId => [ sort keys %{$st{mvs}} ] }) } ],
        [ POST => qr{$base/maskingview$}, sub { $st{mvs}->{$_[2]->{maskingViewId}} = $_[2]; (201, {}) } ],
        [ PUT => qr{$base/storagegroup/(\w+)$}, sub {
            my ($c, undef, $b) = @_;
            my $p = $b->{editStorageGroupActionParam};
            if (my $add = $p->{expandStorageGroupParam}) {
                if (my $a = $add->{addVolumeParam}) {
                    my $attr = $a->{volumeAttributes}->[0];
                    my $id = sprintf('%05X', $dev++);
                    $st{vols}->{$id} = { volumeId => $id, volume_identifier => $attr->{volumeIdentifier}->{identifier_name},
                        cap_mb => $attr->{volume_size}, effective_wwn => '60000970000197900123533030' . $id . '0', storageGroupId => [ $c->[0] ] };
                }
            }
            if (my $rm = $p->{removeVolumeParam}) { $st{vols}->{$_}->{storageGroupId} = [] for @{$rm->{volumeId}}; }
            (200, {});
        } ],
        [ GET => qr{$base/volume$}, sub {
            my (undef, $q) = @_;
            my @m = grep { (!$q->{volume_identifier} || $_->{volume_identifier} eq $q->{volume_identifier})
                && (!$q->{wwn} || uc($_->{effective_wwn}) eq $q->{wwn}) } values %{$st{vols}};
            (200, { resultList => { result => [ map { { volumeId => $_->{volumeId} } } @m ] } });
        } ],
        [ GET => qr{$base/volume/(\w+)$}, sub { (200, $st{vols}->{$_[0]->[0]}) } ],
        [ PUT => qr{$base/volume/(\w+)$}, sub {
            my ($c, undef, $b) = @_;
            my $p = $b->{editVolumeActionParam};
            $st{vols}->{$c->[0]}->{cap_mb} = $p->{expandVolumeParam}->{volumeAttribute}->{volume_size} if $p->{expandVolumeParam};
            $st{vols}->{$c->[0]}->{freed} = 1 if $p->{freeVolumeParam};
            (200, {});
        } ],
        [ DELETE => qr{$base/volume/(\w+)$}, sub {
            return (400, { message => 'volume must be deallocated first' }) if !$st{vols}->{$_[0]->[0]}->{freed};
            delete $st{vols}->{$_[0]->[0]}; (204, '');
        } ],
    ]);

    eval { PVE::SAN::Array::PowerMax->new(address => 'u', username => 'x', password => 'y', fingerprint => 'sha256$0', system_id => '1') };
    like($@, qr/'portgroup' is required/, 'PowerMax: port group required');
    is($drv->system_info->{product}, 'Dell PowerMax_2000', 'PowerMax: model');

    $drv->ensure_hostcluster('pvelab', {
        pvenode01 => ['50:00:00:00:00:00:00:01', '50:00:00:00:00:00:00:02'],
        pvenode03 => ['50:00:00:00:00:00:00:04'],
    }, sub {});
    is_deeply(FakeArray::find_call($calls, 'PUT', qr{/host/pvenode01$})->{body},
        { editHostActionParam => { addInitiatorParam => { initiator => ['5000000000000002'] } } }, 'PowerMax: addInitiatorParam');
    is_deeply(FakeArray::find_call($calls, 'POST', qr{/host$})->{body},
        { hostId => 'pvenode03', initiatorId => ['5000000000000004'] }, 'PowerMax: host created');
    is_deeply(FakeArray::find_call($calls, 'POST', qr{/hostgroup$})->{body},
        { hostGroupId => 'pvelab', hostId => ['pvenode01'] }, 'PowerMax: host group created with first host');
    is_deeply(FakeArray::find_call($calls, 'POST', qr{/storagegroup$})->{body},
        { storageGroupId => 'pvelab_SG', srpId => 'SRP_1', emulation => 'FBA',
          sloBasedStorageGroupParam => [ { sloId => 'None', workloadSelection => 'None' } ] }, 'PowerMax: storage group');
    is_deeply(FakeArray::find_call($calls, 'POST', qr{/maskingview$})->{body}, {
        maskingViewId => 'pvelab_MV',
        portGroupSelection => { useExistingPortGroupParam => { portGroupId => 'pve_PG' } },
        hostOrHostGroupSelection => { useExistingHostGroupParam => { hostGroupId => 'pvelab' } },
        storageGroupSelection => { useExistingStorageGroupParam => { storageGroupId => 'pvelab_SG' } },
    }, 'PowerMax: masking view joins HG, PG and SG');

    my $v = $drv->create_volume(name => 'gold_01', pool => 'SRP_1', size_gib => 100);
    my $add = FakeArray::find_call($calls, 'PUT', qr{/storagegroup/pvelab_SG$})->{body}
        ->{editStorageGroupActionParam}->{expandStorageGroupParam}->{addVolumeParam};
    is_deeply($add->{volumeAttributes}->[0]->{volumeIdentifier},
        { identifier_name => 'gold_01', volumeIdentifierChoice => 'identifier_name' }, 'PowerMax: volume identifier');
    is($add->{volumeAttributes}->[0]->{volume_size}, '102400', 'PowerMax: size in MB');
    is($v->{capacity}, 100 * $GIB, 'PowerMax: capacity');
    like($v->{wwid}, qr/^360000970000197900123533030/, 'PowerMax: WWID from effective_wwn');
    eval { $drv->create_volume(name => 'x', pool => 'SRP_2', size_gib => 1) };
    like($@, qr/SRP 'SRP_1'/, 'PowerMax: pool must be the storage group SRP');

    my $n = scalar(@$calls);
    $drv->map_to_hostcluster($v->{id}, 'pvelab');
    is(scalar(grep { $_->{method} eq 'PUT' } @{$calls}[$n .. $#$calls]), 0, 'PowerMax: already presented through the SG');

    $drv->expand_volume($v->{id}, 50 * $GIB);
    is($st{vols}->{$v->{id}}->{cap_mb}, '153600', 'PowerMax: expandVolumeParam with new total');
    $drv->unmap_from_hostcluster($v->{id}, 'pvelab');
    is_deeply($st{vols}->{$v->{id}}->{storageGroupId}, [], 'PowerMax: removed from the SG');
    $drv->delete_volume($v->{id});
    ok(!$st{vols}->{$v->{id}}, 'PowerMax: freed then deleted');
}

done_testing();
