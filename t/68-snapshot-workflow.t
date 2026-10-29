use strict;
use warnings;

use Test::More;

use StubPVE;
use PVE::SAN::Snapshot;
use PVE::SAN::Array::Base;
use PVE::SAN::Provision;
use PVE::SAN::Datastore;
use PVE::API2::Storage::Config;
use PVE::Storage;

my $S = 'PVE::SAN::Snapshot';

# ---------------- pure helpers ----------------

ok(PVE::SAN::Snapshot::is_auto('auto-20261029-080000'), 'scheduled name recognised');
ok(!PVE::SAN::Snapshot::is_auto('pvesan-20261029-080000'), 'manual name is not automatic');
ok(!PVE::SAN::Snapshot::is_auto('auto-mine'), 'only the timestamp form is automatic');
like(PVE::SAN::Snapshot::default_name('auto', 1793260800), qr/^auto-\d{8}-\d{6}$/, 'default name format');
ok(PVE::SAN::Array::Base->valid_snapshot_name(PVE::SAN::Snapshot::default_name('pvesan')), 'default name is valid on every array');

{
    my $snaps = [
        { id => 'a.s2', name => 's2', volume => 'a', created => 200, size => 5 },
        { id => 'a.s1', name => 's1', volume => 'a', created => 100, size => 5, group => 'pg.s1' },
        { id => 'b.s1', name => 's1', volume => 'b', created => 101, size => 7, group => 'pg.s1' },
    ];
    my $sets = PVE::SAN::Snapshot::group_sets($snaps, ['a', 'b']);
    is_deeply([ map { $_->{name} } @$sets ], [ 's1', 's2' ], 'sets ordered by time');
    is($sets->[0]->{created}, 100, 'set time = earliest member');
    is($sets->[0]->{size}, 12, 'set size = sum');
    is($sets->[0]->{complete}, 1, 'set covering both volumes is complete');
    is($sets->[1]->{complete}, 0, 'set missing a volume is incomplete');
    is(scalar(@{PVE::SAN::Snapshot::delete_targets($sets->[0])}), 1, 'group snapshot deleted once');
    is(scalar(@{PVE::SAN::Snapshot::delete_targets({ members => [ { id => 1 }, { id => 2 } ] })}), 2,
        'independent snapshots deleted one by one');
}

{
    my $sets = [ map { { name => $_, auto => PVE::SAN::Snapshot::is_auto($_) } }
        qw(auto-20261001-000000 manual-1 auto-20261002-000000 auto-20261003-000000 auto-20261004-000000) ];
    is_deeply([ map { $_->{name} } @{PVE::SAN::Snapshot::prune_list($sets, 2, {})} ],
        [ 'auto-20261001-000000', 'auto-20261002-000000' ], 'oldest automatic snapshots beyond keep');
    is_deeply([ map { $_->{name} } @{PVE::SAN::Snapshot::prune_list($sets, 2, { 'auto-20261001-000000' => 'c' })} ],
        [ 'auto-20261002-000000' ], 'mounted snapshot kept');
    is_deeply(PVE::SAN::Snapshot::prune_list($sets, 10, {}), [], 'nothing to prune');
}

{
    my $now = 1_800_000_000;
    my $cfg = { datastores => {
        due => { snapshot_schedule => { interval => 4, keep => 3 }, snapshot_state => { last => $now - 4 * 3600 + 30 } },
        early => { snapshot_schedule => { interval => 4 }, snapshot_state => { last => $now - 3600 } },
        never => { snapshot_schedule => { interval => 1 } },
        claimed => { snapshot_schedule => { interval => 1 }, snapshot_state => { claimed => { node => 'n2', time => $now - 60 } } },
        stale => { snapshot_schedule => { interval => 1 }, snapshot_state => { claimed => { node => 'n2', time => $now - 7 * 3600 } } },
        off => {},
        copy => { copy_of => 'due', snapshot_schedule => { interval => 1 } },
        rec => { auto_reclaim => 1, reclaim_state => { last => $now - 8 * 86400 } },
        rec_new => { auto_reclaim => 1, reclaim_state => { last => $now - 86400 } },
    } };
    is_deeply(PVE::SAN::Snapshot::due_jobs($cfg, 'snapshot', $now), [ qw(due never stale) ],
        'due snapshot jobs (with slack, claims respected, stale claims retried, copies skipped)');
    is_deeply(PVE::SAN::Snapshot::due_jobs($cfg, 'reclaim', $now), [ 'rec' ], 'weekly reclaim due');
}

my $conf = <<'EOF';
boot: order=scsi0;net0
cores: 4
efidisk0: gold:vm-101-disk-1,efitype=4m,size=4M
ide2: local:iso/debian.iso,media=cdrom,size=600M
name: web01
net0: virtio=BC:24:11:AA:BB:CC,bridge=vmbr0,firewall=1
net1: e1000=02:00:00:00:00:01,bridge=vmbr1,link_down=1
onboot: 1
parent: before-upgrade
scsi0: gold:vm-101-disk-0,iothread=1,size=32G
scsi1: other:vm-101-disk-0,size=8G
smbios1: uuid=7b5c6c1e-1111-4222-8333-944455556666
unused0: gold:vm-101-disk-2
vmgenid: 0f0e0d0c-1111-4222-8333-944455556666

[before-upgrade]
scsi0: gold:vm-101-disk-0,size=30G
snaptime: 1700000000
EOF

{
    ok(PVE::SAN::Snapshot::has_snapshots($conf), 'snapshot section found');
    ok(!PVE::SAN::Snapshot::has_snapshots("scsi0: gold:vm-1-disk-0\n"), 'no snapshot section');
    my $main = PVE::SAN::Snapshot::main_section($conf);
    unlike($main, qr/snaptime/, 'main section stops at the first snapshot');
    is_deeply([ map { "$_->{key}=$_->{volname}" } @{PVE::SAN::Snapshot::vm_disks($main, 'gold')} ],
        [ 'efidisk0=vm-101-disk-1', 'scsi0=vm-101-disk-0', 'unused0=vm-101-disk-2' ], 'disks on the datastore, CD-ROM ignored');

    my ($text, $notes) = PVE::SAN::Snapshot::new_vm_config($main, 'gold',
        { 'vm-101-disk-0' => 'gold:vm-202-disk-0', 'vm-101-disk-1' => 'gold:vm-202-disk-1' },
        mac => sub { 'BC:24:11:00:00:01' }, uuid => sub { '00000000-0000-4000-8000-000000000001' });
    like($text, qr/^scsi0: gold:vm-202-disk-0,iothread=1,size=32G$/m, 'disk remapped, options kept');
    like($text, qr/^efidisk0: gold:vm-202-disk-1,efitype=4m,size=4M$/m, 'EFI disk remapped');
    unlike($text, qr/^scsi1:/m, 'disk on another storage left out (it belongs to the original VM)');
    unlike($text, qr/^unused0:/m, 'unrestored unused disk left out');
    like($text, qr/^ide2: local:iso\/debian.iso,media=cdrom/m, 'CD-ROM kept');
    like($text, qr/^net0: virtio=BC:24:11:00:00:01,bridge=vmbr0,firewall=1,link_down=1$/m, 'new MAC, link down');
    like($text, qr/^net1: e1000=BC:24:11:00:00:01,bridge=vmbr1,link_down=1$/m, 'link_down not doubled');
    like($text, qr/^smbios1: uuid=00000000-0000-4000-8000-000000000001$/m, 'new SMBIOS UUID');
    like($text, qr/^vmgenid: 00000000-0000-4000-8000-000000000001$/m, 'new vmgenid');
    like($text, qr/^name: web01-restored$/m, 'name marks the copy');
    unlike($text, qr/^(?:parent|onboot):/m, 'snapshot parent and onboot dropped');
    is(scalar(grep { /left out/ } @$notes), 2, 'notes for disks left out');
    like($text, qr/\n$/, 'ends with a newline');
}

# ---------------- workflow with a fake driver ----------------

package FakeSnapDriver {
    use parent -norequire, 'PVE::SAN::Array::Base';
    sub description { 'Fake array' }
    sub supports_snapshots { 1 }
    sub supports_group_snapshots { 1 }
    sub snapshots { my ($s, $v) = @_; my %w = map { $_ => 1 } @$v; [ grep { $w{$_->{volume}} } @{$s->{snaps}} ] }
    sub snapshot_create {
        my ($s, $vols, $name) = @_;
        $s->check_snapshot_args($vols, $name);
        my @new = map { { id => "$_.$name", name => $name, volume => $_, created => ++$s->{t}, size => 10, group => "g.$name" } } @$vols;
        push @{$s->{snaps}}, @new;
        return \@new;
    }
    sub snapshot_delete {
        my ($s, $snap) = @_;
        push @{$s->{deleted}}, $snap->{id};
        $s->{snaps} = [ grep { ($_->{group} // $_->{id}) ne ($snap->{group} // $snap->{id}) } @{$s->{snaps}} ];
    }
    sub snapshot_clone { my ($s, $snap, $name) = @_; push @{$s->{clones}}, $name; { id => "c-$name", name => $name, wwid => "3600aa$name" } }
    sub map_to_hostcluster { push @{$_[0]->{maps}}, $_[1] }
    sub unmap_from_hostcluster { push @{$_[0]->{unmaps}}, $_[1] }
    sub delete_volume { push @{$_[0]->{vol_deleted}}, $_[1] }
    sub snapshot_restore { push @{$_[0]->{restored}}, [ $_[1], $_[2]->{id} ] }
}

my $drv = bless { snaps => [], t => 1000 }, 'FakeSnapDriver';
my $cfg = { datastores => {
    gold => { array => 'a1', volumes => [ { id => 'v1', name => 'gold', wwid => '3600aa01' }, { id => 'v2', name => 'gold2', wwid => '3600aa02' } ] },
    plain => {},
} };
my (@log, @cmds, @storage_created, %nodes_calls);
{
    no warnings qw(redefine once);
    *PVE::SAN::Config::load = sub { $cfg };
    *PVE::SAN::Config::update = sub { $_[0]->($cfg) };
    *PVE::SAN::Array::driver = sub { $drv };
    *PVE::SAN::Array::config = sub { { type => 'fake' } };
    *PVE::SAN::Array::hostcluster = sub { 'pvelab' };
    *PVE::SAN::Cluster::nodes = sub { [ 'n1', 'n2' ] };
    *PVE::SAN::Cluster::offline_nodes = sub { [] };
    *PVE::SAN::Cluster::local_node = sub { 'n1' };
    *PVE::SAN::Cluster::on_nodes = sub { push @{$nodes_calls{$_[3]}}, $_[4]; return {} };
    *PVE::SAN::Cluster::guest_refs = sub { [] };
    *PVE::SAN::Cluster::running_guests = sub { [] };
    *PVE::SAN::Provision::wait_visible = sub { push @log, "visible $_[1]" };
    *PVE::SAN::Datastore::register_devices = sub { push @log, "register $_[1] @{$_[2]}"; [ map { "/dev/mapper/x$_" } 0 .. $#{$_[2]} ] };
    *PVE::SAN::Datastore::storage = sub { { vgname => "san_$_[0]", type => 'fcsan' } };
    *PVE::SAN::Datastore::storage_nodes = sub { [ 'n1', 'n2' ] };
    *PVE::SAN::Datastore::update_storage = sub { push @log, "storage $_[0] " . join(',', map { "$_=$_[1]->{$_}" } sort keys %{$_[1]}) };
    *PVE::SAN::LVM::vgs = sub { {} };
    *PVE::SAN::LVM::lvs = sub { [ { lv_name => 'vm-101-disk-0' } ] };
    *PVE::SAN::LVM::devicesfile_enabled = sub { 0 };
    *PVE::SAN::LVM::vg_deactivate = sub { push @log, "deactivate $_[0]" };
    *PVE::SAN::Snapshot::run_cmd = sub { push @cmds, join(' ', @{$_[0]}); '' };
    *PVE::Storage::config = sub { { ids => { gold => {} } } };
    *PVE::API2::Storage::Config::create = sub { push @storage_created, $_[1] };
}

eval { PVE::SAN::Snapshot::create(storage => 'plain') };
like($@, qr/not linked to an array/, 'plain datastore refused');

open(my $out, '>', \my $printed);
my $old = select($out);
my $n = PVE::SAN::Snapshot::create(storage => 'gold', name => 'before-upgrade');
PVE::SAN::Snapshot::create(storage => 'gold', name => 'auto-20261001-000000');
PVE::SAN::Snapshot::create(storage => 'gold', name => 'auto-20261002-000000');
select($old);
is($n, 'before-upgrade', 'snapshot named');
like($printed, qr/one point in time/, 'consistency mentioned for several volumes');
eval { PVE::SAN::Snapshot::create(storage => 'gold', name => 'before-upgrade') };
like($@, qr/already exists/, 'duplicate name refused');
eval { PVE::SAN::Snapshot::create(storage => 'gold', name => 'bad name') };
like($@, qr/invalid snapshot name/, 'bad name refused');

my $list = PVE::SAN::Snapshot::list(storage => 'gold');
is_deeply([ map { [ $_->{name}, $_->{volumes}, $_->{complete}, $_->{auto} ] } @$list ],
    [ [ 'before-upgrade', 2, 1, 0 ], [ 'auto-20261001-000000', 2, 1, 1 ], [ 'auto-20261002-000000', 2, 1, 1 ] ], 'listed as sets');

# mount a copy
select($out);
my $copy = PVE::SAN::Snapshot::mount_copy(storage => 'gold', name => 'before-upgrade', copy => 'gold-copy');
select($old);
is($copy, 'gold-copy', 'copy name');
is_deeply($drv->{clones}, [ 'gold-copy-00', 'gold-copy-01' ], 'one clone per volume');
is_deeply($drv->{maps}, [ 'c-gold-copy-00', 'c-gold-copy-01' ], 'clones mapped to the cluster');
is_deeply([ grep { /^visible/ } @log ], [ 'visible 3600aagold-copy-00', 'visible 3600aagold-copy-01' ], 'waited for both LUNs');
ok((grep { $_ eq 'register gold-copy 3600aagold-copy-00 3600aagold-copy-01' } @log), 'devices registered under the copy');
is($cmds[0], 'vgimportclone --basevgname san_gold-copy /dev/mapper/x0 /dev/mapper/x1', 'volume group imported under a new name');
is($cmds[1], 'lvchange --permission r san_gold-copy', 'copy volumes made read-only');
is($storage_created[0]->{storage}, 'gold-copy', 'storage registered');
is($storage_created[0]->{content}, 'images', 'copy holds disk images');
is($cfg->{datastores}->{'gold-copy'}->{copy_of}, 'gold', 'copy recorded');
is($cfg->{datastores}->{'gold-copy'}->{snapshot}, 'before-upgrade', 'snapshot recorded');
is(PVE::SAN::Snapshot::list(storage => 'gold')->[0]->{copy}, 'gold-copy', 'list shows the mounted copy');

eval { PVE::SAN::Snapshot::remove(storage => 'gold', name => 'before-upgrade') };
like($@, qr/mounted as 'gold-copy'/, 'mounted snapshot cannot be deleted');
eval { PVE::SAN::Snapshot::create(storage => 'gold-copy') };
like($@, qr/is a snapshot copy/, 'copies are not snapshotted');
eval { PVE::SAN::Snapshot::rollback(storage => 'gold', name => 'before-upgrade', confirm => 'gold') };
like($@, qr/remove the mounted copies/, 'no rollback while a copy is mounted');
eval { PVE::SAN::Provision::destroy(storage => 'gold') };
like($@, qr/has mounted snapshot copies/, 'datastore with copies is not deleted');

# a failing import cleans up after itself
{
    no warnings 'redefine';
    local *PVE::SAN::Snapshot::run_cmd = sub { die "vgimportclone failed\n" };
    $drv->{maps} = []; $drv->{unmaps} = []; $drv->{vol_deleted} = [];
    select($out);
    eval { PVE::SAN::Snapshot::mount_copy(storage => 'gold', name => 'auto-20261001-000000', copy => 'gold-c2') };
    select($old);
    like($@, qr/vgimportclone failed/, 'error passed on');
    is_deeply($drv->{unmaps}, [ 'c-gold-c2-00', 'c-gold-c2-01' ], 'clones unmapped again');
    is_deeply($drv->{vol_deleted}, [ 'c-gold-c2-00', 'c-gold-c2-01' ], 'clones deleted again');
    ok(!$cfg->{datastores}->{'gold-c2'}, 'copy record removed');
}

# retention
$cfg->{datastores}->{gold}->{snapshot_schedule} = { interval => 1, keep => 1 };
$drv->{deleted} = [];
select($out);
PVE::SAN::Snapshot::prune(storage => 'gold');
select($old);
is_deeply($drv->{deleted}, [ 'v1.auto-20261001-000000' ], 'oldest automatic snapshot pruned (group deleted once)');
is_deeply([ map { $_->{name} } @{PVE::SAN::Snapshot::list(storage => 'gold')} ], [ 'before-upgrade', 'auto-20261002-000000' ],
    'manual snapshot kept');

# scheduled run claims, snapshots and records
$cfg->{datastores}->{gold}->{snapshot_state} = {};
select($out);
my $ran = PVE::SAN::Snapshot::run_snapshot_schedules();
select($old);
is_deeply($ran->{ran}, [ 'gold' ], 'due datastore snapshotted');
ok($cfg->{datastores}->{gold}->{snapshot_state}->{last}, 'run recorded');
ok(!$cfg->{datastores}->{gold}->{snapshot_state}->{claimed}, 'claim released');
is(scalar(grep { $_->{auto} } @{PVE::SAN::Snapshot::list(storage => 'gold')}), 1, 'new automatic snapshot, old one pruned');
is_deeply(PVE::SAN::Snapshot::run_snapshot_schedules()->{ran}, [], 'not due again right away');

# rollback
delete $cfg->{datastores}->{'gold-copy'};
eval { PVE::SAN::Snapshot::rollback(storage => 'gold', name => 'before-upgrade') };
like($@, qr/confirm with the datastore's ID/, 'rollback needs confirmation');
{
    no warnings 'redefine';
    local *PVE::SAN::Cluster::running_guests = sub { [ '101 (n2)' ] };
    eval { PVE::SAN::Snapshot::rollback(storage => 'gold', name => 'before-upgrade', confirm => 'gold') };
    like($@, qr/stop every guest using 'gold' first: 101/, 'running guests block rollback');
}
@log = ();
select($out);
PVE::SAN::Snapshot::rollback(storage => 'gold', name => 'before-upgrade', confirm => 'gold');
select($old);
is($log[0], 'storage gold disable=1', 'datastore disabled during rollback');
ok(grep({ $_->{vgname} eq 'san_gold' } @{$nodes_calls{'vg-deactivate'}}), 'volume group deactivated on all nodes');
is_deeply($drv->{restored}, [ [ 'v1', 'v1.before-upgrade' ], [ 'v2', 'v2.before-upgrade' ] ], 'each volume restored from its member');
is($log[-1], 'storage gold delete=disable', 'datastore enabled again');

done_testing();
