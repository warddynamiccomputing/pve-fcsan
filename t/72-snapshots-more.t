use strict;
use warnings;

use Test::More;
use JSON::PP;

use FakeArray;
use PVE::SAN::Array::ONTAP;
use PVE::SAN::Array::IBMSV;

my $GIB = 1024 ** 3;
my $json = JSON::PP->new->canonical;

# ---------------- NetApp ONTAP ----------------
{
    my %st = (
        luns => { L1 => { uuid => 'L1', name => '/vol/gold/lun0', serial_number => '80BbZ+LnJ9dA',
            space => { size => 10 * $GIB }, location => { volume => { name => 'gold', uuid => 'FV1' } } } },
        flexvols => { FV1 => 'gold' },
        snaps => { FV1 => [ { uuid => 'S0', name => 'hourly.2026-10-29_0805', create_time => '2026-10-29T08:05:00+00:00' } ] },
        n => 0,
    );
    my $recs = sub { (200, { records => $_[0], num_records => scalar(@{$_[0]}) }) };
    my ($drv, $calls) = FakeArray::driver('PVE::SAN::Array::ONTAP', { svm => 'svm1' }, [
        [ GET => qr{^/api/storage/luns/([^/]+)$}, sub { my $l = $st{luns}->{$_[0]->[0]} or return (404, {}); (200, $l) } ],
        [ GET => qr{^/api/storage/luns$}, sub {
            my $q = $_[1];
            $recs->([ grep { !defined($q->{name}) || $_->{name} eq $q->{name} } values %{$st{luns}} ]) } ],
        [ PATCH => qr{^/api/storage/luns/([^/]+)$}, sub { $st{luns}->{$_[0]->[0]}->{enabled} = $_[2]->{enabled}; (200, {}) } ],
        [ GET => qr{^/api/storage/volumes/([^/]+)/snapshots$}, sub { $recs->($st{snaps}->{$_[0]->[0]} // []) } ],
        [ POST => qr{^/api/storage/volumes/([^/]+)/snapshots$}, sub {
            my ($c, $q, $b) = @_;
            return (409, { error => { code => '1638600', message => 'Snapshot name already exists' } })
                if grep { $_->{name} eq $b->{name} } @{$st{snaps}->{$c->[0]}};
            push @{$st{snaps}->{$c->[0]}}, { uuid => 'S' . ++$st{n}, name => $b->{name},
                create_time => sprintf('2026-10-29T09:%02d:00+01:00', $st{n}) };
            (201, {}) } ],
        [ DELETE => qr{^/api/storage/volumes/([^/]+)/snapshots/([^/]+)$}, sub {
            my ($fv, $su) = @{$_[0]};
            $st{snaps}->{$fv} = [ grep { $_->{uuid} ne $su } @{$st{snaps}->{$fv}} ];
            (200, {}) } ],
        [ POST => qr{^/api/storage/volumes$}, sub {
            my ($c, $q, $b) = @_;
            my $fv = 'FV' . (10 + ++$st{n});
            $st{flexvols}->{$fv} = $b->{name};
            $st{luns}->{"L$fv"} = { uuid => "L$fv", name => "/vol/$b->{name}/lun0", serial_number => '80BbZ+LnJ9dB',
                enabled => JSON::PP::false, space => { size => 10 * $GIB }, location => { volume => { name => $b->{name}, uuid => $fv } } };
            (202, {}) } ],
        [ PATCH => qr{^/api/storage/volumes/([^/]+)$}, sub { $st{restored} = [ $_[0]->[0], $_[2]->{'restore_to.snapshot.name'} ]; (200, {}) } ],
    ]);

    ok($drv->supports_snapshots, 'ONTAP: snapshots offered');
    ok(!$drv->supports_group_snapshots, 'ONTAP: no multi-volume snapshots yet');
    eval { $drv->snapshot_create([ 'L1', 'L2' ], 'cg') };
    like($@, qr/consistent snapshot of several volumes is not supported yet/, 'ONTAP: several volumes refused');

    is_deeply($drv->snapshots([ 'L1' ]), [], 'ONTAP: its own scheduled snapshots are not listed');
    my $s = $drv->snapshot_create([ 'L1' ], 'before-upgrade');
    my $mk = FakeArray::find_call($calls, 'POST', qr{/snapshots});
    like($mk->{url}, qr{^/api/storage/volumes/FV1/snapshots\?return_timeout=120$}, 'ONTAP: snapshot of the LUN\'s FlexVol');
    is_deeply($mk->{body}, { name => 'before-upgrade', svm => { name => 'svm1' } }, 'ONTAP: snapshot body');
    is_deeply([ map { [ $_->{id}, $_->{name}, $_->{volume}, $_->{size} ] } @$s ],
        [ [ 'FV1/S1', 'before-upgrade', 'L1', 10 * $GIB ] ], 'ONTAP: snapshot record');
    is($s->[0]->{created}, PVE::SAN::Array::ONTAP::iso_epoch('2026-10-29T08:01:00Z'), 'ONTAP: create_time offset applied');
    is(PVE::SAN::Array::ONTAP::iso_epoch('2026-10-29T08:01:00.123Z'), PVE::SAN::Array::ONTAP::iso_epoch('2026-10-29T08:01:00Z'),
        'ONTAP: fractional seconds ignored');
    ok(!defined(PVE::SAN::Array::ONTAP::iso_epoch('yesterday')), 'ONTAP: bad time is undef');

    eval { $drv->snapshot_create([ 'L1' ], 'before-upgrade') };
    like($@, qr/Snapshot name already exists/, 'ONTAP: array error passed on');

    my $c = $drv->snapshot_clone($s->[0], 'gold_snap_1');
    my $cl = FakeArray::find_call($calls, 'POST', qr{^/api/storage/volumes\?});
    is_deeply($cl->{body}, { name => 'gold_snap_1', 'clone.parent_volume.name' => 'gold',
        'clone.parent_snapshot.name' => 'before-upgrade', 'clone.is_flexclone' => JSON::PP::true, 'svm.name' => 'svm1' },
        'ONTAP: FlexClone of the FlexVol at the snapshot');
    is($c->{name}, '/vol/gold_snap_1/lun0', 'ONTAP: the clone\'s LUN');
    is($c->{wwid}, '3600a0980' . unpack('H*', '80BbZ+LnJ9dB'), 'ONTAP: clone WWID from its own serial');
    ok($st{luns}->{$c->{id}}->{enabled}, 'ONTAP: offline clone LUN brought online');
    eval { $drv->snapshot_clone($s->[0], 'bad-name') };
    like($@, qr/invalid ONTAP volume name/, 'ONTAP: clone name checked');

    my $dup = { %{$st{luns}->{L1}}, uuid => 'LDUP', name => '/vol/same/lun0' }; # serial of the original
    {
        no warnings 'redefine';
        my $orig = \&PVE::SAN::Array::ONTAP::records;
        local *PVE::SAN::Array::ONTAP::records = sub {
            my ($self, $path, $q) = @_;
            return [ $dup ] if $path eq '/storage/luns' && ($q->{name} // '') eq '/vol/same/lun0';
            return $orig->(@_);
        };
        eval { $drv->snapshot_clone($s->[0], 'same') };
        like($@, qr/kept the serial number/, 'ONTAP: a clone with the same serial is refused');
    }

    $drv->snapshot_restore('L1', $s->[0]);
    is_deeply($st{restored}, [ 'FV1', 'before-upgrade' ], 'ONTAP: FlexVol restored to the snapshot');

    $drv->snapshot_delete($s->[0]);
    ok(FakeArray::find_call($calls, 'DELETE', qr{^/api/storage/volumes/FV1/snapshots/S1\?}), 'ONTAP: snapshot deleted');
    is_deeply($drv->snapshots([ 'L1' ]), [], 'ONTAP: gone from the list');

    $st{luns}->{L9} = { uuid => 'L9', name => '/vol/shared/lunA', serial_number => '80BbZ+LnJ9dC',
        space => { size => $GIB }, location => { volume => { name => 'shared', uuid => 'FV9' } } };
    eval { $drv->snapshot_create([ 'L9' ], 'x') };
    like($@, qr/not in a FlexVol of its own/, 'ONTAP: LUN outside pvesan\'s layout refused');
}

# ---------------- IBM Spectrum Virtualize ----------------
{
    my %st = (
        vdisks => { 5 => { id => '5', name => 'gold', mdisk_grp_name => 'Pool0', capacity => 10 * $GIB, vdisk_UID => '600507680C8101234800000000000005' },
                    6 => { id => '6', name => 'gold-01', mdisk_grp_name => 'Pool0', capacity => 20 * $GIB, vdisk_UID => '600507680C8101234800000000000006' } },
        maps => {}, groups => {}, next_vd => 100, next_map => 0, log => [],
    );
    my $transport = sub {
        my ($path, $headers, $body) = @_;
        return (200, '{"token":"t"}') if $path eq '/auth';
        my ($cmd, $obj) = $path =~ m|^/([^/]+)(?:/(.+))?$|;
        push @{$st{log}}, $cmd . (defined($obj) ? " $obj" : '') . ($body && %$body ? ' ' . $json->encode($body) : '');
        my $r;
        if ($cmd eq 'lsvdisk') {
            my $v = $st{vdisks}->{$obj} // (grep { $_->{name} eq $obj } values %{$st{vdisks}})[0];
            return (500, 'CMMVC5753E The object does not exist') if !$v;
            $r = $v;
        } elsif ($cmd eq 'mkvolume') {
            my $id = $st{next_vd}++;
            $st{vdisks}->{$id} = { id => "$id", name => $body->{name}, mdisk_grp_name => $body->{pool},
                capacity => $body->{size} + 0, vdisk_UID => sprintf('600507680C81012348%014X', $id), thin => $body->{thin} };
            $r = { id => "$id", message => "Volume, id [$id], successfully created" };
        } elsif ($cmd eq 'mkfcmap') {
            my $id = $st{next_map}++;
            my $src = $st{vdisks}->{$body->{source}} // die;
            my $tgt = $st{vdisks}->{$body->{target}} // die;
            $st{maps}->{$id} = { id => "$id", source_vdisk_id => $src->{id}, source_vdisk_name => $src->{name},
                target_vdisk_id => $tgt->{id}, target_vdisk_name => $tgt->{name}, copy_rate => $body->{copyrate},
                group_name => $body->{consistgrp} // '', status => 'idle_or_copied', autodelete => $body->{autodelete} ? 1 : 0 };
            $r = { id => "$id", message => "FlashCopy Mapping, id [$id], successfully created" };
        } elsif ($cmd eq 'prestartfcmap') {
            $st{maps}->{$obj}->{status} = 'prepared';
            $st{maps}->{$obj}->{restore} = 1 if $body->{restore};
        } elsif ($cmd eq 'startfcmap') {
            $st{maps}->{$obj}->{status} = 'copying';
            $st{maps}->{$obj}->{start_time} = '261029093000';
        } elsif ($cmd eq 'lsfcmap') {
            my ($want) = ($body->{filtervalue} // '') =~ /^id=(\d+)$/;
            $r = [ map { $st{maps}->{$_} } grep { !defined($want) || $_ eq $want } sort keys %{$st{maps}} ];
        } elsif ($cmd eq 'mkfcconsistgrp') {
            $st{groups}->{$body->{name}} = 'empty';
            $r = { id => '1', message => 'FlashCopy Consistency Group, id [1], successfully created' };
        } elsif ($cmd eq 'prestartfcconsistgrp') {
            $st{groups}->{$obj} = 'prepared';
        } elsif ($cmd eq 'lsfcconsistgrp') {
            $r = { name => $obj, status => $st{groups}->{$obj} };
        } elsif ($cmd eq 'startfcconsistgrp') {
            $st{groups}->{$obj} = 'copying';
            $_->{start_time} = '261029100000' for grep { $_->{group_name} eq $obj } values %{$st{maps}};
        } elsif ($cmd eq 'stopfcmap') {
            $st{maps}->{$obj}->{status} = 'stopped';
        } elsif ($cmd eq 'rmfcmap') {
            delete $st{maps}->{$obj};
        } elsif ($cmd eq 'rmvolume') {
            return (500, 'CMMVC8957E in a FlashCopy mapping') if grep { $_->{target_vdisk_id} eq $obj } values %{$st{maps}};
            delete $st{vdisks}->{$obj};
        } elsif ($cmd eq 'rmfcconsistgrp') {
            delete $st{groups}->{$obj};
        } else {
            return (500, "CMMVC5709E unknown command $cmd");
        }
        return (200, defined($r) ? $json->encode($r) : '');
    };
    my $drv = PVE::SAN::Array::IBMSV->new(address => 'fs', username => 'u', password => 'p', transport => $transport);

    ok($drv->supports_snapshots && $drv->supports_group_snapshots, 'IBM: snapshots and group snapshots');
    my $s = $drv->snapshot_create([ '5' ], 'before-upgrade');
    my $tgt = $st{vdisks}->{100};
    is($tgt->{name}, 'pvs_5_before-upgrade', 'IBM: snapshot target volume named after source and snapshot');
    is($tgt->{capacity}, 10 * $GIB, 'IBM: target the size of the source');
    ok($tgt->{thin}, 'IBM: target thin');
    is($st{maps}->{0}->{copy_rate}, '0', 'IBM: no background copy (a snapshot)');
    ok(!$st{maps}->{0}->{autodelete}, 'IBM: snapshot mapping is kept');
    ok((grep { $_ eq 'prestartfcmap 0' } @{$st{log}}) && (grep { $_ eq 'startfcmap 0' } @{$st{log}}), 'IBM: mapping prepared and started');
    is_deeply([ map { [ $_->{id}, $_->{name}, $_->{volume}, $_->{size} ] } @$s ],
        [ [ '100', 'before-upgrade', '5', 10 * $GIB ] ], 'IBM: snapshot record');
    is($s->[0]->{created}, PVE::SAN::Array::IBMSV::fc_time('261029093000'), 'IBM: start time');
    ok(defined(PVE::SAN::Array::IBMSV::fc_time('261029093000')), 'IBM: start time parsed');

    # two volumes: one consistency group
    $st{log} = [];
    my $g = $drv->snapshot_create([ '5', '6' ], 'cg1');
    is(scalar(@$g), 2, 'IBM: one snapshot per volume');
    is_deeply([ map { $_->{group} } @$g ], [ 'pvs_cg1_5', 'pvs_cg1_5' ], 'IBM: both in one consistency group');
    ok((grep { /^mkfcconsistgrp .*"name":"pvs_cg1_5"/ } @{$st{log}}), 'IBM: consistency group created');
    ok((grep { $_ eq 'startfcconsistgrp pvs_cg1_5' } @{$st{log}}), 'IBM: group started at one point in time');
    ok(!(grep { /^startfcmap/ } @{$st{log}}), 'IBM: mappings not started one by one');
    is($st{vdisks}->{102}->{capacity}, 20 * $GIB, 'IBM: each target sized like its source');

    is_deeply([ map { "$_->{name}:$_->{volume}" } @{$drv->snapshots([ '5', '6' ])} ],
        [ 'before-upgrade:5', 'cg1:5', 'cg1:6' ], 'IBM: snapshots listed');

    # failed creation cleans up
    {
        my $before = scalar(keys %{$st{vdisks}});
        no warnings 'redefine';
        local *PVE::SAN::Array::IBMSV::run_fc = sub { die "prepare failed\n" };
        eval { $drv->snapshot_create([ '5' ], 'broken') };
        like($@, qr/prepare failed/, 'IBM: error passed on');
        is(scalar(keys %{$st{vdisks}}), $before, 'IBM: target volume removed again');
        ok(!(grep { $_->{target_vdisk_name} eq 'pvs_5_broken' } values %{$st{maps}}), 'IBM: mapping removed again');
    }

    # copy of a snapshot
    my $c = $drv->snapshot_clone($s->[0], 'gold-snap-1');
    my ($cm) = grep { $_->{target_vdisk_name} eq 'gold-snap-1' } values %{$st{maps}};
    is($cm->{source_vdisk_id}, '100', 'IBM: copy fed from the snapshot volume');
    is($cm->{copy_rate}, '50', 'IBM: copy runs in the background');
    ok($cm->{autodelete}, 'IBM: copy mapping deletes itself when done');
    like($c->{wwid}, qr/^3600507680c8101234/, 'IBM: copy is a normal volume');
    is_deeply([ map { $_->{name} } @{$drv->snapshots([ '5' ])} ], [ 'before-upgrade', 'cg1' ], 'IBM: copy is not a snapshot');

    # restore
    $drv->snapshot_restore('5', $s->[0]);
    my ($rm) = grep { $_->{target_vdisk_id} eq '5' } values %{$st{maps}};
    is($rm->{source_vdisk_id}, '100', 'IBM: restore mapping from the snapshot onto the volume');
    ok($rm->{restore}, 'IBM: prepared with -restore');
    ok((grep { /^startfcmap $rm->{id} .*restore/ } @{$st{log}}), 'IBM: started with -restore');
    eval { $drv->snapshot_restore('6', $s->[0]) };
    like($@, qr/differ in size/, 'IBM: restore onto a volume of another size refused');
    delete $st{maps}->{$rm->{id}}; delete $st{maps}->{$cm->{id}};

    # delete
    $drv->snapshot_delete($g->[0]);
    ok(!$st{groups}->{pvs_cg1_5}, 'IBM: consistency group removed');
    ok(!$st{vdisks}->{101} && !$st{vdisks}->{102}, 'IBM: both group targets removed');
    $drv->snapshot_delete($s->[0]);
    ok(!$st{vdisks}->{100}, 'IBM: snapshot target removed');
    is_deeply($drv->snapshots([ '5', '6' ]), [], 'IBM: no snapshots left');
}

done_testing();
