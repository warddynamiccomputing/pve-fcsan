package PVE::SAN::Monitor;

# Monitoring, health and cluster lifecycle (where the vSphere plugins show
# storage health): the array's view of each datastore (pools, volumes, data
# reduction, array alerts) cached in the cluster filesystem, I/O rates per
# LUN, datastore <-> VM relations, path health with alerts through Proxmox
# notification targets, zoning hints, and registration of new nodes on the
# arrays.
#
# pvesan-monitor.timer runs run() on every node every 5 minutes: each node
# checks its own paths; one node (holding a lease in the cache file) reads
# the arrays.

use strict;
use warnings;

use JSON::PP;

use PVE::Cluster;

use PVE::SAN::Array;
use PVE::SAN::Array::Base;
use PVE::SAN::Cluster;
use PVE::SAN::Config;
use PVE::SAN::Util qw(read_attr);
use PVE::Tools;

our $CACHE_FILE = '/etc/pve/pvesan/monitor.json';
our $STATE_DIR = '/var/lib/pvesan';
our $DEFAULT_POOL_THRESHOLD = 85; # percent used
my $LEASE = 240; # seconds; shorter than the timer interval
my $VIEW_MAX_AGE = 900;

my $json = JSON::PP->new->canonical->allow_nonref;

# ---------------- pure helpers (unit tested) ----------------

# /sys/block/<dev>/stat: reads, read merges, read sectors, read ms, writes,
# write merges, write sectors, write ms, in flight, io ms, ...
sub parse_stat {
    my ($text) = @_;
    my @f = split(' ', $text // '');
    return undef if @f < 11;
    return {
        r_ios => $f[0], r_sectors => $f[2], r_ms => $f[3],
        w_ios => $f[4], w_sectors => $f[6], w_ms => $f[7],
        in_flight => $f[8], io_ms => $f[9],
    };
}

sub io_rates {
    my ($a, $b, $secs) = @_;
    return undef if !$a || !$b || !$secs || $secs <= 0;
    my %d = map { $_ => ($b->{$_} // 0) - ($a->{$_} // 0) } qw(r_ios r_sectors r_ms w_ios w_sectors w_ms io_ms);
    return undef if grep { $_ < 0 } values %d; # counter reset (map recreated)
    my $round = sub { int($_[0] * 10 + 0.5) / 10 };
    return {
        r_iops => $round->($d{r_ios} / $secs),
        w_iops => $round->($d{w_ios} / $secs),
        r_bps => int($d{r_sectors} * 512 / $secs),
        w_bps => int($d{w_sectors} * 512 / $secs),
        r_lat_ms => $d{r_ios} ? $round->($d{r_ms} / $d{r_ios}) : 0,
        w_lat_ms => $d{w_ios} ? $round->($d{w_ms} / $d{w_ios}) : 0,
        util => $round->(100 * $d{io_ms} / ($secs * 1000)) > 100 ? 100 : $round->(100 * $d{io_ms} / ($secs * 1000)),
        in_flight => $b->{in_flight} // 0,
    };
}

# Path problems of one node.
#   $devices: Inventory::devices() rows; $watch: { wwid => datastore } that
#   must be present here; $expected: { wwid => highest path count seen }.
# Returns ({ key => message }, updated $expected).
sub path_problems {
    my ($devices, $watch, $expected) = @_;
    my %exp = %{$expected // {}};
    my %by = map { $_->{wwid} => $_ } @$devices;
    my %problems;
    for my $wwid (sort keys %$watch) {
        my $ds = $watch->{$wwid};
        my $d = $by{$wwid};
        if (!$d) {
            $problems{"missing:$wwid"} = "LUN $wwid of datastore '$ds' is not visible";
            next;
        }
        my $name = $d->{alias} // $d->{name} // $wwid;
        my ($active, $total) = ($d->{paths_active} // 0, $d->{paths_total} // 0);
        $exp{$wwid} = $total if $total > ($exp{$wwid} // 0);
        if (!$active) {
            $problems{"dead:$wwid"} = "LUN $name (datastore '$ds') has no active path";
        } elsif ($active < $exp{$wwid}) {
            $problems{"degraded:$wwid"} = "LUN $name (datastore '$ds') has $active of $exp{$wwid} paths active";
        }
    }
    delete $exp{$_} for grep { !$watch->{$_} } keys %exp;
    return (\%problems, \%exp);
}

# Problems found in a datastore's array view.
sub view_problems {
    my ($view, $threshold) = @_;
    my $id = $view->{storage};
    my %p;
    if ($view->{error}) {
        $p{"array-error:$id"} = "array '$view->{array}' could not be read for datastore '$id': $view->{error}";
        return \%p;
    }
    for my $pool (@{$view->{pools} // []}) {
        next if !defined($pool->{used_pct}) || $pool->{used_pct} < $threshold;
        $p{"pool:$view->{array}:$pool->{name}"} = "pool '$pool->{name}' on array '$view->{array}' is $pool->{used_pct}% full (threshold $threshold%)";
    }
    my $h = $view->{health};
    if ($h && $h->{status} && $h->{status} ne 'ok') {
        my @a = map { $_->{summary} } grep { ($_->{severity} // '') =~ /^(?:warning|critical)$/ } @{$h->{alerts} // []};
        $p{"health:$view->{array}"} = "array '$view->{array}' reports $h->{status}"
            . (@a ? ': ' . join('; ', @a[0 .. ($#a > 4 ? 4 : $#a)]) : '');
    }
    return \%p;
}

# (new problems, resolved problems) between two { key => message } sets.
sub diff_problems {
    my ($old, $new) = @_;
    $old //= {};
    return (
        [ map { $new->{$_} } sort grep { !exists $old->{$_} } keys %$new ],
        [ map { $old->{$_} } sort grep { !exists $new->{$_} } keys %$old ],
    );
}

# Zoning hints. $expected: [WWPN] of the array's target ports;
# $logins: { node => [ { adapter, adapter_wwpn, wwpn, state, roles } ] }.
sub zoning_rows {
    my ($expected, $logins) = @_;
    my %exp = map { $_ => 1 } grep { defined } map { PVE::SAN::Array::Base::norm_wwpn($_) } @$expected;
    my (@rows, @hints);
    for my $node (sort keys %$logins) {
        my (%per_adapter, %node_seen);
        for my $rp (@{$logins->{$node} // []}) {
            my $a = $per_adapter{$rp->{adapter}} //= { wwpn => $rp->{adapter_wwpn}, seen => {} };
            next if ($rp->{state} // '') ne 'Online' || ($rp->{roles} // '') !~ /target/i;
            my $w = PVE::SAN::Array::Base::norm_wwpn($rp->{wwpn}) // next;
            next if !$exp{$w};
            $a->{seen}->{$w} = 1;
            $node_seen{$w} = 1;
        }
        for my $adapter (sort keys %per_adapter) {
            my $a = $per_adapter{$adapter};
            my @seen = sort keys %{$a->{seen}};
            push @rows, {
                node => $node,
                adapter => $adapter,
                adapter_wwpn => $a->{wwpn},
                seen => scalar(@seen),
                expected => scalar(keys %exp),
                targets => join(',', @seen),
            };
            push @hints, "$node $adapter (" . ($a->{wwpn} // '?') . ") is logged in to none of the array's ports - check its zone"
                if !@seen && %exp;
        }
        my @missing = sort grep { !$node_seen{$_} } keys %exp;
        push @hints, "$node sees no path to array port(s) " . join(', ', @missing) . " - zone missing or port down"
            if @missing && @missing < keys %exp;
        push @hints, "$node has no FC adapter logged in to the array" if !%per_adapter && %exp;
    }
    return (\@rows, \@hints);
}

# Hosts in the cluster's host cluster that belong to no cluster member:
# not named after a member and owning none of the (online) nodes' ports.
sub stale_hosts {
    my ($hosts, $hcname, $node_ports, $members) = @_;
    my %member = map { $_ => 1 } @{$members // [ keys %$node_ports ]};
    my %ours = map { $_ => 1 } grep { defined } map { PVE::SAN::Array::Base::norm_port($_) }
        map { @{$node_ports->{$_}} } keys %$node_ports;
    return [ grep {
        ($_->{hostcluster} // '') eq $hcname
            && !$member{$_->{name}}
            && !grep { $ours{$_} } @{$_->{wwpns} // []}, @{$_->{iqns} // []}
    } @$hosts ];
}

# Nodes none of whose ports belong to any array host (new nodes).
sub unregistered_nodes {
    my ($hosts, $node_ports) = @_;
    my %owned = map { $_ => 1 } map { @{$_->{wwpns} // []}, @{$_->{iqns} // []} } @$hosts;
    return [ sort grep {
        my $w = $node_ports->{$_};
        @$w && !grep { $owned{PVE::SAN::Array::Base::norm_port($_) // ''} } @$w
    } keys %$node_ports ];
}

# Datastore -> disks of each guest config text.
sub config_disks {
    my ($raw, $storeid) = @_;
    my ($main) = split(/^\[/m, $raw, 2);
    my @res;
    for my $line (split(/\n/, $main // '')) {
        my ($key, $val) = $line =~ /^([a-z]+\d+):\s*(\S.*)$/ or next;
        next if $key !~ /^(?:ide|sata|scsi|virtio|efidisk|tpmstate|unused|rootfs|mp)\d*$/;
        next if $val =~ /(?:^|,)media=cdrom(?:,|$)/;
        my ($store, $vol) = $val =~ /^(?:volume=)?([a-z][a-z0-9._-]*):([^,]+)/i or next;
        next if defined($storeid) && $store ne $storeid;
        my ($size) = $val =~ /(?:^|,)size=([^,]+)/;
        push @res, { key => $key, storage => $store, volume => $vol, size => $size };
    }
    return \@res;
}

# ---------------- cache in the cluster filesystem ----------------

sub read_cache {
    return {} if ! -f $CACHE_FILE;
    my $raw = eval { PVE::Tools::file_get_contents($CACHE_FILE) } // '';
    return eval { $json->decode($raw) } // {};
}

sub update_cache {
    my ($code) = @_;
    my $res = PVE::Cluster::cfs_lock_domain('pvesan', 30, sub {
        my $c = read_cache();
        my $r = $code->($c);
        mkdir($PVE::SAN::Config::DIR) if ! -d $PVE::SAN::Config::DIR;
        PVE::Tools::file_set_contents($CACHE_FILE, $json->encode($c));
        return $r;
    });
    die $@ if $@;
    return $res;
}

# ---------------- array view ----------------

sub pool_threshold {
    my ($cfg) = @_;
    return ($cfg // PVE::SAN::Config::load())->{monitor}->{pool_threshold} // $DEFAULT_POOL_THRESHOLD;
}

sub collect_view {
    my ($storeid, $ds) = @_;
    my $view = { storage => $storeid, array => $ds->{array}, time => time() };
    eval {
        my $drv = PVE::SAN::Array::driver($ds->{array});
        my @ids = map { $_->{id} } @{$ds->{volumes} // []};
        my %name = map { $_->{id} => $_->{name} } @{$ds->{volumes} // []};
        $view->{volumes} = [ map { { %$_, name => $name{$_->{id}} } } @{$drv->volume_space(\@ids)} ];
        my %vpool = map { my $v = eval { $drv->volume($_) } // {}; (($v->{pool} // '') => 1) } @ids;
        my @pools = @{$drv->pools()};
        my @mine = grep { $vpool{$_->{name}} || $vpool{$_->{id} // ''} } @pools;
        $view->{pools} = [ map {
            my ($cap, $free) = ($_->{capacity}, $_->{free});
            {
                name => $_->{name},
                capacity => $cap,
                free => $free,
                used_pct => ($cap && defined($free)) ? int(1000 * ($cap - $free) / $cap) / 10 : undef,
            }
        } (@mine ? @mine : @pools) ];
        $view->{health} = $drv->health();
        1;
    } or do {
        my $err = $@ // 'unknown error';
        chomp($err);
        $view->{error} = $err;
    };
    return $view;
}

sub linked_datastores {
    my ($cfg) = @_;
    $cfg //= PVE::SAN::Config::load();
    my $d = $cfg->{datastores} // {};
    return { map { $_ => $d->{$_} } grep { $d->{$_}->{array} } keys %$d };
}

# The array's view of a datastore, from the cache unless stale or asked.
sub array_view {
    my (%p) = @_;
    my $storeid = $p{storage};
    my $ds = linked_datastores()->{$storeid} or die "datastore '$storeid' is not linked to an array\n";
    my $cached = read_cache()->{views}->{$storeid};
    return { %$cached, cached => 1 } if $cached && !$p{refresh} && time() - ($cached->{time} // 0) < $VIEW_MAX_AGE;
    my $view = collect_view($storeid, $ds);
    eval { update_cache(sub { $_[0]->{views}->{$storeid} = $view }) };
    return { %$view, cached => 0 };
}

# ---------------- node-local ----------------

sub iostats {
    my (%p) = @_;
    my $interval = $p{interval} // 2;
    require PVE::SAN::Sysfs;
    my $maps = PVE::SAN::Sysfs::multipath_maps();
    my $read = sub { +{ map { $_->{sysfs} => parse_stat(read_attr("/sys/block/$_->{sysfs}/stat")) } @$maps } };
    my $a = $read->();
    my $t0 = time();
    select(undef, undef, undef, $interval);
    my $b = $read->();
    my $cfg = PVE::SAN::Config::load();
    my @res;
    for my $m (@$maps) {
        my $r = io_rates($a->{$m->{sysfs}}, $b->{$m->{sysfs}}, $interval) // next;
        my $dc = $cfg->{devices}->{$m->{wwid}} // {};
        push @res, { wwid => $m->{wwid}, name => $m->{name}, datastore => $dc->{datastore}, %$r };
    }
    return [ sort { ($a->{name} // '') cmp ($b->{name} // '') } @res ];
}

sub state_file { return "$STATE_DIR/health.json"; }

sub read_state {
    my $raw = eval { PVE::Tools::file_get_contents(state_file()) } // '';
    return eval { $json->decode($raw) } // {};
}

sub write_state {
    my ($st) = @_;
    mkdir($STATE_DIR) if ! -d $STATE_DIR;
    PVE::Tools::file_set_contents(state_file(), $json->encode($st));
}

# LUNs of enabled datastores that should be on this node: { wwid => storeid }
sub watched_luns {
    my ($node) = @_;
    require PVE::Storage;
    my $storecfg = PVE::Storage::config();
    my $cfg = PVE::SAN::Config::load();
    my %watch;
    for my $wwid (keys %{$cfg->{devices} // {}}) {
        my $d = $cfg->{devices}->{$wwid};
        my $ds = $d->{datastore} or next;
        next if $d->{detached};
        my $s = $storecfg->{ids}->{$ds} or next;
        next if $s->{disable} || ($s->{nodes} && !$s->{nodes}->{$node});
        $watch{$wwid} = $ds;
    }
    return \%watch;
}

sub path_health {
    my $node = PVE::SAN::Cluster::local_node();
    require PVE::SAN::Inventory;
    my $devices = PVE::SAN::Inventory::devices(all => 1);
    my $st = read_state();
    my ($problems, $expected) = path_problems($devices, watched_luns($node), $st->{expected});
    return { node => $node, problems => $problems, expected => $expected };
}

# Forget the learned path counts (after an intended zoning change).
sub reset_expected {
    my $st = read_state();
    delete $st->{expected};
    write_state($st);
    return { reset => 1 };
}

# ---------------- alerts ----------------

sub notify {
    my ($severity, $title, $lines) = @_;
    my $text = join("\n", @$lines) . "\n";
    print "pvesan alert ($severity): $title\n$text";
    my $node = PVE::SAN::Cluster::local_node();
    eval {
        require PVE::Notify;
        my $data = eval { PVE::Notify::common_template_data() } // {};
        PVE::Notify::notify($severity, 'pvesan-alert', { %$data, title => $title, message => $text },
            { type => 'pvesan', hostname => $node });
    };
    print "WARNING: could not send notification: $@" if $@;
}

sub report {
    my ($scope, $old, $new) = @_;
    my ($added, $resolved) = diff_problems($old, $new);
    notify('warning', "SAN problem on $scope", $added) if @$added;
    notify('info', "SAN problem resolved on $scope", $resolved) if @$resolved;
    return { new => $added, resolved => $resolved };
}

# ---------------- datastores, guests, zoning ----------------

sub datastore_guests {
    my (%p) = @_;
    my $storeid = $p{storage};
    my $status = eval { PVE::SAN::Cluster::guest_status() } // {};
    my @res;
    for my $r (@{PVE::SAN::Cluster::guest_refs($storeid)}) {
        my $raw = eval { PVE::Tools::file_get_contents($r->{file}) } // '';
        my $disks = config_disks($raw, $storeid);
        my $s = $status->{$r->{vmid}} // {};
        push @res, {
            vmid => $r->{vmid},
            type => $r->{type},
            node => $s->{node} // $r->{node},
            name => $s->{name},
            status => $s->{status},
            disks => join(',', map { "$_->{key}=$_->{volume}" } @$disks),
        };
    }
    return [ sort { $a->{vmid} <=> $b->{vmid} } @res ];
}

# Which datastore, LUNs and array volumes a guest's disks live on.
sub guest_storage {
    my (%p) = @_;
    my $vmid = $p{vmid};
    my ($file) = grep { -f $_ } (glob("/etc/pve/nodes/*/qemu-server/$vmid.conf"), glob("/etc/pve/nodes/*/lxc/$vmid.conf"));
    die "guest $vmid not found\n" if !$file;
    my $raw = PVE::Tools::file_get_contents($file);
    require PVE::Storage;
    my $storecfg = PVE::Storage::config();
    my $cfg = PVE::SAN::Config::load();
    my @res;
    for my $d (@{config_disks($raw)}) {
        my $s = $storecfg->{ids}->{$d->{storage}} // {};
        my $ds = $cfg->{datastores}->{$d->{storage}} // {};
        my @wwids = grep { ($cfg->{devices}->{$_}->{datastore} // '') eq $d->{storage} } sort keys %{$cfg->{devices}};
        push @res, {
            disk => $d->{key},
            volume => "$d->{storage}:$d->{volume}",
            size => $d->{size},
            type => $s->{type},
            vgname => $s->{vgname},
            luns => join(',', map { $cfg->{devices}->{$_}->{alias} // $_ } @wwids),
            wwids => join(',', @wwids),
            array => $ds->{array},
            array_volumes => join(',', map { $_->{name} } @{$ds->{volumes} // []}),
        };
    }
    return \@res;
}

sub array_luns {
    my ($array, $cfg) = @_;
    my $lds = linked_datastores($cfg);
    return [ map { map { $_->{wwid} } @{$lds->{$_}->{volumes} // []} } grep { $lds->{$_}->{array} eq $array } sort keys %$lds ];
}

sub zoning {
    my (%p) = @_;
    my $id = $p{array};
    my $drv = PVE::SAN::Array::driver($id);
    my $nodes = PVE::SAN::Cluster::nodes();
    my $logins = PVE::SAN::Cluster::on_nodes($nodes, 'reading FC logins', 'GET', 'remote-ports');

    my ($expected, $source) = (eval { $drv->target_ports() }, 'array');
    if (!$expected || !@$expected) {
        # without the array's port list: every port any node reaches this
        # array's LUNs through is a port every node should reach
        $source = 'paths';
        my %lun = map { $_ => 1 } @{array_luns($id)};
        my $devs = PVE::SAN::Cluster::on_nodes($nodes, 'reading paths', 'GET', 'devices', { all => 1 });
        my %t;
        for my $node (@$nodes) {
            for my $d (grep { $lun{$_->{wwid}} } @{$devs->{$node} // []}) {
                $t{$_->{target_wwpn}} = 1 for grep { $_->{target_wwpn} } @{$d->{paths} // []};
            }
        }
        $expected = [ sort keys %t ];
    }
    my ($rows, $hints) = zoning_rows($expected, $logins);
    return {
        array => $id,
        source => $source,
        expected => join(',', map { PVE::SAN::Array::Base::colon_wwpn($_) } grep { defined } map { PVE::SAN::Array::Base::norm_wwpn($_) } @$expected),
        adapters => $rows,
        hints => $hints,
    };
}

# ---------------- node join and leave ----------------

sub register_new_nodes {
    my (%p) = @_;
    my $id = $p{array};
    my $cfg = PVE::SAN::Array::config($id);
    my $hc = PVE::SAN::Array::hostcluster($cfg);
    my $protocol = PVE::SAN::Array::protocol($cfg);
    my $drv = PVE::SAN::Array::driver($id);
    my $ports = $p{node_ports} // PVE::SAN::Array::node_ports($protocol);
    my $new = unregistered_nodes($drv->hosts(), $ports);
    return [] if !@$new;
    print "registering new node(s) @$new on array '$id'\n";
    $drv->ensure_hostcluster($hc, { map { $_ => $ports->{$_} } @$new });
    if ($protocol ne 'fc') {
        require PVE::SAN::Provision;
        PVE::SAN::Provision::iscsi_login(array => $id, driver => $drv, nodes => $new, quiet => 1);
    }
    return $new;
}

sub array_hosts {
    my (%p) = @_;
    my $id = $p{array};
    my $cfg = PVE::SAN::Array::config($id);
    my $hc = PVE::SAN::Array::hostcluster($cfg);
    my $drv = PVE::SAN::Array::driver($id);
    my $hosts = $drv->hosts();
    # with a node offline its host can't be told from a removed node's
    my $off = PVE::SAN::Cluster::offline_nodes();
    my $stale = @$off ? {} : { map { $_->{name} => 1 }
        @{stale_hosts($hosts, $hc, PVE::SAN::Array::node_ports(PVE::SAN::Array::protocol($cfg)), PVE::SAN::Cluster::all_nodes())} };
    return [ map {
        {
            host => $_->{name},
            hostcluster => $_->{hostcluster},
            wwpns => join(',', map { PVE::SAN::Array::Base::colon_wwpn($_) } @{$_->{wwpns} // []}),
            iqns => join(',', @{$_->{iqns} // []}),
            stale => $stale->{$_->{name}} ? 1 : 0,
        }
    } grep { ($_->{hostcluster} // '') eq $hc } @$hosts ];
}

sub remove_stale_host {
    my (%p) = @_;
    my $id = $p{array};
    my $cfg = PVE::SAN::Array::config($id);
    my $hc = PVE::SAN::Array::hostcluster($cfg);
    my $drv = PVE::SAN::Array::driver($id);
    my $hosts = $drv->hosts();
    my ($host) = grep { $_->{name} eq $p{host} } @$hosts;
    die "host '$p{host}' not found on array '$id'\n" if !$host;
    my $off = PVE::SAN::Cluster::offline_nodes();
    die "node(s) offline: @$off - bring them online first so their hosts are not mistaken for a removed node's
" if @$off;
    my $stale = stale_hosts($hosts, $hc, PVE::SAN::Array::node_ports(PVE::SAN::Array::protocol($cfg)), PVE::SAN::Cluster::all_nodes());
    die "host '$p{host}' still belongs to a cluster node (or is not in host cluster '$hc') - only hosts of removed nodes can be removed\n"
        if !grep { $_->{name} eq $p{host} } @$stale;
    print "removing host '$p{host}' from host cluster '$hc' and deleting it on array '$id'\n";
    $drv->remove_host($host, $hc);
}

# ---------------- timer ----------------

sub take_lease {
    my $node = PVE::SAN::Cluster::local_node();
    my $now = time();
    return update_cache(sub {
        my ($c) = @_;
        my $l = $c->{lease} // {};
        return 0 if $l->{node} && $l->{node} ne $node && $now - ($l->{time} // 0) < $LEASE;
        $c->{lease} = { node => $node, time => $now };
        return 1;
    });
}

sub run {
    my $node = PVE::SAN::Cluster::local_node();
    my %res = (node => $node);

    # this node's paths
    my $h = eval { path_health() };
    if ($h) {
        my $st = read_state();
        $res{paths} = report("node $node", $st->{problems}, $h->{problems});
        $st->{problems} = $h->{problems};
        $st->{expected} = $h->{expected};
        write_state($st);
    } else {
        print "ERROR: path check failed: $@";
    }

    my $cfg = PVE::SAN::Config::load();
    my $lds = linked_datastores($cfg);
    return \%res if !%$lds && !%{$cfg->{arrays} // {}};
    return \%res if !take_lease();
    $res{arrays} = 1;

    # the arrays, from one node
    my $threshold = pool_threshold($cfg);
    my (%views, %problems);
    for my $id (sort keys %$lds) {
        next if $lds->{$id}->{copy_of};
        my $v = $views{$id} = collect_view($id, $lds->{$id});
        %problems = (%problems, %{view_problems($v, $threshold)});
    }

    # new nodes: register them on every array with auto-register, once per
    # membership change
    my $members = join(',', @{PVE::SAN::Cluster::all_nodes()});
    my $cache = read_cache();
    my %ports; # protocol => node ports
    for my $id (sort keys %{$cfg->{arrays} // {}}) {
        next if defined($cfg->{arrays}->{$id}->{auto_register}) && !$cfg->{arrays}->{$id}->{auto_register};
        next if ($cache->{members}->{$id} // '') eq $members;
        my $ok = eval {
            my $proto = PVE::SAN::Array::protocol($cfg->{arrays}->{$id});
            $ports{$proto} //= PVE::SAN::Array::node_ports($proto);
            my $new = register_new_nodes(array => $id, node_ports => $ports{$proto});
            notify('info', "pvesan registered new node(s) on array '$id'", [ "nodes: @$new" ]) if @$new;
            1;
        };
        if ($ok) {
            $cache->{members}->{$id} = $members;
        } else {
            my $err = $@; chomp($err);
            $problems{"register:$id"} = "registering new nodes on array '$id' failed: $err";
        }
    }

    my $old = $cache->{problems};
    update_cache(sub {
        my ($c) = @_;
        $c->{views}->{$_} = $views{$_} for keys %views;
        delete $c->{views}->{$_} for grep { !$lds->{$_} } keys %{$c->{views} // {}};
        $c->{members} = $cache->{members};
        $c->{problems} = \%problems;
    });
    $res{array_problems} = report('the SAN arrays', $old, \%problems);
    return \%res;
}

1;
