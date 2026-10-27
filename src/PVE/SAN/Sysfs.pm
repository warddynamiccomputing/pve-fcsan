package PVE::SAN::Sysfs;

# Read-only discovery of HBAs, remote ports, SCSI paths and multipath maps
# from sysfs. Pure Perl: only directory listings and attribute reads, no
# symlink resolution, so a fixture tree made of plain directories works.

use strict;
use warnings;

use PVE::SAN::Util qw(read_attr first_attr list_dir fmt_wwn normalize_wwid);

# Array "access" or placeholder LUNs that are never real storage.
my $PSEUDO_MODELS = qr/^(?:Universal Xport|LUNZ|Access LUN)\b/i;

# host number => transport ('fc' or 'iscsi'); anything else is 'local'
sub host_transports {
    my $res = {};
    for my $h (list_dir('/sys/class/fc_host')) {
        $res->{$1} = 'fc' if $h =~ /^host(\d+)$/;
    }
    for my $h (list_dir('/sys/class/iscsi_host')) {
        $res->{$1} //= 'iscsi' if $h =~ /^host(\d+)$/;
    }
    return $res;
}

sub hex_counter {
    my ($value) = @_;
    return undef if !defined($value) || $value !~ /^(0x[0-9a-f]+|\d+)$/i;
    return $value =~ /^0x/i ? hex($value) : int($value);
}

sub remote_ports {
    my ($hostnum) = @_;

    my @ports;
    for my $rp (list_dir('/sys/class/fc_remote_ports')) {
        next if $rp !~ /^rport-(\d+):\d+-\d+$/ || $1 != $hostnum;
        my $dir = "/sys/class/fc_remote_ports/$rp";
        push @ports, {
            name => $rp,
            wwpn => fmt_wwn(read_attr("$dir/port_name")),
            wwnn => fmt_wwn(read_attr("$dir/node_name")),
            state => read_attr("$dir/port_state"),
            roles => read_attr("$dir/roles") // '',
        };
    }
    return \@ports;
}

# qla2xxx on recent kernels reports proc_name "(null)"; fall back to the
# PCI driver bound to the adapter.
sub driver_name {
    my ($host) = @_;

    my $name = read_attr("/sys/class/scsi_host/$host/proc_name");
    return $name if defined($name) && length($name) && $name ne '(null)';

    my $link = readlink(PVE::SAN::Util::sysfs_path("/sys/class/scsi_host/$host/device/../driver"));
    return $link =~ m|([^/]+)$| ? $1 : undef if defined($link);
    return undef;
}

sub fc_hosts {
    my @hosts;
    for my $h (list_dir('/sys/class/fc_host')) {
        next if $h !~ /^host(\d+)$/;
        my $num = int($1);
        my $fc = "/sys/class/fc_host/$h";
        my $sh = "/sys/class/scsi_host/$h";

        my $rports = remote_ports($num);
        my @targets = grep {
            ($_->{roles} =~ /FCP Target/) && (($_->{state} // '') eq 'Online')
        } @$rports;

        push @hosts, {
            name => $h,
            host => $num,
            transport => 'fc',
            wwpn => fmt_wwn(read_attr("$fc/port_name")),
            wwnn => fmt_wwn(read_attr("$fc/node_name")),
            state => read_attr("$fc/port_state"),
            port_type => read_attr("$fc/port_type"),
            port_id => read_attr("$fc/port_id"),
            speed => read_attr("$fc/speed"),
            supported_speeds => read_attr("$fc/supported_speeds"),
            fabric => fmt_wwn(read_attr("$fc/fabric_name")),
            symbolic_name => read_attr("$fc/symbolic_name"),
            driver => driver_name($h),
            model => first_attr($sh, qw(model_name modelname model_desc modeldesc)),
            firmware => first_attr($sh, qw(fw_version fwrev)),
            driver_version => first_attr($sh, qw(driver_version lpfc_drvr_version)),
            link_failures => hex_counter(read_attr("$fc/statistics/link_failure_count")),
            loss_of_sync => hex_counter(read_attr("$fc/statistics/loss_of_sync_count")),
            error_frames => hex_counter(read_attr("$fc/statistics/error_frames")),
            targets => scalar(@targets),
            remote_ports => $rports,
        };
    }
    return \@hosts;
}

sub iscsi_hosts {
    my @hosts;
    for my $h (list_dir('/sys/class/iscsi_host')) {
        next if $h !~ /^host(\d+)$/;
        my $num = int($1); # read_attr's regexes clobber $1
        my $dir = "/sys/class/iscsi_host/$h";
        my $iqn = read_attr("$dir/initiatorname");
        $iqn = undef if defined($iqn) && $iqn eq '(null)';
        push @hosts, {
            name => $h,
            host => $num,
            transport => 'iscsi',
            wwpn => $iqn,
            state => 'Online',
            driver => driver_name($h),
            ipaddress => read_attr("$dir/ipaddress"),
        };
    }
    return \@hosts;
}

# Linux SCSI sysfs exposes the designator as "naa.<hex>", multipath uses the
# scsi_id form. Vendor/t10 designators are left to the caller (scsi_id).
sub wwid_from_sysfs {
    my ($raw) = @_;
    return undef if !defined($raw) || $raw !~ /^(?:naa|eui)\./;
    return normalize_wwid($raw);
}

# One entry per SCSI disk path (sdX).
sub scsi_disks {
    my $transports = host_transports();

    my @disks;
    for my $hctl (list_dir('/sys/class/scsi_device')) {
        my ($h, $c, $t, $l) = $hctl =~ /^(\d+):(\d+):(\d+):(\d+)$/ or next;
        my $dev = "/sys/class/scsi_device/$hctl/device";

        my $type = read_attr("$dev/type");
        next if !defined($type) || $type ne '0'; # TYPE_DISK only

        my ($block) = list_dir("$dev/block");
        next if !$block;

        my $model = read_attr("$dev/model") // '';
        my $sectors = read_attr("/sys/block/$block/size") // 0;

        push @disks, {
            dev => $block,
            hctl => $hctl,
            host => int($h),
            channel => int($c),
            target => int($t),
            lun => int($l),
            transport => $transports->{$h} // 'local',
            vendor => read_attr("$dev/vendor"),
            model => $model,
            rev => read_attr("$dev/rev"),
            state => read_attr("$dev/state"),
            size => $sectors * 512,
            wwid => wwid_from_sysfs(read_attr("$dev/wwid")),
            target_wwpn => fmt_wwn(read_attr("/sys/class/fc_transport/target$h:$c:$t/port_name")),
            rotational => read_attr("/sys/block/$block/queue/rotational"),
            holders => [ list_dir("/sys/block/$block/holders") ],
            pseudo => ($model =~ $PSEUDO_MODELS) ? 1 : 0,
        };
    }
    return \@disks;
}

# Device-mapper multipath maps (dm uuid "mpath-<wwid>").
sub multipath_maps {
    my @maps;
    for my $dm (list_dir('/sys/block')) {
        next if $dm !~ /^dm-\d+$/;
        my $uuid = read_attr("/sys/block/$dm/dm/uuid") // '';
        next if $uuid !~ /^mpath-(.+)$/;
        my $wwid = $1; # read_attr's regexes clobber $1
        my $sectors = read_attr("/sys/block/$dm/size") // 0;
        my $discard = read_attr("/sys/block/$dm/queue/discard_max_bytes") // 0;
        push @maps, {
            sysfs => $dm,
            name => read_attr("/sys/block/$dm/dm/name"),
            wwid => $wwid,
            size => $sectors * 512,
            slaves => [ list_dir("/sys/block/$dm/slaves") ],
            holders => [ list_dir("/sys/block/$dm/holders") ],
            suspended => (read_attr("/sys/block/$dm/dm/suspended") // 0) ? 1 : 0,
            discard => ($discard =~ /^\d+$/ && $discard > 0) ? 1 : 0,
        };
    }
    return \@maps;
}

# Group paths into logical devices (LUNs), keyed by WWID.
#
# $pathstate is the multipathd view ({ sdX => { dm_state, chk_state, ... } });
# it is optional so this works when multipathd is not running.
sub build_devices {
    my ($disks, $maps, $pathstate) = @_;

    $pathstate //= {};
    my $by_dev = { map { $_->{dev} => $_ } @$disks };

    # map membership is authoritative for the WWID
    for my $map (@$maps) {
        for my $slave (@{$map->{slaves}}) {
            $by_dev->{$slave}->{wwid} = $map->{wwid} if $by_dev->{$slave};
        }
    }
    my $map_by_wwid = { map { $_->{wwid} => $_ } @$maps };

    my $devices = {};
    for my $disk (@$disks) {
        my $wwid = $disk->{wwid} // "unknown-$disk->{dev}";
        my $d = $devices->{$wwid} //= {
            wwid => $wwid,
            vendor => $disk->{vendor},
            model => $disk->{model},
            rev => $disk->{rev},
            transport => $disk->{transport},
            lun => $disk->{lun},
            size => 0,
            pseudo => $disk->{pseudo},
            rotational => $disk->{rotational},
            paths => [],
        };
        $d->{size} = $disk->{size} if $disk->{size} > $d->{size};

        my $mp = $pathstate->{$disk->{dev}} // {};
        push @{$d->{paths}}, {
            dev => $disk->{dev},
            hctl => $disk->{hctl},
            host => $disk->{host},
            lun => $disk->{lun},
            target_wwpn => $disk->{target_wwpn},
            state => $disk->{state},
            size => $disk->{size},
            dm_state => $mp->{dm_state},
            chk_state => $mp->{chk_state},
            priority => $mp->{priority},
        };
    }

    for my $d (values %$devices) {
        my $map = $map_by_wwid->{$d->{wwid}};
        if ($map) {
            $d->{map} = $map->{name};
            $d->{dm} = $map->{sysfs};
            $d->{map_size} = $map->{size};
            $d->{discard} = $map->{discard};
            $d->{holders} = $map->{holders};
        } else {
            $d->{holders} = [ map { @{$by_dev->{$_->{dev}}->{holders}} } @{$d->{paths}} ];
        }

        my $total = scalar(@{$d->{paths}});
        my $active = grep { path_is_active($_) } @{$d->{paths}};
        $d->{paths_total} = $total;
        $d->{paths_active} = $active;
        $d->{status} = !$active ? 'dead' : ($active < $total ? 'degraded' : 'ok');
        # a path grew on the array but the map was not resized yet
        $d->{resize_pending} = ($map && $d->{size} > $map->{size}) ? 1 : 0;
    }

    return [ sort { ($a->{map} // "~$a->{wwid}") cmp ($b->{map} // "~$b->{wwid}") } values %$devices ];
}

sub path_is_active {
    my ($path) = @_;

    my $state = $path->{state} // '';
    return 0 if $state ne 'running';
    if (defined(my $chk = $path->{chk_state})) {
        # "ghost" = ALUA standby: healthy but not serving I/O
        return $chk eq 'ready' || $chk eq 'ghost';
    }
    return 1;
}

1;
