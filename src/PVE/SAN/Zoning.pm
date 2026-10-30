package PVE::SAN::Zoning;

# Automatic FC zoning between the cluster's nodes and an array.
#
# Single-initiator zoning: on each fabric, one zone per node HBA port that is
# logged in there, holding that port and every port of the array logged in
# to the same fabric. Zones are named
#   pve_<host cluster>_<node>_<initiator WWPN>_<array>
# and go into the fabric's zone set (the setting 'zoneset', else the active
# one), which is then activated. A port pair that an active zone already
# covers (any zone, pvesan's or not) is left alone.
#
# plan() only reads (nodes, array, switches); apply() recomputes the plan and
# changes the fabrics. compute() is the pure part, unit tested.

use strict;
use warnings;

use PVE::SAN::Array;
use PVE::SAN::Array::Base;
use PVE::SAN::Fabric;

*norm_wwpn = \&PVE::SAN::Array::Base::norm_wwpn;
*colon_wwpn = \&PVE::SAN::Array::Base::colon_wwpn;

sub part {
    my ($s, $len) = @_;
    $s =~ s/[^A-Za-z0-9]+/_/g;
    $s =~ s/^_+|_+$//g;
    return substr($s, 0, $len);
}

sub zone_name {
    my ($hc, $node, $wwpn, $array) = @_;
    return join('_', 'pve', part($hc, 12), part($node, 16), lc($wwpn), part($array, 12));
}

sub same_set {
    my ($a, $b) = @_;
    return join(',', sort @{$a // []}) eq join(',', sort @{$b // []});
}

# Does the defined zone set $cfg differ from what is active (changes saved
# but never activated)? Activating it would activate those too.
sub pending_changes {
    my ($z, $cfg) = @_;
    return 0 if !defined($z->{active_cfg}) || $z->{active_cfg} ne $cfg;
    my @def = @{$z->{cfgs}->{$cfg} // []};
    my %act = %{$z->{active_zones} // {}};
    return 1 if !same_set(\@def, [ keys %act ]);
    for my $name (@def) {
        return 1 if !same_set($z->{zones}->{$name}, $act{$name});
    }
    return 0;
}

# $in = {
#   array, hostcluster,
#   nodes   => { node => [WWPN] },
#   targets => [WWPN],
#   fabrics => [ { fabric, type, zoneset, ns => name_server(), zoning => zoning() } ],
# }
sub compute {
    my ($in) = @_;
    my $nodes = $in->{nodes} // {};
    my @targets = sort grep { defined } map { norm_wwpn($_) } @{$in->{targets} // []};
    my (%placed_init, %placed_tgt, %node_fabrics, @fabrics, @rows, @warnings);
    my $changes = 0;

    for my $f (@{$in->{fabrics}}) {
        my %logged = map { $_->{wwpn} => 1 } grep { defined($_->{wwpn}) } @{$f->{ns} // []};
        my $z = $f->{zoning} // {};
        my @tgts = grep { $logged{$_} } @targets;
        my @inits;
        for my $node (sort keys %$nodes) {
            for my $w (sort grep { defined } map { norm_wwpn($_) } @{$nodes->{$node}}) {
                next if !$logged{$w};
                push @inits, [ $node, $w ];
                $placed_init{$w} = 1;
                $node_fabrics{$node}->{$f->{fabric}} = 1;
            }
        }
        $placed_tgt{$_} = 1 for @tgts;

        my $res = { fabric => $f->{fabric}, type => $f->{type}, zones => [], warnings => [], blocked => undef };
        push @fabrics, $res;
        my $cfg = $f->{zoneset} // $z->{active_cfg};
        $res->{zoneset} = $cfg;

        if (!@tgts) {
            push @{$res->{warnings}}, "none of the array's ports is logged in to this fabric";
            next;
        }
        if (!@inits) {
            push @{$res->{warnings}}, "no cluster node port is logged in to this fabric";
            next;
        }
        if (!defined($cfg)) {
            $res->{blocked} = "no zone set is active on this fabric - set the switch setting 'zoneset'";
        } elsif ($z->{busy}) {
            $res->{blocked} = $z->{busy};
        } elsif (pending_changes($z, $cfg)) {
            $res->{blocked} = "zone set $cfg has saved changes that are not active yet; activating it would activate them too - activate or discard them on the switch first";
            $res->{pending} = 1;
        }
        my %in_cfg = map { $_ => 1 } @{($z->{cfgs} // {})->{$cfg // ''} // []};
        my $active = $z->{active_zones} // {};

        for my $i (@inits) {
            my ($node, $w) = @$i;
            my @want = ($w, @tgts);
            my $name = zone_name($in->{hostcluster}, $node, $w, $in->{array});
            my $row = { fabric => $f->{fabric}, zoneset => $cfg, zone => $name, node => $node,
                initiator => colon_wwpn($w), targets => join(' ', map { colon_wwpn($_) } @tgts) };

            my ($cover) = grep { my %m = map { $_ => 1 } @{$active->{$_}}; !grep { !$m{$_} } @want } sort keys %$active;
            if ($cover) {
                $row->{action} = 'exists';
                $row->{zone} = $cover;
                push @rows, $row;
                next;
            }
            my $have = ($z->{zones} // {})->{$name};
            my %h = map { $_ => 1 } @{$have // []};
            my @missing = grep { !$h{$_} } @want;
            my $zone = { name => $name, members => \@missing, add_to_cfg => !$in_cfg{$name} ? 1 : 0 };
            $row->{action} = !$have ? 'create' : @missing ? 'extend' : $zone->{add_to_cfg} ? 'add to zone set' : 'activate';
            push @{$res->{zones}}, $zone;
            push @rows, $row;
            $changes++;
        }
    }

    my @lost_init = map { my $n = $_; map { "$n " . colon_wwpn($_) } grep { !$placed_init{$_} }
        grep { defined } map { norm_wwpn($_) } @{$nodes->{$n}} } sort keys %$nodes;
    push @warnings, "node port(s) logged in to none of the fabrics: " . join(', ', @lost_init) if @lost_init;
    my @lost_tgt = map { colon_wwpn($_) } grep { !$placed_tgt{$_} } @targets;
    push @warnings, "array port(s) logged in to none of the fabrics: " . join(', ', @lost_tgt) if @lost_tgt;
    if (@{$in->{fabrics}} > 1) {
        my @single = grep { keys(%{$node_fabrics{$_} // {}}) == 1 } sort keys %$nodes;
        push @warnings, "only one fabric reaches node(s) @single - no fabric redundancy" if @single;
    }

    return {
        array => $in->{array},
        hostcluster => $in->{hostcluster},
        targets => join(' ', map { colon_wwpn($_) } @targets),
        fabrics => \@fabrics,
        rows => \@rows,
        warnings => \@warnings,
        changes => $changes,
    };
}

sub array_targets {
    my ($id, $override) = @_;
    if (defined($override) && length($override)) {
        my @t = map { norm_wwpn($_) // die "invalid target WWPN '$_'\n" } grep { length } split(/[\s,;]+/, $override);
        return \@t;
    }
    my $cfg = PVE::SAN::Array::config($id);
    my $t = PVE::SAN::Array::driver($id)->target_ports();
    die "array type '$cfg->{type}' cannot list its FC target ports yet - give them with 'targets'\n" if !$t;
    die "array '$id' reports no FC target ports\n" if !@$t;
    return $t;
}

sub gather {
    my (%p) = @_;
    my $id = $p{array};
    my $acfg = PVE::SAN::Array::config($id);
    my @fids = defined($p{fabrics}) && length($p{fabrics}) ? split(/,/, $p{fabrics}) : @{PVE::SAN::Fabric::ids()};
    die "no FC switches configured - add one per fabric first ('pvesan fabric add')\n" if !@fids;

    my @fabrics;
    my %drivers;
    for my $fid (@fids) {
        my $fcfg = PVE::SAN::Fabric::config($fid);
        my $drv = $drivers{$fid} = PVE::SAN::Fabric::driver($fid);
        push @fabrics, { fabric => $fid, type => $fcfg->{type}, zoneset => $fcfg->{zoneset},
            ns => $drv->name_server(), zoning => $drv->zoning() };
    }
    my $in = {
        array => $id,
        hostcluster => PVE::SAN::Array::hostcluster($acfg),
        nodes => PVE::SAN::Array::node_wwpns(),
        targets => array_targets($id, $p{targets}),
        fabrics => \@fabrics,
    };
    return ($in, \%drivers);
}

sub plan {
    my (%p) = @_;
    my ($in) = gather(%p);
    return compute($in);
}

sub apply {
    my (%p) = @_;
    my ($in, $drivers) = gather(%p);
    my $plan = compute($in);
    for my $w (@{$plan->{warnings}}) { print "warning: $w\n"; }
    if (!$plan->{changes}) {
        print "nothing to do: every node port is already zoned to the array\n";
        return $plan;
    }
    for my $f (grep { @{$_->{zones}} } @{$plan->{fabrics}}) {
        die "fabric $f->{fabric}: $f->{blocked}\n" if $f->{blocked};
    }
    for my $f (grep { @{$_->{zones}} } @{$plan->{fabrics}}) {
        print "fabric $f->{fabric} ($f->{type}), zone set $f->{zoneset}:\n";
        my $log = $drivers->{$f->{fabric}}->apply_zones($f->{zoneset}, $f->{zones});
        print "  $_\n" for @$log;
    }
    print "zoning done - rescan the nodes, then register the cluster on the array if not done yet\n";
    return $plan;
}

1;
