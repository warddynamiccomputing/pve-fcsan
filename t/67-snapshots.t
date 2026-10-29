use strict;
use warnings;

use Test::More;
use JSON::PP;

use FakeArray;
use PVE::SAN::Array::Pure;
use PVE::SAN::Array::Infinidat;
use PVE::SAN::Array::PowerStore;
use PVE::SAN::Array::IBMSV;
use PVE::SAN::Array::PowerMax;
use PVE::SAN::Array::ONTAP;
use PVE::SAN::Array::ESeries;
use PVE::SAN::Array::Hitachi;
use PVE::SAN::Array::Eternus;

my $GIB = 1024 ** 3;

# --- shared name rules ---
my $B = 'PVE::SAN::Array::Base';
ok($B->valid_snapshot_name('pvesan-20261029-0800'), 'timestamped name ok');
ok($B->valid_snapshot_name('before-upgrade'), 'manual name ok');
ok(!$B->valid_snapshot_name('1st'), 'must start with a letter');
ok(!$B->valid_snapshot_name('a_b'), 'no underscore (Pure suffix rules)');
ok(!$B->valid_snapshot_name('a.b'), 'no dot (separates volume and snapshot)');
ok(!$B->valid_snapshot_name('end-'), 'no trailing dash');
ok(!$B->valid_snapshot_name('x' x 41), 'at most 40 characters');

# --- drivers without snapshots say so clearly ---
for my $class (qw(PowerMax ESeries Hitachi Eternus)) {
    my $c = "PVE::SAN::Array::$class";
    ok(!$c->supports_snapshots, "$class: snapshots not offered");
    my $drv = bless { address => 'x' }, $c;
    eval { $drv->snapshot_create(['1'], 'snap1') };
    like($@, qr/array snapshots is not supported yet by the pvesan driver/, "$class: clear error");
}

# ---------------- Pure FlashArray ----------------
{
    my %st = (vols => { 'ds-a' => 'A', 'ds-b' => 'B' }, snaps => [], pgroups => {}, pgmembers => {}, created => 1_700_000_000_000);
    my $snap = sub {
        my ($name, $src) = @_;
        push @{$st{snaps}}, { name => $name, source => { name => $src }, created => $st{created} += 60_000,
            provisioned => 10 * $GIB, destroyed => JSON::PP::false };
        return $st{snaps}->[-1];
    };
    my $items = sub { (200, { items => $_[0] }) };
    my ($drv, $calls) = FakeArray::driver('PVE::SAN::Array::Pure', {}, [
        [ GET => qr{^/api/api_version$}, sub { (200, { version => ['2.10'] }) } ],
        [ POST => qr{^/api/2\.10/login$}, sub { (200, { items => [] }, { 'x-auth-token' => 'S' }) } ],
        [ POST => qr{^/api/2\.10/volume-snapshots$}, sub {
            my ($c, $q, $b) = @_;
            return (400, { errors => [ { message => 'Snapshot already exists.' } ] })
                if grep { $_->{name} eq "$q->{source_names}.$b->{suffix}" } @{$st{snaps}};
            $items->([ { %{$snap->("$q->{source_names}.$b->{suffix}", $q->{source_names})}, suffix => $b->{suffix} } ]) } ],
        [ GET => qr{^/api/2\.10/volume-snapshots$}, sub {
            my %src = map { $_ => 1 } split(/,/, $_[1]->{source_names});
            $items->([ grep { $src{$_->{source}->{name}} && !$_->{destroyed} } @{$st{snaps}} ]) } ],
        [ PATCH => qr{^/api/2\.10/volume-snapshots$}, sub {
            $_->{destroyed} = JSON::PP::true for grep { $_->{name} eq $_[1]->{names} } @{$st{snaps}};
            $items->([]) } ],
        [ GET => qr{^/api/2\.10/protection-groups$}, sub { $items->([ map { { name => $_ } } sort keys %{$st{pgroups}} ]) } ],
        [ POST => qr{^/api/2\.10/protection-groups$}, sub { $st{pgroups}->{$_[1]->{names}} = 1; $items->([]) } ],
        [ GET => qr{^/api/2\.10/protection-groups/volumes$}, sub {
            my $g = $_[1]->{group_names};
            $items->([ map { { group => { name => $g }, member => { name => $_ } } } sort keys %{$st{pgmembers}->{$g} // {}} ]) } ],
        [ POST => qr{^/api/2\.10/protection-groups/volumes$}, sub {
            $st{pgmembers}->{$_[1]->{group_names}}->{$_} = 1 for split(/,/, $_[1]->{member_names});
            $items->([]) } ],
        [ POST => qr{^/api/2\.10/protection-group-snapshots$}, sub {
            my ($c, $q, $b) = @_;
            $snap->("$q->{source_names}.$b->{suffix}.$_", $_) for sort keys %{$st{pgmembers}->{$q->{source_names}}};
            $items->([ { name => "$q->{source_names}.$b->{suffix}" } ]) } ],
        [ PATCH => qr{^/api/2\.10/protection-group-snapshots$}, sub {
            my $g = $_[1]->{names};
            $_->{destroyed} = JSON::PP::true for grep { $_->{name} =~ /^\Q$g\E\./ } @{$st{snaps}};
            $items->([]) } ],
        [ POST => qr{^/api/2\.10/volumes$}, sub {
            my ($c, $q, $b) = @_;
            return (400, { errors => [ { message => 'Volume already exists.' } ] })
                if $st{vols}->{$q->{names}} && ($q->{overwrite} // '') ne 'true';
            $st{vols}->{$q->{names}} = "copy of $b->{source}->{name}";
            $items->([ { name => $q->{names}, serial => 'A1B2C3D4E5F6A7B800000042', provisioned => 10 * $GIB } ]) } ],
    ]);

    ok($drv->supports_snapshots && $drv->supports_group_snapshots, 'Pure: snapshots and group snapshots');
    my $s = $drv->snapshot_create(['ds-a'], 'snap1');
    my $mk = FakeArray::find_call($calls, 'POST', qr{/volume-snapshots});
    is($mk->{url}, '/api/2.10/volume-snapshots?source_names=ds-a', 'Pure: snapshot of the volume');
    is_deeply($mk->{body}, { suffix => 'snap1' }, 'Pure: pvesan name is the suffix');
    is_deeply([ map { [ $_->{id}, $_->{name}, $_->{volume} ] } @$s ], [ [ 'ds-a.snap1', 'snap1', 'ds-a' ] ], 'Pure: snapshot record');
    is($s->[0]->{created}, 1_700_000_060, 'Pure: created in seconds');

    eval { $drv->snapshot_create(['ds-a'], 'snap1') };
    like($@, qr/Snapshot already exists/, 'Pure: array error passed on');
    eval { $drv->snapshot_create(['ds-a'], 'bad_name') };
    like($@, qr/invalid snapshot name/, 'Pure: name checked before any call');

    # two volumes: protection group snapshot
    my $g = $drv->snapshot_create(['ds-a', 'ds-b'], 'cg1');
    ok($st{pgroups}->{'pvesan-ds-a'}, 'Pure: protection group created');
    is_deeply([ sort keys %{$st{pgmembers}->{'pvesan-ds-a'}} ], [ 'ds-a', 'ds-b' ], 'Pure: both volumes are members');
    is(scalar(@$g), 2, 'Pure: one snapshot per volume');
    is_deeply([ map { $_->{group} } @$g ], [ 'pvesan-ds-a.cg1', 'pvesan-ds-a.cg1' ], 'Pure: members know their group');
    is($g->[0]->{name}, 'cg1', 'Pure: group member name is the suffix');

    my $before = scalar(grep { $_->{method} eq 'POST' && $_->{url} =~ m{/protection-groups(?:/volumes)?\?} } @$calls);
    $drv->snapshot_create(['ds-a', 'ds-b'], 'cg2');
    is(scalar(grep { $_->{method} eq 'POST' && $_->{url} =~ m{/protection-groups(?:/volumes)?\?} } @$calls), $before,
        'Pure: existing group and members reused');

    my $list = $drv->snapshots(['ds-a', 'ds-b']);
    is_deeply([ map { $_->{name} } @$list ], [ qw(snap1 cg1 cg1 cg2 cg2) ], 'Pure: list sorted by time');
    my $lc = $calls->[-1];
    like($lc->{url}, qr/destroyed=false/, 'Pure: destroyed snapshots not listed');
    like($lc->{url}, qr/source_names=ds-a%2Cds-b/, 'Pure: all volumes in one query');

    $drv->snapshot_delete($g->[0]);
    my $del = $calls->[-1];
    is($del->{url}, '/api/2.10/protection-group-snapshots?names=pvesan-ds-a.cg1', 'Pure: group member deletes the group snapshot');
    is_deeply($del->{body}, { destroyed => JSON::PP::true }, 'Pure: destroy (recoverable)');
    $drv->snapshot_delete($s->[0]);
    is($calls->[-1]->{url}, '/api/2.10/volume-snapshots?names=ds-a.snap1', 'Pure: volume snapshot destroyed');
    is_deeply([ map { $_->{name} } @{$drv->snapshots(['ds-a', 'ds-b'])} ], [ qw(cg2 cg2) ], 'Pure: gone from list');

    my $v = $drv->snapshot_clone({ id => 'pvesan-ds-a.cg2.ds-a' }, 'ds-a-snap-1');
    my $cl = $calls->[-1];
    is($cl->{url}, '/api/2.10/volumes?names=ds-a-snap-1', 'Pure: clone is a new volume');
    is_deeply($cl->{body}, { source => { name => 'pvesan-ds-a.cg2.ds-a' } }, 'Pure: copied from the snapshot');
    is($v->{wwid}, '3624a9370a1b2c3d4e5f6a7b800000042', 'Pure: clone WWID');
    eval { $drv->snapshot_clone({ id => 'x.y' }, 'bad_name') };
    like($@, qr/invalid FlashArray volume name/, 'Pure: clone name checked');

    $drv->snapshot_restore('ds-a', { id => 'ds-a.snap1' });
    is($calls->[-1]->{url}, '/api/2.10/volumes?names=ds-a&overwrite=true', 'Pure: restore = copy with overwrite');
    is($st{vols}->{'ds-a'}, 'copy of ds-a.snap1', 'Pure: volume overwritten');
}

# ---------------- InfiniBox ----------------
{
    my %st = (vols => { 10 => { id => 10, name => 'ds_a', size => 10 * $GIB, type => 'MASTER', serial => '742b0f000000000000000000000a1' },
                        11 => { id => 11, name => 'ds_b', size => 10 * $GIB, type => 'MASTER', serial => '742b0f000000000000000000000a2' } },
              next => 100, t => 1_700_000_000_000, restored => []);
    my $res = sub { (200, { result => $_[0], error => undef, metadata => { ready => JSON::PP::true, pages_total => 1 } }) };
    my $add = sub {
        my (%v) = @_;
        my $id = $st{next}++;
        $st{vols}->{$id} = { id => $id, size => 10 * $GIB, created_at => $st{t} += 1000,
            serial => sprintf('742b0f%025x', $id), %v };
        return $st{vols}->{$id};
    };
    my ($drv, $calls) = FakeArray::driver('PVE::SAN::Array::Infinidat', {}, [
        [ GET => qr{^/api/rest/volumes/(\d+)$}, sub { $st{vols}->{$_[0]->[0]} ? $res->($st{vols}->{$_[0]->[0]}) : (404, {}) } ],
        [ GET => qr{^/api/rest/volumes$}, sub {
            my ($pid) = ($_[1]->{parent_id} // '') =~ /^eq:(\d+)$/;
            $res->([ grep { defined($pid) && ($_->{parent_id} // -1) == $pid } map { $st{vols}->{$_} } sort keys %{$st{vols}} ]) } ],
        [ POST => qr{^/api/rest/volumes$}, sub {
            my $b = $_[2];
            my $p = $st{vols}->{$b->{parent_id}};
            $res->($add->(name => $b->{name}, parent_id => $b->{parent_id},
                type => $p->{type} eq 'MASTER' ? 'SNAPSHOT' : 'SNAPSHOT', write_protected => $b->{write_protected})) } ],
        [ POST => qr{^/api/rest/volumes/group_snapshot$}, sub {
            my $b = $_[2];
            $res->([ map { $add->(name => $st{vols}->{$_->{id}}->{name} . $b->{snap_suffix}, parent_id => $_->{id}, type => 'SNAPSHOT') }
                @{$b->{entities}} ]) } ],
        [ DELETE => qr{^/api/rest/volumes/(\d+)$}, sub { $res->(delete $st{vols}->{$_[0]->[0]}) } ],
        [ POST => qr{^/api/rest/volumes/(\d+)/restore$}, sub { push @{$st{restored}}, [ $_[0]->[0], $_[2] ]; $res->(undef) } ],
    ]);

    my $s = $drv->snapshot_create([10], 'snap1');
    my $mk = FakeArray::find_call($calls, 'POST', qr{/api/rest/volumes\?});
    like($mk->{url}, qr/approved=true/, 'InfiniBox: snapshot request approved');
    is_deeply($mk->{body}, { name => 'ds_a.snap1', parent_id => 10, write_protected => JSON::PP::true },
        'InfiniBox: snapshot = write-protected child volume');
    is_deeply([ @{$s->[0]}{qw(name volume)} ], [ 'snap1', 10 ], 'InfiniBox: snapshot record');
    is($s->[0]->{created}, 1_700_000_001, 'InfiniBox: created in seconds');

    my $g = $drv->snapshot_create([10, 11], 'cg1');
    my $gs = FakeArray::find_call($calls, 'POST', qr{/group_snapshot});
    is_deeply($gs->{body}, { snap_suffix => '.cg1', entities => [ { id => 10 }, { id => 11 } ] }, 'InfiniBox: group snapshot body');
    is_deeply([ sort map { $_->{volume} } @$g ], [ 10, 11 ], 'InfiniBox: one per volume');
    is_deeply([ map { $_->{name} } @$g ], [ 'cg1', 'cg1' ], 'InfiniBox: names without volume prefix');

    my $list = $drv->snapshots([10, 11]);
    is_deeply([ map { $_->{name} } @$list ], [ qw(snap1 cg1 cg1) ], 'InfiniBox: children listed in time order');
    like(FakeArray::find_call($calls, 'GET', qr{/api/rest/volumes\?.*parent_id})->{url}, qr/parent_id=eq%3A10/,
        'InfiniBox: parent_id filter');

    my $c = $drv->snapshot_clone($s->[0], 'ds_a_copy');
    is_deeply($calls->[-1]->{body}, { name => 'ds_a_copy', parent_id => $s->[0]->{id}, write_protected => JSON::PP::false },
        'InfiniBox: clone = writable child of the snapshot');
    ok($c->{wwid} =~ /^36742b0f/, 'InfiniBox: clone WWID');
    is_deeply([ map { $_->{name} } @{$drv->snapshots([10])} ], [ qw(snap1 cg1) ], 'InfiniBox: clone is not a snapshot of the volume');

    $drv->snapshot_restore(10, $s->[0]);
    is_deeply($st{restored}, [ [ 10, $s->[0]->{id} ] ], 'InfiniBox: restore posts the snapshot id');

    $drv->snapshot_delete($g->[0]);
    is($calls->[-1]->{method}, 'DELETE', 'InfiniBox: delete');
    is(scalar(@{$drv->snapshots([10, 11])}), 2, 'InfiniBox: one member gone');
}

# ---------------- PowerStore ----------------
{
    my %st = (vols => { v1 => { id => 'v1', name => 'ds-a', size => 10 * $GIB, wwn => 'naa.68ccf09800aabbccddeeff0011223344', type => 'Primary' },
                        v2 => { id => 'v2', name => 'ds-a-01', size => 10 * $GIB, wwn => 'naa.68ccf09800aabbccddeeff0011223355', type => 'Primary' } },
              n => 0, restored => []);
    $st{vgs} = {};
    my ($drv, $calls) = FakeArray::driver('PVE::SAN::Array::PowerStore', {}, [
        [ GET => qr{^/api/rest/login_session$}, sub { (200, [ {} ], { 'dell-emc-token' => 'TOK' }) } ],
        [ GET => qr{^/api/rest/volume/([\w-]+)$}, sub { $st{vols}->{$_[0]->[0]} ? (200, $st{vols}->{$_[0]->[0]}) : (404, {}) } ],
        [ GET => qr{^/api/rest/volume$}, sub {
            my ($src) = ($_[1]->{'protection_data->>source_id'} // '') =~ /^eq\.(.+)$/;
            (200, [ grep { ($_->{type} // '') eq 'Snapshot' && ($_->{protection_data}->{source_id} // '') eq ($src // '') }
                map { $st{vols}->{$_} } sort keys %{$st{vols}} ]) } ],
        [ POST => qr{^/api/rest/volume/([\w-]+)/snapshot$}, sub {
            my $id = 's' . ++$st{n};
            $st{vols}->{$id} = { id => $id, name => $_[2]->{name}, size => 10 * $GIB, type => 'Snapshot',
                creation_timestamp => "2026-10-29T08:0$st{n}:00.000+00:00", protection_data => { source_id => $_[0]->[0] } };
            (201, { id => $id }) } ],
        [ POST => qr{^/api/rest/volume/([\w-]+)/clone$}, sub {
            $st{vols}->{c1} = { id => 'c1', name => $_[2]->{name}, size => 10 * $GIB, wwn => 'naa.68ccf09800aabbccddeeff0011223399', type => 'Clone' };
            (201, { id => 'c1' }) } ],
        [ POST => qr{^/api/rest/volume/([\w-]+)/restore$}, sub { push @{$st{restored}}, [ $_[0]->[0], $_[2] ]; (200, {}) } ],
        [ DELETE => qr{^/api/rest/volume/([\w-]+)$}, sub { delete $st{vols}->{$_[0]->[0]}; (204, '') } ],
        [ GET => qr{^/api/rest/volume_group$}, sub {
            my ($n) = ($_[1]->{name} // '') =~ /^eq\.(.+)$/;
            my ($src) = ($_[1]->{'protection_data->>source_id'} // '') =~ /^eq\.(.+)$/;
            (200, [ grep { defined($n) ? $_->{name} eq $n && !$_->{source} : ($_->{source} // '') eq ($src // '-') }
                map { $st{vgs}->{$_} } sort keys %{$st{vgs}} ]) } ],
        [ POST => qr{^/api/rest/volume_group$}, sub {
            $st{vgs}->{g1} = { id => 'g1', name => $_[2]->{name}, volumes => [ map { { id => $_ } } @{$_[2]->{volume_ids}} ],
                wo => $_[2]->{is_write_order_consistent} };
            (201, { id => 'g1' }) } ],
        [ POST => qr{^/api/rest/volume_group/(\w+)/add_members$}, sub {
            push @{$st{vgs}->{$_[0]->[0]}->{volumes}}, map { { id => $_ } } @{$_[2]->{volume_ids}}; (204, '') } ],
        [ POST => qr{^/api/rest/volume_group/(\w+)/snapshot$}, sub {
            my $g = $st{vgs}->{$_[0]->[0]};
            my $set = 'set' . ++$st{n};
            my @m;
            for my $v (@{$g->{volumes}}) {
                my $id = "$set-$v->{id}";
                $st{vols}->{$id} = { id => $id, name => "auto name $id", size => 10 * $GIB, type => 'Snapshot',
                    creation_timestamp => '2026-10-29T09:00:00Z', protection_data => { source_id => $v->{id} } };
                push @m, { id => $id, name => "auto name $id" };
            }
            $st{vgs}->{$set} = { id => $set, name => $_[2]->{name}, source => $g->{id}, volumes => \@m };
            (201, { id => $set }) } ],
        [ DELETE => qr{^/api/rest/volume_group/(\w+)$}, sub {
            my $set = delete $st{vgs}->{$_[0]->[0]};
            delete $st{vols}->{$_->{id}} for @{$set->{volumes}};
            (204, '') } ],
        [ POST => qr{^/api/rest/volume_group/(\w+)/restore$}, sub { push @{$st{vg_restored}}, [ $_[0]->[0], $_[2] ]; (200, {}) } ],
    ]);

    ok($drv->supports_snapshots && $drv->supports_group_snapshots, 'PowerStore: snapshots, also of several volumes');
    my $s = $drv->snapshot_create(['v1'], 'snap1');
    is_deeply(FakeArray::find_call($calls, 'POST', qr{/snapshot$})->{body}, { name => 'ds-a.snap1' }, 'PowerStore: snapshot named after the volume');
    is_deeply([ @{$s->[0]}{qw(id name volume)} ], [ 's1', 'snap1', 'v1' ], 'PowerStore: snapshot record');
    is($s->[0]->{created}, 1793260860, 'PowerStore: ISO timestamp to epoch');
    is(PVE::SAN::Array::PowerStore::parse_timestamp('2026-10-29T10:01:00+02:00'), 1793260860, 'PowerStore: time zone offset');
    is(PVE::SAN::Array::PowerStore::parse_timestamp('garbage'), undef, 'PowerStore: bad timestamp');

    $drv->snapshot_create(['v1'], 'snap2');
    my $list = $drv->snapshots(['v1']);
    is_deeply([ map { $_->{name} } @$list ], [ qw(snap1 snap2) ], 'PowerStore: snapshots listed');
    my $q = FakeArray::find_call($calls, 'GET', qr{/api/rest/volume\?});
    like($q->{url}, qr/protection_data-%3E%3Esource_id=eq\.v1/, 'PowerStore: filtered by source');
    like($q->{url}, qr/type=eq\.Snapshot/, 'PowerStore: snapshots only');


    my $c = $drv->snapshot_clone($s->[0], 'ds-a-copy');
    is_deeply($calls->[-2]->{body}, { name => 'ds-a-copy' }, 'PowerStore: clone POST');
    like($calls->[-2]->{url}, qr{/volume/s1/clone$}, 'PowerStore: cloned from the snapshot');
    is($c->{wwid}, '368ccf09800aabbccddeeff0011223399', 'PowerStore: clone WWID');

    $drv->snapshot_restore('v1', $s->[0]);
    is_deeply($st{restored}, [ [ 'v1', { from_snap_id => 's1', create_backup_snap => JSON::PP::true } ] ],
        'PowerStore: restore keeps a backup snapshot');

    $drv->snapshot_delete($s->[0]);
    is_deeply([ map { $_->{name} } @{$drv->snapshots(['v1'])} ], [ 'snap2' ], 'PowerStore: deleted');

    # several volumes: a write-order consistent volume group, snapshotted as a whole
    my $g = $drv->snapshot_create(['v1', 'v2'], 'cg1');
    is($st{vgs}->{g1}->{name}, 'pvesan-ds-a', 'PowerStore: volume group named after the first volume');
    ok($st{vgs}->{g1}->{wo}, 'PowerStore: write-order consistent');
    is_deeply([ sort map { $_->{volume} } @$g ], [ 'v1', 'v2' ], 'PowerStore: one member per volume');
    is_deeply([ map { $_->{name} } @$g ], [ 'cg1', 'cg1' ], 'PowerStore: members carry the set name');
    is_deeply([ map { $_->{group} } @$g ], [ 'set3', 'set3' ], 'PowerStore: members know their set');
    my $n_posts = scalar(grep { $_->{method} eq 'POST' && $_->{url} =~ m{/volume_group(?:/g1/add_members)?$} } @$calls);
    $drv->snapshot_create(['v1', 'v2'], 'cg2');
    is(scalar(grep { $_->{method} eq 'POST' && $_->{url} =~ m{/volume_group(?:/g1/add_members)?$} } @$calls), $n_posts,
        'PowerStore: existing group reused');
    is_deeply([ map { $_->{name} } grep { $_->{group} } @{$drv->snapshots(['v1', 'v2'])} ], [ qw(cg1 cg1 cg2 cg2) ],
        'PowerStore: sets listed by their name');
    is(scalar(grep { $_->{name} =~ /^auto name/ } @{$drv->snapshots(['v1', 'v2'])}), 0, 'PowerStore: members not listed twice');

    $drv->snapshot_restore('v1', $g->[0]);
    $drv->snapshot_restore('v2', $g->[1]);
    is_deeply($st{vg_restored}, [ [ 'g1', { from_snap_id => 'set3', create_backup_snap => JSON::PP::true } ] ],
        'PowerStore: the group restored once from the set');

    $drv->snapshot_delete($g->[0]);
    is_deeply([ map { $_->{name} } grep { $_->{group} } @{$drv->snapshots(['v1', 'v2'])} ], [ qw(cg2 cg2) ], 'PowerStore: set deleted as a whole');
}

done_testing();
