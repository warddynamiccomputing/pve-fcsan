package PVE::Storage::Custom::FCSANVolPlugin;

# Storage type 'fcsanvol': every VM disk is its own array volume (the vVols
# equivalent). Disks are thin on the array; snapshots, rollback, templates
# and clones are array operations; resize is an array expand. The work is
# done in PVE::SAN::Volume; this class maps the storage plugin API onto it.
#
# Needs an array driver with supports_disk_volumes (Pure FlashArray so far).
# Raw disks only; containers are not supported.

use strict;
use warnings;

use PVE::Storage::Plugin;

use PVE::SAN::Volume;

use base qw(PVE::Storage::Plugin);

# like rbd: the same volume is reachable from every node
push @PVE::Storage::Plugin::SHARED_STORAGE, 'fcsanvol'
    if !grep { $_ eq 'fcsanvol' } @PVE::Storage::Plugin::SHARED_STORAGE;

sub api {
    return PVE::Storage::APIVER();
}

sub type {
    return 'fcsanvol';
}

sub plugindata {
    return {
        content => [ { images => 1 }, { images => 1 } ],
        format => [ { raw => 1 }, 'raw' ],
    };
}

sub properties {
    return {
        'fc-array' => {
            description => "pvesan array ID the disk volumes are created on.",
            type => 'string',
            pattern => '[a-z][a-z0-9_-]{0,31}',
        },
        'fc-pool' => {
            description => "Array pool for new disk volumes ('default' on Pure FlashArray).",
            type => 'string',
            maxLength => 65,
        },
        'fc-max-luns' => {
            description => "Most disk volumes this storage may hold. Every disk is a LUN on every node, and arrays and HBAs limit LUNs per host.",
            type => 'integer',
            minimum => 1,
            maximum => 16383,
            default => 255,
        },
    };
}

sub options {
    return {
        'fc-array' => { fixed => 1 },
        'fc-pool' => {},
        'fc-max-luns' => { optional => 1 },
        nodes => { optional => 1 },
        disable => { optional => 1 },
        content => { optional => 1 },
        bwlimit => { optional => 1 },
    };
}

sub parse_volname {
    my ($class, $volname) = @_;
    my ($name, $vmid, $isbase) = PVE::SAN::Volume::parse_volname($volname);
    return ('images', $name, $vmid, undef, undef, $isbase, 'raw');
}

sub path {
    my ($class, $scfg, $volname, $storeid, $snapname) = @_;
    die "array snapshots of '$volname' can't be attached directly - clone them\n" if $snapname;
    my ($name, $vmid) = PVE::SAN::Volume::parse_volname($volname);
    return wantarray ? (PVE::SAN::Volume::path_for($storeid, $volname), $vmid, 'images')
        : PVE::SAN::Volume::path_for($storeid, $volname);
}

sub filesystem_path {
    my ($class, $scfg, $volname, $snapname) = @_;
    die "filesystem_path is not supported for fcsanvol\n";
}

sub alloc_image {
    my ($class, $storeid, $scfg, $vmid, $fmt, $name, $size) = @_;
    die "unsupported format '$fmt' - fcsanvol stores raw disks only\n" if $fmt && $fmt ne 'raw';
    return PVE::SAN::Volume::alloc($storeid, $scfg, $vmid, $name, $size);
}

sub free_image {
    my ($class, $storeid, $scfg, $volname, $isBase, $format) = @_;
    return PVE::SAN::Volume::free($storeid, $scfg, $volname);
}

sub list_images {
    my ($class, $storeid, $scfg, $vmid, $vollist, $cache) = @_;
    return PVE::SAN::Volume::list($storeid, $scfg, $vmid, $vollist);
}

sub status {
    my ($class, $storeid, $scfg, $cache) = @_;
    return PVE::SAN::Volume::status($storeid, $scfg);
}

sub activate_storage {
    my ($class, $storeid, $scfg, $cache) = @_;
    return 1;
}

sub deactivate_storage {
    my ($class, $storeid, $scfg, $cache) = @_;
    return 1;
}

sub check_connection {
    my ($class, $storeid, $scfg) = @_;
    return 1;
}

sub activate_volume {
    my ($class, $storeid, $scfg, $volname, $snapname, $cache, $hints) = @_;
    die "array snapshots can't be activated directly\n" if $snapname;
    PVE::SAN::Volume::activate($storeid, $scfg, $volname);
    return 1;
}

# The LUN stays visible; the next activation on this node is instant.
sub deactivate_volume {
    my ($class, $storeid, $scfg, $volname, $snapname, $cache) = @_;
    return 1;
}

sub volume_size_info {
    my ($class, $scfg, $storeid, $volname, $timeout) = @_;
    my $size = PVE::SAN::Volume::size($storeid, $scfg, $volname);
    return wantarray ? ($size, 'raw', $size, undef) : $size;
}

sub volume_resize {
    my ($class, $scfg, $storeid, $volname, $size, $running) = @_;
    return PVE::SAN::Volume::resize($storeid, $scfg, $volname, $size);
}

sub volume_snapshot {
    my ($class, $scfg, $storeid, $volname, $snap) = @_;
    return PVE::SAN::Volume::snapshot($storeid, $scfg, $volname, $snap);
}

sub volume_snapshot_rollback {
    my ($class, $scfg, $storeid, $volname, $snap) = @_;
    return PVE::SAN::Volume::snapshot_rollback($storeid, $scfg, $volname, $snap);
}

sub volume_rollback_is_possible {
    my ($class, $scfg, $storeid, $volname, $snap, $blockers) = @_;
    return 1; # array snapshots are independent; any one can be restored
}

sub volume_snapshot_delete {
    my ($class, $scfg, $storeid, $volname, $snap, $running) = @_;
    return PVE::SAN::Volume::snapshot_delete($storeid, $scfg, $volname, $snap);
}

sub volume_snapshot_needs_fsfreeze {
    return 1;
}

sub create_base {
    my ($class, $storeid, $scfg, $volname) = @_;
    return PVE::SAN::Volume::create_base($storeid, $scfg, $volname);
}

sub clone_image {
    my ($class, $scfg, $storeid, $volname, $vmid, $snap) = @_;
    return PVE::SAN::Volume::clone($storeid, $scfg, $volname, $vmid, $snap);
}

sub volume_has_feature {
    my ($class, $scfg, $feature, $storeid, $volname, $snapname, $running, $opts) = @_;
    my $features = {
        snapshot => { current => 1 },
        clone => { base => 1, snap => 1 },
        template => { current => 1 },
        copy => { base => 1, current => 1 },
        sparseinit => { base => 1, current => 1 },
    };
    my (undef, undef, $isbase) = PVE::SAN::Volume::parse_volname($volname);
    my $key = $snapname ? 'snap' : $isbase ? 'base' : 'current';
    return $features->{$feature}->{$key} ? 1 : undef;
}

sub rename_volume {
    die "renaming fcsanvol volumes is not supported yet\n";
}

1;
