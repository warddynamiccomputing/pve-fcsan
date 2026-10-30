package PVE::SAN::DR;

# Replication and disaster recovery (experimental): the array replicates a
# datastore to a second array, and a second Proxmox VE cluster brings the
# datastore and its guests up from the replica - the role SRM plays for
# vSphere.
#
# Guest configs live in /etc/pve, which stays at the primary site, so each
# protected datastore carries its own: the LV 'pvesan-dr-meta' holds the
# configs of every guest with disks on it and the datastore's recovery plan.
# It has two slots written alternately with a generation number and a
# checksum, so a replica taken mid-write still has one complete copy.
#
# Primary site: enable/disable replication, status, replicate now, recovery
# plan, planned failover (shut down, write the configs, unmount, send a last
# replica). DR site: list replicas, test failover (a writable copy of a
# replica under a new name, guests isolated), failover, import of LUNs an
# admin promoted by hand (any array), run the recovery plan, clean up a test.

use strict;
use warnings;

use Digest::SHA qw(sha256_hex);
use JSON::PP;
use POSIX qw(strftime);

use PVE::SAN::Array;
use PVE::SAN::Cluster;
use PVE::SAN::Config;
use PVE::SAN::LVM;
use PVE::SAN::Snapshot;
use PVE::SAN::Util qw(run_cmd);
use PVE::Tools;

our $META_LV = 'pvesan-dr-meta';
our $SLOT = 4 * 1024 * 1024;
my $MAGIC = "PVESANDR1\n";

my $json = JSON::PP->new->canonical->utf8;

# --- pure helpers (unit tested) ---

# One metadata slot: magic, a JSON header line { gen, len, sha256 }, the
# JSON payload, zero padding to $SLOT bytes.
sub meta_encode {
    my ($gen, $data) = @_;
    my $payload = $json->encode($data);
    my $head = $json->encode({ gen => $gen, len => length($payload), sha256 => sha256_hex($payload) }) . "\n";
    my $bytes = $MAGIC . $head . $payload;
    die "DR metadata too large (" . length($bytes) . " bytes, at most $SLOT)\n" if length($bytes) > $SLOT;
    return $bytes . ("\0" x ($SLOT - length($bytes)));
}

# -> { gen, data } or undef for an empty, torn or foreign slot
sub meta_decode {
    my ($bytes) = @_;
    return undef if !defined($bytes) || substr($bytes, 0, length($MAGIC)) ne $MAGIC;
    my $nl = index($bytes, "\n", length($MAGIC));
    return undef if $nl < 0;
    my $head = eval { $json->decode(substr($bytes, length($MAGIC), $nl - length($MAGIC))) } or return undef;
    my $payload = substr($bytes, $nl + 1, $head->{len} // 0);
    return undef if length($payload) != ($head->{len} // -1) || sha256_hex($payload) ne ($head->{sha256} // '');
    my $data = eval { $json->decode($payload) } or return undef;
    return { gen => $head->{gen} // 0, data => $data };
}

# Newest valid slot: (slot index, decoded) or (undef, undef).
sub meta_pick {
    my (@slots) = @_;
    my ($best, $idx);
    for my $i (0 .. $#slots) {
        my $s = $slots[$i] or next;
        ($best, $idx) = ($s, $i) if !$best || $s->{gen} > $best->{gen};
    }
    return ($idx, $best);
}

# "101:30,102,103" -> [ { vmid => 101, delay => 30 }, ... ] (start order)
sub parse_plan {
    my ($text) = @_;
    my (@plan, %seen);
    for my $item (grep { length } split(/[\s,;]+/, $text // '')) {
        my ($vmid, $delay) = $item =~ /^(\d+)(?::(\d+))?$/
            or die "invalid recovery plan entry '$item' (expected VMID or VMID:DELAY-SECONDS)\n";
        die "VM $vmid is listed twice in the recovery plan\n" if $seen{$vmid}++;
        die "start delay for $vmid is too long (at most 3600 s)\n" if ($delay // 0) > 3600;
        push @plan, { vmid => $vmid + 0, delay => ($delay // 0) + 0 };
    }
    return \@plan;
}

sub format_plan {
    my ($plan) = @_;
    return join(',', map { $_->{delay} ? "$_->{vmid}:$_->{delay}" : $_->{vmid} } @{$plan // []});
}

# New VM IDs for the guests: { old => new } and the IDs already taken.
sub vmid_map {
    my ($guests, $offset, $in_use) = @_;
    my (%map, @taken);
    for my $g (@$guests) {
        my $new = $g->{vmid} + ($offset // 0);
        die "VM ID $new is out of range - use a smaller offset\n" if $new > 999_999_999;
        $map{$g->{vmid}} = $new;
        push @taken, $new if $in_use->{$new};
    }
    return (\%map, [ sort { $a <=> $b } @taken ]);
}

sub renamed_volname {
    my ($volname, $old, $new) = @_;
    return $volname if $old == $new;
    (my $v = $volname) =~ s/^((?:vm|base)-)\Q$old\E-/$1$new-/;
    return $v;
}

my $QEMU_DISK = qr/^(?:ide|sata|scsi|virtio|efidisk|tpmstate|unused)\d+$/;
my $LXC_DISK = qr/^(?:rootfs|mp\d+|unused\d+)$/;

# The config of a guest brought up at the DR site. Disks on $o{from} move to
# $o{to} (renamed to the new VM ID), disks on storages the DR cluster has are
# kept, others dropped. A test copy gets new MACs and identity and starts
# with its links down; a failover keeps the guest's identity.
# Returns (text, [notes], [ [old LV, new LV] ]).
sub dr_guest_config {
    my ($main, %o) = @_;
    my ($from, $to, $old, $new) = @o{qw(from to old new)};
    my $lxc = ($o{type} // 'qemu') eq 'lxc';
    my $disk_re = $lxc ? $LXC_DISK : $QEMU_DISK;
    my $mac = $o{mac} // \&PVE::SAN::Snapshot::random_mac;
    my $uuid = $o{uuid} // \&PVE::SAN::Snapshot::random_uuid;
    my $have = $o{storages} // {};

    my (@out, @notes, @renames);
    for my $line (split(/\n/, $main)) {
        my ($key, $val) = $line =~ /^([a-z][a-z0-9_-]*):\s*(.*)$/;
        if (!defined($key)) {
            push @out, $line;
            next;
        }
        if ($key =~ /^(?:parent|lock|vmstate|runningmachine|runningcpu)$/ || ($o{test} && $key eq 'onboot')) {
            next;
        } elsif ($key =~ $disk_re) {
            if ($val =~ /^\Q$from\E:([^,]+)(.*)$/) {
                my ($vol, $opts) = ($1, $2);
                my $nv = renamed_volname($vol, $old, $new);
                push @renames, [ $vol, $nv ] if $nv ne $vol;
                push @out, "$key: $to:$nv$opts";
            } elsif (!$lxc && ($val =~ /(?:^|,)media=cdrom(?:,|$)/ || $val =~ /^(?:none|cdrom)(?:,|$)/)) {
                my ($store) = $val =~ /^([^:,]+):/;
                if (defined($store) && !$have->{$store}) {
                    push @out, "$key: none,media=cdrom";
                    push @notes, "$key: CD-ROM image on '$store' is not available here, drive left empty";
                } else {
                    push @out, $line;
                }
            } else {
                my ($store) = $val =~ /^([^:,]+):/;
                if (defined($store) && $have->{$store}) {
                    push @out, $line;
                    push @notes, "$key stays on '$store' - check that it holds this guest's data at this site";
                } else {
                    my ($what) = split(/,/, $val);
                    push @notes, "$key ($what) is not on '$from' and is left out";
                }
            }
        } elsif ($key =~ /^net\d+$/) {
            if ($o{test}) {
                if ($lxc) {
                    $val =~ s/(^|,)hwaddr=[0-9A-Fa-f:]{17}/$1 . 'hwaddr=' . $mac->()/e;
                } else {
                    $val =~ s/(^|,)((?:[a-z0-9]+=)?)[0-9A-Fa-f]{2}(?::[0-9A-Fa-f]{2}){5}/$1 . $2 . $mac->()/e;
                }
                $val .= ',link_down=1' if $val !~ /(?:^|,)link_down=1/;
            }
            push @out, "$key: $val";
        } elsif ($o{test} && $key eq 'smbios1') {
            $val =~ s/(^|,)uuid=[0-9a-fA-F-]+/$1 . 'uuid=' . $uuid->()/e;
            push @out, "$key: $val";
        } elsif ($o{test} && $key eq 'vmgenid') {
            push @out, "vmgenid: " . $uuid->();
        } elsif ($o{test} && $key eq 'name') {
            push @out, "name: " . substr($val, 0, 56) . '-drtest';
        } else {
            push @out, $line;
        }
    }
    push @notes, 'network links start down (link_down=1) and MAC addresses are new' if $o{test} && grep { /^net\d+:/ } @out;
    my $text = join("\n", @out);
    $text =~ s/\n*$/\n/;
    return ($text, \@notes, \@renames);
}

# Storage ID a replica is brought up as: "pvesan-gold" -> "gold".
sub storage_from_group {
    my ($group) = @_;
    (my $id = $group // '') =~ s/^pvesan-//;
    $id =~ s/[^A-Za-z0-9_.-]/-/g;
    $id = "dr-$id" if $id !~ /^[A-Za-z]/;
    return $id;
}

# --- metadata LV ---

sub meta_path { return "/dev/$_[0]/$META_LV"; }

sub read_slots {
    my ($path) = @_;
    open(my $fh, '<:raw', $path) or die "cannot open $path: $!\n";
    my @slots;
    for my $i (0, 1) {
        sysseek($fh, $i * $SLOT, 0) or die "seek on $path failed: $!\n";
        my $buf = '';
        my $n = sysread($fh, $buf, $SLOT);
        push @slots, defined($n) ? meta_decode($buf) : undef;
    }
    close($fh);
    return @slots;
}

sub write_slot {
    my ($path, $idx, $bytes) = @_;
    open(my $fh, '+<:raw', $path) or die "cannot open $path: $!\n";
    sysseek($fh, $idx * $SLOT, 0) or die "seek on $path failed: $!\n";
    my $n = syswrite($fh, $bytes);
    die "writing $path failed: $!\n" if !defined($n) || $n != length($bytes);
    require IO::Handle;
    $fh->sync or die "fsync on $path failed: $!\n";
    close($fh) or die "closing $path failed: $!\n";
}

sub with_meta_lv {
    my ($vg, $code) = @_;
    run_cmd(['lvchange', '-ay', "$vg/$META_LV"]);
    my $res = eval { $code->(meta_path($vg)) };
    my $err = $@;
    run_cmd(['lvchange', '-an', "$vg/$META_LV"], noerr => 1);
    die $err if $err;
    return $res;
}

sub has_meta_lv {
    my ($vg) = @_;
    return (grep { $_->{lv_name} eq $META_LV } @{PVE::SAN::LVM::lvs($vg)}) ? 1 : 0;
}

# Guests with disks on the datastore, as they are configured now.
sub collect {
    my ($storeid) = @_;
    my $ds = PVE::SAN::Config::load()->{datastores}->{$storeid} // {};
    my @guests;
    for my $r (sort { $a->{vmid} <=> $b->{vmid} } @{PVE::SAN::Cluster::guest_refs($storeid)}) {
        my $raw = eval { PVE::Tools::file_get_contents($r->{file}) } // next;
        my $main = PVE::SAN::Snapshot::main_section($raw);
        my ($name) = $main =~ /^(?:name|hostname):\s*(\S+)/m;
        push @guests, {
            vmid => $r->{vmid} + 0, type => $r->{type}, node => $r->{node}, name => $name,
            snapshots => PVE::SAN::Snapshot::has_snapshots($raw), config => $main,
        };
    }
    return {
        version => 1,
        storage => $storeid,
        written => time(),
        guests => \@guests,
        plan => $ds->{dr_plan} // [],
    };
}

# Write the datastore's guest configs into its metadata LV (created on first use).
sub write_meta {
    my (%p) = @_;
    my $storeid = $p{storage};
    require PVE::SAN::Datastore;
    require PVE::Storage::Plugin;
    my $vg = PVE::SAN::Datastore::storage($storeid)->{vgname};
    my $data = collect($storeid);
    PVE::Storage::Plugin->cluster_lock_storage($storeid, 1, 60, sub {
        if (!has_meta_lv($vg)) {
            print "creating DR metadata volume $vg/$META_LV\n";
            run_cmd(['lvcreate', '--yes', '--activate', 'n', '--zero', 'n', '-L', ($SLOT * 2 / 1024 / 1024) . 'm',
                '-n', $META_LV, $vg]);
        }
        with_meta_lv($vg, sub {
            my ($path) = @_;
            my ($idx, $cur) = meta_pick(read_slots($path));
            my $next = defined($idx) ? 1 - $idx : 0;
            write_slot($path, $next, meta_encode(($cur ? $cur->{gen} : 0) + 1, $data));
        });
    });
    PVE::SAN::Config::update(sub {
        my $ds = $_[0]->{datastores}->{$storeid} or return;
        $ds->{drmeta_state}->{last} = $data->{written};
        delete $ds->{drmeta_state}->{error};
    });
    print "DR metadata of '$storeid' written: " . scalar(@{$data->{guests}}) . " guest config(s)\n";
    return $data;
}

sub read_meta_vg {
    my ($vg) = @_;
    return undef if !has_meta_lv($vg);
    return with_meta_lv($vg, sub {
        my ($idx, $cur) = meta_pick(read_slots($_[0]));
        return $cur ? $cur->{data} : undef;
    });
}

# --- primary site ---

sub repl_context {
    my ($storeid) = @_;
    my $ds = PVE::SAN::Snapshot::linked_ds($storeid);
    die "'$storeid' is a snapshot copy\n" if $ds->{copy_of};
    die "'$storeid' is a DR test copy\n" if ($ds->{dr_import}->{mode} // '') eq 'test';
    my $drv = PVE::SAN::Array::driver($ds->{array});
    $drv->not_supported('replication') if !$drv->supports_replication;
    my $vols = [ map { $_->{id} } @{$ds->{volumes} // []} ];
    die "datastore '$storeid' has no array volumes recorded\n" if !@$vols;
    return ($ds, $drv, $vols);
}

sub partners {
    my (%p) = @_;
    return PVE::SAN::Array::driver($p{array})->replication_partners();
}

sub enable {
    my (%p) = @_;
    my $storeid = $p{storage};
    my ($ds, $drv, $vols) = repl_context($storeid);
    my $interval = ($p{interval} // 60) * 60;
    my $retain = ($p{retain} // 24) * 3600;
    die "keep replicas at least two intervals long\n" if $retain < 2 * $interval;

    write_meta(storage => $storeid);
    print "enabling replication of '$storeid' (" . scalar(@$vols) . " volume(s)) to '$p{partner}' every "
        . ($interval / 60) . " min, replicas kept " . ($retain / 3600) . " h\n";
    my $group = $drv->replication_enable($vols, $p{partner}, $interval, $retain);
    PVE::SAN::Config::update(sub {
        my $d = $_[0]->{datastores}->{$storeid};
        $d->{replication} = { partner => $p{partner}, interval => $interval, retain => $retain, group => $group };
        $d->{dr_meta} = 1;
    });
    print "replication enabled (array group '$group'); guest configs are refreshed every "
        . ($PVE::SAN::Snapshot::DRMETA_INTERVAL / 60) . " minutes by pvesan-dr.timer\n";
    return $group;
}

sub disable {
    my (%p) = @_;
    my $storeid = $p{storage};
    my ($ds, $drv, $vols) = repl_context($storeid);
    my $r = $ds->{replication} // die "replication of '$storeid' is not enabled\n";
    $drv->replication_disable($vols, $r->{partner});
    PVE::SAN::Config::update(sub {
        my $d = $_[0]->{datastores}->{$storeid};
        delete $d->{replication};
        delete $d->{dr_meta};
    });
    print "replication of '$storeid' to '$r->{partner}' disabled; replicas already on the partner stay there\n";
}

sub status {
    my (%p) = @_;
    my $storeid = $p{storage};
    my ($ds, $drv, $vols) = repl_context($storeid);
    my $r = $ds->{replication} // {};
    my $st = eval { $drv->replication_status($vols) } // {};
    my $err = $@;
    my ($last) = grep { $_->{completed} } @{$st->{transfers} // []};
    my ($running) = grep { !$_->{completed} } @{$st->{transfers} // []};
    my $now = time();
    return {
        storage => $storeid,
        enabled => $r->{partner} ? 1 : 0,
        partner => $r->{partner},
        group => $st->{group} // $r->{group},
        interval => $r->{interval},
        retain => $r->{retain},
        'array-partners' => join(',', @{$st->{partners} // []}),
        'array-schedule' => $st->{enabled},
        'last-replica' => $last ? $last->{name} : undef,
        'last-completed' => $last ? $last->{completed} : undef,
        lag => $last ? $now - ($last->{started} // $last->{completed}) : undef, # age of the newest complete replica
        'in-progress' => $running ? $running->{name} : undef,
        progress => $running ? $running->{progress} : undef,
        'meta-written' => $ds->{drmeta_state}->{last},
        'meta-error' => $ds->{drmeta_state}->{error},
        plan => format_plan($ds->{dr_plan}),
        ($err ? (error => ($err =~ s/\s+$//r)) : ()),
    };
}

sub wait_transfer {
    my ($drv, $vols, $name, $timeout) = @_;
    my $deadline = time() + ($timeout // 3600);
    while (1) {
        my ($t) = grep { $_->{name} eq $name } @{$drv->replication_status($vols)->{transfers} // []};
        if ($t && $t->{completed}) {
            print "replica '$name' received by the partner\n";
            return $t;
        }
        die "replica '$name' was not completed within " . ($timeout // 3600) . " s\n" if time() > $deadline;
        printf("replicating '%s': %s\n", $name, $t && defined($t->{progress}) ? sprintf('%.0f%%', $t->{progress} * 100) : 'queued');
        pause(15);
    }
}

sub replicate {
    my (%p) = @_;
    my $storeid = $p{storage};
    my ($ds, $drv, $vols) = repl_context($storeid);
    die "replication of '$storeid' is not enabled\n" if !$ds->{replication};
    write_meta(storage => $storeid);
    my $name = $p{name} // PVE::SAN::Snapshot::default_name('dr');
    print "taking replica '$name' of '$storeid' and sending it now (crash-consistent)\n";
    $drv->replicate_now($vols, $name);
    wait_transfer($drv, $vols, $name, $p{timeout}) if $p{wait};
    return $name;
}

sub get_plan {
    my (%p) = @_;
    my $ds = PVE::SAN::Config::load()->{datastores}->{$p{storage}} // die "unknown datastore '$p{storage}'\n";
    my %guests = map { $_->{vmid} => $_ } @{PVE::SAN::Cluster::guest_refs($p{storage})};
    my @res = map { { %$_, order => 0, type => ($guests{$_->{vmid}} // {})->{type} // 'missing' } } @{$ds->{dr_plan} // []};
    $res[$_]->{order} = $_ + 1 for 0 .. $#res;
    return \@res;
}

sub set_plan {
    my (%p) = @_;
    my $plan = parse_plan($p{order});
    my %guests = map { $_->{vmid} => 1 } @{PVE::SAN::Cluster::guest_refs($p{storage})};
    my @missing = grep { !$guests{$_->{vmid}} } @$plan;
    die "guest(s) " . join(' ', map { $_->{vmid} } @missing) . " have no disks on '$p{storage}'\n" if @missing;
    PVE::SAN::Config::update(sub {
        my $ds = $_[0]->{datastores}->{$p{storage}} // die "unknown datastore '$p{storage}'\n";
        if (@$plan) { $ds->{dr_plan} = $plan } else { delete $ds->{dr_plan} }
    });
    return get_plan(storage => $p{storage});
}

sub guest_action {
    my ($node, $type, $vmid, $action, %params) = @_;
    run_cmd(['pvesh', 'create', "/nodes/$node/$type/$vmid/status/$action",
        (map { ("--$_", $params{$_}) } sort keys %params)], timeout => 600);
}

# Planned failover, primary side: shut the guests down (reverse plan order),
# write their configs, unmount the datastore everywhere and send one last
# replica, so the DR site starts from exactly the state at shutdown.
sub prepare_failover {
    my (%p) = @_;
    my $storeid = $p{storage};
    die "confirm with the datastore's ID ('$storeid') to prepare its failover\n" if ($p{confirm} // '') ne $storeid;
    my ($ds, $drv, $vols) = repl_context($storeid);
    die "replication of '$storeid' is not enabled\n" if !$ds->{replication};

    my $refs = PVE::SAN::Cluster::guest_refs($storeid);
    my $timeout = $p{timeout} // 600;
    if ($p{shutdown}) {
        my %order;
        my @plan = @{$ds->{dr_plan} // []};
        $order{$plan[$_]->{vmid}} = $_ + 1 for 0 .. $#plan;
        my $status = PVE::SAN::Cluster::guest_status();
        # guests outside the plan first, then the plan backwards
        for my $r (sort { ($order{$b->{vmid}} // 1e9) <=> ($order{$a->{vmid}} // 1e9) } @$refs) {
            my $s = $status->{$r->{vmid}} // next;
            next if ($s->{status} // '') ne 'running';
            print "shutting down $r->{type} $r->{vmid} on $s->{node}\n";
            guest_action($s->{node}, $r->{type}, $r->{vmid}, 'shutdown', timeout => $timeout);
        }
    }
    my $running = PVE::SAN::Cluster::running_guests($refs);
    die "guests using '$storeid' are still running: @$running - stop them (or set 'shutdown')\n" if @$running;

    write_meta(storage => $storeid);
    require PVE::SAN::Datastore;
    PVE::SAN::Datastore::unmount(storage => $storeid);
    my $name = PVE::SAN::Snapshot::default_name('dr-final');
    print "sending final replica '$name'\n";
    $drv->replicate_now($vols, $name);
    wait_transfer($drv, $vols, $name, $p{wait_timeout} // 4 * 3600);
    print "'$storeid' is unmounted here and its final replica '$name' is on '$ds->{replication}->{partner}'.\n"
        . "At the DR site run: pvesan dr failover <array> <replica> --snapshot $name --confirm <replica>\n";
    return $name;
}

# Timer entry point: refresh the metadata of protected datastores, on one
# node that has the datastore.
sub run_meta_sync {
    require PVE::Storage;
    my $node = PVE::SAN::Cluster::local_node();
    my $storecfg = PVE::Storage::config();
    my $jobs = PVE::SAN::Snapshot::claim('drmeta', sub {
        my $s = $storecfg->{ids}->{$_[0]} or return 0;
        return 0 if $s->{disable};
        return !$s->{nodes} || $s->{nodes}->{$node};
    });
    for my $id (@$jobs) {
        my $ok = eval { write_meta(storage => $id); 1 };
        my $err = $ok ? undef : $@;
        print "ERROR: DR metadata of '$id' failed: $err" if $err;
        PVE::SAN::Snapshot::finish('drmeta', $id, $err);
    }
    return { ran => $jobs };
}

# --- DR site ---

sub replica_list {
    my (%p) = @_;
    my $drv = PVE::SAN::Array::driver($p{array});
    $drv->not_supported('replication') if !$drv->supports_replication;
    my $now = time();
    my @res;
    for my $r (@{$drv->replicas()}) {
        my $snaps = eval { $drv->replica_snapshots($r->{id}) } // [];
        my $last = $snaps->[-1];
        push @res, {
            replica => $r->{id},
            source => $r->{source},
            storage => storage_from_group($r->{group}),
            replicas => scalar(@$snaps),
            latest => $last ? $last->{name} : undef,
            'latest-time' => $last ? $last->{created} // $last->{completed} : undef,
            age => $last ? $now - ($last->{created} // $last->{completed}) : undef,
            volumes => $last ? scalar(@{$last->{members}}) : undef,
        };
    }
    return \@res;
}

sub replica_snapshot_list {
    my (%p) = @_;
    my $drv = PVE::SAN::Array::driver($p{array});
    return [ map { { name => $_->{name}, created => $_->{created}, completed => $_->{completed},
        volumes => scalar(@{$_->{members}}) } } @{$drv->replica_snapshots($p{replica})} ];
}

# Bring a replica up: copy its newest (or the named) replica snapshot to new
# volumes, map them to this cluster and import them.
sub from_replica {
    my (%p) = @_;
    my $mode = $p{mode};
    my $drv = PVE::SAN::Array::driver($p{array});
    $drv->not_supported('replication') if !$drv->supports_replication;
    my ($rep) = grep { $_->{id} eq $p{replica} } @{$drv->replicas()};
    die "array '$p{array}' has no replica '$p{replica}'\n" if !$rep;
    my $snaps = $drv->replica_snapshots($rep->{id});
    die "replica '$p{replica}' has no complete replica snapshot yet\n" if !@$snaps;
    my ($snap) = defined($p{snapshot}) ? grep { $_->{name} eq $p{snapshot} } @$snaps : ($snaps->[-1]);
    die "replica '$p{replica}' has no complete snapshot '$p{snapshot}'\n" if !$snap;

    my $base = storage_from_group($rep->{group});
    my $storeid = $p{storage} // ($mode eq 'test' ? "$base-drtest" : $base);
    precheck($storeid);
    my $hc = PVE::SAN::Array::hostcluster(PVE::SAN::Array::config($p{array}));
    my $off = PVE::SAN::Cluster::offline_nodes();
    die "all nodes must be online to bring up a replica (offline: @$off)\n" if @$off;

    print(($mode eq 'test' ? 'TEST FAILOVER' : 'FAILOVER') . " of replica '$p{replica}' from snapshot '$snap->{name}' ("
        . strftime('%Y-%m-%d %H:%M:%S', localtime($snap->{created} // $snap->{completed})) . ") as datastore '$storeid'\n");

    my $stamp = strftime('%Y%m%d%H%M', localtime());
    my @members = @{$snap->{members}};
    my (@vols, @mapped);
    my $res = eval {
        for my $i (0 .. $#members) {
            my $name = $drv->volume_name_for(@members > 1 ? sprintf('%s-%s-%02d', $storeid, $stamp, $i) : "$storeid-$stamp");
            print "copying replica $members[$i]->{id} to volume '$name'\n";
            my $v = $drv->replica_clone($members[$i], $name);
            push @vols, $v;
            print "mapping '$name' to host cluster '$hc'\n";
            $drv->map_to_hostcluster($v->{id}, $hc);
            push @mapped, $v;
            if (!$v->{wwid}) {
                $v->{wwid} = $drv->volume($v->{id})->{wwid} // die "array reports no WWID for volume $v->{id}\n";
            }
        }
        import_luns(
            storage => $storeid, mode => $mode, wwids => [ map { $_->{wwid} } @vols ],
            array => $p{array}, volumes => [ map { { id => $_->{id}, name => $_->{name}, wwid => $_->{wwid} } } @vols ],
            source => $p{replica}, snapshot => $snap->{name},
            vmid_offset => $p{vmid_offset}, start => $p{start}, node => $p{node}, timeout => $p{timeout},
        );
    };
    if (my $err = $@) {
        print "bringing up the replica failed - removing the copied volumes\n";
        for my $v (@vols) {
            eval { $drv->unmap_from_hostcluster($v->{id}, $hc) } if grep { $_ == $v } @mapped;
        }
        my $nodes = PVE::SAN::Cluster::nodes();
        eval { PVE::SAN::Cluster::on_nodes($nodes, 'removing stale paths', 'POST', 'cleanup-paths') } if @mapped;
        for my $v (@vols) {
            eval { $drv->delete_volume($v->{id}) };
            print "WARNING: could not delete volume $v->{id} on the array: $@" if $@;
        }
        PVE::SAN::Config::update(sub { delete $_[0]->{devices}->{$_->{wwid}} for grep { $_->{wwid} } @vols; });
        eval { PVE::SAN::Cluster::on_nodes($nodes, 'applying multipath configuration', 'POST', 'sync') };
        die $err;
    }
    return $res;
}

sub precheck {
    my ($storeid) = @_;
    die "invalid storage ID '$storeid'\n" if $storeid !~ /^[a-z][a-z0-9\-_.]*[a-z0-9]$/i;
    require PVE::Storage;
    die "storage '$storeid' already exists here\n" if PVE::Storage::config()->{ids}->{$storeid};
    die "volume group 'san_$storeid' already exists here\n" if PVE::SAN::LVM::vgs()->{"san_$storeid"};
}

# Import LUNs holding a replicated datastore, register it and recreate its
# guests from the metadata. Also the entry point for LUNs an admin promoted
# on the array by hand (no driver needed).
sub import_luns {
    my (%p) = @_;
    my $storeid = $p{storage};
    my $mode = $p{mode};
    my $test = $mode eq 'test';
    my $wwids = $p{wwids};
    die "no LUNs given\n" if !@$wwids;
    precheck($storeid);
    my $vg = "san_$storeid";
    my $node = $p{node} // PVE::SAN::Cluster::local_node();
    my $nodes = PVE::SAN::Cluster::nodes();

    require PVE::SAN::Provision;
    require PVE::SAN::Datastore;
    require PVE::Storage;

    my ($meta, $map, $imported);
    my $ok = eval {
        # this node imports first; the others see the LUNs once their UUIDs are new
        my $here = [ PVE::SAN::Cluster::local_node() ];
        PVE::SAN::Provision::wait_visible($here, $_, $p{timeout}) for @$wwids;
        my $devs = PVE::SAN::Datastore::register_devices($here, $storeid, $wwids, 0);
        print "importing the volume group as '$vg' (new PV and VG UUIDs)\n";
        run_cmd(['vgimportclone', '--basevgname', $vg,
            (PVE::SAN::LVM::devicesfile_enabled() ? ('--importdevices') : ()), @$devs], timeout => 300);
        $imported = 1;

        $meta = read_meta_vg($vg);
        if (!$meta) {
            print "WARNING: the datastore carries no guest configs (was DR protection enabled on it?); "
                . "only the datastore is imported\n";
            $meta = { guests => [], plan => [] };
        } else {
            print "guest configs from " . strftime('%Y-%m-%d %H:%M:%S', localtime($meta->{written})) . ": "
                . scalar(@{$meta->{guests}}) . " guest(s)\n";
        }
        my $taken;
        ($map, $taken) = vmid_map($meta->{guests}, $p{vmid_offset}, PVE::SAN::Cluster::guest_status());
        die "VM ID(s) @$taken are already used in this cluster - set 'vmid-offset'\n" if @$taken;

        my $from = $meta->{storage} // $storeid;
        my $storages = { %{PVE::Storage::config()->{ids}} };
        my %lv = map { $_->{lv_name} => 1 } @{PVE::SAN::LVM::lvs($vg)};
        for my $g (@{$meta->{guests}}) {
            my ($text, $notes, $renames) = dr_guest_config($g->{config}, type => $g->{type}, from => $from,
                to => $storeid, old => $g->{vmid}, new => $map->{$g->{vmid}}, test => $test, storages => $storages);
            print "WARNING: $g->{type} $g->{vmid} had snapshots; only its current state is brought up\n" if $g->{snapshots};
            for my $rn (@$renames) {
                next if !$lv{$rn->[0]};
                print "renaming $vg/$rn->[0] to $rn->[1]\n";
                run_cmd(['lvrename', $vg, $rn->[0], $rn->[1]]);
            }
            $g->{new_config} = $text;
            $g->{notes} = $notes;
        }
        PVE::SAN::LVM::vg_deactivate($vg);
        1;
    };
    if (my $err = $@) {
        eval { PVE::SAN::LVM::vg_deactivate($vg) } if $imported;
        PVE::SAN::Config::update(sub {
            my ($cfg) = @_;
            for my $w (@$wwids) {
                delete $cfg->{devices}->{$w}->{datastore} if $cfg->{devices}->{$w};
            }
        });
        die $err;
    }

    print "registering storage '$storeid'\n";
    PVE::API2::Storage::Config->create({
        storage => $storeid,
        type => 'fcsan',
        vgname => $vg,
        shared => 1,
        content => 'images,rootdir',
        'fc-wwids' => join(',', @$wwids),
    });
    PVE::SAN::Provision::wait_visible($nodes, $_, $p{timeout}) for @$wwids;
    PVE::SAN::Cluster::on_nodes($nodes, 'refreshing LVM device lists', 'POST', 'sync');

    my @created;
    for my $g (@{$meta->{guests}}) {
        my $new = $map->{$g->{vmid}};
        my $dir = $g->{type} eq 'lxc' ? 'lxc' : 'qemu-server';
        my $file = "/etc/pve/nodes/$node/$dir/$new.conf";
        if (-e $file) {
            print "WARNING: $file exists, $g->{type} $g->{vmid} not created\n";
            next;
        }
        PVE::Tools::file_set_contents($file, $g->{new_config});
        print "created $g->{type} $new" . ($new != $g->{vmid} ? " (was $g->{vmid})" : '') . " on $node"
            . ($g->{name} ? " ($g->{name})" : '') . "\n";
        print "  note: $_\n" for @{$g->{notes}};
        push @created, { vmid => $new, type => $g->{type}, from => $g->{vmid} };
    }
    my @plan = map { { vmid => $map->{$_->{vmid}}, delay => $_->{delay} } } grep { $map->{$_->{vmid}} } @{$meta->{plan} // []};

    PVE::SAN::Config::update(sub {
        my ($cfg) = @_;
        $cfg->{datastores}->{$storeid} = {
            created => time(),
            label => ($test ? 'DR test of ' : 'failed over from ') . ($p{source} // 'replica'),
            ($p{array} ? (array => $p{array}, volumes => $p{volumes}) : ()),
            dr_import => {
                mode => $mode, source => $p{source} // 'manual', snapshot => $p{snapshot}, node => $node,
                time => time(), guests => \@created,
            },
            ($test ? () : (@plan ? (dr_plan => \@plan) : ())),
            ($test && @plan ? (dr_test_plan => \@plan) : ()),
        };
    });
    print "datastore '$storeid' is up with " . scalar(@created) . " guest(s)"
        . ($test ? "; this is a test copy - remove it with 'pvesan dr cleanup $storeid'" : '') . "\n";
    run_plan(storage => $storeid) if $p{start};
    return $storeid;
}

sub import_record {
    my ($storeid) = @_;
    my $ds = PVE::SAN::Config::load()->{datastores}->{$storeid} // {};
    die "'$storeid' was not brought up by pvesan dr\n" if !$ds->{dr_import};
    return $ds;
}

sub pause { sleep($_[0]); }

sub remove_config {
    my ($file) = @_;
    unlink($file) or die "cannot remove $file: $!\n";
}

# Start the guests of a datastore brought up from a replica, in plan order.
sub run_plan {
    my (%p) = @_;
    my $ds = import_record($p{storage});
    my $imp = $ds->{dr_import};
    my $plan = $ds->{dr_test_plan} // $ds->{dr_plan} // [];
    my %type = map { $_->{vmid} => $_->{type} } @{$imp->{guests} // []};
    if (!@$plan) {
        print "no recovery plan for '$p{storage}' - start the guests by hand\n";
        return [];
    }
    my $status = PVE::SAN::Cluster::guest_status();
    my @started;
    for my $i (0 .. $#$plan) {
        my $e = $plan->[$i];
        my $s = $status->{$e->{vmid}};
        if (!$s) {
            print "WARNING: guest $e->{vmid} of the plan does not exist here, skipped\n";
            next;
        }
        if (($s->{status} // '') eq 'running') {
            print "$e->{vmid} is already running\n";
        } else {
            print "starting " . ($type{$e->{vmid}} // $s->{type}) . " $e->{vmid} on $s->{node}\n";
            my $ok = eval { guest_action($s->{node}, $type{$e->{vmid}} // $s->{type}, $e->{vmid}, 'start'); 1 };
            print "WARNING: starting $e->{vmid} failed: $@" if !$ok;
            push @started, $e->{vmid} if $ok;
        }
        if ($e->{delay} && $i < $#$plan) {
            print "waiting $e->{delay} s before the next guest\n";
            pause($e->{delay});
        }
    }
    my %planned = map { $_->{vmid} => 1 } @$plan;
    my @rest = grep { !$planned{$_} } map { $_->{vmid} } @{$imp->{guests} // []};
    print "not in the plan, left stopped: @rest\n" if @rest;
    return \@started;
}

# Remove a test copy: stop and remove its guests, then the datastore and
# (if pvesan copied them) its array volumes.
sub cleanup {
    my (%p) = @_;
    my $storeid = $p{storage};
    my $ds = import_record($storeid);
    my $imp = $ds->{dr_import};
    die "'$storeid' was brought up by a failover, not a test - it is production now and is not removed this way\n"
        if $imp->{mode} ne 'test';

    my $status = PVE::SAN::Cluster::guest_status();
    for my $g (@{$imp->{guests} // []}) {
        my $s = $status->{$g->{vmid}} // next;
        if (($s->{status} // '') eq 'running') {
            print "stopping $g->{type} $g->{vmid}\n";
            guest_action($s->{node}, $g->{type}, $g->{vmid}, 'stop');
        }
        my $dir = $g->{type} eq 'lxc' ? 'lxc' : 'qemu-server';
        my $file = "/etc/pve/nodes/$s->{node}/$dir/$g->{vmid}.conf";
        my $raw = eval { PVE::Tools::file_get_contents($file) } // '';
        if ($raw !~ /:\s*\Q$storeid\E:/m) {
            print "WARNING: $g->{type} $g->{vmid} no longer uses '$storeid', left alone\n";
            next;
        }
        print "removing test $g->{type} $g->{vmid}\n";
        remove_config($file);
    }

    require PVE::SAN::Provision;
    require PVE::SAN::Datastore;
    if ($ds->{array}) {
        PVE::SAN::Provision::destroy(storage => $storeid, destroy_data => 1);
    } else {
        # LUNs an admin presented: release them, leave their data alone
        my $scfg = PVE::SAN::Datastore::storage($storeid);
        my $nodes = PVE::SAN::Datastore::storage_nodes($scfg);
        my @wwids = PVE::Tools::split_list($scfg->{'fc-wwids'} // '');
        PVE::SAN::Cluster::on_nodes($nodes, "deactivating VG $scfg->{vgname}", 'POST', 'vg-deactivate',
            { vgname => $scfg->{vgname} });
        PVE::API2::Storage::Config->delete({ storage => $storeid });
        PVE::SAN::Config::update(sub { delete $_[0]->{datastores}->{$storeid} });
        PVE::SAN::Datastore::device_detach(wwid => $_) for @wwids;
        print "test datastore '$storeid' released; its LUNs can now be unmapped on the array: @wwids\n";
    }
}

1;
