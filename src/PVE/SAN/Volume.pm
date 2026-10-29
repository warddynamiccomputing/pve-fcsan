package PVE::SAN::Volume;

# Storage type 'fcsanvol' (the vVols equivalent): every VM disk is its own
# array volume, mapped to the cluster's host cluster. No LVM and no
# metadata on the LUNs; the array holds the volumes, the pvesan cluster DB
# remembers which LUN is which disk:
#
#   devices.<wwid> = { alias => '<storage>-<volname>', datastore => <storage>,
#                      disk => <volname>, lun => <LUN number>,
#                      array_volume => { id, name } }
#
# The array volume is named '<storage prefix>-<volname>', so list_images
# needs only the array. A node only scans for a disk's LUN number when it
# activates the disk (targeted rescan), never the whole fabric.
#
# Called by PVE::Storage::Custom::FCSANVolPlugin; each function gets the
# storage ID and its storage.cfg section.

use strict;
use warnings;

use POSIX qw(ceil);

use PVE::SAN::Array;
use PVE::SAN::Cluster;
use PVE::SAN::Config;
use PVE::SAN::Multipath;
use PVE::SAN::Util qw(run_cmd valid_alias);
use PVE::Tools;

my $GIB = 1024 * 1024 * 1024;
our $DEFAULT_MAX_LUNS = 255;
our $STATUS_CACHE_DIR = '/run/pvesan';
my $STATUS_TTL = 60;

# --- names (pure) ---

sub parse_volname {
    my ($volname) = @_;
    my ($name, $base, $vmid) = $volname =~ /^((base)?(?:vm)?-(\d+)-disk-\d+)$/
        or die "unable to parse fcsanvol volume name '$volname'\n";
    return ($name, $vmid, $base ? 1 : 0);
}

sub alias_for {
    my ($storeid, $volname) = @_;
    my $alias = "$storeid-$volname";
    die "multipath alias '$alias' is too long or invalid - use a shorter storage ID\n" if !valid_alias($alias);
    return $alias;
}

sub path_for {
    my ($storeid, $volname) = @_;
    return '/dev/mapper/' . alias_for($storeid, $volname);
}

sub array_prefix {
    my ($drv, $storeid) = @_;
    return $drv->object_name_for($storeid) . '-';
}

sub array_name {
    my ($drv, $storeid, $volname) = @_;
    my $name = array_prefix($drv, $storeid) . $volname;
    die "array volume name '$name' is not valid on this array (too long?) - use a shorter storage ID\n"
        if !$drv->valid_name($name);
    return $name;
}

# Next free 'vm-<vmid>-disk-<n>' among the existing names.
sub next_disk_name {
    my ($vmid, $existing) = @_;
    my %used = map { $_ => 1 } @$existing;
    for my $n (0 .. 9999) {
        return "vm-$vmid-disk-$n" if !$used{"vm-$vmid-disk-$n"} && !$used{"base-$vmid-disk-$n"};
    }
    die "no free disk name for VM $vmid\n";
}

# PVE snapshot names allow '_', array snapshot names don't.
sub check_snapname {
    my ($drv, $snap) = @_;
    die "snapshot name '$snap' is not possible on this storage: use letters, digits and '-' (no '_'), start with a letter, at most 40 characters\n"
        if !$drv->valid_snapshot_name($snap);
}

# --- context ---

sub driver {
    my ($storeid, $scfg) = @_;
    my $array = $scfg->{'fc-array'} // die "storage '$storeid' has no 'fc-array'\n";
    my $drv = PVE::SAN::Array::driver($array);
    $drv->not_supported('volumes per VM disk') if !$drv->supports_disk_volumes;
    return ($drv, PVE::SAN::Array::hostcluster(PVE::SAN::Array::config($array)));
}

# (wwid, device record) of a disk, from the cluster DB.
sub record {
    my ($storeid, $volname, $cfg) = @_;
    $cfg //= PVE::SAN::Config::load();
    for my $wwid (keys %{$cfg->{devices} // {}}) {
        my $d = $cfg->{devices}->{$wwid};
        return ($wwid, $d) if ($d->{datastore} // '') eq $storeid && ($d->{disk} // '') eq $volname;
    }
    die "volume '$storeid:$volname' is not known to pvesan\n";
}

sub disk_names {
    my ($drv, $storeid) = @_;
    my $prefix = array_prefix($drv, $storeid);
    return [ map { substr($_->{name}, length($prefix)) } @{$drv->volumes_named($prefix)} ];
}

# Map a new array volume to the cluster and record it. Returns the record.
sub attach_new {
    my ($drv, $hc, $storeid, $volname, $vol) = @_;
    my $mapped;
    my $res = eval {
        $drv->map_to_hostcluster($vol->{id}, $hc);
        $mapped = 1;
        $vol = $drv->volume($vol->{id}) if !$vol->{wwid};
        my $wwid = $vol->{wwid} // die "array reports no WWID for volume $vol->{id}\n";
        my $lun = $drv->host_lun($vol->{id}, $hc);
        die "array reports no LUN number for volume $vol->{id}\n" if !defined($lun);
        my $alias = alias_for($storeid, $volname);
        PVE::SAN::Config::update(sub {
            my ($cfg) = @_;
            die "multipath alias '$alias' is already used\n" if PVE::SAN::Config::alias_owner($cfg, $alias);
            $cfg->{devices}->{$wwid} = {
                alias => $alias,
                datastore => $storeid,
                disk => $volname,
                lun => $lun + 0,
                array_volume => { id => $vol->{id}, name => $vol->{name} },
                policy => $drv->default_policy,
            };
        });
        { wwid => $wwid, lun => $lun };
    };
    if (my $err = $@) {
        eval { $drv->unmap_from_hostcluster($vol->{id}, $hc) } if $mapped;
        eval { $drv->delete_volume($vol->{id}) };
        die $err;
    }
    return $res;
}

# --- storage plugin entry points ---

sub alloc {
    my ($storeid, $scfg, $vmid, $name, $size_kib) = @_;
    my ($drv, $hc) = driver($storeid, $scfg);
    my $existing = disk_names($drv, $storeid);
    my $max = $scfg->{'fc-max-luns'} // $DEFAULT_MAX_LUNS;
    die "storage '$storeid' already holds $max volumes ('fc-max-luns'); every volume is a LUN on every node\n"
        if @$existing >= $max;

    my $volname = $name // next_disk_name($vmid, $existing);
    my (undef, $owner) = parse_volname($volname);
    die "illegal name '$volname' - should be 'vm-$vmid-disk-<n>'\n" if $owner != $vmid || $volname =~ /^base-/;
    die "volume '$storeid:$volname' already exists\n" if grep { $_ eq $volname } @$existing;

    my $gib = ceil(($size_kib // 0) / (1024 * 1024)) || 1;
    my $vol = $drv->create_volume(name => array_name($drv, $storeid, $volname), pool => $scfg->{'fc-pool'},
        size_gib => $gib, thin => 1);
    attach_new($drv, $hc, $storeid, $volname, $vol);
    return $volname;
}

# Detach the LUN on every node, unmap and delete the array volume.
sub free {
    my ($storeid, $scfg, $volname) = @_;
    my ($drv, $hc) = driver($storeid, $scfg);
    my ($wwid, $rec) = record($storeid, $volname);
    PVE::SAN::Config::update(sub { $_[0]->{devices}->{$wwid}->{detached} = 1 });
    my $nodes = PVE::SAN::Cluster::nodes();
    eval { PVE::SAN::Cluster::on_nodes($nodes, 'applying multipath configuration', 'POST', 'sync') };
    eval { PVE::SAN::Cluster::on_nodes($nodes, "removing paths of $volname", 'POST', "devices/$wwid/detach-local") };
    warn "WARNING: $@" if $@;
    $drv->unmap_from_hostcluster($rec->{array_volume}->{id}, $hc);
    $drv->delete_volume($rec->{array_volume}->{id});
    # stays blacklisted on nodes that missed the detach until they sync again
    PVE::SAN::Config::update(sub { delete $_[0]->{devices}->{$wwid} });
    eval { PVE::SAN::Cluster::on_nodes($nodes, 'applying multipath configuration', 'POST', 'sync') };
    return undef;
}

# Make the disk's LUN usable on this node: scan just its LUN number, apply
# the multipath configuration and wait for the map.
sub activate {
    my ($storeid, $scfg, $volname) = @_;
    my $path = path_for($storeid, $volname);
    return $path if -b $path;
    my ($wwid, $rec) = record($storeid, $volname);
    require PVE::SAN::Ops;
    if (!PVE::SAN::Multipath::map_for_wwid($wwid)) {
        PVE::SAN::Ops::rescan_lun($rec->{lun});
    }
    PVE::SAN::Ops::sync();
    PVE::SAN::Multipath::wait_for_map($wwid, 30)
        // die "LUN $wwid ($storeid:$volname, LUN $rec->{lun}) did not appear on this node - check zoning and the host cluster on the array\n";
    for (1 .. 20) {
        return $path if -b $path;
        select(undef, undef, undef, 0.5);
    }
    die "multipath map for $storeid:$volname is not named '" . alias_for($storeid, $volname) . "' on this node\n";
}

sub list {
    my ($storeid, $scfg, $vmid, $vollist) = @_;
    my ($drv) = driver($storeid, $scfg);
    my $prefix = array_prefix($drv, $storeid);
    my %want = map { $_ => 1 } @{$vollist // []};
    my @res;
    for my $v (@{$drv->volumes_named($prefix)}) {
        my $volname = substr($v->{name}, length($prefix));
        my ($name, $owner) = eval { parse_volname($volname) } or next;
        my $volid = "$storeid:$volname";
        next if $vollist && !$want{$volid};
        next if defined($vmid) && $owner != $vmid;
        push @res, { volid => $volid, format => 'raw', size => $v->{capacity}, vmid => $owner };
    }
    return [ sort { $a->{volid} cmp $b->{volid} } @res ];
}

# (total, free, used, active) of the storage's array pool. pvestatd asks
# every 10 seconds on every node, so the answer is cached per node.
sub status {
    my ($storeid, $scfg) = @_;
    my $file = "$STATUS_CACHE_DIR/fcsanvol-$storeid.status";
    if (my @st = stat($file)) {
        if (time() - $st[9] < $STATUS_TTL) {
            my $raw = eval { PVE::Tools::file_get_contents($file) } // '';
            my @v = split(/\s+/, $raw);
            return @v if @v == 4;
        }
    }
    my ($drv) = driver($storeid, $scfg);
    my ($pool) = grep { $_->{name} eq ($scfg->{'fc-pool'} // '') } @{$drv->pools()};
    die "pool '" . ($scfg->{'fc-pool'} // '') . "' not found on array '$scfg->{'fc-array'}'\n" if !$pool;
    my ($total, $free) = ($pool->{capacity} // 0, $pool->{free} // 0);
    my @v = ($total, $free, $total - $free, 1);
    mkdir($STATUS_CACHE_DIR) if ! -d $STATUS_CACHE_DIR;
    eval { PVE::Tools::file_set_contents($file, join(' ', @v)) };
    return @v;
}

sub size {
    my ($storeid, $scfg, $volname) = @_;
    my ($wwid, $rec) = record($storeid, $volname);
    if (my $dm = PVE::SAN::Multipath::map_for_wwid($wwid)) {
        my $out = run_cmd(['blockdev', '--getsize64', "/dev/mapper/$dm"], noerr => 1) // '';
        return $1 + 0 if $out =~ /^(\d+)/;
    }
    my ($drv) = driver($storeid, $scfg);
    return $drv->volume($rec->{array_volume}->{id})->{capacity};
}

# Grow on the array, then make this node (where PVE resizes the running
# disk) see the new size. Other nodes pick it up when they activate it.
sub resize {
    my ($storeid, $scfg, $volname, $bytes) = @_;
    my ($drv) = driver($storeid, $scfg);
    my ($wwid, $rec) = record($storeid, $volname);
    my $cur = $drv->volume($rec->{array_volume}->{id});
    die "new size must be larger than the current size\n" if $bytes < $cur->{capacity};
    $bytes += 512 - $bytes % 512 if $bytes % 512;
    $drv->expand_volume($rec->{array_volume}->{id}, $bytes - $cur->{capacity}) if $bytes > $cur->{capacity};
    if (PVE::SAN::Multipath::map_for_wwid($wwid)) {
        require PVE::SAN::Ops;
        PVE::SAN::Ops::refresh_device($wwid);
    }
    return $bytes;
}

sub snapshot {
    my ($storeid, $scfg, $volname, $snap) = @_;
    my ($drv) = driver($storeid, $scfg);
    check_snapname($drv, $snap);
    my (undef, $rec) = record($storeid, $volname);
    $drv->snapshot_create([ $rec->{array_volume}->{id} ], $snap);
    return undef;
}

sub find_snapshot {
    my ($drv, $rec, $snap) = @_;
    my ($s) = grep { $_->{name} eq $snap } @{$drv->snapshots([ $rec->{array_volume}->{id} ])};
    die "snapshot '$snap' of array volume '$rec->{array_volume}->{name}' not found\n" if !$s;
    return $s;
}

sub snapshot_delete {
    my ($storeid, $scfg, $volname, $snap) = @_;
    my ($drv) = driver($storeid, $scfg);
    my (undef, $rec) = record($storeid, $volname);
    my ($s) = grep { $_->{name} eq $snap } @{$drv->snapshots([ $rec->{array_volume}->{id} ])};
    $drv->snapshot_delete($s) if $s; # already gone is fine
    return undef;
}

# The VM is stopped (PVE checks); drop any buffered blocks of the old data.
sub snapshot_rollback {
    my ($storeid, $scfg, $volname, $snap) = @_;
    my ($drv) = driver($storeid, $scfg);
    my ($wwid, $rec) = record($storeid, $volname);
    $drv->snapshot_restore($rec->{array_volume}->{id}, find_snapshot($drv, $rec, $snap));
    my $path = path_for($storeid, $volname);
    run_cmd(['blockdev', '--flushbufs', $path], noerr => 1) if -b $path;
    return undef;
}

# Template: rename vm-N-disk-M to base-N-disk-M on the array and in the DB.
sub create_base {
    my ($storeid, $scfg, $volname) = @_;
    my ($drv) = driver($storeid, $scfg);
    my (undef, undef, $isbase) = parse_volname($volname);
    die "'$volname' is already a base volume\n" if $isbase;
    my ($wwid, $rec) = record($storeid, $volname);
    (my $newname = $volname) =~ s/^vm-/base-/;
    my $newarray = array_name($drv, $storeid, $newname);
    my $alias = alias_for($storeid, $newname);
    $drv->rename_volume($rec->{array_volume}->{id}, $newarray);
    PVE::SAN::Config::update(sub {
        my ($cfg) = @_;
        my $d = $cfg->{devices}->{$wwid};
        $d->{disk} = $newname;
        $d->{alias} = $alias;
        # on arrays where the name is the ID (Pure) the ID changes too
        $d->{array_volume} = { id => ($d->{array_volume}->{id} eq $d->{array_volume}->{name} ? $newarray : $d->{array_volume}->{id}),
            name => $newarray };
    });
    eval { PVE::SAN::Cluster::on_nodes(PVE::SAN::Cluster::nodes(), 'renaming multipath map', 'POST', 'sync') };
    warn "WARNING: $@" if $@;
    return $newname;
}

# Linked clone from a template, or a clone of a snapshot: an array copy,
# which takes seconds and no space until written.
sub clone {
    my ($storeid, $scfg, $volname, $vmid, $snap) = @_;
    my ($drv, $hc) = driver($storeid, $scfg);
    my (undef, undef, $isbase) = parse_volname($volname);
    die "'$volname' is not a base volume and no snapshot was given\n" if !$isbase && !$snap;
    my (undef, $rec) = record($storeid, $volname);
    my $existing = disk_names($drv, $storeid);
    my $max = $scfg->{'fc-max-luns'} // $DEFAULT_MAX_LUNS;
    die "storage '$storeid' already holds $max volumes ('fc-max-luns')\n" if @$existing >= $max;
    my $newname = next_disk_name($vmid, $existing);
    my $target = array_name($drv, $storeid, $newname);
    my $vol = $snap
        ? $drv->snapshot_clone(find_snapshot($drv, $rec, $snap), $target)
        : $drv->copy_volume($rec->{array_volume}->{id}, $target);
    attach_new($drv, $hc, $storeid, $newname, $vol);
    return $newname;
}

1;
