package PVE::SAN::Datastore;

# Cluster-wide operations (the vCenter "datastore" and "device" actions).
# These run inside an API worker on one node and drive the node-local steps
# on every node through PVE::SAN::Cluster.
#
# Locking rules:
#  - LVM metadata changes on a shared VG happen only under PVE's cluster
#    storage lock (the same lock PVE takes for volume allocation).
#  - pmxcfs aborts locked code after 60s, so slow work (node fan-out,
#    discards) happens outside the lock and only the metadata write inside.

use strict;
use warnings;

use PVE::Storage;
use PVE::Storage::Plugin;
use PVE::API2::Storage::Config;
use PVE::Tools;

use PVE::SAN::Cluster;
use PVE::SAN::Config;
use PVE::SAN::Inventory;
use PVE::SAN::LVM;
use PVE::SAN::Multipath;
use PVE::SAN::Util qw(run_cmd valid_alias);

sub storage {
    my ($storeid) = @_;
    my $scfg = PVE::Storage::config()->{ids}->{$storeid}
        or die "storage '$storeid' does not exist\n";
    die "storage '$storeid' is not an LVM/fcsan storage\n"
        if $scfg->{type} ne 'fcsan' && $scfg->{type} ne 'lvm';
    return $scfg;
}

sub storage_nodes {
    my ($scfg) = @_;
    return PVE::SAN::Cluster::nodes(restrict => $scfg->{nodes});
}

sub warn_offline {
    my ($restrict) = @_;
    my $off = PVE::SAN::Cluster::offline_nodes(restrict => $restrict);
    print "WARNING: node(s) offline, they pick up the change at boot (pvesan-sync.service): @$off\n"
        if @$off;
}

# Every node must see every LUN with at least one working path.
sub check_visible {
    my ($nodes, $wwids) = @_;

    my $res = PVE::SAN::Cluster::on_nodes($nodes, 'checking LUN visibility', 'GET', 'devices', { all => 1 });
    my (@errors, $sizes);
    for my $node (@$nodes) {
        my $have = { map { $_->{wwid} => $_ } @{$res->{$node} // []} };
        for my $wwid (@$wwids) {
            my $d = $have->{$wwid};
            if (!$d) {
                push @errors, "$node: LUN $wwid not visible - check zoning and LUN masking, then rescan";
            } elsif (!$d->{paths_active}) {
                push @errors, "$node: LUN $wwid has no active path";
            } else {
                print "[$node] WARNING: LUN $wwid has only one active path\n" if $d->{paths_active} < 2;
                $sizes->{$wwid}->{$node} = $d->{size};
            }
        }
    }
    die join("\n", @errors) . "\n" if @errors;
    return $sizes;
}

sub unique_alias {
    my ($cfg, $base, $wwid) = @_;
    my $alias = $base;
    for (my $n = 1; ; $n++) {
        my $owner = PVE::SAN::Config::alias_owner($cfg, $alias);
        return $alias if !$owner || $owner eq $wwid;
        $alias = "$base-$n";
    }
}

# Give LUNs a cluster-wide entry (claim + alias) and push it to all nodes.
sub register_devices {
    my ($nodes, $storeid, $wwids, $first_index) = @_;

    my $aliases = PVE::SAN::Config::update(sub {
        my ($cfg) = @_;
        my @res;
        for my $i (0 .. $#$wwids) {
            my $wwid = $wwids->[$i];
            my $d = $cfg->{devices}->{$wwid} //= {};
            delete $d->{detached};
            my $base = (@$wwids > 1 || $first_index)
                ? sprintf('%s-%02d', $storeid, $first_index + $i) : $storeid;
            $d->{alias} //= unique_alias($cfg, $base, $wwid);
            $d->{datastore} = $storeid;
            push @res, $d->{alias};
        }
        return \@res;
    });

    PVE::SAN::Cluster::on_nodes($nodes, 'applying multipath configuration', 'POST', 'sync');

    my @devs;
    for my $wwid (@$wwids) {
        my $name = PVE::SAN::Multipath::wait_for_map($wwid, 30)
            // die "multipath map for $wwid did not appear on this node\n";
        push @devs, "/dev/mapper/$name";
    }
    print "LUN(s) mapped as: @devs\n";
    return \@devs;
}

sub check_unused_locally {
    my ($wwids, $force) = @_;

    my $local = { map { $_->{wwid} => $_ } @{PVE::SAN::Inventory::devices(all => 1)} };
    my @wipe;
    for my $wwid (@$wwids) {
        my $d = $local->{$wwid} // die "LUN $wwid not found on this node\n";
        my $usage = $d->{usage};
        next if $usage eq 'free';
        die "LUN $wwid is in use ($usage)\n" if $usage =~ /^(?:datastore|lvm-vg|in-use|unknown)/;
        die "LUN $wwid has existing data ($usage); use 'force' to wipe it\n" if !$force;
        print "WARNING: wiping existing $usage on LUN $wwid\n";
        push @wipe, $wwid;
    }
    return \@wipe;
}

sub update_storage {
    my ($storeid, $param) = @_;
    PVE::API2::Storage::Config->update({ storage => $storeid, %$param });
}

sub create {
    my (%p) = @_;

    my $storeid = $p{storage};
    my $wwids = $p{devices};
    die "no LUNs given\n" if !@$wwids;
    my $vg = $p{vgname} // "san_$storeid";

    die "storage '$storeid' already exists\n" if PVE::Storage::config()->{ids}->{$storeid};
    die "volume group '$vg' already exists\n" if PVE::SAN::LVM::vgs()->{$vg};

    my $restrict = $p{nodes} ? { map { $_ => 1 } PVE::Tools::split_list($p{nodes}) } : undef;
    my $nodes = PVE::SAN::Cluster::nodes(restrict => $restrict);
    warn_offline($restrict);

    check_visible($nodes, $wwids);
    my $wipe = check_unused_locally($wwids, $p{force});

    my $devs = register_devices($nodes, $storeid, $wwids, 0);

    my $created_vg;
    eval {
        for my $i (0 .. $#$wwids) {
            if (grep { $_ eq $wwids->[$i] } @$wipe) {
                print "wipefs $devs->[$i]\n";
                PVE::SAN::LVM::wipefs($devs->[$i]);
            }
            print "pvcreate $devs->[$i]\n";
            PVE::SAN::LVM::pvcreate($devs->[$i]);
        }
        print "vgcreate $vg @$devs\n";
        PVE::SAN::LVM::vgcreate($vg, @$devs);
        $created_vg = 1;

        print "registering storage '$storeid'\n";
        PVE::API2::Storage::Config->create({
            storage => $storeid,
            type => 'fcsan',
            vgname => $vg,
            shared => 1,
            content => $p{content} // 'images,rootdir',
            'fc-wwids' => join(',', @$wwids),
            ($p{nodes} ? (nodes => $p{nodes}) : ()),
            (defined($p{saferemove}) ? (saferemove => $p{saferemove}) : ()),
        });
    };
    if (my $err = $@) {
        print "creation failed, rolling back LVM changes\n";
        eval { PVE::SAN::LVM::vgremove($vg) } if $created_vg;
        eval { PVE::SAN::LVM::pvremove($_) } for @$devs;
        die $err;
    }

    PVE::SAN::Config::update(sub {
        my ($cfg) = @_;
        $cfg->{datastores}->{$storeid} = { created => time(), (defined($p{label}) ? (label => $p{label}) : ()) };
    });

    # second pass: nodes with an LVM devices file learn the new PV
    PVE::SAN::Cluster::on_nodes($nodes, 'refreshing LVM device lists', 'POST', 'sync');
    print "datastore '$storeid' created on VG '$vg' (@$devs)\n";
}

# Grow into expanded LUNs, or add LUNs as new extents.
sub extend {
    my (%p) = @_;

    my $storeid = $p{storage};
    my $scfg = storage($storeid);
    my $vg = $scfg->{vgname};
    my $nodes = storage_nodes($scfg);
    my $backing = PVE::SAN::Inventory::vg_backing($vg);
    die "volume group '$vg' not found on this node\n" if !@$backing;

    if (my $add = $p{add_devices}) {
        check_visible($nodes, $add);
        my $wipe = check_unused_locally($add, $p{force});
        my $devs = register_devices($nodes, $storeid, $add, scalar(@$backing));

        PVE::Storage::Plugin->cluster_lock_storage($storeid, 1, 60, sub {
            for my $i (0 .. $#$add) {
                PVE::SAN::LVM::wipefs($devs->[$i]) if grep { $_ eq $add->[$i] } @$wipe;
                print "pvcreate $devs->[$i]\n";
                PVE::SAN::LVM::pvcreate($devs->[$i]);
            }
            print "vgextend $vg @$devs\n";
            PVE::SAN::LVM::vgextend($vg, @$devs);
        });

        if ($scfg->{type} eq 'fcsan') {
            my $all = PVE::SAN::Util::parse_wwid_list(join(',', $scfg->{'fc-wwids'} // '', @$add));
            update_storage($storeid, { 'fc-wwids' => join(',', @$all) });
        }
        PVE::SAN::Cluster::on_nodes($nodes, 'refreshing LVM device lists', 'POST', 'sync');
        print "added @$devs to datastore '$storeid'\n";
        return;
    }

    my @grow = grep { $_->{wwid} } @$backing;
    if (my $only = $p{devices}) {
        my %want = map { $_ => 1 } @$only;
        @grow = grep { $want{$_->{wwid}} } @grow;
    }
    die "no multipath-backed PV to grow in '$vg'\n" if !@grow;

    for my $b (@grow) {
        my $res = PVE::SAN::Cluster::on_nodes($nodes, "re-reading size of $b->{map}", 'POST', "devices/$b->{wwid}/refresh");
        my %sizes = map { $_ => ($res->{$_}->{size} // 0) } keys %$res;
        my %distinct = map { $_ => 1 } values %sizes;
        if (keys %distinct > 1) {
            die "nodes disagree about the size of $b->{map}: "
                . join(', ', map { "$_=$sizes{$_}" } sort keys %sizes)
                . " - check the LUN on the array and rescan\n";
        }
        my ($size) = keys %distinct;
        if ($size <= $b->{pv_size}) {
            print "$b->{map}: LUN size unchanged ($size bytes), nothing to grow\n";
            next;
        }
        PVE::Storage::Plugin->cluster_lock_storage($storeid, 1, 60, sub {
            print "pvresize $b->{pv}\n";
            PVE::SAN::LVM::pvresize($b->{pv});
        });
    }
    my $info = PVE::SAN::LVM::vgs()->{$vg};
    print "datastore '$storeid' size now $info->{vg_size} bytes ($info->{vg_free} free)\n";
}

# Rewrite "<old>:" volume references in a guest config.
sub rewrite_guest_config {
    my ($file, $old, $new) = @_;
    my $raw = PVE::Tools::file_get_contents($file);
    my $n = ($raw =~ s/^([a-z][a-z0-9_]*:\s+)\Q$old\E:/$1$new:/mg);
    PVE::Tools::file_set_contents($file, $raw) if $n;
    return $n;
}

sub rename_datastore {
    my (%p) = @_;

    my $storeid = $p{storage};
    my $scfg = storage($storeid);

    if (defined($p{label})) {
        PVE::SAN::Config::update(sub {
            my ($cfg) = @_;
            my $ds = $cfg->{datastores}->{$storeid} //= {};
            if (length($p{label})) { $ds->{label} = $p{label} } else { delete $ds->{label} }
        });
        print "label of '$storeid' set to '$p{label}'\n";
    }

    my $new = $p{new_id} // return;
    die "storage '$new' already exists\n" if PVE::Storage::config()->{ids}->{$new};
    my $nodes = storage_nodes($scfg);
    my $off = PVE::SAN::Cluster::offline_nodes(restrict => $scfg->{nodes});
    die "all nodes must be online to rename a storage ID (offline: @$off)\n" if @$off;

    my $refs = PVE::SAN::Cluster::guest_refs($storeid);
    my $running = PVE::SAN::Cluster::running_guests($refs);
    die "stop these guests first: @$running\n" if @$running;

    my $old_vg = $scfg->{vgname};
    my $new_vg = $p{rename_vg} ? "san_$new" : $old_vg;
    die "volume group '$new_vg' already exists\n" if $new_vg ne $old_vg && PVE::SAN::LVM::vgs()->{$new_vg};

    PVE::SAN::Cluster::on_nodes($nodes, "deactivating VG $old_vg", 'POST', 'vg-deactivate', { vgname => $old_vg });

    PVE::Storage::lock_storage_config(sub {
        my $cfg = PVE::Storage::config();
        my $entry = delete $cfg->{ids}->{$storeid} or die "storage '$storeid' vanished\n";
        die "storage '$new' already exists\n" if $cfg->{ids}->{$new};
        if ($new_vg ne $old_vg) {
            print "vgrename $old_vg $new_vg\n";
            PVE::SAN::LVM::vgrename($old_vg, $new_vg);
            $entry->{vgname} = $new_vg;
        }
        $cfg->{ids}->{$new} = $entry;
        PVE::Storage::write_config($cfg);
    }, "rename storage failed");
    print "storage '$storeid' renamed to '$new'\n";

    for my $r (@$refs) {
        my $n = eval { rewrite_guest_config($r->{file}, $storeid, $new) };
        if ($@) {
            print "ERROR: could not update $r->{file}: $@";
        } else {
            print "updated $r->{type} $r->{vmid}: $n reference(s)\n";
        }
    }

    PVE::SAN::Config::update(sub {
        my ($cfg) = @_;
        $cfg->{datastores}->{$new} = delete($cfg->{datastores}->{$storeid}) // {};
        for my $d (values %{$cfg->{devices}}) {
            $d->{datastore} = $new if ($d->{datastore} // '') eq $storeid;
        }
    });
}

sub unmount {
    my (%p) = @_;

    my $storeid = $p{storage};
    my $scfg = storage($storeid);
    my $active = storage_nodes($scfg);
    my $targets = $p{nodes} ? [ PVE::Tools::split_list($p{nodes}) ] : $active;

    my $refs = PVE::SAN::Cluster::guest_refs($storeid);
    my $running = PVE::SAN::Cluster::running_guests($refs, nodes => $targets);
    die "guests using '$storeid' are running on the target node(s): @$running\n" if @$running;

    my @online = grep { my $n = $_; grep { $_ eq $n } @$active } @$targets;
    PVE::SAN::Cluster::on_nodes(\@online, "deactivating VG $scfg->{vgname}", 'POST', 'vg-deactivate',
        { vgname => $scfg->{vgname} });

    if (!$p{nodes}) {
        update_storage($storeid, { disable => 1 });
        print "datastore '$storeid' unmounted (disabled) cluster-wide\n";
    } else {
        my $current = $scfg->{nodes} ? [ sort keys %{$scfg->{nodes}} ] : PVE::SAN::Cluster::all_nodes();
        my %drop = map { $_ => 1 } @$targets;
        my @keep = grep { !$drop{$_} } @$current;
        die "unmounting from every node - omit 'nodes' to disable the datastore instead\n" if !@keep;
        update_storage($storeid, { nodes => join(',', @keep) });
        print "datastore '$storeid' unmounted from: @$targets\n";
    }
}

sub mount {
    my (%p) = @_;

    my $storeid = $p{storage};
    my $scfg = storage($storeid);

    my $param = {};
    my @delete;
    push @delete, 'disable' if $scfg->{disable};
    if ($p{nodes} && $scfg->{nodes}) {
        my %n = (%{$scfg->{nodes}}, map { $_ => 1 } PVE::Tools::split_list($p{nodes}));
        my $all = PVE::SAN::Cluster::all_nodes();
        if (grep { !$n{$_} } @$all) {
            $param->{nodes} = join(',', sort keys %n);
        } else {
            push @delete, 'nodes';
        }
    } elsif (!$p{nodes} && $scfg->{nodes}) {
        push @delete, 'nodes';
    }
    $param->{delete} = join(',', @delete) if @delete;
    update_storage($storeid, $param) if %$param;

    $scfg = storage($storeid);
    my $nodes = storage_nodes($scfg);
    PVE::SAN::Cluster::on_nodes($nodes, 'applying multipath configuration', 'POST', 'sync');
    for my $node (@$nodes) {
        my $ok = eval { run_cmd(['pvesh', 'get', "/nodes/$node/storage/$storeid/status", '--output-format', 'json']); 1 };
        print "[$node] " . ($ok ? "datastore '$storeid' active\n" : "WARNING: activation failed: $@");
    }
}

sub destroy {
    my (%p) = @_;

    my $storeid = $p{storage};
    my $scfg = storage($storeid);
    my $vg = $scfg->{vgname};
    my $nodes = storage_nodes($scfg);

    my $refs = PVE::SAN::Cluster::guest_refs($storeid);
    die "datastore is referenced by guest(s): " . join(' ', map { $_->{vmid} } @$refs)
        . " - move or remove their disks first\n" if @$refs;

    my $lvs = PVE::SAN::LVM::lvs($vg);
    if (@$lvs) {
        my @names = map { $_->{lv_name} } @$lvs;
        die "volume group '$vg' still holds volumes (@names); set 'destroy-data' to delete them\n"
            if !$p{destroy_data};
        print "WARNING: destroying volumes: @names\n";
    }

    my $backing = PVE::SAN::Inventory::vg_backing($vg);
    PVE::SAN::Cluster::on_nodes($nodes, "deactivating VG $vg", 'POST', 'vg-deactivate', { vgname => $vg });

    print "removing storage definition '$storeid'\n";
    PVE::API2::Storage::Config->delete({ storage => $storeid });

    print "vgremove $vg\n";
    PVE::SAN::LVM::vgremove($vg);
    for my $b (@$backing) {
        print "pvremove/wipefs $b->{pv}\n";
        PVE::SAN::LVM::pvremove($b->{pv});
        eval { PVE::SAN::LVM::wipefs($b->{pv}) };
    }

    my @wwids = map { $_->{wwid} } grep { $_->{wwid} } @$backing;
    PVE::SAN::Config::update(sub {
        my ($cfg) = @_;
        delete $cfg->{datastores}->{$storeid};
        delete $cfg->{devices}->{$_}->{datastore} for grep { $cfg->{devices}->{$_} } @wwids;
    });

    if ($p{detach}) {
        device_detach(wwid => $_) for @wwids;
        print "LUN(s) detached; they can now be unmapped on the array: @wwids\n";
    }
    print "datastore '$storeid' deleted\n";
}

# Return free extents to a thin-provisioned array (SCSI UNMAP).
sub reclaim {
    my (%p) = @_;

    my $storeid = $p{storage};
    my $scfg = storage($storeid);
    my $vg = $scfg->{vgname};
    my $lv = 'pvesan_reclaim';

    my $backing = PVE::SAN::Inventory::vg_backing($vg);
    my @nodiscard = map { $_->{pv} } grep { !$_->{discard} } @$backing;
    die "LUN(s) do not support UNMAP: @nodiscard\n" if @nodiscard;

    my $reserve = int(($p{reserve} // 0) * 1024 * 1024 * 1024);
    my $free = PVE::SAN::LVM::vgs()->{$vg}->{vg_free} // 0;
    my $size = $free - $reserve;
    if ($size < 64 * 1024 * 1024) {
        print "not enough free space to reclaim ($free bytes free, $reserve reserved)\n";
        return;
    }
    $size -= $size % (4 * 1024 * 1024); # whole default extents

    # allocate under the storage lock so PVE can't hand out the same space
    PVE::Storage::Plugin->cluster_lock_storage($storeid, 1, 60, sub {
        run_cmd(['lvcreate', '--yes', '--wipesignatures', 'n', '--zero', 'n',
            '-L', "${size}b", '-n', $lv, $vg]);
    });
    print "discarding $size bytes of free space in $vg (allocations may see less free space meanwhile)\n";
    eval { run_cmd(['blkdiscard', "/dev/$vg/$lv"], timeout => 6 * 3600) };
    my $err = $@;
    PVE::Storage::Plugin->cluster_lock_storage($storeid, 1, 60, sub {
        run_cmd(['lvremove', '--yes', "$vg/$lv"]);
    });
    die $err if $err;
    print "reclaimed $size bytes on datastore '$storeid'\n";
}

# --- device level (cluster wide) ---

sub device_claim {
    my (%p) = @_;
    my $wwid = $p{wwid};
    my $nodes = PVE::SAN::Cluster::nodes();
    check_visible($nodes, [$wwid]);
    PVE::SAN::Config::update(sub {
        my ($cfg) = @_;
        my $d = $cfg->{devices}->{$wwid} //= {};
        delete $d->{detached};
        if (defined($p{alias})) {
            my $owner = PVE::SAN::Config::alias_owner($cfg, $p{alias});
            die "alias '$p{alias}' is already used by $owner\n" if $owner && $owner ne $wwid;
            $d->{alias} = $p{alias};
        }
    });
    PVE::SAN::Cluster::on_nodes($nodes, 'applying multipath configuration', 'POST', 'sync');
}

sub device_set {
    my (%p) = @_;
    my $wwid = $p{wwid};
    my %delete = map { $_ => 1 } PVE::Tools::split_list($p{delete} // '');

    die "invalid alias '$p{alias}'\n" if defined($p{alias}) && !valid_alias($p{alias});
    die "unknown policy '$p{policy}'\n"
        if defined($p{policy}) && !$PVE::SAN::Multipath::POLICIES->{$p{policy}};
    die "invalid no_path_retry '$p{no_path_retry}' (a number of path checks, 'queue' or 'fail')\n"
        if defined($p{no_path_retry}) && !PVE::SAN::Multipath::valid_no_path_retry($p{no_path_retry});

    PVE::SAN::Config::update(sub {
        my ($cfg) = @_;
        my $d = $cfg->{devices}->{$wwid} //= {};
        if (defined($p{alias})) {
            my $owner = PVE::SAN::Config::alias_owner($cfg, $p{alias});
            die "alias '$p{alias}' is already used by $owner\n" if $owner && $owner ne $wwid;
            $d->{alias} = $p{alias};
        }
        $d->{policy} = $p{policy} if defined($p{policy});
        $d->{no_path_retry} = $p{no_path_retry} if defined($p{no_path_retry});
        delete $d->{$_ =~ s/-/_/gr} for grep { /^(?:alias|policy|no-path-retry)$/ } keys %delete;
    });
    PVE::SAN::Cluster::on_nodes(PVE::SAN::Cluster::nodes(), 'applying multipath configuration', 'POST', 'sync');
}

sub device_detach {
    my (%p) = @_;
    my $wwid = $p{wwid};
    my $nodes = PVE::SAN::Cluster::nodes();

    my $res = PVE::SAN::Cluster::on_nodes($nodes, 'checking device usage', 'GET', 'devices', { all => 1 });
    for my $node (@$nodes) {
        my ($d) = grep { $_->{wwid} eq $wwid } @{$res->{$node} // []};
        next if !$d;
        die "[$node] device is in use ($d->{usage})\n"
            if $d->{usage} =~ /^(?:datastore|lvm-vg|lvm-pv|in-use)/;
    }

    PVE::SAN::Config::update(sub {
        my ($cfg) = @_;
        my $d = $cfg->{devices}->{$wwid} //= {};
        $d->{detached} = 1;
        delete $d->{datastore};
    });
    PVE::SAN::Cluster::on_nodes($nodes, 'applying multipath configuration', 'POST', 'sync');
    PVE::SAN::Cluster::on_nodes($nodes, "detaching $wwid", 'POST', "devices/$wwid/detach-local");
    warn_offline();
}

sub device_attach {
    my (%p) = @_;
    my $wwid = $p{wwid};
    my $nodes = PVE::SAN::Cluster::nodes();

    PVE::SAN::Config::update(sub {
        my ($cfg) = @_;
        delete $cfg->{devices}->{$wwid}->{detached} if $cfg->{devices}->{$wwid};
    });
    PVE::SAN::Cluster::on_nodes($nodes, 'applying multipath configuration', 'POST', 'sync');
    PVE::SAN::Cluster::on_nodes($nodes, 'rescanning', 'POST', 'rescan');
    PVE::SAN::Cluster::on_nodes($nodes, 'creating multipath maps', 'POST', 'sync');
}

sub rescan_all {
    my (%p) = @_;
    my $nodes = PVE::SAN::Cluster::nodes();
    my $res = PVE::SAN::Cluster::on_nodes($nodes, 'rescanning SAN adapters', 'POST', 'rescan',
        { ($p{lip} ? (lip => 1) : ()) });
    for my $node (@$nodes) {
        my $r = $res->{$node} // {};
        printf("[%s] %d path(s), new: %s, removed: %s, resized maps: %s\n", $node, $r->{paths} // 0,
            join(' ', @{$r->{new_paths} // []}) || '-',
            join(' ', @{$r->{removed_paths} // []}) || '-',
            join(' ', @{$r->{resized_maps} // []}) || '-');
    }
    warn_offline();
}

1;
