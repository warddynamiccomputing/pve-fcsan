use strict;
use warnings;

use Test::More;
use JSON::PP;
use File::Temp qw(tempfile);

use StubPVE;
use FakeArray;
use PVE::SAN::DR;
use PVE::SAN::Snapshot;
use PVE::SAN::Array::Base;
use PVE::SAN::Array::Pure;
use PVE::SAN::Provision;
use PVE::SAN::Datastore;
use PVE::API2::Storage::Config;
use PVE::Storage;
use PVE::Storage::Plugin;

my $DR = 'PVE::SAN::DR';

# ---------------- metadata slots ----------------
{
    my $data = { storage => 'gold', guests => [ { vmid => 101, config => "name: web\n" } ] };
    my $slot = PVE::SAN::DR::meta_encode(3, $data);
    is(length($slot), $PVE::SAN::DR::SLOT, 'slot padded to its full size');
    my $d = PVE::SAN::DR::meta_decode($slot);
    is($d->{gen}, 3, 'generation read back');
    is_deeply($d->{data}, $data, 'payload read back');

    (my $torn = $slot) =~ s/web/wab/;
    ok(!PVE::SAN::DR::meta_decode($torn), 'checksum catches a torn or changed slot');
    ok(!PVE::SAN::DR::meta_decode("\0" x 64), 'empty slot ignored');
    ok(!PVE::SAN::DR::meta_decode(undef), 'unreadable slot ignored');

    my ($i, $best) = PVE::SAN::DR::meta_pick({ gen => 4, data => 'a' }, { gen => 5, data => 'b' });
    is($i, 1, 'newest slot picked');
    ($i, $best) = PVE::SAN::DR::meta_pick({ gen => 4, data => 'a' }, undef);
    is($best->{data}, 'a', 'the valid slot wins over a broken one');
    ($i, $best) = PVE::SAN::DR::meta_pick(undef, undef);
    ok(!defined($i) && !$best, 'nothing written yet');

    eval { PVE::SAN::DR::meta_encode(1, { big => 'x' x $PVE::SAN::DR::SLOT }) };
    like($@, qr/too large/, 'oversized metadata refused');
}

# ---------------- recovery plans and IDs ----------------
is_deeply(PVE::SAN::DR::parse_plan('101:60, 102,103:5'),
    [ { vmid => 101, delay => 60 }, { vmid => 102, delay => 0 }, { vmid => 103, delay => 5 } ], 'plan parsed');
is_deeply(PVE::SAN::DR::parse_plan(''), [], 'empty plan');
is(PVE::SAN::DR::format_plan(PVE::SAN::DR::parse_plan('101:60,102')), '101:60,102', 'plan formatted');
eval { PVE::SAN::DR::parse_plan('101,abc') };
like($@, qr/invalid recovery plan entry 'abc'/, 'bad entry refused');
eval { PVE::SAN::DR::parse_plan('101,101') };
like($@, qr/listed twice/, 'duplicate refused');
eval { PVE::SAN::DR::parse_plan('101:7200') };
like($@, qr/too long/, 'delay bounded');

{
    my ($map, $taken) = PVE::SAN::DR::vmid_map([ { vmid => 101 }, { vmid => 102 } ], 0, { 102 => {} });
    is_deeply($map, { 101 => 101, 102 => 102 }, 'IDs kept without offset');
    is_deeply($taken, [ 102 ], 'taken ID reported');
    ($map, $taken) = PVE::SAN::DR::vmid_map([ { vmid => 101 } ], 10000, { 101 => {} });
    is_deeply([ $map->{101}, scalar(@$taken) ], [ 10101, 0 ], 'offset avoids the clash');
}
is(PVE::SAN::DR::renamed_volname('vm-101-disk-0', 101, 10101), 'vm-10101-disk-0', 'disk renamed to the new ID');
is(PVE::SAN::DR::renamed_volname('base-101-disk-0', 101, 201), 'base-201-disk-0', 'template disk renamed');
is(PVE::SAN::DR::renamed_volname('vm-1011-disk-0', 101, 201), 'vm-1011-disk-0', 'other guest\'s disk untouched');
is(PVE::SAN::DR::renamed_volname('vm-101-disk-0', 101, 101), 'vm-101-disk-0', 'same ID, same name');
is(PVE::SAN::DR::storage_from_group('pvesan-gold'), 'gold', 'storage ID from the array group');
is(PVE::SAN::DR::storage_from_group('pvesan-1st'), 'dr-1st', 'storage ID starts with a letter');

# ---------------- guest configs at the DR site ----------------
my $vm = <<'EOF';
boot: order=scsi0;net0
efidisk0: gold:vm-101-disk-1,efitype=4m,size=4M
ide2: local:iso/debian.iso,media=cdrom,size=600M
name: web01
net0: virtio=BC:24:11:AA:BB:CC,bridge=vmbr0,firewall=1
onboot: 1
scsi0: gold:vm-101-disk-0,iothread=1,size=32G
scsi1: nfs1:101/vm-101-disk-0.qcow2,size=8G
scsi2: other:vm-101-disk-0,size=8G
smbios1: uuid=7b5c6c1e-1111-4222-8333-944455556666
vmgenid: 0f0e0d0c-1111-4222-8333-944455556666
EOF
{
    my ($text, $notes, $ren) = PVE::SAN::DR::dr_guest_config($vm, type => 'qemu', from => 'gold', to => 'gold',
        old => 101, new => 101, storages => { nfs1 => {} });
    like($text, qr/^scsi0: gold:vm-101-disk-0,iothread=1,size=32G$/m, 'failover: disk on the datastore kept');
    like($text, qr/^net0: virtio=BC:24:11:AA:BB:CC,bridge=vmbr0,firewall=1$/m, 'failover: MAC and link kept');
    like($text, qr/^smbios1: uuid=7b5c6c1e-1111/m, 'failover: identity kept');
    like($text, qr/^onboot: 1$/m, 'failover: onboot kept');
    like($text, qr/^ide2: none,media=cdrom$/m, 'ISO storage missing here: drive emptied');
    like($text, qr/^scsi1: nfs1:/m, 'disk on a storage this site has is kept');
    unlike($text, qr/^scsi2:/m, 'disk on a storage this site lacks is left out');
    is(scalar(@$ren), 0, 'nothing to rename');
    ok((grep { /stays on 'nfs1'/ } @$notes), 'note about the kept foreign disk');

    ($text, $notes, $ren) = PVE::SAN::DR::dr_guest_config($vm, type => 'qemu', from => 'gold', to => 'gold-drtest',
        old => 101, new => 10101, test => 1, storages => { local => {} },
        mac => sub { 'BC:24:11:00:00:01' }, uuid => sub { '00000000-0000-4000-8000-000000000001' });
    like($text, qr/^scsi0: gold-drtest:vm-10101-disk-0,iothread=1,size=32G$/m, 'test: disk moved and renamed');
    like($text, qr/^efidisk0: gold-drtest:vm-10101-disk-1,/m, 'test: EFI disk too');
    like($text, qr/^net0: virtio=BC:24:11:00:00:01,bridge=vmbr0,firewall=1,link_down=1$/m, 'test: new MAC, link down');
    like($text, qr/^smbios1: uuid=00000000-0000-4000-8000-000000000001$/m, 'test: new SMBIOS UUID');
    like($text, qr/^name: web01-drtest$/m, 'test: name marks the copy');
    unlike($text, qr/^onboot:/m, 'test: never starts on boot');
    like($text, qr/^ide2: local:iso/m, 'ISO kept where the storage exists');
    is_deeply($ren, [ [ 'vm-101-disk-1', 'vm-10101-disk-1' ], [ 'vm-101-disk-0', 'vm-10101-disk-0' ] ], 'LVs to rename');
}
{
    my $ct = "arch: amd64\nhostname: db1\nnet0: name=eth0,bridge=vmbr0,hwaddr=BC:24:11:12:34:56,ip=dhcp\nrootfs: gold:vm-200-disk-0,size=8G\nmp0: gold:vm-200-disk-1,mp=/data,size=20G\n";
    my ($text) = PVE::SAN::DR::dr_guest_config($ct, type => 'lxc', from => 'gold', to => 'gold-drtest',
        old => 200, new => 200, test => 1, mac => sub { 'BC:24:11:00:00:02' });
    like($text, qr/^rootfs: gold-drtest:vm-200-disk-0,size=8G$/m, 'container root disk moved');
    like($text, qr/^mp0: gold-drtest:vm-200-disk-1,mp=\/data/m, 'mount point moved');
    like($text, qr/^net0: name=eth0,bridge=vmbr0,hwaddr=BC:24:11:00:00:02,ip=dhcp,link_down=1$/m, 'container: new hwaddr, link down');
}

# ---------------- metadata refresh is a timer job ----------------
{
    my $now = 1_800_000_000;
    my $cfg = { datastores => {
        due => { dr_meta => 1, drmeta_state => { last => $now - 900 } },
        fresh => { dr_meta => 1, drmeta_state => { last => $now - 300 } },
        never => { dr_meta => 1 },
        off => {},
    } };
    is_deeply(PVE::SAN::Snapshot::due_jobs($cfg, 'drmeta', $now), [ qw(due never) ], 'DR metadata due every 15 minutes');
}

# ---------------- Pure FlashArray replication ----------------
{
    my $GIB = 1024 ** 3;
    my %st = (pgroups => { 'pvesan-gold' => { vols => [ 'gold' ], targets => [] } }, patches => [], posts => []);
    my $items = sub { (200, { items => $_[0] }) };
    my ($drv, $calls) = FakeArray::driver('PVE::SAN::Array::Pure', {}, [
        [ GET => qr{^/api/api_version$}, sub { (200, { version => ['2.20'] }) } ],
        [ POST => qr{^/api/2\.20/login$}, sub { (200, {}, { 'x-auth-token' => 'S' }) } ],
        [ GET => qr{^/api/2\.20/array-connections$}, sub { $items->([
            { name => 'c1', remote => { name => 'dr-array' }, status => 'connected', type => 'async-replication' },
            { name => 'c2', remote => { name => 'fleet' }, status => 'connected', type => 'fleet-management' } ]) } ],
        [ GET => qr{^/api/2\.20/protection-groups$}, sub {
            my ($c, $q) = @_;
            $items->([ (map { { name => $_, is_local => JSON::PP::true,
                    replication_schedule => { enabled => JSON::PP::true, frequency => 3_600_000 } } } sort keys %{$st{pgroups}}),
                ($q->{destroyed} ? ({ name => 'prod-fa:pvesan-gold', is_local => JSON::PP::false },
                    { name => 'prod-fa:other', is_local => JSON::PP::false }) : ()) ]) } ],
        [ GET => qr{^/api/2\.20/protection-groups/volumes$}, sub {
            $items->([ map { { member => { name => $_ } } } @{$st{pgroups}->{$_[1]->{group_names}}->{vols} // []} ]) } ],
        [ GET => qr{^/api/2\.20/protection-groups/targets$}, sub {
            $items->([ map { { member => { name => $_ } } } @{$st{pgroups}->{$_[1]->{group_names}}->{targets} // []} ]) } ],
        [ POST => qr{^/api/2\.20/protection-groups/targets$}, sub {
            push @{$st{pgroups}->{$_[1]->{group_names}}->{targets}}, $_[1]->{member_names}; $items->([]) } ],
        [ DELETE => qr{^/api/2\.20/protection-groups/targets$}, sub {
            my $g = $st{pgroups}->{$_[1]->{group_names}};
            $g->{targets} = [ grep { $_ ne $_[1]->{member_names} } @{$g->{targets}} ]; $items->([]) } ],
        [ PATCH => qr{^/api/2\.20/protection-groups$}, sub { push @{$st{patches}}, $_[2]; $items->([]) } ],
        [ POST => qr{^/api/2\.20/protection-group-snapshots$}, sub { push @{$st{posts}}, [ $_[1], $_[2] ]; $items->([]) } ],
        [ GET => qr{^/api/2\.20/protection-group-snapshots/transfer$}, sub {
            my $src = $_[1]->{source_names};
            $items->($src eq 'pvesan-gold'
                ? [ { name => 'pvesan-gold.dr-1', started => 1_000_000, completed => 1_060_000, progress => 1, data_transferred => 5 },
                    { name => 'pvesan-gold.dr-2', started => 2_000_000, progress => 0.4 } ]
                : [ { name => "$src.dr-1", started => 1_000_000, completed => 1_060_000 },
                    { name => "$src.dr-2", started => 2_000_000 } ]) } ],
        [ GET => qr{^/api/2\.20/volume-snapshots$}, sub { $items->([
            { name => 'prod-fa:pvesan-gold.dr-1.gold', provisioned => 10 * $GIB },
            { name => 'prod-fa:pvesan-gold.dr-1.gold-01', provisioned => 10 * $GIB },
            { name => 'prod-fa:pvesan-gold.dr-2.gold', provisioned => 10 * $GIB },
            { name => 'local.snap', provisioned => 1 } ]) } ],
    ]);

    ok($drv->supports_replication, 'Pure: replication offered');
    is_deeply($drv->replication_partners(), [ { name => 'dr-array', status => 'connected', type => 'async-replication' } ],
        'Pure: replication partners (fleet links left out)');
    eval { $drv->replication_enable([ 'gold' ], 'nowhere', 3600, 86400) };
    like($@, qr/no replication connection to 'nowhere'/, 'Pure: unknown partner refused');
    eval { $drv->replication_enable([ 'gold' ], 'dr-array', 60, 86400) };
    like($@, qr/at least 5 minutes/, 'Pure: interval bounded');

    open(my $o, '>', \my $printed);
    my $old = select($o);
    my $pg = $drv->replication_enable([ 'gold' ], 'dr-array', 3600, 86400);
    select($old);
    is($pg, 'pvesan-gold', 'Pure: protection group');
    is_deeply($st{pgroups}->{'pvesan-gold'}->{targets}, [ 'dr-array' ], 'Pure: partner added as target');
    is($st{patches}->[-1]->{replication_schedule}->{frequency}, 3_600_000, 'Pure: replication schedule in ms');
    ok($st{patches}->[-1]->{replication_schedule}->{enabled}, 'Pure: schedule enabled');
    is($st{patches}->[-1]->{target_retention}->{all_for_sec}, 86400, 'Pure: target retention');
    select($o);
    $drv->replication_enable([ 'gold' ], 'dr-array', 3600, 86400);
    select($old);
    is(scalar(@{$st{pgroups}->{'pvesan-gold'}->{targets}}), 1, 'Pure: target not added twice');

    is($drv->replicate_now([ 'gold' ], 'dr-3'), 'dr-3', 'Pure: replicate now');
    is_deeply($st{posts}->[-1], [ { source_names => 'pvesan-gold', replicate_now => 'true' }, { suffix => 'dr-3' } ],
        'Pure: protection group snapshot with replicate_now');

    my $s = $drv->replication_status([ 'gold' ]);
    is_deeply($s->{partners}, [ 'dr-array' ], 'Pure: status partners');
    is($s->{interval}, 3600, 'Pure: status interval');
    is_deeply([ map { $_->{name} } @{$s->{transfers}} ], [ 'dr-2', 'dr-1' ], 'Pure: transfers newest first');
    is($s->{transfers}->[1]->{completed}, 1060, 'Pure: completion time in seconds');
    ok(!$s->{transfers}->[0]->{completed}, 'Pure: running transfer has no completion');

    is_deeply($drv->replicas(), [ { id => 'prod-fa:pvesan-gold', source => 'prod-fa', group => 'pvesan-gold' } ],
        'Pure: incoming pvesan replicas (others and local groups ignored)');
    my $rs = $drv->replica_snapshots('prod-fa:pvesan-gold');
    is(scalar(@$rs), 1, 'Pure: only fully received replica snapshots');
    is($rs->[0]->{name}, 'dr-1', 'Pure: replica snapshot name');
    is_deeply([ map { "$_->{volume}=$_->{id}" } @{$rs->[0]->{members}} ],
        [ 'gold=prod-fa:pvesan-gold.dr-1.gold', 'gold-01=prod-fa:pvesan-gold.dr-1.gold-01' ], 'Pure: members by source volume');

    $drv->replication_disable([ 'gold' ], 'dr-array');
    ok(!$st{patches}->[-1]->{replication_schedule}->{enabled}, 'Pure: schedule disabled');
    is_deeply($st{pgroups}->{'pvesan-gold'}->{targets}, [], 'Pure: target removed');
}

for my $class (qw(IBMSV Infinidat PowerStore PowerMax ONTAP ESeries Hitachi Eternus Unity)) {
    my $c = "PVE::SAN::Array::$class";
    eval "require $c" or die $@;
    ok(!$c->supports_replication, "$class: replication not offered yet");
    my $d = bless { address => 'x' }, $c;
    eval { $d->replicas() };
    like($@, qr/replication is not supported yet by the pvesan driver/, "$class: clear error");
}

# ---------------- workflow with a fake driver ----------------

package FakeReplDriver {
    use parent -norequire, 'PVE::SAN::Array::Base';
    sub description { 'Fake array' }
    sub supports_snapshots { 1 }
    sub supports_group_snapshots { 1 }
    sub supports_replication { 1 }
    sub replication_partners { [ { name => 'dr', status => 'connected' } ] }
    sub replication_enable { my ($s, $v, $p, $i, $r) = @_; $s->{enabled} = [ $v, $p, $i, $r ]; 'pvesan-gold' }
    sub replication_disable { $_[0]->{disabled} = $_[2] }
    sub replicate_now { my ($s, $v, $n) = @_; push @{$s->{sent}}, $n; push @{$s->{transfers}}, { name => $n, started => time(), completed => time() }; $n }
    sub replication_status { { group => 'pvesan-gold', partners => [ 'dr' ], transfers => [ reverse @{$_[0]->{transfers} // []} ] } }
    sub replicas { [ { id => 'src:pvesan-gold', source => 'src', group => 'pvesan-gold' } ] }
    sub replica_snapshots { [ { name => 'dr-1', created => 100, completed => 160,
        members => [ { id => 'src:pvesan-gold.dr-1.gold', volume => 'gold' } ] } ] }
    sub snapshot_clone { my ($s, $m, $name) = @_; push @{$s->{clones}}, [ $m->{id}, $name ]; { id => "c-$name", name => $name, wwid => "3600bb$name" } }
    sub map_to_hostcluster { push @{$_[0]->{maps}}, $_[1] }
    sub unmap_from_hostcluster { push @{$_[0]->{unmaps}}, $_[1] }
    sub delete_volume { push @{$_[0]->{vol_deleted}}, $_[1] }
}

package main;

my $drv = bless {}, 'FakeReplDriver';
my $cfg = { datastores => {
    gold => { array => 'a1', volumes => [ { id => 'v1', name => 'gold', wwid => '3600aa01' } ], dr_plan => [ { vmid => 101, delay => 30 } ] },
} };
my ($fh, $metafile) = tempfile(UNLINK => 1);
binmode($fh);
print $fh "\0" x (2 * $PVE::SAN::DR::SLOT);
close($fh);

my (@cmds, @log, %files, @storage_created, @storage_deleted, @detached, @destroyed, @actions);
my %storage_ids = (gold => {}, local => {});
my %guests = (101 => 'running'); # vmid => status of guests whose config is in %files
my %foreign; # guests that exist at the site without a config here
{
    no warnings qw(redefine once);
    *PVE::SAN::Config::load = sub { $cfg };
    *PVE::SAN::Config::update = sub { $_[0]->($cfg) };
    *PVE::SAN::Array::driver = sub { $drv };
    *PVE::SAN::Array::config = sub { { type => 'fake' } };
    *PVE::SAN::Array::hostcluster = sub { 'pvedr' };
    *PVE::SAN::Cluster::nodes = sub { [ 'n1', 'n2' ] };
    *PVE::SAN::Cluster::offline_nodes = sub { [] };
    *PVE::SAN::Cluster::local_node = sub { 'n1' };
    *PVE::SAN::Cluster::on_nodes = sub { push @log, "on_nodes $_[3]"; {} };
    *PVE::SAN::Cluster::guest_refs = sub {
        $_[0] eq 'gold' ? [ { vmid => 101, node => 'n1', type => 'qemu', file => '/etc/pve/nodes/n1/qemu-server/101.conf' },
            { vmid => 102, node => 'n2', type => 'qemu', file => '/etc/pve/nodes/n2/qemu-server/102.conf' } ] : [] };
    *PVE::SAN::Cluster::guest_status = sub {
        my %res = %foreign;
        for my $f (keys %files) {
            my ($n, $k, $id) = $f =~ m{^/etc/pve/nodes/([^/]+)/(qemu-server|lxc)/(\d+)\.conf$} or next;
            $res{$id} = { node => $n, type => ($k eq 'lxc' ? 'lxc' : 'qemu'), status => $guests{$id} // 'stopped' };
        }
        return \%res;
    };
    *PVE::SAN::Cluster::running_guests = sub { [ map { "$_ (n1)" } grep { ($guests{$_} // '') eq 'running' } sort keys %guests ] };
    *PVE::SAN::Provision::wait_visible = sub { push @log, "visible $_[1]" };
    *PVE::SAN::Provision::destroy = sub { my (%p) = @_; push @destroyed, $p{storage} };
    *PVE::SAN::Datastore::register_devices = sub { push @log, "register $_[1] @{$_[2]}"; [ map { "/dev/mapper/d$_" } 0 .. $#{$_[2]} ] };
    *PVE::SAN::Datastore::storage = sub { { vgname => "san_$_[0]", type => 'fcsan', 'fc-wwids' => '3600cc01' } };
    *PVE::SAN::Datastore::storage_nodes = sub { [ 'n1', 'n2' ] };
    *PVE::SAN::Datastore::unmount = sub { my (%p) = @_; push @log, "unmount $p{storage}" };
    *PVE::SAN::Datastore::device_detach = sub { my (%p) = @_; push @detached, $p{wwid} };
    *PVE::SAN::LVM::vgs = sub { {} };
    *PVE::SAN::LVM::lvs = sub { [ { lv_name => 'vm-101-disk-0' }, { lv_name => 'vm-102-disk-0' }, { lv_name => $PVE::SAN::DR::META_LV } ] };
    *PVE::SAN::LVM::devicesfile_enabled = sub { 0 };
    *PVE::SAN::LVM::vg_deactivate = sub { push @log, "deactivate $_[0]" };
    *PVE::SAN::DR::run_cmd = sub {
        my ($cmd) = @_;
        push @cmds, join(' ', @$cmd);
        if ($cmd->[0] eq 'pvesh' && $cmd->[2] =~ m{/(\d+)/status/(\w+)$}) {
            my ($vmid, $what) = ($1, $2);
            push @actions, "$what $vmid";
            $guests{$vmid} = 'stopped' if $what eq 'shutdown' || $what eq 'stop';
            $guests{$vmid} = 'running' if $what eq 'start';
        }
        '';
    };
    *PVE::SAN::DR::meta_path = sub { $metafile };
    *PVE::SAN::DR::pause = sub { };
    *PVE::SAN::DR::remove_config = sub { delete $files{$_[0]} };
    *PVE::Storage::Plugin::cluster_lock_storage = sub { my ($class, $id, $shared, $t, $code) = @_; $code->() };
    *PVE::Tools::file_get_contents = sub { $files{$_[0]} // die "no file $_[0]\n" };
    *PVE::Tools::file_set_contents = sub { $files{$_[0]} = $_[1] };
    *PVE::Tools::split_list = sub { grep { length } split(/[\s,;]+/, $_[0] // '') };
    *PVE::Storage::config = sub { { ids => { %storage_ids } } };
    *PVE::API2::Storage::Config::create = sub { push @storage_created, $_[1] };
    *PVE::API2::Storage::Config::delete = sub { push @storage_deleted, $_[1]->{storage} };
}
$files{'/etc/pve/nodes/n1/qemu-server/101.conf'} = $vm;
$files{'/etc/pve/nodes/n2/qemu-server/102.conf'} = "name: db\nscsi0: gold:vm-102-disk-0,size=8G\nnet0: virtio=BC:24:11:01:02:03,bridge=vmbr0\n\n[snap1]\nscsi0: gold:vm-102-disk-0\n";

open(my $out, '>', \my $printed);
my $old = select($out);

# primary site
eval { PVE::SAN::DR::enable(storage => 'gold', partner => 'dr', interval => 60, retain => 1) };
like($@, qr/at least two intervals/, 'retention shorter than two intervals refused');
PVE::SAN::DR::enable(storage => 'gold', partner => 'dr', interval => 15, retain => 24);
is_deeply($drv->{enabled}, [ [ 'v1' ], 'dr', 900, 86400 ], 'driver asked to replicate the volumes');
is($cfg->{datastores}->{gold}->{replication}->{partner}, 'dr', 'replication recorded');
ok($cfg->{datastores}->{gold}->{dr_meta}, 'metadata refresh switched on');
ok($cfg->{datastores}->{gold}->{drmeta_state}->{last}, 'metadata written at once');
ok((grep { /^lvchange -ay san_gold\/pvesan-dr-meta$/ } @cmds), 'metadata LV activated to write');
ok((grep { /^lvchange -an san_gold\/pvesan-dr-meta$/ } @cmds), 'and deactivated afterwards');

my ($idx, $cur) = PVE::SAN::DR::meta_pick(PVE::SAN::DR::read_slots($metafile));
is($cur->{gen}, 1, 'first generation in slot 0');
is($idx, 0, 'slot 0 written first');
is_deeply([ map { $_->{vmid} } @{$cur->{data}->{guests}} ], [ 101, 102 ], 'both guests\' configs on the datastore');
unlike($cur->{data}->{guests}->[1]->{config}, qr/snap1/, 'snapshot sections not carried');
ok($cur->{data}->{guests}->[1]->{snapshots}, 'but the snapshot is noted');
is_deeply($cur->{data}->{plan}, [ { vmid => 101, delay => 30 } ], 'recovery plan carried');

PVE::SAN::DR::write_meta(storage => 'gold');
($idx, $cur) = PVE::SAN::DR::meta_pick(PVE::SAN::DR::read_slots($metafile));
is_deeply([ $idx, $cur->{gen} ], [ 1, 2 ], 'slots alternate');

my $plan = PVE::SAN::DR::set_plan(storage => 'gold', order => '102:10,101');
is_deeply([ map { "$_->{order}:$_->{vmid}:$_->{delay}" } @$plan ], [ '1:102:10', '2:101:0' ], 'plan set');
eval { PVE::SAN::DR::set_plan(storage => 'gold', order => '999') };
like($@, qr/999 have no disks on 'gold'/, 'guest outside the datastore refused');

my $name = PVE::SAN::DR::replicate(storage => 'gold', name => 'dr-manual', wait => 1);
is($name, 'dr-manual', 'replica sent');
is($drv->{sent}->[-1], 'dr-manual', 'driver sent it');
my $st = PVE::SAN::DR::status(storage => 'gold');
is($st->{'last-replica'}, 'dr-manual', 'status: newest replica');
is($st->{plan}, '102:10,101', 'status: plan');

eval { PVE::SAN::DR::prepare_failover(storage => 'gold', confirm => 'nope') };
like($@, qr/confirm with the datastore's ID/, 'planned failover needs confirmation');
eval { PVE::SAN::DR::prepare_failover(storage => 'gold', confirm => 'gold') };
like($@, qr/still running: 101/, 'running guests block a planned failover');
@actions = ();
my $final = PVE::SAN::DR::prepare_failover(storage => 'gold', confirm => 'gold', shutdown => 1);
is_deeply(\@actions, [ 'shutdown 101' ], 'running guest shut down');
like($final, qr/^dr-final-/, 'final replica named');
ok((grep { $_ eq 'unmount gold' } @log), 'datastore unmounted before the final replica');

# DR site: test failover
@cmds = (); @log = ();
$cfg->{datastores} = {};
my $list = PVE::SAN::DR::replica_list(array => 'dr');
is_deeply([ $list->[0]->{replica}, $list->[0]->{storage}, $list->[0]->{latest} ], [ 'src:pvesan-gold', 'gold', 'dr-1' ], 'replicas listed');

# the DR cluster has none of the primary's guest configs
delete $files{$_} for grep { m{/qemu-server/} } keys %files;
%guests = ();
%foreign = (101 => { status => 'running', node => 'n2', type => 'qemu' }); # a local guest holds ID 101
eval { PVE::SAN::DR::from_replica(mode => 'test', array => 'dr', replica => 'src:pvesan-gold') };
like($@, qr/VM ID\(s\) 101 are already used/, 'ID clash refused');
is_deeply($drv->{unmaps}, [ $drv->{maps}->[0] ], 'copy unmapped again after the failure');
is(scalar(@{$drv->{vol_deleted}}), 1, 'and deleted');
ok(!$cfg->{datastores}->{'gold-drtest'}, 'nothing recorded');

$drv->{maps} = [];
%foreign = ();
@cmds = ();
my $sid = PVE::SAN::DR::from_replica(mode => 'test', array => 'dr', replica => 'src:pvesan-gold', vmid_offset => 10000, start => 1);
is($sid, 'gold-drtest', 'test copy named');
like($drv->{clones}->[-1]->[1], qr/^gold-drtest-\d{12}$/, 'replica copied to a new volume');
is($drv->{clones}->[-1]->[0], 'src:pvesan-gold.dr-1.gold', 'from the newest replica snapshot');
ok((grep { /^vgimportclone --basevgname san_gold-drtest/ } @cmds), 'volume group imported under the test name');
ok((grep { $_ eq 'lvrename san_gold-drtest vm-101-disk-0 vm-10101-disk-0' } @cmds), 'disks renamed to the new IDs');
is($storage_created[-1]->{storage}, 'gold-drtest', 'test datastore registered');
my $conf = $files{'/etc/pve/nodes/n1/qemu-server/10101.conf'};
like($conf, qr/^scsi0: gold-drtest:vm-10101-disk-0/m, 'test VM points at the copy');
like($conf, qr/link_down=1/, 'test VM isolated');
ok($files{'/etc/pve/nodes/n1/qemu-server/10102.conf'}, 'second guest created');
my $rec = $cfg->{datastores}->{'gold-drtest'};
is($rec->{dr_import}->{mode}, 'test', 'import recorded as a test');
is_deeply($rec->{dr_test_plan}, [ { vmid => 10102, delay => 10 }, { vmid => 10101, delay => 0 } ], 'plan mapped to the new IDs');
ok(!$rec->{dr_plan}, 'a test copy is not a protected datastore');
is_deeply([ grep { /^start/ } @actions ], [ 'start 10102', 'start 10101' ], 'guests started in plan order');

eval { PVE::SAN::DR::cleanup(storage => 'gold') };
like($@, qr/not brought up by pvesan dr/, 'cleanup only for DR imports');
PVE::SAN::DR::cleanup(storage => 'gold-drtest');
ok(!exists $files{'/etc/pve/nodes/n1/qemu-server/10101.conf'} && !exists $files{'/etc/pve/nodes/n1/qemu-server/10102.conf'},
    'test guests removed');
ok((grep { $_ eq 'stop 10101' } @actions), 'running test guest stopped');
is_deeply(\@destroyed, [ 'gold-drtest' ], 'test datastore and its array copies removed');

# failover
$cfg->{datastores} = {};
delete $storage_ids{gold}; # this site has no datastore of that name yet
%guests = ();
eval { PVE::SAN::DR::from_replica(mode => 'failover', array => 'dr', replica => 'src:pvesan-gold') };
is($@, '', 'failover ran');
my $fo = $files{'/etc/pve/nodes/n1/qemu-server/101.conf'};
like($fo, qr/^scsi0: gold:vm-101-disk-0/m, 'failed-over VM keeps its storage ID and disk');
like($fo, qr/^net0: virtio=BC:24:11:AA:BB:CC,bridge=vmbr0,firewall=1$/m, 'and its MAC');
is_deeply($cfg->{datastores}->{gold}->{dr_plan}, [ { vmid => 102, delay => 10 }, { vmid => 101, delay => 0 } ],
    'the failed-over datastore carries the plan for failing back');
ok($cfg->{datastores}->{gold}->{array}, 'and is linked to the DR array for replicating back');
eval { PVE::SAN::DR::cleanup(storage => 'gold') };
like($@, qr/production now/, 'a failover is not cleaned up like a test');

# manual import of promoted LUNs (any array)
$cfg->{datastores} = {};
%guests = ();
my $m = PVE::SAN::DR::import_luns(storage => 'silver', wwids => [ '3600cc01' ], mode => 'test', vmid_offset => 500);
is($m, 'silver', 'manual import');
ok(!$cfg->{datastores}->{silver}->{array}, 'no array recorded');
PVE::SAN::DR::cleanup(storage => 'silver');
is_deeply(\@detached, [ '3600cc01' ], 'manual test import released, LUN data left alone');
is($storage_deleted[-1], 'silver', 'storage definition removed');

select($old);

done_testing();
