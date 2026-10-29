package PVE::Storage::Custom::FCSANPlugin;

# Storage type 'fcsan': a shared thick-LVM volume group on multipathed
# Fibre Channel (or iSCSI) LUNs.
#
# All volume handling (alloc, free, resize, snapshots via volume chains on
# PVE 9, ...) is inherited unchanged from the built-in LVM plugin. This class
# only adds the binding to the backing LUN WWIDs, makes activation check
# for, and if needed rescan for, missing LUNs, and can discard removed
# volumes (fc-discard).

use strict;
use warnings;

use PVE::Storage::LVMPlugin;
use PVE::Tools;

use PVE::SAN::Multipath;
use PVE::SAN::Util;

use base qw(PVE::Storage::LVMPlugin);

my $RESCAN_STAMP_DIR = '/run/pvesan';
my $RESCAN_INTERVAL = 300; # seconds between automatic rescans per storage

# Every method we override has kept its signature since APIVER 9, and every
# other method comes from the running LVMPlugin, so we are compatible with
# whatever storage API version is installed.
sub api {
    return PVE::Storage::APIVER();
}

sub type {
    return 'fcsan';
}

sub plugindata {
    return PVE::Storage::LVMPlugin->plugindata();
}

sub properties {
    return {
        'fc-wwids' => {
            description => "Comma separated SCSI WWIDs of the LUNs backing this datastore.",
            type => 'string',
            pattern => '[0-9A-Za-z][0-9A-Za-z_.:-]*(?:,[0-9A-Za-z][0-9A-Za-z_.:-]*)*',
            maxLength => 4096,
        },
        'fc-autorescan' => {
            description => "Rescan SAN adapters on activation when a backing LUN is missing.",
            type => 'boolean',
            default => 1,
        },
        'fc-discard' => {
            description => "Discard (UNMAP) a volume's blocks before it is removed, so a thin array frees the space at once. Slows deletes; ignored with 'saferemove'.",
            type => 'boolean',
            default => 0,
        },
    };
}

sub options {
    my $opts = { %{PVE::Storage::LVMPlugin->options()} };
    delete $opts->{base}; # LVM-on-iSCSI base volumes do not apply
    $opts->{shared} //= { optional => 1 };
    $opts->{'fc-wwids'} = { optional => 1 };
    $opts->{'fc-autorescan'} = { optional => 1 };
    $opts->{'fc-discard'} = { optional => 1 };
    return $opts;
}

sub missing_luns {
    my ($scfg) = @_;
    my $wwids = PVE::SAN::Util::parse_wwid_list($scfg->{'fc-wwids'} // '');
    return [ grep { !PVE::SAN::Multipath::map_for_wwid($_) } @$wwids ];
}

# pvestatd activates storages every few seconds, so a LUN that is gone for
# good must not trigger a rescan each time.
sub rescan_allowed {
    my ($storeid) = @_;
    mkdir($RESCAN_STAMP_DIR) if ! -d $RESCAN_STAMP_DIR;
    my $stamp = "$RESCAN_STAMP_DIR/rescan-$storeid";
    my $mtime = (stat($stamp))[9];
    return 0 if $mtime && time() - $mtime < $RESCAN_INTERVAL;
    if (open(my $fh, '>', $stamp)) {
        close($fh);
    }
    return 1;
}

sub activate_storage {
    my ($class, $storeid, $scfg, $cache) = @_;

    if ($scfg->{'fc-wwids'}) {
        my $missing = missing_luns($scfg);
        if (@$missing && ($scfg->{'fc-autorescan'} // 1) && rescan_allowed($storeid)) {
            warn "storage '$storeid': LUN(s) @$missing missing, rescanning SAN adapters\n";
            eval {
                require PVE::SAN::Ops;
                PVE::SAN::Ops::rescan(resize => 0);
                PVE::SAN::Ops::sync();
            };
            warn "storage '$storeid': rescan failed - $@" if $@;
            $missing = missing_luns($scfg);
        }
        die "storage '$storeid': backing LUN(s) not present on this node: @$missing\n" if @$missing;
    }

    return $class->SUPER::activate_storage($storeid, $scfg, $cache);
}

# Opt-in discard of a removed volume (fc-discard). With saferemove PVE
# already wipes the volume, so nothing is added then. A discard that fails
# (LUN without UNMAP) only warns; the removal goes on.
sub free_image {
    my ($class, $storeid, $scfg, $volname, $isBase, $format) = @_;

    if ($scfg->{'fc-discard'} && !$scfg->{saferemove} && $volname =~ m/^[A-Za-z0-9_.+-]+$/) {
        my $lv = "$scfg->{vgname}/$volname";
        eval {
            PVE::Tools::run_command(['lvchange', '-ay', $lv]);
            PVE::Tools::run_command(['blkdiscard', "/dev/$lv"], timeout => 3600);
        };
        warn "storage '$storeid': discard of $volname failed - $@" if $@;
    }
    return $class->SUPER::free_image($storeid, $scfg, $volname, $isBase, $format);
}

1;
