package PVE::SAN::Snapshot;

# Array snapshots of datastores (the vSphere plugins' "snapshot and restore"):
# take, list and delete a snapshot of every array volume behind a datastore,
# mount a snapshot as a separate copy datastore, restore a VM's disks from
# that copy, roll a whole datastore back in place, and the scheduled
# snapshot and space-reclaim jobs.
#
# A snapshot "set" is all array snapshots with the same pvesan name across
# the datastore's volumes. Copies are recorded in the pvesan config like
# array-linked datastores, plus { copy_of => <storage>, snapshot => <name> }.
#
# Runs inside API workers (output goes to the task log) or, for the
# scheduled jobs, in the timer's process.

use strict;
use warnings;

use POSIX qw(strftime ceil);

use PVE::SAN::Array;
use PVE::SAN::Cluster;
use PVE::SAN::Config;
use PVE::SAN::LVM;
use PVE::SAN::Util qw(run_cmd);
use PVE::Tools;

my $HOUR = 3600;
my $CLAIM_TIMEOUT = 6 * $HOUR; # a claimed job whose node died is retried after this
our $RECLAIM_INTERVAL = 7 * 24 * $HOUR;

# --- pure helpers (unit tested) ---

sub default_name {
    my ($prefix, $time) = @_;
    return strftime("$prefix-%Y%m%d-%H%M%S", localtime($time // time()));
}

sub is_auto {
    my ($name) = @_;
    return $name =~ /^auto-\d{8}-\d{6}$/ ? 1 : 0;
}

# Group per-volume snapshots into sets by name, oldest first.
sub group_sets {
    my ($snaps, $vol_ids) = @_;
    my %by;
    for my $s (@$snaps) {
        my $set = $by{$s->{name}} //= { name => $s->{name}, members => [], size => 0 };
        push @{$set->{members}}, $s;
        $set->{size} += $s->{size} // 0;
        $set->{created} = $s->{created}
            if defined($s->{created}) && (!defined($set->{created}) || $s->{created} < $set->{created});
    }
    for my $set (values %by) {
        my %have = map { ($_->{volume} // '') => 1 } @{$set->{members}};
        $set->{complete} = (grep { !$have{$_} } @$vol_ids) ? 0 : 1;
        $set->{auto} = is_auto($set->{name});
    }
    return [ sort { ($a->{created} // 0) <=> ($b->{created} // 0) || $a->{name} cmp $b->{name} } values %by ];
}

# Members to delete for a set: a group snapshot is deleted once.
sub delete_targets {
    my ($set) = @_;
    my (%seen, @res);
    for my $m (@{$set->{members}}) {
        next if $m->{group} && $seen{$m->{group}}++;
        push @res, $m;
    }
    return \@res;
}

# Automatic sets beyond 'keep', oldest first; mounted ones are kept.
sub prune_list {
    my ($sets, $keep, $mounted) = @_;
    my @auto = grep { $_->{auto} } @$sets;
    my $excess = @auto - $keep;
    return [] if $excess <= 0;
    return [ grep { !$mounted->{$_->{name}} } @auto[0 .. $excess - 1] ];
}

# Datastores whose job is due at $now. $kind: 'snapshot' or 'reclaim'.
sub due_jobs {
    my ($cfg, $kind, $now) = @_;
    my @due;
    for my $id (sort keys %{$cfg->{datastores} // {}}) {
        my $ds = $cfg->{datastores}->{$id};
        next if $ds->{copy_of};
        my ($interval, $state);
        if ($kind eq 'snapshot') {
            my $sch = $ds->{snapshot_schedule} or next;
            $interval = ($sch->{interval} // 0) * $HOUR or next;
            $state = $ds->{snapshot_state} // {};
        } else {
            $ds->{auto_reclaim} or next;
            $interval = $RECLAIM_INTERVAL;
            $state = $ds->{reclaim_state} // {};
        }
        next if $state->{claimed} && $now - ($state->{claimed}->{time} // 0) < $CLAIM_TIMEOUT;
        # a minute of slack so a timer tick right on the boundary counts
        next if $state->{last} && $now - $state->{last} < $interval - 60;
        push @due, $id;
    }
    return \@due;
}

my $DISK_KEY = qr/^(?:ide|sata|scsi|virtio|efidisk|tpmstate|unused)\d+$/;

# The current configuration of a guest config file (snapshot sections cut).
sub main_section {
    my ($raw) = @_;
    my ($main) = split(/^\[/m, $raw, 2);
    return $main;
}

sub has_snapshots {
    my ($raw) = @_;
    return $raw =~ /^\[[^\]]+\]\s*$/m ? 1 : 0;
}

# Disks of the current config on $storeid: [ { key, volname, opts } ].
sub vm_disks {
    my ($main, $storeid) = @_;
    my @res;
    for my $line (split(/\n/, $main)) {
        my ($key, $val) = $line =~ /^([a-z]+\d+):\s*(\S.*)$/ or next;
        next if $key !~ $DISK_KEY;
        my ($vol, $opts) = $val =~ /^\Q$storeid\E:([^,]+)(.*)$/ or next;
        next if $val =~ /(?:^|,)media=cdrom(?:,|$)/;
        push @res, { key => $key, volname => $vol, opts => $opts };
    }
    return \@res;
}

sub random_mac {
    # Proxmox's OUI, like the GUI's default MAC addresses
    return sprintf('BC:24:11:%02X:%02X:%02X', map { int(rand(256)) } 1 .. 3);
}

sub random_uuid {
    my @b = map { int(rand(256)) } 1 .. 16;
    $b[6] = ($b[6] & 0x0f) | 0x40;
    $b[8] = ($b[8] & 0x3f) | 0x80;
    return sprintf('%02x%02x%02x%02x-%02x%02x-%02x%02x-%02x%02x-%02x%02x%02x%02x%02x%02x', @b);
}

# Config for a VM restored under a new ID: disks on $storeid are remapped
# through $map (volname -> new volid), disks elsewhere dropped (they belong
# to the original VM), and identity (MACs, SMBIOS UUID, vmgenid) renewed.
# Network links start down so the copy can't clash with the original.
# Returns (text, [notes]).
sub new_vm_config {
    my ($main, $storeid, $map, %o) = @_;
    my $mac = $o{mac} // \&random_mac;
    my $uuid = $o{uuid} // \&random_uuid;
    my (@out, @notes);
    for my $line (split(/\n/, $main)) {
        my ($key, $val) = $line =~ /^([a-z][a-z0-9_-]*):\s*(.*)$/;
        if (!defined($key)) {
            push @out, $line;
            next;
        }
        if ($key =~ /^(?:parent|lock|vmstate|runningmachine|runningcpu|onboot)$/) {
            next;
        } elsif ($key =~ $DISK_KEY) {
            if ($val =~ /^\Q$storeid\E:([^,]+)(.*)$/) {
                my ($vol, $opts) = ($1, $2);
                if ($map->{$vol}) {
                    push @out, "$key: $map->{$vol}$opts";
                } else {
                    push @notes, "$key ($storeid:$vol) was not restored and is left out";
                }
            } elsif ($val =~ /(?:^|,)media=cdrom(?:,|$)/ || $val =~ /^(?:none|cdrom)(?:,|$)/) {
                push @out, $line;
            } else {
                my ($what) = split(/,/, $val);
                push @notes, "$key ($what) is not on '$storeid' and is left out";
            }
        } elsif ($key =~ /^net\d+$/) {
            $val =~ s/(^|,)((?:[a-z0-9]+=)?)[0-9A-Fa-f]{2}(?::[0-9A-Fa-f]{2}){5}/$1 . $2 . $mac->()/e;
            $val .= ',link_down=1' if $val !~ /(?:^|,)link_down=1/;
            push @out, "$key: $val";
        } elsif ($key eq 'smbios1') {
            $val =~ s/(^|,)uuid=[0-9a-fA-F-]+/$1 . 'uuid=' . $uuid->()/e;
            push @out, "$key: $val";
        } elsif ($key eq 'vmgenid') {
            push @out, "vmgenid: " . $uuid->();
        } elsif ($key eq 'name') {
            push @out, "name: " . substr($val, 0, 54) . '-restored';
        } else {
            push @out, $line;
        }
    }
    push @notes, 'network links start down (link_down=1) and MAC addresses are new' if grep { /^net\d+:/ } @out;
    my $text = join("\n", @out);
    $text =~ s/\n*$/\n/;
    return ($text, \@notes);
}

# --- context ---

sub linked_ds {
    my ($storeid) = @_;
    my $ds = PVE::SAN::Config::load()->{datastores}->{$storeid} // {};
    die "datastore '$storeid' is not linked to an array\n" if !$ds->{array};
    return $ds;
}

# ($ds, $driver, [volume ids]) of an array datastore that can be snapshotted.
sub context {
    my ($storeid) = @_;
    my $ds = linked_ds($storeid);
    die "'$storeid' is a snapshot copy; use the snapshots of '$ds->{copy_of}'\n" if $ds->{copy_of};
    my $drv = PVE::SAN::Array::driver($ds->{array});
    $drv->not_supported('array snapshots') if !$drv->supports_snapshots;
    my $vols = [ map { $_->{id} } @{$ds->{volumes} // []} ];
    die "datastore '$storeid' has no array volumes recorded\n" if !@$vols;
    return ($ds, $drv, $vols);
}

# Mounted copies: { snapshot name => copy storage } for one datastore.
sub mounted_copies {
    my ($storeid, $cfg) = @_;
    $cfg //= PVE::SAN::Config::load();
    my %res;
    for my $id (keys %{$cfg->{datastores} // {}}) {
        my $d = $cfg->{datastores}->{$id};
        $res{$d->{snapshot}} = $id if ($d->{copy_of} // '') eq $storeid;
    }
    return \%res;
}

sub find_set {
    my ($drv, $vols, $name) = @_;
    my ($set) = grep { $_->{name} eq $name } @{group_sets($drv->snapshots($vols), $vols)};
    die "snapshot '$name' not found\n" if !$set;
    die "snapshot '$name' does not cover every volume of the datastore\n" if !$set->{complete};
    return $set;
}

# --- snapshots ---

sub create {
    my (%p) = @_;
    my $storeid = $p{storage};
    my ($ds, $drv, $vols) = context($storeid);
    my $name = $p{name} // default_name('pvesan');
    die "invalid snapshot name '$name' (letters, digits and '-', starting with a letter)\n"
        if !$drv->valid_snapshot_name($name);
    die "snapshot '$name' already exists\n" if grep { $_->{name} eq $name } @{$drv->snapshots($vols)};

    print "taking array snapshot '$name' of datastore '$storeid' (" . scalar(@$vols) . " volume(s)"
        . (@$vols > 1 ? ', one point in time' : '') . ")\n";
    print "note: the snapshot is crash-consistent; running VMs are not frozen\n";
    my $res = $drv->snapshot_create($vols, $name);
    print "snapshot '$name' created on array '$ds->{array}'\n";
    return $name;
}

sub list {
    my (%p) = @_;
    my $storeid = $p{storage};
    my ($ds, $drv, $vols) = context($storeid);
    my $mounted = mounted_copies($storeid);
    return [ map {
        {
            name => $_->{name},
            created => $_->{created},
            size => $_->{size},
            volumes => scalar(@{$_->{members}}),
            complete => $_->{complete},
            auto => $_->{auto},
            ($mounted->{$_->{name}} ? (copy => $mounted->{$_->{name}}) : ()),
        }
    } @{group_sets($drv->snapshots($vols), $vols)} ];
}

sub delete_set {
    my ($drv, $set) = @_;
    $drv->snapshot_delete($_) for @{delete_targets($set)};
}

sub remove {
    my (%p) = @_;
    my $storeid = $p{storage};
    my ($ds, $drv, $vols) = context($storeid);
    my $mounted = mounted_copies($storeid);
    die "snapshot '$p{name}' is mounted as '$mounted->{$p{name}}' - remove that copy first\n" if $mounted->{$p{name}};
    my ($set) = grep { $_->{name} eq $p{name} } @{group_sets($drv->snapshots($vols), $vols)};
    die "snapshot '$p{name}' not found\n" if !$set;
    delete_set($drv, $set);
    print "snapshot '$p{name}' of datastore '$storeid' deleted\n";
}

# --- copies ---

sub copy_name_for {
    my ($storeid, $set) = @_;
    return "$storeid-snap-" . strftime('%Y%m%d-%H%M', localtime($set->{created} // time()));
}

# Clone the snapshot, map the clones, import their volume group under a new
# name (vgimportclone gives the PVs and the VG new UUIDs, so it never
# collides with the live datastore) and register it as storage.
sub mount_copy {
    my (%p) = @_;

    my $storeid = $p{storage};
    my ($ds, $drv, $vols) = context($storeid);
    my $set = find_set($drv, $vols, $p{name});
    my $copy = $p{copy} // copy_name_for($storeid, $set);
    my $vg = "san_$copy";

    require PVE::Storage;
    die "storage '$copy' already exists\n" if PVE::Storage::config()->{ids}->{$copy};
    die "volume group '$vg' already exists\n" if PVE::SAN::LVM::vgs()->{$vg};
    my $mounted = mounted_copies($storeid);
    die "snapshot '$p{name}' is already mounted as '$mounted->{$p{name}}'\n" if $mounted->{$p{name}};

    my $hc = PVE::SAN::Array::hostcluster(PVE::SAN::Array::config($ds->{array}));
    my $nodes = PVE::SAN::Cluster::nodes();
    my $off = PVE::SAN::Cluster::offline_nodes();
    die "all nodes must be online to mount a copy (offline: @$off)\n" if @$off;

    my %member = map { ($_->{volume} // '') => $_ } @{$set->{members}};
    my (@clones, @mapped);
    my $ok = eval {
        for my $i (0 .. $#$vols) {
            my $m = $member{$vols->[$i]} // die "snapshot '$p{name}' has no member for volume $vols->[$i]\n";
            my $cname = $drv->volume_name_for(@$vols > 1 ? sprintf('%s-%02d', $copy, $i) : $copy);
            print "cloning snapshot $m->{id} to volume '$cname'\n";
            my $c = $drv->snapshot_clone($m, $cname);
            push @clones, $c;
            print "mapping '$cname' to host cluster '$hc'\n";
            $drv->map_to_hostcluster($c->{id}, $hc);
            push @mapped, $c;
            if (!$c->{wwid}) {
                my $v = $drv->volume($c->{id});
                $c->{wwid} = $v->{wwid} // die "array reports no WWID for volume $c->{id}\n";
            }
        }
        PVE::SAN::Config::update(sub {
            my ($cfg) = @_;
            $cfg->{datastores}->{$copy} = {
                array => $ds->{array},
                volumes => [ map { { id => $_->{id}, name => $_->{name}, wwid => $_->{wwid} } } @clones ],
                copy_of => $storeid,
                snapshot => $p{name},
                created => time(),
                label => "$storeid at snapshot $p{name}",
            };
        });

        require PVE::SAN::Provision;
        require PVE::SAN::Datastore;
        my @wwids = map { $_->{wwid} } @clones;
        print "rescanning all nodes for the copy's LUN(s)\n";
        PVE::SAN::Provision::wait_visible($nodes, $_, $p{timeout}) for @wwids;
        my $devs = PVE::SAN::Datastore::register_devices($nodes, $copy, \@wwids, 0);

        print "importing the volume group as '$vg' (new PV and VG UUIDs)\n";
        run_cmd(['vgimportclone', '--basevgname', $vg,
            (PVE::SAN::LVM::devicesfile_enabled() ? ('--importdevices') : ()), @$devs], timeout => 300);
        if (@{PVE::SAN::LVM::lvs($vg)}) {
            run_cmd(['lvchange', '--permission', 'r', $vg]); # read-only: a copy is for restoring from
        }
        PVE::SAN::LVM::vg_deactivate($vg);

        require PVE::API2::Storage::Config;
        PVE::API2::Storage::Config->create({
            storage => $copy,
            type => 'fcsan',
            vgname => $vg,
            shared => 1,
            content => 'images',
            'fc-wwids' => join(',', @wwids),
        });
        PVE::SAN::Cluster::on_nodes($nodes, 'refreshing LVM device lists', 'POST', 'sync');
        1;
    };
    if (my $err = $@) {
        print "mounting the copy failed - cleaning up\n";
        eval { PVE::SAN::LVM::vgremove($vg) } if PVE::SAN::LVM::vgs()->{$vg};
        for my $c (@clones) {
            eval { $drv->unmap_from_hostcluster($c->{id}, $hc) } if grep { $_ == $c } @mapped;
        }
        eval { PVE::SAN::Cluster::on_nodes($nodes, 'removing stale paths', 'POST', 'cleanup-paths') } if @mapped;
        for my $c (@clones) {
            eval { $drv->delete_volume($c->{id}) };
            print "WARNING: could not delete clone $c->{id} on the array: $@" if $@;
        }
        PVE::SAN::Config::update(sub {
            my ($cfg) = @_;
            delete $cfg->{datastores}->{$copy};
            delete $cfg->{devices}->{$_->{wwid}} for grep { $_->{wwid} } @clones;
        });
        eval { PVE::SAN::Cluster::on_nodes($nodes, 'applying multipath configuration', 'POST', 'sync') };
        die $err;
    }
    print "snapshot '$p{name}' of '$storeid' mounted read-only as datastore '$copy'\n";
    return $copy;
}

sub copy_record {
    my ($copy) = @_;
    my $ds = PVE::SAN::Config::load()->{datastores}->{$copy} // {};
    die "'$copy' is not a snapshot copy\n" if !$ds->{copy_of};
    return $ds;
}

# Remove a copy: its storage, volume group and clone volume(s).
sub remove_copy {
    my (%p) = @_;
    copy_record($p{storage});
    require PVE::SAN::Provision;
    PVE::SAN::Provision::destroy(storage => $p{storage}, destroy_data => 1);
}

# --- restore one VM from a copy ---

sub qemu_img_info {
    my ($path, $fmt) = @_;
    my $out = run_cmd(['qemu-img', 'info', '--output=json', '-f', $fmt, $path], timeout => 60);
    require JSON::PP;
    return JSON::PP->new->decode($out);
}

sub lv_format {
    my ($volname) = @_;
    return $volname =~ /\.qcow2$/ ? 'qcow2' : 'raw';
}

sub restore_vm {
    my (%p) = @_;

    my $copy = $p{storage};
    my $vmid = $p{vmid};
    my $ds = copy_record($copy);
    my $src = $ds->{copy_of};
    my $mode = $p{target_vmid} ? 'new' : 'replace';

    require PVE::Storage;
    require PVE::SAN::Datastore;
    my $copy_vg = PVE::SAN::Datastore::storage($copy)->{vgname};
    my $live_vg = PVE::SAN::Datastore::storage($src)->{vgname};

    my ($ref) = grep { $_->{vmid} == $vmid } @{PVE::SAN::Cluster::guest_refs($src)};
    die "VM $vmid has no disks on '$src'\n" if !$ref;
    die "only QEMU VMs can be restored yet (CT $vmid)\n" if $ref->{type} ne 'qemu';
    my $raw = PVE::Tools::file_get_contents($ref->{file});
    my $main = main_section($raw);

    my %copy_lv = map { $_->{lv_name} => $_ } @{PVE::SAN::LVM::lvs($copy_vg)};
    my @disks;
    for my $d (@{vm_disks($main, $src)}) {
        if (!$copy_lv{$d->{volname}}) {
            print "$d->{key}: $d->{volname} is not in the snapshot (created later?), skipped\n";
            next;
        }
        push @disks, $d;
    }
    die "none of VM $vmid's disks on '$src' exist in snapshot '$ds->{snapshot}'\n" if !@disks;

    my $check_stopped = sub {
        my $s = PVE::SAN::Cluster::guest_status()->{$vmid} // {};
        die "VM $vmid is running on $s->{node} - shut it down first\n" if ($s->{status} // '') eq 'running';
    };
    if ($mode eq 'replace') {
        $check_stopped->();
        die "VM $vmid has snapshots; delete them first, or restore into a new VM\n" if has_snapshots($raw);
    }

    my $storecfg = PVE::Storage::config();
    my $target_store = $p{target_storage} // $src;
    my $newid = $p{target_vmid};
    if ($mode eq 'new') {
        die "VM ID $newid is already in use\n" if PVE::SAN::Cluster::guest_status()->{$newid};
    }

    my (%map, @allocated);
    eval {
        for my $d (@disks) {
            my $lv = "$copy_vg/$d->{volname}";
            my $from = "/dev/$lv";
            my $fmt = lv_format($d->{volname});
            run_cmd(['lvchange', '-ay', $lv]);
            my $info = eval { qemu_img_info($from, $fmt) } // {};
            die "$d->{key}: $d->{volname} is part of a snapshot chain in the copy; it can't be restored on its own\n"
                if $info->{'backing-filename'};

            if ($mode eq 'replace') {
                my $volid = "$src:$d->{volname}";
                my $to = "/dev/$live_vg/$d->{volname}";
                PVE::Storage::activate_volumes($storecfg, [$volid]);
                my ($live) = grep { $_->{lv_name} eq $d->{volname} } @{PVE::SAN::LVM::lvs($live_vg)};
                die "$d->{key}: $volid no longer exists\n" if !$live;
                die "$d->{key}: $volid is smaller than in the snapshot\n" if $live->{lv_size} < $copy_lv{$d->{volname}}->{lv_size};
                $check_stopped->();
                print "$d->{key}: copying $d->{volname} from the snapshot over the live disk\n";
                run_cmd(['qemu-img', 'convert', '-n', '-f', 'raw', '-O', 'raw', '-t', 'none', '-T', 'none', $from, $to],
                    timeout => 24 * $HOUR);
                PVE::Storage::deactivate_volumes($storecfg, [$volid]);
            } else {
                my $size = $info->{'virtual-size'} // $copy_lv{$d->{volname}}->{lv_size};
                my $volid = PVE::Storage::vdisk_alloc($storecfg, $target_store, $newid, 'raw', undef, ceil($size / 1024));
                push @allocated, $volid;
                PVE::Storage::activate_volumes($storecfg, [$volid]);
                my $to = PVE::Storage::path($storecfg, $volid);
                print "$d->{key}: copying $d->{volname} from the snapshot to $volid\n";
                run_cmd(['qemu-img', 'convert', '-n', '-f', $fmt, '-O', 'raw', '-t', 'none', '-T', 'none', $from, $to],
                    timeout => 24 * $HOUR);
                PVE::Storage::deactivate_volumes($storecfg, [$volid]);
                $map{$d->{volname}} = $volid;
            }
            run_cmd(['lvchange', '-an', $lv], noerr => 1);
        }
        1;
    } or do {
        my $err = $@;
        for my $volid (@allocated) {
            eval { PVE::Storage::vdisk_free($storecfg, $volid) };
        }
        die $err;
    };

    if ($mode eq 'new') {
        my ($text, $notes) = new_vm_config($main, $src, \%map);
        print "note: $_\n" for @$notes;
        my $node = PVE::SAN::Cluster::local_node();
        my $file = "/etc/pve/nodes/$node/qemu-server/$newid.conf";
        die "VM ID $newid is already in use\n" if -e $file || PVE::SAN::Cluster::guest_status()->{$newid};
        PVE::Tools::file_set_contents($file, $text);
        print "VM $vmid restored from snapshot '$ds->{snapshot}' as new VM $newid on $node\n";
        return $newid;
    }
    print "disks of VM $vmid restored from snapshot '$ds->{snapshot}'\n";
    return $vmid;
}

# --- whole datastore in place ---

sub rollback {
    my (%p) = @_;

    my $storeid = $p{storage};
    die "confirm with the datastore's ID ('$storeid') to roll it back\n" if ($p{confirm} // '') ne $storeid;
    my ($ds, $drv, $vols) = context($storeid);
    my $set = find_set($drv, $vols, $p{name});

    require PVE::SAN::Datastore;
    my $scfg = PVE::SAN::Datastore::storage($storeid);
    my $off = PVE::SAN::Cluster::offline_nodes(restrict => $scfg->{nodes});
    die "all nodes of the datastore must be online so its volume group can be deactivated everywhere (offline: @$off)\n" if @$off;
    my $refs = PVE::SAN::Cluster::guest_refs($storeid);
    my $running = PVE::SAN::Cluster::running_guests($refs);
    die "stop every guest using '$storeid' first: @$running\n" if @$running;
    my $copies = mounted_copies($storeid);
    die "remove the mounted copies of '$storeid' first: " . join(' ', sort values %$copies) . "\n" if %$copies;

    my $nodes = PVE::SAN::Datastore::storage_nodes($scfg);
    my $was_disabled = $scfg->{disable};
    PVE::SAN::Datastore::update_storage($storeid, { disable => 1 }) if !$was_disabled;
    PVE::SAN::Cluster::on_nodes($nodes, "deactivating VG $scfg->{vgname}", 'POST', 'vg-deactivate',
        { vgname => $scfg->{vgname} });

    my %member = map { ($_->{volume} // '') => $_ } @{$set->{members}};
    for my $vol (@$vols) {
        print "restoring array volume $vol from snapshot '$p{name}'\n";
        $drv->snapshot_restore($vol, $member{$vol});
    }

    my @wwids = map { $_->{wwid} } @{$ds->{volumes}};
    for my $wwid (@wwids) {
        PVE::SAN::Cluster::on_nodes($nodes, "re-reading LUN $wwid", 'POST', "devices/$wwid/refresh");
    }
    PVE::SAN::Cluster::on_nodes($nodes, 'refreshing LVM device lists', 'POST', 'sync');
    PVE::SAN::Datastore::update_storage($storeid, { delete => 'disable' }) if !$was_disabled;

    my %lv = map { $_->{lv_name} => 1 } @{PVE::SAN::LVM::lvs($scfg->{vgname})};
    for my $r (@$refs) {
        my $raw = eval { PVE::Tools::file_get_contents($r->{file}) } // '';
        my @gone = grep { !$lv{$_->{volname}} } @{vm_disks(main_section($raw), $storeid)};
        print "WARNING: $r->{type} $r->{vmid} references disks that did not exist at the snapshot: "
            . join(' ', map { $_->{volname} } @gone) . "\n" if @gone;
    }
    print "datastore '$storeid' rolled back to snapshot '$p{name}'\n";
}

# --- schedules ---

sub get_schedule {
    my (%p) = @_;
    my $ds = PVE::SAN::Config::load()->{datastores}->{$p{storage}} // {};
    my $sch = $ds->{snapshot_schedule} // {};
    my $ss = $ds->{snapshot_state} // {};
    my $rs = $ds->{reclaim_state} // {};
    return {
        storage => $p{storage},
        'snapshot-interval' => $sch->{interval} // 0,
        'snapshot-keep' => $sch->{keep},
        'snapshot-last' => $ss->{last},
        'snapshot-error' => $ss->{error},
        'auto-reclaim' => $ds->{auto_reclaim} ? 1 : 0,
        'reclaim-last' => $rs->{last},
        'reclaim-error' => $rs->{error},
    };
}

sub set_schedule {
    my (%p) = @_;
    my $storeid = $p{storage};
    my %delete = map { $_ => 1 } PVE::Tools::split_list($p{delete} // '');
    if ($p{interval} || $p{keep}) {
        my ($ds, $drv) = context($storeid); # snapshot schedules need a driver with snapshots
    }
    PVE::SAN::Config::update(sub {
        my ($cfg) = @_;
        my $ds = $cfg->{datastores}->{$storeid} //= {};
        die "'$storeid' is a snapshot copy\n" if $ds->{copy_of};
        if ($delete{'snapshot-interval'} || (defined($p{interval}) && !$p{interval})) {
            delete $ds->{snapshot_schedule};
        } elsif ($p{interval} || $p{keep}) {
            my $sch = $ds->{snapshot_schedule} //= { keep => 7 };
            $sch->{interval} = $p{interval} if $p{interval};
            $sch->{keep} = $p{keep} if $p{keep};
            die "set 'snapshot-interval' too\n" if !$sch->{interval};
        }
        if (defined($p{auto_reclaim}) || $delete{'auto-reclaim'}) {
            if ($p{auto_reclaim}) { $ds->{auto_reclaim} = 1 } else { delete $ds->{auto_reclaim} }
        }
    });
    return get_schedule(storage => $storeid);
}

# Claim due jobs under the cluster-wide pvesan lock so exactly one node runs
# each, run them outside the lock, then record the result.
sub claim {
    my ($kind, $filter) = @_;
    my $node = PVE::SAN::Cluster::local_node();
    my $now = time();
    my $skey = "${kind}_state";
    # the timers fire on every node; only take the lock when something is due
    return [] if !grep { !$filter || $filter->($_) } @{due_jobs(PVE::SAN::Config::load(), $kind, $now)};
    return PVE::SAN::Config::update(sub {
        my ($cfg) = @_;
        my @mine;
        for my $id (@{due_jobs($cfg, $kind, $now)}) {
            next if $filter && !$filter->($id);
            $cfg->{datastores}->{$id}->{$skey}->{claimed} = { node => $node, time => $now };
            push @mine, $id;
        }
        return \@mine;
    });
}

sub finish {
    my ($kind, $id, $err) = @_;
    my $skey = "${kind}_state";
    PVE::SAN::Config::update(sub {
        my ($cfg) = @_;
        my $ds = $cfg->{datastores}->{$id} or return;
        my $st = $ds->{$skey} //= {};
        delete $st->{claimed};
        $st->{last} = time();
        if ($err) { chomp($err); $st->{error} = $err } else { delete $st->{error} }
    });
}

# Remove automatic snapshots beyond the schedule's 'keep'.
sub prune {
    my (%p) = @_;
    my ($ds, $drv, $vols) = context($p{storage});
    my $keep = $ds->{snapshot_schedule}->{keep} // return;
    my $sets = group_sets($drv->snapshots($vols), $vols);
    for my $set (@{prune_list($sets, $keep, mounted_copies($p{storage}))}) {
        print "removing automatic snapshot '$set->{name}' of '$p{storage}' (keep $keep)\n";
        delete_set($drv, $set);
    }
}

# Timer entry point: take due scheduled snapshots, then prune.
sub run_snapshot_schedules {
    my $jobs = claim('snapshot');
    for my $id (@$jobs) {
        my $ok = eval {
            create(storage => $id, name => default_name('auto'));
            prune(storage => $id);
            1;
        };
        my $err = $ok ? undef : $@;
        print "ERROR: scheduled snapshot of '$id' failed: $err" if $err;
        finish('snapshot', $id, $err);
    }
    return { ran => $jobs };
}

# Timer entry point: weekly UNMAP of datastores with auto-reclaim, on a node
# that has the datastore.
sub run_reclaim {
    require PVE::Storage;
    require PVE::SAN::Datastore;
    my $node = PVE::SAN::Cluster::local_node();
    my $storecfg = PVE::Storage::config();
    my $jobs = claim('reclaim', sub {
        my $s = $storecfg->{ids}->{$_[0]} or return 0;
        return 0 if $s->{disable};
        return !$s->{nodes} || $s->{nodes}->{$node};
    });
    for my $id (@$jobs) {
        my $ok = eval { PVE::SAN::Datastore::reclaim(storage => $id); 1 };
        my $err = $ok ? undef : $@;
        print "ERROR: reclaim of '$id' failed: $err" if $err;
        finish('reclaim', $id, $err);
    }
    return { ran => $jobs };
}

1;
