use strict;
use warnings;

use Test::More;
use JSON::PP;

use FakeArray;
use PVE::SAN::Array::ONTAP;
use PVE::SAN::Array::ESeries;

my $GIB = 1024 ** 3;

# ---------------- ONTAP ----------------
{
    my %st = (igroups => [ { uuid => 'ig1', name => 'old', protocol => 'fcp', initiators => [] } ],
        vols => {}, luns => {}, maps => {}, jobs => {});
    my $n = 0;
    my $job = sub { my $u = 'job' . ++$n; $st{jobs}->{$u} = 'success'; (202, { job => { uuid => $u } }) };
    my ($drv, $calls) = FakeArray::driver('PVE::SAN::Array::ONTAP', { svm => 'svm_san' }, [
        [ GET => qr{^/api/cluster$}, sub { (200, { name => 'ontap-c1', uuid => 'c-1', version => { full => 'NetApp Release 9.14.1' } }) } ],
        [ GET => qr{^/api/cluster/jobs/(\w+)$}, sub { (200, { state => $st{jobs}->{$_[0]->[0]} }) } ],
        [ GET => qr{^/api/storage/aggregates$}, sub {
            (200, { records => [ { name => 'aggr1', state => 'online', space => { block_storage => { size => 10 * $GIB, available => 6 * $GIB } } } ] }) } ],
        [ GET => qr{^/api/protocols/san/igroups$}, sub {
            my (undef, $q) = @_; (200, { records => [ grep { $_->{name} eq $q->{name} } @{$st{igroups}} ] }) } ],
        [ POST => qr{^/api/protocols/san/igroups$}, sub {
            push @{$st{igroups}}, { uuid => 'ig2', %{$_[2]} }; $job->() } ],
        [ POST => qr{^/api/protocols/san/igroups/(\w+)/initiators$}, sub {
            my ($c, undef, $b) = @_; my ($g) = grep { $_->{uuid} eq $c->[0] } @{$st{igroups}};
            push @{$g->{initiators}}, @{$b->{records}}; $job->() } ],
        [ POST => qr{^/api/storage/volumes$}, sub { $st{vols}->{$_[2]->{name}} = { uuid => 'fv-' . $_[2]->{name}, %{$_[2]} }; $job->() } ],
        [ GET => qr{^/api/storage/volumes$}, sub {
            my (undef, $q) = @_; (200, { records => [ grep { defined } $st{vols}->{$q->{name}} ] }) } ],
        [ GET => qr{^/api/storage/volumes/([\w-]+)$}, sub {
            my ($v) = grep { $_->{uuid} eq $_[0]->[0] } values %{$st{vols}}; (200, $v) } ],
        [ PATCH => qr{^/api/storage/volumes/([\w-]+)$}, sub {
            my ($v) = grep { $_->{uuid} eq $_[0]->[0] } values %{$st{vols}}; $v->{size} = $_[2]->{size}; $job->() } ],
        [ DELETE => qr{^/api/storage/volumes/([\w-]+)$}, sub {
            my ($k) = grep { $st{vols}->{$_}->{uuid} eq $_[0]->[0] } keys %{$st{vols}}; delete $st{vols}->{$k}; $job->() } ],
        [ POST => qr{^/api/storage/luns$}, sub {
            my $b = $_[2]; my ($fv) = $b->{name} =~ m|^/vol/([^/]+)/|;
            $st{luns}->{'l1'} = { uuid => 'l1', name => $b->{name}, serial_number => '80S5?F0ErzA1',
                space => { size => $b->{space}->{size} }, location => { volume => { name => $fv, uuid => "fv-$fv" } }, req => $b };
            $job->() } ],
        [ GET => qr{^/api/storage/luns$}, sub {
            my (undef, $q) = @_;
            (200, { records => [ grep { (!$q->{name} || $_->{name} eq $q->{name})
                && (!$q->{serial_number} || $_->{serial_number} eq $q->{serial_number})
                && (!$q->{'location.volume.uuid'} || $_->{location}->{volume}->{uuid} eq $q->{'location.volume.uuid'}) } values %{$st{luns}} ] }) } ],
        [ GET => qr{^/api/storage/luns/(\w+)$}, sub { (200, $st{luns}->{$_[0]->[0]}) } ],
        [ PATCH => qr{^/api/storage/luns/(\w+)$}, sub { $st{luns}->{$_[0]->[0]}->{space}->{size} = $_[2]->{space}->{size}; $job->() } ],
        [ DELETE => qr{^/api/storage/luns/(\w+)$}, sub { delete $st{luns}->{$_[0]->[0]}; $job->() } ],
        [ POST => qr{^/api/protocols/san/lun-maps$}, sub { $st{maps}->{$_[2]->{lun}->{uuid} . '/' . $_[2]->{igroup}->{name}} = 1; $job->() } ],
        [ DELETE => qr{^/api/protocols/san/lun-maps/(\w+)/(\w+)$}, sub { $st{maps}->{"$_[0]->[0]/$_[0]->[1]"} = 0; $job->() } ],
    ]);

    eval { PVE::SAN::Array::ONTAP->new(address => 'a', username => 'u', password => 'p', fingerprint => 'sha256$0') };
    like($@, qr/'svm' is required/, 'ONTAP: SVM required');
    is($drv->system_info->{code_level}, 'NetApp Release 9.14.1', 'ONTAP: version');
    is($drv->pools->[0]->{free}, 6 * $GIB, 'ONTAP: aggregate free space');

    my $res = $drv->ensure_hostcluster('pvelab', {
        pvenode01 => ['50:00:00:00:00:00:00:01'], pvenode02 => ['50:00:00:00:00:00:00:05'] }, sub {});
    my $ig = FakeArray::find_call($calls, 'POST', qr{/igroups\?});
    is_deeply($ig->{body}, { name => 'pvelab', svm => { name => 'svm_san' }, os_type => 'linux', protocol => 'fcp',
        initiators => [ { name => '50:00:00:00:00:00:00:01' }, { name => '50:00:00:00:00:00:00:05' } ] }, 'ONTAP: FCP igroup with all initiators');
    like($ig->{url}, qr/return_timeout=120/, 'ONTAP: changes wait for their job');
    ok(FakeArray::find_call($calls, 'GET', qr{/cluster/jobs/job1}), 'ONTAP: job polled');

    $drv->ensure_hostcluster('pvelab', { pvenode01 => ['50:00:00:00:00:00:00:01', '50:00:00:00:00:00:00:02'] }, sub {});
    is_deeply(FakeArray::find_call($calls, 'POST', qr{/igroups/ig2/initiators})->{body},
        { records => [ { name => '50:00:00:00:00:00:00:02' } ] }, 'ONTAP: missing initiator added as records');

    is($drv->volume_name_for('gold-01'), 'gold_01', 'ONTAP: FlexVol name adapted');
    my $v = $drv->create_volume(name => 'gold_01', pool => 'aggr1', size_gib => 100, thin => 1);
    my $fv = FakeArray::find_call($calls, 'POST', qr{/storage/volumes\?})->{body};
    is_deeply([ @$fv{qw(name size)}, $fv->{guarantee}->{type}, $fv->{aggregates}->[0]->{name} ],
        [ 'gold_01', int(100 * $GIB * 1.1), 'none', 'aggr1' ], 'ONTAP: thin FlexVol with 10% headroom');
    my $lun = FakeArray::find_call($calls, 'POST', qr{/storage/luns\?})->{body};
    is_deeply($lun, { svm => { name => 'svm_san' }, name => '/vol/gold_01/lun0', os_type => 'linux',
        space => { size => 100 * $GIB, guarantee => { requested => JSON::PP::false } } }, 'ONTAP: LUN body');
    is($v->{wwid}, '3600a098038305335 3f463045727a4131' =~ s/ //r, 'ONTAP: WWID = 3600a0980 + hex(serial)');
    is($drv->find_volume_by_wwid($v->{wwid})->{id}, 'l1', 'ONTAP: lookup by serial');

    $drv->map_to_hostcluster($v->{id}, 'pvelab');
    is_deeply(FakeArray::find_call($calls, 'POST', qr{/lun-maps\?})->{body},
        { svm => { name => 'svm_san' }, igroup => { name => 'pvelab' }, lun => { uuid => 'l1' } }, 'ONTAP: LUN map body');

    $drv->expand_volume($v->{id}, 100 * $GIB);
    is($st{vols}->{gold_01}->{size}, int(200 * $GIB * 1.1), 'ONTAP: FlexVol grown first');
    is($st{luns}->{l1}->{space}->{size}, 200 * $GIB, 'ONTAP: then the LUN');

    $drv->unmap_from_hostcluster($v->{id}, 'pvelab');
    ok(FakeArray::find_call($calls, 'DELETE', qr{/lun-maps/l1/ig2}), 'ONTAP: unmap by LUN and igroup uuid');
    $drv->delete_volume($v->{id});
    ok(!$st{luns}->{l1} && !$st{vols}->{gold_01}, 'ONTAP: LUN and its FlexVol deleted');
}

# ---------------- E-Series ----------------
{
    my $NOG = '0' x 40;
    my %st = (groups => [], hosts => [ { id => 'h1', name => 'pvenode01', clusterRef => $NOG,
        hostSidePorts => [ { type => 'fc', address => '5000000000000001' } ] } ], vols => {}, maps => []);
    my ($drv, $calls) = FakeArray::driver('PVE::SAN::Array::ESeries', {}, [
        [ GET => qr{^/devmgr/v2/storage-systems/1$}, sub { (200, { name => 'ef600-a', model => 'EF600', fwVersion => '11.80' }) } ],
        [ GET => qr{/storage-pools$}, sub { (200, [ { id => 'p1', name => 'DDP1', totalRaidedSpace => '1000', freeSpace => '400' } ]) } ],
        [ GET => qr{/host-types$}, sub { (200, [ { index => 7, name => 'Linux (ATTO)' }, { index => 28, code => 'LnxDHP', name => 'Linux DM-MP (Kernel 3.10 or later)' } ]) } ],
        [ GET => qr{/host-groups$}, sub { (200, $st{groups}) } ],
        [ POST => qr{/host-groups$}, sub { push @{$st{groups}}, { clusterRef => 'G1', name => $_[2]->{name} }; (200, $st{groups}->[-1]) } ],
        [ GET => qr{/hosts$}, sub { (200, $st{hosts}) } ],
        [ POST => qr{/hosts$}, sub {
            my $b = $_[2];
            push @{$st{hosts}}, { id => 'h2', name => $b->{name}, clusterRef => $NOG,
                hostSidePorts => [ map { { type => $_->{type}, address => $_->{port} } } @{$b->{ports}} ] };
            (200, $st{hosts}->[-1]) } ],
        [ POST => qr{/hosts/(\w+)/move$}, sub { my ($h) = grep { $_->{id} eq $_[0]->[0] } @{$st{hosts}}; $h->{clusterRef} = $_[2]->{group}; (200, $h) } ],
        [ POST => qr{/hosts/(\w+)$}, sub { (200, {}) } ],
        [ POST => qr{/volumes$}, sub {
            $st{vols}->{v1} = { id => 'v1', name => $_[2]->{name}, capacity => "$_[2]->{size}", wwn => '600A098000A4B1C2000005E6650F1A2B' };
            (200, $st{vols}->{v1}) } ],
        [ GET => qr{/volumes/(\w+)$}, sub { (200, $st{vols}->{$_[0]->[0]}) } ],
        [ GET => qr{/volumes$}, sub { (200, [ values %{$st{vols}} ]) } ],
        [ POST => qr{/volumes/(\w+)/expand$}, sub { $st{vols}->{$_[0]->[0]}->{capacity} = "$_[2]->{expansionSize}"; (200, {}) } ],
        [ DELETE => qr{/volumes/(\w+)$}, sub { delete $st{vols}->{$_[0]->[0]}; (204, '') } ],
        [ POST => qr{/volume-mappings$}, sub {
            push @{$st{maps}}, { lunMappingRef => 'M1', volumeRef => $_[2]->{mappableObjectId}, mapRef => $_[2]->{targetId}, lun => 1 }; (200, {}) } ],
        [ GET => qr{/volume-mappings$}, sub { (200, $st{maps}) } ],
        [ DELETE => qr{/volume-mappings/(\w+)$}, sub { $st{maps} = [ grep { $_->{lunMappingRef} ne $_[0]->[0] } @{$st{maps}} ]; (204, '') } ],
    ]);

    is($drv->system_info->{product}, 'NetApp E-Series EF600', 'E-Series: model');
    like($calls->[0]->{url}, qr{^/devmgr/v2/storage-systems/1}, 'E-Series: embedded system id 1 by default');

    $drv->ensure_hostcluster('pvelab', {
        pvenode01 => ['50:00:00:00:00:00:00:01'], pvenode02 => ['50:00:00:00:00:00:00:05'] }, sub {});
    is_deeply(FakeArray::find_call($calls, 'POST', qr{/host-groups$})->{body}, { name => 'pvelab', hosts => [] }, 'E-Series: host group');
    is_deeply(FakeArray::find_call($calls, 'POST', qr{/hosts$})->{body},
        { name => 'pvenode02', hostType => { index => 28 }, ports => [ { type => 'fc', port => '5000000000000005', label => 'pvenode02-p0' } ] },
        'E-Series: host with Linux DM-MP type and FC port');
    is(scalar(grep { $_->{url} =~ m{/hosts/h\d/move$} } @$calls), 2, 'E-Series: both hosts moved into the group');

    my $v = $drv->create_volume(name => 'gold_01', pool => 'DDP1', size_gib => 10);
    is_deeply(FakeArray::find_call($calls, 'POST', qr{/volumes$})->{body}, { name => 'gold_01', poolId => 'p1', sizeUnit => 'bytes',
        size => 10 * $GIB, segSize => 128, dataAssuranceEnabled => JSON::PP::false }, 'E-Series: thick volume body');
    is($v->{wwid}, '3600a098000a4b1c2000005e6650f1a2b', 'E-Series: WWID from wwn');
    $drv->map_to_hostcluster($v->{id}, 'pvelab');
    is_deeply(FakeArray::find_call($calls, 'POST', qr{/volume-mappings$})->{body}, { mappableObjectId => 'v1', targetId => 'G1' }, 'E-Series: map to group');
    $drv->expand_volume($v->{id}, 5 * $GIB);
    is($st{vols}->{v1}->{capacity}, 15 * $GIB, 'E-Series: expansionSize = new total');
    $drv->unmap_from_hostcluster($v->{id}, 'pvelab');
    is_deeply($st{maps}, [], 'E-Series: mapping deleted by lunMappingRef');
    $drv->delete_volume($v->{id});
    ok(!$st{vols}->{v1}, 'E-Series: deleted');
}

done_testing();
