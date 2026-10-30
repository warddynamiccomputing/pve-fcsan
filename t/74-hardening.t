use strict;
use warnings;

use Test::More;

use StubPVE;
use PVE::SAN::Snapshot;
use PVE::SAN::Datastore;
use PVE::Storage;
use PVE::Storage::LVMPlugin;
use PVE::Storage::Custom::FCSANPlugin;

# ---------------- fc-discard hands off to the LVM plugin's own discard ----------------
{
    my ($opts, @freed) = ({});
    no warnings qw(redefine once);
    local *PVE::Storage::LVMPlugin::options = sub { $opts };
    local *PVE::Storage::LVMPlugin::free_image = sub { my ($c, $id, $scfg) = @_; push @freed, { %$scfg }; 'worker' };
    my @cmds;
    local *PVE::Tools::run_command = sub { push @cmds, join(' ', @{$_[0]}) };
    my $P = 'PVE::Storage::Custom::FCSANPlugin';

    $opts = { 'on-volume-remove' => { optional => 1 } };
    is($P->free_image('gold', { vgname => 'san_gold', 'fc-discard' => 1 }, 'vm-100-disk-0', 0, 'raw'), 'worker',
        'the LVM plugin\'s cleanup worker is returned');
    is($freed[-1]->{'on-volume-remove'}, 'discard=1', 'fc-discard turns on the native discard (outside the storage lock)');
    is_deeply(\@cmds, [], 'no discard inside the lock');
    $P->free_image('gold', { vgname => 'san_gold', 'fc-discard' => 1, 'on-volume-remove' => 'discard=0' }, 'vm-100-disk-0', 0, 'raw');
    is($freed[-1]->{'on-volume-remove'}, 'discard=0', 'an explicit on-volume-remove wins');
    $P->free_image('gold', { vgname => 'san_gold' }, 'vm-100-disk-0', 0, 'raw');
    ok(!$freed[-1]->{'on-volume-remove'}, 'nothing added without fc-discard');

    $opts = {}; # older libpve-storage-perl
    $P->free_image('gold', { vgname => 'san_gold', 'fc-discard' => 1 }, 'vm-100-disk-0', 0, 'raw');
    is_deeply(\@cmds, [ 'lvchange -ay san_gold/vm-100-disk-0', 'blkdiscard /dev/san_gold/vm-100-disk-0' ],
        'older LVM plugin: discard before the removal');
    @cmds = ();
    $P->free_image('gold', { vgname => 'san_gold', 'fc-discard' => 1, saferemove => 1 }, 'vm-100-disk-0', 0, 'raw');
    is_deeply(\@cmds, [], 'older LVM plugin: saferemove already wipes');
}

# ---------------- container configs restored into a new ID ----------------
my $ct = <<'EOF';
arch: amd64
hostname: db1
memory: 2048
mp0: gold:vm-200-disk-1,mp=/data,size=20G
mp1: other:vm-200-disk-0,mp=/logs,size=4G
net0: name=eth0,bridge=vmbr0,hwaddr=BC:24:11:12:34:56,ip=dhcp,type=veth
onboot: 1
ostype: debian
rootfs: gold:vm-200-disk-0,size=8G
unused0: gold:vm-200-disk-2
EOF
{
    is_deeply([ map { "$_->{key}=$_->{volname}" } @{PVE::SAN::Snapshot::vm_disks($ct, 'gold')} ],
        [ 'mp0=vm-200-disk-1', 'rootfs=vm-200-disk-0', 'unused0=vm-200-disk-2' ], 'container disks on the datastore found');
    my ($text, $notes) = PVE::SAN::Snapshot::new_vm_config($ct, 'gold',
        { 'vm-200-disk-0' => 'gold:vm-300-disk-0', 'vm-200-disk-1' => 'gold:vm-300-disk-1' }, mac => sub { 'BC:24:11:00:00:09' });
    like($text, qr/^rootfs: gold:vm-300-disk-0,size=8G$/m, 'root disk remapped');
    like($text, qr/^mp0: gold:vm-300-disk-1,mp=\/data,size=20G$/m, 'mount point remapped');
    unlike($text, qr/^mp1:/m, 'mount point on another storage left out');
    like($text, qr/^net0: name=eth0,bridge=vmbr0,hwaddr=BC:24:11:00:00:09,ip=dhcp,type=veth,link_down=1$/m, 'new hwaddr, link down');
    unlike($text, qr/^onboot:/m, 'onboot dropped');
    like($text, qr/^hostname: db1$/m, 'hostname kept');
    is(scalar(grep { /left out/ } @$notes), 2, 'notes for what was left out');
}

# ---------------- restore of a container from a mounted copy ----------------
my $cfg = { datastores => { 'gold-snap' => { array => 'a1', copy_of => 'gold', snapshot => 'before', volumes => [] } } };
my (%files, @cmds, @alloc, @written, %status);
$files{'/etc/pve/nodes/n1/lxc/200.conf'} = $ct;
{
    no warnings qw(redefine once);
    *PVE::SAN::Config::load = sub { $cfg };
    *PVE::SAN::Datastore::storage = sub { { vgname => "san_$_[0]" } };
    *PVE::SAN::Cluster::guest_refs = sub { [ { vmid => 200, node => 'n1', type => 'lxc', file => '/etc/pve/nodes/n1/lxc/200.conf' } ] };
    *PVE::SAN::Cluster::guest_status = sub { +{ %status } };
    *PVE::SAN::Cluster::local_node = sub { 'n2' };
    *PVE::SAN::LVM::lvs = sub {
        [ map { { lv_name => $_, lv_size => 8 * 1024 ** 3 } } qw(vm-200-disk-0 vm-200-disk-1 vm-200-disk-2) ] };
    *PVE::SAN::Snapshot::run_cmd = sub { push @cmds, join(' ', @{$_[0]}); '' };
    *PVE::SAN::Snapshot::qemu_img_info = sub { { 'virtual-size' => 8 * 1024 ** 3 } };
    *PVE::Tools::file_get_contents = sub { $files{$_[0]} // die "no $_[0]\n" };
    *PVE::Tools::file_set_contents = sub { $files{$_[0]} = $_[1]; push @written, $_[0] };
    *PVE::Storage::config = sub { { ids => {} } };
    *PVE::Storage::activate_volumes = sub { };
    *PVE::Storage::deactivate_volumes = sub { };
    *PVE::Storage::vdisk_alloc = sub { my $n = scalar(@alloc); push @alloc, [ @_[1 .. 3] ]; "gold:vm-$_[2]-disk-$n" };
    *PVE::Storage::path = sub { "/dev/san_gold/" . (split(/:/, $_[1]))[1] };
    *PVE::Storage::vdisk_free = sub { };
}

open(my $out, '>', \my $printed);
my $old = select($out);
my $id = PVE::SAN::Snapshot::restore_vm(storage => 'gold-snap', vmid => 200, target_vmid => 300);
select($old);
is($id, 300, 'container restored into a new ID');
is_deeply([ map { $_->[1] } @alloc ], [ 300, 300, 300 ], 'a new volume per disk on the datastore');
is($written[-1], '/etc/pve/nodes/n2/lxc/300.conf', 'written as a container config on this node');
like($files{'/etc/pve/nodes/n2/lxc/300.conf'}, qr/^rootfs: gold:vm-300-disk-\d,size=8G$/m, 'root disk points at the copy');
like($printed, qr/CT 200 restored from snapshot 'before' as new CT 300/, 'reported as a container');

%status = (200 => { status => 'running', node => 'n1' });
eval { PVE::SAN::Snapshot::restore_vm(storage => 'gold-snap', vmid => 200) };
like($@, qr/CT 200 is running on n1/, 'a running container is not restored over');
%status = ();
@cmds = ();
select($out);
PVE::SAN::Snapshot::restore_vm(storage => 'gold-snap', vmid => 200);
select($old);
ok((grep { m{^qemu-img convert -n -f raw -O raw .* /dev/san_gold-snap/vm-200-disk-0 /dev/san_gold/vm-200-disk-0$} } @cmds),
    'container disk copied over the live one');

done_testing();
