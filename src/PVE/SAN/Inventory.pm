package PVE::SAN::Inventory;

# The node-local picture: adapters, LUNs with their paths, what each LUN is
# used for, and the datastores built on top of them.

use strict;
use warnings;

use Cwd qw(abs_path);

use PVE::Storage;

use PVE::SAN::Config;
use PVE::SAN::LVM;
use PVE::SAN::Multipath;
use PVE::SAN::Sysfs;
use PVE::SAN::Util qw(run_cmd normalize_wwid);

my $SAN_TRANSPORTS = { fc => 1, iscsi => 1 };

sub scsi_id {
    my ($dev) = @_;
    for my $bin ('/lib/udev/scsi_id', '/usr/lib/udev/scsi_id') {
        next if ! -x $bin;
        my $out = run_cmd([$bin, '-g', '-u', '-d', "/dev/$dev"], noerr => 1) // '';
        chomp($out);
        return normalize_wwid($out) if length($out);
    }
    return undef;
}

sub adapters {
    my $hosts = [ @{PVE::SAN::Sysfs::fc_hosts()}, @{PVE::SAN::Sysfs::iscsi_hosts()} ];
    my $disks = PVE::SAN::Sysfs::scsi_disks();

    my (%paths, %luns);
    for my $d (@$disks) {
        $paths{$d->{host}}++;
        $luns{$d->{host}}->{$d->{wwid} // $d->{dev}} = 1;
    }
    for my $h (@$hosts) {
        $h->{paths} = $paths{$h->{host}} // 0;
        $h->{devices} = scalar(keys %{$luns{$h->{host}} // {}});
        delete $h->{remote_ports};
    }
    return $hosts;
}

sub remote_ports {
    my @res;
    for my $h (@{PVE::SAN::Sysfs::fc_hosts()}) {
        push @res, map { { %$_, adapter => $h->{name}, adapter_wwpn => $h->{wwpn} } } @{$h->{remote_ports}};
    }
    return \@res;
}

# vgname => storeid for every LVM-backed storage in storage.cfg
sub vg_storage_map {
    my ($storecfg) = @_;
    $storecfg //= PVE::Storage::config();
    my $res = {};
    for my $id (keys %{$storecfg->{ids}}) {
        my $s = $storecfg->{ids}->{$id};
        next if $s->{type} ne 'lvm' && $s->{type} ne 'fcsan';
        $res->{$s->{vgname}} = $id if $s->{vgname};
    }
    return $res;
}

# dm-N => { pv_name, vg_name, ... } for every PV on a device-mapper device
sub pvs_by_dm {
    my $res = {};
    for my $pv (@{PVE::SAN::LVM::pvs()}) {
        my $real = abs_path($pv->{pv_name}) // next;
        $res->{$1} = $pv if $real =~ m|^/dev/(dm-\d+)$|;
        $res->{$1} = $pv if $real =~ m|^/dev/(sd[a-z]+)$|;
    }
    return $res;
}

sub probe_signature {
    my ($devpath) = @_;
    my $out = run_cmd(['blkid', '-p', '-o', 'export', $devpath], noerr => 1) // '';
    return "signature:$1" if $out =~ /^TYPE=(\S+)/m;
    return "partitioned:$1" if $out =~ /^PTTYPE=(\S+)/m;
    return undef;
}

# Full device list. Options: all => include local disks and pseudo LUNs,
# unused => only devices a datastore could be created on.
sub devices {
    my (%opts) = @_;

    my $disks = PVE::SAN::Sysfs::scsi_disks();
    for my $d (@$disks) {
        $d->{wwid} //= scsi_id($d->{dev});
    }
    my $maps = PVE::SAN::Sysfs::multipath_maps();
    my $states = PVE::SAN::Multipath::path_states();
    my $devices = PVE::SAN::Sysfs::build_devices($disks, $maps, $states);

    my $cfg = PVE::SAN::Config::load();
    my $storecfg = PVE::Storage::config();
    my $vgmap = vg_storage_map($storecfg);
    my $pvs = pvs_by_dm();
    my $claimed = PVE::SAN::Multipath::claimed_wwids();

    my @res;
    for my $d (@$devices) {
        next if !$opts{all} && (!$SAN_TRANSPORTS->{$d->{transport}} || $d->{pseudo});

        my $dc = $cfg->{devices}->{$d->{wwid}} // {};
        $d->{alias} = $dc->{alias};
        $d->{policy} = $dc->{policy} // 'array-default';
        $d->{detached} = $dc->{detached} ? 1 : 0;
        $d->{claimed} = ($claimed->{$d->{wwid}} || $d->{map}) ? 1 : 0;
        $d->{name} = $d->{map} // $d->{paths}->[0]->{dev};

        # what is this LUN used for?
        my $pv = $d->{dm} ? $pvs->{$d->{dm}} : undef;
        $pv //= $pvs->{$_->{dev}} for @{$d->{paths}}; # PV on a raw path: bad, but report it
        if ($dc->{disk}) { # a VM disk of an fcsanvol storage
            $d->{usage} = "vm-disk:$dc->{datastore}:$dc->{disk}";
        } elsif ($pv && $pv->{vg_name}) {
            my $storeid = $vgmap->{$pv->{vg_name}};
            $d->{usage} = $storeid ? "datastore:$storeid" : "lvm-vg:$pv->{vg_name}";
            $d->{vgname} = $pv->{vg_name};
            $d->{datastore} = $storeid;
        } elsif ($pv) {
            $d->{usage} = 'lvm-pv';
        } elsif (@{$d->{holders} // []}) {
            $d->{usage} = 'in-use:' . join('+', @{$d->{holders}});
        } elsif ($d->{status} ne 'dead') {
            my $devpath = $d->{map} ? "/dev/mapper/$d->{map}" : "/dev/$d->{paths}->[0]->{dev}";
            $d->{usage} = probe_signature($devpath) // 'free';
        } else {
            $d->{usage} = 'unknown';
        }

        next if $opts{unused} && $d->{usage} ne 'free';
        push @res, $d;
    }
    return \@res;
}

sub paths {
    my $res = [];
    for my $d (@{devices()}) {
        for my $p (@{$d->{paths}}) {
            push @$res, { %$p, wwid => $d->{wwid}, device => $d->{name}, alias => $d->{alias} };
        }
    }
    return $res;
}

sub find_device {
    my ($wwid, %opts) = @_;
    my ($dev) = grep { $_->{wwid} eq $wwid } @{devices(all => 1)};
    die "device '$wwid' not found on this node\n" if !$dev && !$opts{noerr};
    return $dev;
}

# PVs (and their maps) that make up a volume group.
sub vg_backing {
    my ($vg) = @_;

    my $maps = { map { $_->{sysfs} => $_ } @{PVE::SAN::Sysfs::multipath_maps()} };
    my @res;
    for my $pv (@{PVE::SAN::LVM::pvs()}) {
        next if ($pv->{vg_name} // '') ne $vg;
        my $real = abs_path($pv->{pv_name}) // '';
        my ($dm) = $real =~ m|^/dev/(dm-\d+)$|;
        my $map = $dm ? $maps->{$dm} : undef;
        push @res, {
            pv => $pv->{pv_name},
            pv_size => $pv->{pv_size},
            map => $map ? $map->{name} : undef,
            wwid => $map ? $map->{wwid} : undef,
            discard => $map ? $map->{discard} : 0,
        };
    }
    return \@res;
}

sub datastores {
    my $storecfg = PVE::Storage::config();
    my $cfg = PVE::SAN::Config::load();
    my $vgs = PVE::SAN::LVM::vgs();

    my @res;
    for my $id (sort keys %{$storecfg->{ids}}) {
        my $s = $storecfg->{ids}->{$id};
        next if $s->{type} ne 'fcsan' && $s->{type} ne 'lvm';

        my $vg = $vgs->{$s->{vgname}};
        my $backing = $vg ? vg_backing($s->{vgname}) : [];
        my $on_san = grep { $_->{wwid} } @$backing;
        # plain LVM storages are listed only when they sit on multipath LUNs
        next if $s->{type} eq 'lvm' && !$on_san;

        my @wwids = map { $_->{wwid} } grep { $_->{wwid} } @$backing;
        push @res, {
            storage => $id,
            type => $s->{type},
            label => $cfg->{datastores}->{$id}->{label},
            vgname => $s->{vgname},
            shared => $s->{shared} ? 1 : 0,
            enabled => $s->{disable} ? 0 : 1,
            nodes => $s->{nodes} ? join(',', sort keys %{$s->{nodes}}) : undef,
            content => join(',', sort keys %{$s->{content} // {}}),
            active => $vg ? 1 : 0,
            size => $vg ? $vg->{vg_size} : undef,
            free => $vg ? $vg->{vg_free} : undef,
            used => $vg ? $vg->{vg_size} - $vg->{vg_free} : undef,
            lvs => $vg ? $vg->{lv_count} : undef,
            devices => join(',', map { $cfg->{devices}->{$_}->{alias} // $_ } @wwids),
            wwids => join(',', @wwids),
            discard => (@$backing && !grep { !$_->{discard} } @$backing) ? 1 : 0,
            array => $cfg->{datastores}->{$id}->{array},
            volumes => join(',', map { $_->{name} } @{$cfg->{datastores}->{$id}->{volumes} // []}),
            copy_of => $cfg->{datastores}->{$id}->{copy_of},
            snapshot => $cfg->{datastores}->{$id}->{snapshot},
        };
    }
    return \@res;
}

1;
