package PVE::SAN::Provision;

# Array-driven workflows: register the cluster on the array, provision a
# datastore end to end (volume -> map -> rescan -> datastore), grow it on
# the array, delete it including the array volume.
#
# Runs inside API workers; output goes to the task log.

use strict;
use warnings;

use PVE::Storage;
use PVE::Tools;

use PVE::SAN::Array;
use PVE::SAN::Array::Base;
use PVE::SAN::Cluster;
use PVE::SAN::Config;
use PVE::SAN::Datastore;
use PVE::SAN::Inventory;
use PVE::SAN::ISCSI;

my $GIB = 1024 * 1024 * 1024;

# --- array configuration ---

sub array_add {
    my (%p) = @_;

    my $id = $p{array};
    die "array '$id' already exists\n" if PVE::SAN::Config::load()->{arrays}->{$id};

    my $class = PVE::SAN::Array::driver_class($p{type});
    my %opts = map { $PVE::SAN::Array::OPTION_KEYS->{$_} => $p{$_} }
        grep { defined($p{$_}) } keys %$PVE::SAN::Array::OPTION_KEYS;
    $class->check_protocol($p{protocol}) if defined($p{protocol});
    my $drv = $class->new((map { $_ => $p{$_} } qw(address port username password fingerprint)), %opts);
    my $info = $drv->system_info(); # proves address, certificate and credentials
    die "host cluster name '$p{hostcluster}' is not valid on this array\n"
        if defined($p{hostcluster}) && !$class->valid_hostcluster_name($p{hostcluster});

    PVE::SAN::Array::write_password($id, $p{password});
    PVE::SAN::Config::update(sub {
        my ($cfg) = @_;
        die "array '$id' already exists\n" if $cfg->{arrays}->{$id};
        $cfg->{arrays}->{$id} = {
            type => $p{type},
            address => $p{address},
            port => $p{port} // $class->default_port,
            (defined($p{username}) ? (username => $p{username}) : ()),
            fingerprint => $p{fingerprint},
            (defined($p{hostcluster}) ? (hostcluster => $p{hostcluster}) : ()),
            (defined($p{description}) ? (description => $p{description}) : ()),
            %opts,
            system => join(' ', grep { defined } $info->{product}, $info->{name}, $info->{code_level}),
        };
    });
    return $info;
}

sub array_update {
    my (%p) = @_;

    my $id = $p{array};
    my $cur = PVE::SAN::Array::config($id);
    my %new = (%$cur, map { $_ => $p{$_} } grep { defined($p{$_}) }
        qw(address port username fingerprint hostcluster description));
    for my $o (keys %$PVE::SAN::Array::OPTION_KEYS) {
        $new{$PVE::SAN::Array::OPTION_KEYS->{$o}} = $p{$o} if defined($p{$o});
    }
    for my $d (PVE::Tools::split_list($p{delete} // '')) {
        delete $new{$d} if $d =~ /^(?:hostcluster|description)$/;
        delete $new{$PVE::SAN::Array::OPTION_KEYS->{$d}} if $PVE::SAN::Array::OPTION_KEYS->{$d};
    }
    PVE::SAN::Array::driver_class($new{type})->check_protocol($p{protocol}) if defined($p{protocol});
    my $password = $p{password} // PVE::SAN::Array::read_password($id);

    # re-test whenever connection settings change
    if (grep { defined($p{$_}) } qw(address port username password fingerprint)) {
        my $class = PVE::SAN::Array::driver_class($new{type});
        $class->new(%new, password => $password)->system_info();
    }

    PVE::SAN::Array::write_password($id, $password) if defined($p{password});
    PVE::SAN::Config::update(sub {
        my ($cfg) = @_;
        delete $new{id};
        $cfg->{arrays}->{$id} = \%new;
    });
}

sub array_remove {
    my (%p) = @_;
    my $id = $p{array};
    PVE::SAN::Config::update(sub {
        my ($cfg) = @_;
        die "array '$id' is not configured\n" if !$cfg->{arrays}->{$id};
        my @linked = grep { ($cfg->{datastores}->{$_}->{array} // '') eq $id } keys %{$cfg->{datastores}};
        die "array '$id' still backs datastore(s): @linked\n" if @linked;
        delete $cfg->{arrays}->{$id};
        # nodes stay logged in until rebooted or logged out; they just stop
        # logging in to this array's portals at boot
        my $portals = ($cfg->{iscsi} // {})->{portals} // {};
        delete $portals->{$_} for grep { ($portals->{$_}->{array} // '') eq $id } keys %$portals;
    });
    PVE::SAN::Array::delete_password($id);
}

# Registration state of each node on the array (read only).
sub array_status {
    my (%p) = @_;

    my $id = $p{array};
    my $cfg = PVE::SAN::Array::config($id);
    my $hc = PVE::SAN::Array::hostcluster($cfg);
    my $drv = PVE::SAN::Array::driver($id);

    my $info = $drv->system_info();
    my $hosts = $drv->hosts();
    my %owner;
    for my $h (@$hosts) { $owner{$_} = $h for @{$h->{wwpns} // []}, @{$h->{iqns} // []}; }
    my $hc_exists = grep { $_->{name} eq $hc } @{$drv->host_clusters()};

    my @nodes;
    my $ports = PVE::SAN::Array::node_ports(PVE::SAN::Array::protocol($cfg));
    for my $node (sort keys %$ports) {
        my ($ww, $wi) = PVE::SAN::Array::Base::split_ports($ports->{$node});
        my @w = (@$ww, @$wi);
        my %hn = map { $_->{name} => $_ } grep { defined } map { $owner{$_} } @w;
        my @missing = grep { !$owner{$_} } @w;
        my ($host) = values %hn;
        my $ok = (keys %hn == 1 && !@missing && ($host->{hostcluster} // '') eq $hc) ? 1 : 0;
        push @nodes, {
            node => $node,
            wwpns => join(',', @$ww),
            iqns => join(',', @$wi),
            host => join(',', sort keys %hn),
            hostcluster => $host ? $host->{hostcluster} : undef,
            missing => join(',', @missing),
            registered => $ok,
        };
    }

    return {
        array => $id,
        system => $info->{name},
        product => $info->{product},
        code_level => $info->{code_level},
        protocol => PVE::SAN::Array::protocol($cfg),
        hostcluster => $hc,
        hostcluster_exists => $hc_exists ? 1 : 0,
        nodes => \@nodes,
    };
}

sub register_cluster {
    my (%p) = @_;

    my $id = $p{array};
    my $cfg = PVE::SAN::Array::config($id);
    my $hc = PVE::SAN::Array::hostcluster($cfg);
    my $protocol = PVE::SAN::Array::protocol($cfg);
    my $drv = PVE::SAN::Array::driver($id);

    my $off = PVE::SAN::Cluster::offline_nodes();
    print "WARNING: offline node(s) not registered: @$off - run this again when they are back\n" if @$off;

    my $ports = PVE::SAN::Array::node_ports($protocol);
    my $res = $drv->ensure_hostcluster($hc, $ports);
    for my $node (sort keys %$res) {
        my $r = $res->{$node};
        my @what = (
            ($r->{created} ? 'created' : 'existing'),
            (@{$r->{added_ports}} ? 'added ports ' . join(' ', @{$r->{added_ports}}) : ()),
            ($r->{joined} ? "joined '$hc'" : ()),
        );
        print "[$node] array host '$r->{host}': " . join(', ', @what) . "\n";
    }
    print "cluster registered on array '$id' as host cluster '$hc'\n";

    iscsi_login(array => $id, driver => $drv, nodes => [ sort keys %$ports ], quiet => 1) if $protocol ne 'fc';
    return $hc;
}

# Log the nodes in to the array's iSCSI portals: the ones given, else the
# ones the array reports, else the ones recorded for this array earlier.
sub iscsi_login {
    my (%p) = @_;

    my $id = $p{array};
    my $nodes = $p{nodes} // PVE::SAN::Cluster::nodes();
    my @portals;
    if (defined($p{portals}) && length($p{portals})) {
        @portals = map { { portal => PVE::SAN::ISCSI::norm_portal($_) } } grep { length } split(/[,; ]+/, $p{portals});
    } else {
        my $drv = $p{driver} // PVE::SAN::Array::driver($id);
        my $tp = $drv->supports_iscsi ? $drv->target_portals() : undef;
        @portals = map { { portal => PVE::SAN::ISCSI::norm_portal("$_->{address}:" . ($_->{port} // 3260)), target => $_->{iqn} } }
            grep { $_->{address} } @{$tp // []};
        if (!@portals) {
            my $rec = PVE::SAN::ISCSI::recorded_portals();
            @portals = map { { portal => $_, target => $rec->{$_}->{target} } }
                grep { ($rec->{$_}->{array} // '') eq $id } sort keys %$rec;
        }
    }
    if (!@portals) {
        my $msg = "array '$id' reports no iSCSI target portals - log the nodes in with"
            . " 'pvesan array iscsi-login $id --portals <address>[,<address>...]'\n";
        die $msg if !$p{quiet};
        print "WARNING: $msg";
        return [];
    }

    my %seen;
    @portals = grep { !$seen{"$_->{portal} " . ($_->{target} // '')}++ } @portals;
    for my $pt (@portals) {
        PVE::SAN::Cluster::on_nodes($nodes, "logging in to iSCSI portal $pt->{portal}", 'POST', 'iscsi-login', {
            portal => $pt->{portal},
            array => $id,
            (defined($pt->{target}) ? (target => $pt->{target}) : ()),
        });
    }
    print "nodes logged in to " . scalar(@portals) . " iSCSI portal(s) of array '$id'\n";
    return [ map { $_->{portal} } @portals ];
}

# --- datastore lifecycle on the array ---

# Rescan all nodes until every node sees $wwid on at least one path.
sub wait_visible {
    my ($nodes, $wwid, $timeout) = @_;

    my $deadline = time() + ($timeout // 120);
    my $last_rescan = 0;
    while (1) {
        if (time() - $last_rescan >= 30) {
            PVE::SAN::Cluster::on_nodes($nodes, 'rescanning SAN adapters', 'POST', 'rescan', { resize => 0 });
            $last_rescan = time();
        }
        my $res = eval {
            PVE::SAN::Cluster::on_nodes($nodes, "looking for LUN $wwid", 'GET', 'devices', { all => 1 })
        };
        my @missing = grep {
            my $node = $_;
            !grep { $_->{wwid} eq $wwid && $_->{paths_active} } @{($res // {})->{$node} // []}
        } @$nodes;
        return if !@missing;
        die "LUN $wwid did not appear on: @missing - check zoning and that the host objects' ports are logged in\n"
            if time() > $deadline;
        print "waiting for LUN on: @missing\n";
        sleep(10);
    }
}

sub remove_device_record {
    my ($wwid) = @_;
    PVE::SAN::Config::update(sub { delete $_[0]->{devices}->{$wwid}; });
}

sub provision {
    my (%p) = @_;

    my $id = $p{array};
    my $storeid = $p{storage};

    die "storage '$storeid' already exists\n" if PVE::Storage::config()->{ids}->{$storeid};
    my $cfg = PVE::SAN::Array::config($id);
    my $hc = PVE::SAN::Array::hostcluster($cfg);
    my $drv = PVE::SAN::Array::driver($id);
    my $volname = $p{volume} // $drv->volume_name_for($storeid);
    die "invalid volume name '$volname' for this array\n" if !$drv->valid_name($volname);
    my $nodes = PVE::SAN::Cluster::nodes();
    my $off = PVE::SAN::Cluster::offline_nodes();
    die "all nodes must be online to provision (offline: @$off)\n" if @$off;

    print "== 1/5 checking cluster registration on array '$id'\n";
    register_cluster(array => $id);

    print "== 2/5 creating volume '$volname' ($p{size} GiB, " . ($p{thin} ? 'thin' : 'thick') . ") in pool '$p{pool}'\n";
    my $vol = $drv->create_volume(name => $volname, pool => $p{pool}, size_gib => $p{size}, thin => $p{thin});
    print "volume id $vol->{id}, UID " . ($vol->{uid} // '(after mapping)') . "\n";
    my $wwid = $vol->{wwid};

    my ($mapped, $created);
    eval {
        die "array returned no volume UID\n" if !$wwid && !$drv->wwid_after_map;

        print "== 3/5 mapping volume to host cluster '$hc'\n";
        $drv->map_to_hostcluster($vol->{id}, $hc);
        $mapped = 1;

        if (!$wwid) { # e.g. Hitachi reports the NAA ID only once an LU path exists
            $vol = $drv->volume($vol->{id});
            $wwid = $vol->{wwid} // die "array reports no WWID for volume $vol->{id} after mapping\n";
            print "volume WWID $wwid\n";
        }

        print "== 4/5 rescanning all nodes for the new LUN\n";
        wait_visible($nodes, $wwid, $p{timeout});

        print "== 5/5 creating datastore '$storeid'\n";
        PVE::SAN::Config::update(sub {
            my ($c) = @_;
            $c->{devices}->{$wwid}->{policy} //= $p{policy} // $drv->default_policy;
            my $npr = $drv->default_no_path_retry;
            $c->{devices}->{$wwid}->{no_path_retry} //= $npr if defined($npr);
        });
        PVE::SAN::Datastore::create(
            storage => $storeid,
            devices => [$wwid],
            label => $p{label},
            content => $p{content},
            vgname => $p{vgname},
        );
        $created = 1;

        PVE::SAN::Config::update(sub {
            my ($c) = @_;
            my $ds = $c->{datastores}->{$storeid} //= {};
            $ds->{array} = $id;
            $ds->{volumes} = [ { id => $vol->{id}, name => $vol->{name}, wwid => $wwid } ];
        });
    };
    if (my $err = $@) {
        die $err if $created; # datastore exists; leave everything for inspection
        print "provisioning failed - removing volume '$volname' again\n";
        eval { $drv->unmap_from_hostcluster($vol->{id}, $hc) } if $mapped;
        eval { PVE::SAN::Cluster::on_nodes($nodes, 'removing stale paths', 'POST', 'cleanup-paths') } if $mapped;
        eval { $drv->delete_volume($vol->{id}) };
        print "WARNING: could not delete volume $vol->{id} on the array: $@" if $@;
        remove_device_record($wwid) if $wwid;
        eval { PVE::SAN::Cluster::on_nodes($nodes, 'applying multipath configuration', 'POST', 'sync') };
        die $err;
    }
    print "datastore '$storeid' is ready on array volume '$vol->{name}'\n";
}

sub linked {
    my ($storeid) = @_;
    my $ds = PVE::SAN::Config::load()->{datastores}->{$storeid} // {};
    die "datastore '$storeid' is not linked to an array\n" if !$ds->{array};
    return $ds;
}

# Grow the array volume to $size GiB, then grow the datastore into it.
sub grow {
    my (%p) = @_;

    my $storeid = $p{storage};
    my $ds = linked($storeid);
    my @vols = @{$ds->{volumes} // []};
    my $v = $p{volume}
        ? (grep { $_->{name} eq $p{volume} || $_->{id} eq $p{volume} } @vols)[0]
        : (@vols == 1 ? $vols[0] : undef);
    die "datastore has several volumes; choose one with 'volume'\n" if !$v;

    my $drv = PVE::SAN::Array::driver($ds->{array});
    my $cur = $drv->volume($v->{id});
    my $target = $p{size} * $GIB;
    die "new size $p{size} GiB is not larger than the current " . sprintf('%.1f', $cur->{capacity} / $GIB) . " GiB\n"
        if $target <= $cur->{capacity};

    print "expanding array volume '$cur->{name}' to $p{size} GiB\n";
    $drv->expand_volume($cur->{id}, $target - $cur->{capacity});
    PVE::SAN::Datastore::extend(storage => $storeid, devices => [ $v->{wwid} ]);
}

# Delete the datastore, then unmap and delete its array volume(s).
sub destroy {
    my (%p) = @_;

    my $storeid = $p{storage};
    my $ds = linked($storeid);
    my @copies = grep { ($_->{copy_of} // '') eq $storeid } values %{PVE::SAN::Config::load()->{datastores}};
    die "datastore '$storeid' has mounted snapshot copies - remove them first\n" if @copies;
    my $id = $ds->{array};
    my $hc = PVE::SAN::Array::hostcluster(PVE::SAN::Array::config($id));
    my $drv = PVE::SAN::Array::driver($id); # fail early if the array is unreachable
    my @vols = @{$ds->{volumes} // []};

    PVE::SAN::Datastore::destroy(storage => $storeid, destroy_data => $p{destroy_data}, detach => 1);

    my $nodes = PVE::SAN::Cluster::nodes();
    for my $v (@vols) {
        print "unmapping and deleting array volume '$v->{name}'\n";
        $drv->unmap_from_hostcluster($v->{id}, $hc);
        $drv->delete_volume($v->{id});
        remove_device_record($v->{wwid});
    }
    PVE::SAN::Cluster::on_nodes($nodes, 'applying multipath configuration', 'POST', 'sync');
    print "datastore '$storeid' and its array volume(s) deleted\n";
}

# Attach an existing datastore to the array that holds its LUNs.
sub link_datastore {
    my (%p) = @_;

    my $storeid = $p{storage};
    my $scfg = PVE::SAN::Datastore::storage($storeid);
    my $drv = PVE::SAN::Array::driver($p{array});
    my $backing = PVE::SAN::Inventory::vg_backing($scfg->{vgname});

    my @vols;
    for my $b (grep { $_->{wwid} } @$backing) {
        my $v = $drv->find_volume_by_wwid($b->{wwid})
            // die "LUN $b->{wwid} of '$storeid' is not a volume on array '$p{array}'\n";
        push @vols, { id => $v->{id}, name => $v->{name}, wwid => $b->{wwid} };
    }
    die "datastore '$storeid' has no multipath LUNs\n" if !@vols;

    PVE::SAN::Config::update(sub {
        my ($c) = @_;
        my $d = $c->{datastores}->{$storeid} //= {};
        $d->{array} = $p{array};
        $d->{volumes} = \@vols;
    });
    return { storage => $storeid, array => $p{array}, volumes => join(',', map { $_->{name} } @vols) };
}

1;
