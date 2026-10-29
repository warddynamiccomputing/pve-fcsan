package PVE::SAN::Ops;

# Node-local operations. Each runs on exactly one node; PVE::SAN::Datastore
# fans them out over the cluster through the API.

use strict;
use warnings;

use PVE::SAN::Config;
use PVE::SAN::LVM;
use PVE::SAN::Multipath;
use PVE::SAN::Sysfs;
use PVE::SAN::Util qw(write_attr read_attr run_cmd);

my $SAN = { fc => 1, iscsi => 1 };

sub settle {
    run_cmd(['udevadm', 'settle', '--timeout=30'], noerr => 1, timeout => 40);
}

sub path_snapshot {
    return { map { $_->{dev} => $_ } grep { $SAN->{$_->{transport}} } @{PVE::SAN::Sysfs::scsi_disks()} };
}

# A FC LIP makes the HBA log in to the fabric again. It briefly interrupts
# I/O on that port, so it is only done when asked for, one port at a time.
sub issue_lip {
    my ($host) = @_;

    print "issuing LIP on $host->{name}\n";
    write_attr("/sys/class/fc_host/$host->{name}/issue_lip", "1");
    for (1 .. 60) {
        select(undef, undef, undef, 0.5);
        last if (read_attr("/sys/class/fc_host/$host->{name}/port_state") // '') eq 'Online';
    }
}

# Remove the SCSI paths of a device (sdX). The kernel flushes and detaches.
sub delete_path {
    my ($dev) = @_;
    print "removing SCSI path $dev\n";
    write_attr("/sys/block/$dev/device/delete", "1");
}

# vCenter "Rescan Storage": find new LUNs and paths, pick up LUN size
# changes, keep detached devices away, resize multipath maps that grew.
sub rescan {
    my (%opts) = @_;

    my $resize = $opts{resize} // 1;
    my $before = path_snapshot();

    my $fc = PVE::SAN::Sysfs::fc_hosts();
    if ($opts{lip}) {
        issue_lip($_) for grep { ($_->{state} // '') eq 'Online' } @$fc;
    }

    for my $h (@$fc, @{PVE::SAN::Sysfs::iscsi_hosts()}) {
        eval { write_attr("/sys/class/scsi_host/$h->{name}/scan", "- - -") };
        warn "scan of $h->{name} failed: $@" if $@;
    }

    if ($resize) {
        for my $p (values %$before) {
            eval { write_attr("/sys/class/scsi_device/$p->{hctl}/device/rescan", "1") };
        }
    }
    settle();

    # detached devices stay detached even if the array still presents them
    my $cfg = PVE::SAN::Config::load();
    my $after = path_snapshot();
    my @suppressed;
    for my $p (values %$after) {
        my $wwid = $p->{wwid} // next;
        next if !$cfg->{devices}->{$wwid}->{detached};
        eval { delete_path($p->{dev}) };
        push @suppressed, $p->{dev} if !$@;
    }
    settle() if @suppressed;
    $after = path_snapshot();

    my @resized;
    my $maps = PVE::SAN::Sysfs::multipath_maps();
    for my $map (@$maps) {
        my $largest = 0;
        for my $s (@{$map->{slaves}}) {
            $largest = $after->{$s}->{size} if $after->{$s} && $after->{$s}->{size} > $largest;
        }
        next if $largest <= $map->{size};
        eval { PVE::SAN::Multipath::resize_map($map->{name}) };
        if ($@) {
            warn "resize of map $map->{name} failed: $@";
        } else {
            push @resized, $map->{name};
        }
    }

    my @new = sort grep { !$before->{$_} } keys %$after;
    my %suppressed = map { $_ => 1 } @suppressed;
    my @gone = sort grep { !$after->{$_} && !$suppressed{$_} } keys %$before;
    my %new_wwids = map { ($after->{$_}->{wwid} // $_) => 1 } @new;
    my %old_wwids = map { ($before->{$_}->{wwid} // $_) => 1 } keys %$before;

    return {
        paths => scalar(keys %$after),
        new_paths => \@new,
        removed_paths => \@gone,
        new_devices => [ sort grep { !$old_wwids{$_} } keys %new_wwids ],
        resized_maps => \@resized,
        suppressed_paths => \@suppressed,
    };
}

# Scan one LUN number on every FC/iSCSI host instead of the whole fabric
# ("- - <lun>": all channels and targets, that LUN only). Used when a VM disk
# volume is activated, so a node with hundreds of LUNs is not rescanned.
sub rescan_lun {
    my ($lun) = @_;
    die "invalid LUN number '$lun'\n" if !defined($lun) || $lun !~ /^\d+$/;
    for my $h (@{PVE::SAN::Sysfs::fc_hosts()}, @{PVE::SAN::Sysfs::iscsi_hosts()}) {
        eval { write_attr("/sys/class/scsi_host/$h->{name}/scan", "- - $lun") };
        warn "scan of LUN $lun on $h->{name} failed: $@" if $@;
    }
    settle();
}

# Bring local multipath/LVM configuration in line with the cluster config.
sub sync {
    my $cfg = PVE::SAN::Config::load();
    my $devices = $cfg->{devices};

    my $changed = PVE::SAN::Multipath::write_conf(PVE::SAN::Multipath::render_conf($devices));

    my $claimed = PVE::SAN::Multipath::claimed_wwids();
    for my $wwid (sort keys %$devices) {
        if ($devices->{$wwid}->{detached}) {
            if ($claimed->{$wwid}) {
                PVE::SAN::Multipath::unclaim_wwid($wwid);
                $changed = 1;
            }
        } elsif (!$claimed->{$wwid}) {
            PVE::SAN::Multipath::claim_wwid($wwid);
            $changed = 1;
        }
    }

    PVE::SAN::Multipath::reconfigure() if $changed;

    # only wait for maps of LUNs this node actually has paths to
    my %visible = map { $_->{wwid} => 1 } grep { $_->{wwid} } @{PVE::SAN::Sysfs::scsi_disks()};

    my (@present, @missing);
    for my $wwid (sort grep { !$devices->{$_}->{detached} } keys %$devices) {
        my $name = ($changed && $visible{$wwid}) ? PVE::SAN::Multipath::wait_for_map($wwid, 20)
            : PVE::SAN::Multipath::map_for_wwid($wwid);
        if ($name) {
            push @present, $name;
        } else {
            push @missing, $wwid;
        }
    }

    if (@present && PVE::SAN::LVM::devicesfile_enabled()) {
        PVE::SAN::LVM::devicesfile_add("/dev/mapper/$_") for @present;
    }

    return { changed => $changed ? 1 : 0, maps => \@present, missing => \@missing };
}

# Re-read the size of one LUN on every path and resize its map.
sub refresh_device {
    my ($wwid) = @_;

    my ($map) = grep { $_->{wwid} eq $wwid } @{PVE::SAN::Sysfs::multipath_maps()};
    die "no multipath map for '$wwid' on this node\n" if !$map;

    for my $s (@{$map->{slaves}}) {
        write_attr("/sys/block/$s/device/rescan", "1");
    }
    settle();
    PVE::SAN::Multipath::resize_map($map->{name});
    ($map) = grep { $_->{wwid} eq $wwid } @{PVE::SAN::Sysfs::multipath_maps()};
    return { map => $map->{name}, size => $map->{size} };
}

# Remove the device from this node: flush the map, delete every path.
sub detach_device {
    my ($wwid) = @_;

    my ($map) = grep { $_->{wwid} eq $wwid } @{PVE::SAN::Sysfs::multipath_maps()};
    my @paths = grep { ($_->{wwid} // '') eq $wwid } @{PVE::SAN::Sysfs::scsi_disks()};

    if ($map) {
        die "device $map->{name} is in use by: @{$map->{holders}}\n" if @{$map->{holders}};
        push @paths, map { { dev => $_ } } @{$map->{slaves}};
        print "flushing multipath map $map->{name}\n";
        PVE::SAN::Multipath::flush_map($map->{name});
    }

    my %seen;
    for my $p (grep { !$seen{$_->{dev}}++ } @paths) {
        my @holders = PVE::SAN::Util::list_dir("/sys/block/$p->{dev}/holders");
        die "path $p->{dev} is in use by: @holders\n" if @holders;
        delete_path($p->{dev});
    }
    settle();
    return { removed_paths => [ sort keys %seen ] };
}

# Remove paths whose LUN is gone (offline / failed checker), e.g. after the
# array stopped presenting a LUN. Maps that are still open are left alone.
sub cleanup_dead_paths {
    my $states = PVE::SAN::Multipath::path_states();
    my $disks = PVE::SAN::Sysfs::scsi_disks();
    my $maps = PVE::SAN::Sysfs::multipath_maps();
    my $devices = PVE::SAN::Sysfs::build_devices($disks, $maps, $states);

    my (@removed, @skipped);
    for my $d (@$devices) {
        next if !$SAN->{$d->{transport}};
        my @dead = grep { !PVE::SAN::Sysfs::path_is_active($_) } @{$d->{paths}};
        next if !@dead;

        if (@dead == @{$d->{paths}} && $d->{map}) {
            if (@{$d->{holders} // []}) {
                push @skipped, "$d->{map} (in use by @{$d->{holders}})";
                next;
            }
            eval { PVE::SAN::Multipath::flush_map($d->{map}) };
            if ($@) {
                push @skipped, "$d->{map} ($@)";
                next;
            }
        }
        for my $p (@dead) {
            eval { delete_path($p->{dev}) };
            push @removed, $p->{dev} if !$@;
        }
    }
    settle() if @removed;
    return { removed_paths => \@removed, skipped => \@skipped };
}

sub deactivate_vg {
    my ($vg) = @_;

    my $lvs = PVE::SAN::LVM::lvs($vg);
    my @open = map { $_->{lv_name} } grep { $_->{open} } @$lvs;
    die "volume group '$vg' has open volumes on this node: @open\n" if @open;
    PVE::SAN::LVM::vg_deactivate($vg) if grep { $_->{active} } @$lvs;
    return { vgname => $vg, deactivated => 1 };
}

1;
