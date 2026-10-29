use strict;
use warnings;

use Test::More;
use JSON::PP;
use File::Temp ();

use StubPVE;
use FakeArray;
use PVE::SAN::Array::Pure;
use PVE::SAN::Array::IBMSV;
use PVE::SAN::Volume;
use PVE::Storage::Custom::FCSANVolPlugin;

my $GIB = 1024 ** 3;
my $V = 'PVE::SAN::Volume';
my $P = 'PVE::Storage::Custom::FCSANVolPlugin';

# ---------------- names ----------------
is_deeply([ PVE::SAN::Volume::parse_volname('vm-100-disk-0') ], [ 'vm-100-disk-0', 100, 0 ], 'disk name');
is_deeply([ PVE::SAN::Volume::parse_volname('base-9000-disk-1') ], [ 'base-9000-disk-1', 9000, 1 ], 'base name');
eval { PVE::SAN::Volume::parse_volname('vm-100-disk-0.qcow2') };
like($@, qr/unable to parse/, 'other formats refused');
eval { PVE::SAN::Volume::parse_volname('vm-100-cloudinit') };
like($@, qr/unable to parse/, 'cloud-init volumes not supported yet');
is(PVE::SAN::Volume::alias_for('vols', 'vm-100-disk-0'), 'vols-vm-100-disk-0', 'multipath alias');
eval { PVE::SAN::Volume::alias_for('x' x 60, 'vm-100-disk-0') };
like($@, qr/too long/, 'alias length checked');
is(PVE::SAN::Volume::next_disk_name(100, [ 'vm-100-disk-0', 'base-100-disk-1', 'vm-101-disk-2' ]), 'vm-100-disk-2', 'next free disk number');
{
    my $pure = bless { address => 'x' }, 'PVE::SAN::Array::Pure';
    is(PVE::SAN::Volume::array_name($pure, 'vols_a', 'vm-100-disk-0'), 'vols-a-vm-100-disk-0', 'array name adapted to Pure rules');
    eval { PVE::SAN::Volume::check_snapname($pure, 'before_update') };
    like($@, qr/no '_'/, 'PVE snapshot names with _ refused with a clear message');
    eval { PVE::SAN::Volume::check_snapname($pure, 'before-update') };
    is($@, '', 'valid snapshot name');
}

# ---------------- Pure primitives ----------------
{
    my %st = (vols => { 'vols-vm-100-disk-0' => { name => 'vols-vm-100-disk-0', serial => 'A1B2C3D4E5F6A7B800000001', provisioned => 32 * $GIB },
                        'other' => { name => 'other', serial => 'A1B2C3D4E5F6A7B800000002', provisioned => $GIB } },
              conns => { 'vols-vm-100-disk-0' => 7 });
    my $items = sub { (200, { items => $_[0] }) };
    my ($drv, $calls) = FakeArray::driver('PVE::SAN::Array::Pure', {}, [
        [ GET => qr{^/api/api_version$}, sub { (200, { version => ['2.10'] }) } ],
        [ POST => qr{^/api/2\.10/login$}, sub { (200, { items => [] }, { 'x-auth-token' => 'S' }) } ],
        [ GET => qr{^/api/2\.10/volumes$}, sub {
            my $q = $_[1];
            my @v = map { $st{vols}->{$_} } sort keys %{$st{vols}};
            if (my ($n) = ($q->{filter} // '') =~ /^name='(.+)'$/) { @v = grep { $_->{name} eq $n } @v; }
            $items->(\@v) } ],
        [ GET => qr{^/api/2\.10/connections$}, sub {
            my $l = $st{conns}->{$_[1]->{volume_names}};
            $items->(defined($l) ? [ { lun => $l, volume => { name => $_[1]->{volume_names} } } ] : []) } ],
        [ PATCH => qr{^/api/2\.10/volumes$}, sub {
            my ($q, $b) = @_[1, 2];
            $st{vols}->{$b->{name}} = delete $st{vols}->{$q->{names}};
            $st{vols}->{$b->{name}}->{name} = $b->{name};
            $items->([ $st{vols}->{$b->{name}} ]) } ],
        [ POST => qr{^/api/2\.10/volumes$}, sub {
            my ($q, $b) = @_[1, 2];
            $st{vols}->{$q->{names}} = { name => $q->{names}, serial => 'A1B2C3D4E5F6A7B800000003', provisioned => 32 * $GIB, source => $b->{source}->{name} };
            $items->([ $st{vols}->{$q->{names}} ]) } ],
    ]);
    ok($drv->supports_disk_volumes, 'Pure: disk volumes supported');
    is_deeply([ map { $_->{name} } @{$drv->volumes_named('vols-')} ], [ 'vols-vm-100-disk-0' ], 'Pure: volumes by prefix');
    like(FakeArray::find_call($calls, 'GET', qr{/volumes\?})->{url}, qr/destroyed=false/, 'Pure: destroyed volumes ignored');
    is($drv->volume_by_name('vols-vm-100-disk-0')->{wwid}, '3624a9370a1b2c3d4e5f6a7b800000001', 'Pure: lookup by name');
    like($calls->[-1]->{url}, qr/filter=name%3D%27vols-vm-100-disk-0%27/, 'Pure: exact name filter');
    is($drv->volume_by_name('nope'), undef, 'Pure: missing volume is undef, not an error');
    is($drv->host_lun('vols-vm-100-disk-0', 'lab'), 7, 'Pure: LUN number from the connection');
    like($calls->[-1]->{url}, qr/host_group_names=lab/, 'Pure: connection of the host group');
    is($drv->host_lun('other', 'lab'), undef, 'Pure: not connected');
    my $c = $drv->copy_volume('vols-vm-100-disk-0', 'vols-vm-101-disk-0');
    is_deeply($calls->[-1]->{body}, { source => { name => 'vols-vm-100-disk-0' } }, 'Pure: copy = new volume from source');
    is($c->{name}, 'vols-vm-101-disk-0', 'Pure: copy named');
    $drv->rename_volume('vols-vm-100-disk-0', 'vols-base-100-disk-0');
    is_deeply($calls->[-1]->{body}, { name => 'vols-base-100-disk-0' }, 'Pure: rename');
    ok($st{vols}->{'vols-base-100-disk-0'}, 'Pure: renamed');
}
{
    my $ibm = bless { address => 'x' }, 'PVE::SAN::Array::IBMSV';
    ok(!$ibm->supports_disk_volumes, 'IBM: not yet');
    eval { $ibm->volumes_named('x') };
    like($@, qr/volumes per VM disk is not supported yet/, 'IBM: clear error');
}

# ---------------- PVE::SAN::Volume with a fake driver ----------------

package FakeVolDriver {
    use parent -norequire, 'PVE::SAN::Array::Base';
    sub description { 'Fake' }
    sub supports_disk_volumes { 1 }
    sub supports_snapshots { 1 }
    sub object_name_for { my ($c, $n) = @_; $n =~ s/_/-/g; $n }
    sub valid_name { defined($_[1]) && $_[1] =~ /^[A-Za-z0-9-]{1,63}$/ }
    sub volumes_named { my ($s, $p) = @_; [ map { $s->{vols}->{$_} } grep { index($_, $p) == 0 } sort keys %{$s->{vols}} ] }
    sub create_volume {
        my ($s, %p) = @_;
        die "pool missing\n" if !$p{pool};
        my $n = ++$s->{n};
        $s->{vols}->{$p{name}} = { id => $p{name}, name => $p{name}, capacity => $p{size_gib} * 1024 ** 3, wwid => sprintf('3624a9370%024x', $n) };
    }
    sub volume { $_[0]->{vols}->{$_[1]} // die "no volume $_[1]\n" }
    sub map_to_hostcluster { die "map failed\n" if $_[0]->{fail_map}; $_[0]->{lun}->{$_[1]} = 10 + keys %{$_[0]->{lun}} }
    sub host_lun { $_[0]->{lun}->{$_[1]} }
    sub unmap_from_hostcluster { delete $_[0]->{lun}->{$_[1]}; push @{$_[0]->{log}}, "unmap $_[1]" }
    sub delete_volume { delete $_[0]->{vols}->{$_[1]}; push @{$_[0]->{log}}, "delete $_[1]" }
    sub expand_volume { $_[0]->{vols}->{$_[1]}->{capacity} += $_[2] }
    sub pools { [ { name => 'default', capacity => 1000, free => 400 } ] }
    sub snapshot_create { my ($s, $v, $n) = @_; $s->check_snapshot_args($v, $n); push @{$s->{snaps}}, { id => "$v->[0].$n", name => $n, volume => $v->[0] }; }
    sub snapshots { my ($s, $v) = @_; [ grep { $_->{volume} eq $v->[0] } @{$s->{snaps} // []} ] }
    sub snapshot_delete { my ($s, $x) = @_; $s->{snaps} = [ grep { $_->{id} ne $x->{id} } @{$s->{snaps}} ] }
    sub snapshot_restore { push @{$_[0]->{log}}, "restore $_[1] from $_[2]->{id}" }
    sub snapshot_clone { my ($s, $x, $n) = @_; $s->create_volume(name => $n, pool => 'p', size_gib => 1) }
    sub copy_volume { my ($s, $v, $n) = @_; $s->create_volume(name => $n, pool => 'p', size_gib => 1) }
    sub rename_volume { my ($s, $v, $n) = @_; $s->{vols}->{$n} = delete $s->{vols}->{$v}; @{$s->{vols}->{$n}}{qw(id name)} = ($n, $n) }
}

my $drv = bless { vols => {}, n => 0 }, 'FakeVolDriver';
my $cfg = { devices => {}, datastores => {} };
my (@nodes_calls, @local);
{
    no warnings qw(redefine once);
    *PVE::SAN::Config::load = sub { $cfg };
    *PVE::SAN::Config::update = sub { $_[0]->($cfg) };
    *PVE::SAN::Array::driver = sub { $drv };
    *PVE::SAN::Array::config = sub { {} };
    *PVE::SAN::Array::hostcluster = sub { 'lab' };
    *PVE::SAN::Cluster::nodes = sub { [ 'n1', 'n2' ] };
    *PVE::SAN::Cluster::on_nodes = sub { push @nodes_calls, "$_[2] $_[3]"; {} };
    require PVE::SAN::Ops;
    *PVE::SAN::Ops::rescan_lun = sub { push @local, "rescan lun $_[0]" };
    *PVE::SAN::Ops::sync = sub { push @local, 'sync'; {} };
    *PVE::SAN::Ops::refresh_device = sub { push @local, "refresh $_[0]" };
    *PVE::SAN::Multipath::map_for_wwid = sub { undef };
    *PVE::SAN::Multipath::wait_for_map = sub { push @local, "wait $_[0]"; 'map' };
    *PVE::SAN::Volume::run_cmd = sub { push @local, join(' ', @{$_[0]}); '' };
}
$PVE::SAN::Volume::STATUS_CACHE_DIR = File::Temp::tempdir(CLEANUP => 1);
my $scfg = { type => 'fcsanvol', 'fc-array' => 'fa1', 'fc-pool' => 'default', 'fc-max-luns' => 3 };

my $vol = PVE::SAN::Volume::alloc('vols', $scfg, 100, undef, 10 * 1024 * 1024 + 1);
is($vol, 'vm-100-disk-0', 'first disk allocated');
my $av = $drv->{vols}->{'vols-vm-100-disk-0'};
is($av->{capacity}, 11 * $GIB, 'size rounded up to whole GiB');
my ($wwid, $rec) = PVE::SAN::Volume::record('vols', 'vm-100-disk-0');
is($wwid, $av->{wwid}, 'recorded by WWID');
is_deeply($rec, { alias => 'vols-vm-100-disk-0', datastore => 'vols', disk => 'vm-100-disk-0', lun => 10,
    array_volume => { id => 'vols-vm-100-disk-0', name => 'vols-vm-100-disk-0' }, policy => 'array-default' }, 'record');
is(scalar(@nodes_calls), 0, 'allocation does not rescan the cluster');

is(PVE::SAN::Volume::alloc('vols', $scfg, 100, 'vm-100-disk-5', $GIB / 1024), 'vm-100-disk-5', 'named disk');
eval { PVE::SAN::Volume::alloc('vols', $scfg, 100, 'vm-101-disk-1', 1024) };
like($@, qr/illegal name/, 'disk of another VM refused');
eval { PVE::SAN::Volume::alloc('vols', $scfg, 100, 'vm-100-disk-5', 1024) };
like($@, qr/already exists/, 'duplicate refused');

$drv->{fail_map} = 1;
eval { PVE::SAN::Volume::alloc('vols', $scfg, 102, undef, 1024) };
like($@, qr/map failed/, 'mapping failure passed on');
ok(!$drv->{vols}->{'vols-vm-102-disk-0'}, 'volume deleted again after a failed mapping');
$drv->{fail_map} = 0;

PVE::SAN::Volume::alloc('vols', $scfg, 102, undef, 1024);
eval { PVE::SAN::Volume::alloc('vols', $scfg, 103, undef, 1024) };
like($@, qr/already holds 3 volumes/, 'LUN limit enforced');

my $list = PVE::SAN::Volume::list('vols', $scfg, undef);
is_deeply([ map { $_->{volid} } @$list ], [ 'vols:vm-100-disk-0', 'vols:vm-100-disk-5', 'vols:vm-102-disk-0' ], 'all disks listed');
is_deeply([ map { $_->{vmid} } @{PVE::SAN::Volume::list('vols', $scfg, 102)} ], [ 102 ], 'disks of one VM');
is_deeply([ PVE::SAN::Volume::status('vols-nocache-' . $$, $scfg) ], [ 1000, 400, 600, 1 ], 'pool capacity as storage status');

# activation: targeted rescan of one LUN number
@local = ();
eval { PVE::SAN::Volume::activate('vols', $scfg, 'vm-100-disk-0') };
is_deeply([ @local[0 .. 2] ], [ 'rescan lun 10', 'sync', "wait $wwid" ], 'only the disk\'s LUN number is scanned');

# deactivation releases the LUN on this node; an open map is kept
{
    no warnings qw(redefine once);
    my @detached;
    local *PVE::SAN::Ops::detach_device = sub { push @detached, $_[0]; die "device is in use\n" if $_[0] eq 'busy' };
    PVE::SAN::Volume::deactivate('vols', $scfg, 'vm-100-disk-0');
    is_deeply(\@detached, [ $wwid ], 'LUN released on this node after the VM stopped');
    my $warned = '';
    local $SIG{__WARN__} = sub { $warned .= $_[0] };
    local *PVE::SAN::Volume::record = sub { ('busy', {}) };
    PVE::SAN::Volume::deactivate('vols', $scfg, 'vm-100-disk-0');
    like($warned, qr/LUN kept on this node - device is in use/, 'a map still in use only warns');
    @detached = ();
    $P->deactivate_volume('vols', { %$scfg, 'fc-keep-luns' => 1 }, 'vm-100-disk-0');
    is_deeply(\@detached, [], 'fc-keep-luns keeps the LUN');
    $P->deactivate_volume('vols', $scfg, 'vm-100-disk-0', 'snap1');
    is_deeply(\@detached, [], 'snapshots are never released');
}

# resize
@local = ();
is(PVE::SAN::Volume::resize('vols', $scfg, 'vm-100-disk-0', 20 * $GIB), 20 * $GIB, 'resized');
is($av->{capacity}, 20 * $GIB, 'expanded on the array');
eval { PVE::SAN::Volume::resize('vols', $scfg, 'vm-100-disk-0', $GIB) };
like($@, qr/must be larger/, 'shrinking refused');

# snapshots
PVE::SAN::Volume::snapshot('vols', $scfg, 'vm-100-disk-0', 'before-update');
is($drv->{snaps}->[0]->{name}, 'before-update', 'array snapshot');
eval { PVE::SAN::Volume::snapshot('vols', $scfg, 'vm-100-disk-0', 'bad_name') };
like($@, qr/no '_'/, 'underscore refused');
@local = ();
PVE::SAN::Volume::snapshot_rollback('vols', $scfg, 'vm-100-disk-0', 'before-update');
is($drv->{log}->[-1], 'restore vols-vm-100-disk-0 from vols-vm-100-disk-0.before-update', 'rollback = array restore');
eval { PVE::SAN::Volume::snapshot_rollback('vols', $scfg, 'vm-100-disk-0', 'nope') };
like($@, qr/snapshot 'nope' .* not found/, 'unknown snapshot');

# clone from snapshot, template, linked clone
$scfg->{'fc-max-luns'} = 10;
my $c1 = PVE::SAN::Volume::clone('vols', $scfg, 'vm-100-disk-0', 200, 'before-update');
is($c1, 'vm-200-disk-0', 'clone of a snapshot');
ok(PVE::SAN::Volume::record('vols', 'vm-200-disk-0'), 'clone recorded and mapped');
eval { PVE::SAN::Volume::clone('vols', $scfg, 'vm-100-disk-5', 201) };
like($@, qr/not a base volume/, 'clone of a plain disk needs a snapshot');
@nodes_calls = ();
my $base = PVE::SAN::Volume::create_base('vols', $scfg, 'vm-100-disk-5');
is($base, 'base-100-disk-5', 'template disk');
ok($drv->{vols}->{'vols-base-100-disk-5'}, 'renamed on the array');
my (undef, $brec) = PVE::SAN::Volume::record('vols', 'base-100-disk-5');
is($brec->{alias}, 'vols-base-100-disk-5', 'alias follows');
is($brec->{array_volume}->{id}, 'vols-base-100-disk-5', 'name-as-ID follows the rename');
is_deeply(\@nodes_calls, [ 'POST sync' ], 'nodes rename their multipath maps');
is(PVE::SAN::Volume::clone('vols', $scfg, 'base-100-disk-5', 300), 'vm-300-disk-0', 'linked clone = array copy');

# free
@nodes_calls = ();
$drv->{log} = [];
PVE::SAN::Volume::free('vols', $scfg, 'vm-102-disk-0');
like($nodes_calls[1], qr{^POST devices/3624a9370\w+/detach-local$}, 'paths removed on every node first');
is_deeply($drv->{log}, [ 'unmap vols-vm-102-disk-0', 'delete vols-vm-102-disk-0' ], 'then unmapped and deleted');
eval { PVE::SAN::Volume::record('vols', 'vm-102-disk-0') };
like($@, qr/not known/, 'record removed');

# ---------------- plugin ----------------
is($P->type, 'fcsanvol', 'type');
ok(grep({ $_ eq 'fcsanvol' } @PVE::Storage::Plugin::SHARED_STORAGE), 'registered as shared storage');
is_deeply([ $P->parse_volname('base-100-disk-5') ], [ 'images', 'base-100-disk-5', 100, undef, undef, 1, 'raw' ], 'parse_volname');
is(scalar($P->path($scfg, 'vm-100-disk-0', 'vols')), '/dev/mapper/vols-vm-100-disk-0', 'path without an array call');
eval { $P->path($scfg, 'vm-100-disk-0', 'vols', 'snap1') };
like($@, qr/can't be attached directly/, 'snapshot path refused');
eval { $P->alloc_image('vols', $scfg, 100, 'qcow2', undef, 1024) };
like($@, qr/raw disks only/, 'qcow2 refused');
ok($P->volume_has_feature($scfg, 'snapshot', 'vols', 'vm-100-disk-0'), 'snapshots');
ok($P->volume_has_feature($scfg, 'clone', 'vols', 'base-100-disk-5'), 'linked clones from templates');
ok($P->volume_has_feature($scfg, 'clone', 'vols', 'vm-100-disk-0', 'snap1'), 'clones from snapshots');
ok(!$P->volume_has_feature($scfg, 'clone', 'vols', 'vm-100-disk-0'), 'no clone of a running disk');
ok($P->volume_has_feature($scfg, 'template', 'vols', 'vm-100-disk-0'), 'templates');
ok(!$P->volume_has_feature($scfg, 'rename', 'vols', 'vm-100-disk-0'), 'no rename yet');
ok($P->volume_rollback_is_possible($scfg, 'vols', 'vm-100-disk-0', 'snap1'), 'any snapshot can be rolled back');

done_testing();
