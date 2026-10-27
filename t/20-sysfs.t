use strict;
use warnings;

use Test::More;

use SanFixture;

BEGIN { $ENV{PVESAN_SYSFS_ROOT} = SanFixture::build(); }

use PVE::SAN::Sysfs;

my $hosts = PVE::SAN::Sysfs::fc_hosts();
is(scalar(@$hosts), 2, 'two FC hosts');
my ($h1) = grep { $_->{name} eq 'host1' } @$hosts;
is($h1->{wwpn}, '21:00:00:24:ff:3d:5e:10', 'host1 WWPN');
is($h1->{driver}, 'qla2xxx', 'driver from scsi_host');
is($h1->{model}, 'QLE2692', 'model from model_name');
is($h1->{targets}, 2, 'two online FCP targets');
is($h1->{link_failures}, 2, 'hex counter decoded');
is($h1->{fabric}, '10:00:00:05:1e:90:a2:b1', 'fabric name');

my $iscsi = PVE::SAN::Sysfs::iscsi_hosts();
is(scalar(@$iscsi), 1, 'one iSCSI host');
is($iscsi->[0]->{host}, 3, 'iSCSI host number survives attribute reads');
is($iscsi->[0]->{wwpn}, 'iqn.1993-08.org.debian:01:pve1', 'initiator IQN');

my $disks = PVE::SAN::Sysfs::scsi_disks();
is(scalar(@$disks), 8, 'eight SCSI disk paths');
my ($sda) = grep { $_->{dev} eq 'sda' } @$disks;
is($sda->{transport}, 'local', 'AHCI disk is local');
is($sda->{wwid}, undef, 't10 id left for scsi_id');
my ($sdc) = grep { $_->{dev} eq 'sdc' } @$disks;
is($sdc->{transport}, 'fc', 'FC path');
is($sdc->{lun}, 1, 'LUN number');
is($sdc->{target_wwpn}, '21:10:d0:39:ea:0a:3b:1c', 'target WWPN via fc_transport');
is($sdc->{wwid}, $SanFixture::LUN_A, 'naa id normalized');
my ($sdh) = grep { $_->{dev} eq 'sdh' } @$disks;
ok($sdh->{pseudo}, 'access LUN flagged as pseudo');

my $maps = PVE::SAN::Sysfs::multipath_maps();
is(scalar(@$maps), 1, 'one multipath map');
is($maps->[0]->{name}, 'ds1', 'map alias');
is($maps->[0]->{wwid}, $SanFixture::LUN_A, 'map WWID survives attribute reads');
is_deeply($maps->[0]->{slaves}, [qw(sdb sdc sdd sde)], 'map slaves');
ok($maps->[0]->{discard}, 'discard supported');

my $states = {
    sdb => { dm_state => 'active', chk_state => 'ready' },
    sdc => { dm_state => 'active', chk_state => 'ready' },
    sdd => { dm_state => 'active', chk_state => 'ghost' },
    sde => { dm_state => 'active', chk_state => 'ghost' },
};
my $devices = PVE::SAN::Sysfs::build_devices($disks, $maps, $states);
my ($lun_a) = grep { $_->{wwid} eq $SanFixture::LUN_A } @$devices;
my ($lun_b) = grep { $_->{wwid} eq $SanFixture::LUN_B } @$devices;

is($lun_a->{map}, 'ds1', 'LUN A has its map');
is($lun_a->{paths_total}, 4, 'LUN A paths');
is($lun_a->{paths_active}, 4, 'ALUA standby (ghost) paths count as healthy');
is($lun_a->{status}, 'ok', 'LUN A ok');
is($lun_a->{size}, 1073741824, 'LUN A size in bytes');
is($lun_a->{resize_pending}, 0, 'no resize pending');
is_deeply($lun_a->{holders}, ['dm-1'], 'map holders reported');

is($lun_b->{map}, undef, 'LUN B not multipathed');
is($lun_b->{paths_active}, 1, 'offline path not active');
is($lun_b->{status}, 'degraded', 'LUN B degraded');

# grow LUN A on the array: paths report 2 GiB, map still 1 GiB
SanFixture::put($ENV{PVESAN_SYSFS_ROOT}, "/sys/block/$_/size", 4194304) for qw(sdb sdc sdd sde);
$devices = PVE::SAN::Sysfs::build_devices(PVE::SAN::Sysfs::scsi_disks(), PVE::SAN::Sysfs::multipath_maps(), $states);
($lun_a) = grep { $_->{wwid} eq $SanFixture::LUN_A } @$devices;
is($lun_a->{resize_pending}, 1, 'grown LUN flagged for map resize');

ok(!PVE::SAN::Sysfs::path_is_active({ state => 'running', chk_state => 'faulty' }), 'faulty checker');
ok(PVE::SAN::Sysfs::path_is_active({ state => 'running' }), 'no multipathd info: SCSI state decides');

done_testing();
