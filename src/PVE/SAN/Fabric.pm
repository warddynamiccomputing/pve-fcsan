package PVE::SAN::Fabric;

# Registry of FC switches pvesan can zone (one entry per fabric, or per
# VSAN / virtual fabric). Non-secret settings live in the cluster DB under
# "fabrics"; passwords root-only in /etc/pve/priv/pvesan/fabric-<id>.pw.

use strict;
use warnings;

use PVE::SAN::Array;
use PVE::SAN::Config;
use PVE::SAN::Fabric::Base;

our $DRIVERS = {
    'brocade' => 'PVE::SAN::Fabric::Brocade',
    'cisco' => 'PVE::SAN::Fabric::Cisco',
};

# switch settings (API name => config/driver key)
our $OPTION_KEYS = {
    'vsan' => 'vsan',       # Cisco: VSAN (required)
    'vf-id' => 'vf_id',     # Brocade: virtual fabric ID
    'zoneset' => 'zoneset', # zone set / cfg the zones go in (default: the active one)
};

sub types {
    return [ sort keys %$DRIVERS ];
}

sub driver_class {
    my ($type) = @_;
    my $class = $DRIVERS->{$type} // die "unknown switch type '$type'\n";
    (my $file = "$class.pm") =~ s|::|/|g;
    require $file;
    return $class;
}

sub default_port {
    my ($type) = @_;
    return driver_class($type)->default_port();
}

sub secret_id { return "fabric-$_[0]"; }

sub config {
    my ($id) = @_;
    my $f = PVE::SAN::Config::load()->{fabrics}->{$id} or die "fabric '$id' is not configured\n";
    return { %$f, id => $id };
}

sub ids {
    return [ sort keys %{PVE::SAN::Config::load()->{fabrics} // {}} ];
}

sub driver_for {
    my ($cfg, $password) = @_;
    my $class = driver_class($cfg->{type});
    return $class->new(
        address => $cfg->{address},
        port => $cfg->{port},
        username => $cfg->{username},
        password => $password,
        fingerprint => $cfg->{fingerprint},
        (map { $_ => $cfg->{$_} } grep { defined($cfg->{$_}) } values %$OPTION_KEYS),
        ($cfg->{transport} ? (transport => $cfg->{transport}) : ()),
    );
}

sub driver {
    my ($id) = @_;
    my $cfg = config($id);
    return driver_for($cfg, PVE::SAN::Array::read_password(secret_id($id)));
}

sub list {
    my $cfg = PVE::SAN::Config::load();
    my @res;
    for my $id (sort keys %{$cfg->{fabrics} // {}}) {
        my $f = $cfg->{fabrics}->{$id};
        push @res, {
            fabric => $id,
            (map { defined($f->{$_}) ? ($_ => $f->{$_}) : () } qw(type address port username fingerprint description system)),
            (map { my $k = $OPTION_KEYS->{$_}; defined($f->{$k}) ? ($_ => $f->{$k}) : () } keys %$OPTION_KEYS),
        };
    }
    return \@res;
}

sub check_settings {
    my ($p) = @_;
    die "invalid zone set name '$p->{zoneset}'\n"
        if defined($p->{zoneset}) && !PVE::SAN::Fabric::Base::valid_zone_name($p->{zoneset});
}

# Add a switch: the connection and credentials are tested before saving.
sub add {
    my (%p) = @_;
    my $id = $p{fabric};
    die "fabric '$id' already exists\n" if PVE::SAN::Config::load()->{fabrics}->{$id};
    check_settings(\%p);

    my %f = (
        type => $p{type},
        address => $p{address},
        port => $p{port} // default_port($p{type}),
        username => $p{username},
        fingerprint => $p{fingerprint},
        (defined($p{description}) ? (description => $p{description}) : ()),
        (map { $OPTION_KEYS->{$_} => $p{$_} } grep { defined($p{$_}) } keys %$OPTION_KEYS),
    );
    my $info = driver_for(\%f, $p{password})->system_info(); # proves address, certificate, credentials
    $f{system} = join(' ', grep { defined && length } $info->{model}, $info->{name}, $info->{version});

    PVE::SAN::Array::write_password(secret_id($id), $p{password});
    PVE::SAN::Config::update(sub {
        my ($cfg) = @_;
        die "fabric '$id' already exists\n" if $cfg->{fabrics}->{$id};
        $cfg->{fabrics}->{$id} = \%f;
    });
    return $info;
}

sub update {
    my (%p) = @_;
    my $id = $p{fabric};
    check_settings(\%p);
    my $cur = config($id);
    delete $cur->{id};
    my %new = (%$cur, map { $_ => $p{$_} } grep { defined($p{$_}) } qw(address port username fingerprint description));
    $new{$OPTION_KEYS->{$_}} = $p{$_} for grep { defined($p{$_}) } keys %$OPTION_KEYS;
    for my $d (split(/,/, $p{delete} // '')) {
        delete $new{$d} if $d eq 'description';
        delete $new{$OPTION_KEYS->{$d}} if $OPTION_KEYS->{$d};
    }
    my $password = $p{password} // PVE::SAN::Array::read_password(secret_id($id));
    my $info = driver_for(\%new, $password)->system_info();
    $new{system} = join(' ', grep { defined && length } $info->{model}, $info->{name}, $info->{version});

    PVE::SAN::Array::write_password(secret_id($id), $p{password}) if defined($p{password});
    PVE::SAN::Config::update(sub {
        my ($cfg) = @_;
        die "fabric '$id' is not configured\n" if !$cfg->{fabrics}->{$id};
        $cfg->{fabrics}->{$id} = \%new;
    });
}

sub remove {
    my (%p) = @_;
    my $id = $p{fabric};
    PVE::SAN::Config::update(sub {
        my ($cfg) = @_;
        die "fabric '$id' is not configured\n" if !$cfg->{fabrics}->{$id};
        delete $cfg->{fabrics}->{$id};
    });
    PVE::SAN::Array::delete_password(secret_id($id));
}

# What the switch sees: system info and the logged-in ports, marked with
# the cluster node or array they belong to where pvesan knows it.
sub status {
    my (%p) = @_;
    my $drv = driver($p{fabric});
    my $info = $drv->system_info();
    my $ns = $drv->name_server();
    my %owner;
    my $nodes = eval { PVE::SAN::Array::node_wwpns() } // {};
    for my $n (keys %$nodes) { $owner{$_} = "node $n" for @{$nodes->{$n}}; }
    for my $a (@{PVE::SAN::Array::list()}) {
        my $t = eval { PVE::SAN::Array::driver($a->{array})->target_ports() } // [];
        $owner{$_} //= "array $a->{array}" for grep { defined } map { PVE::SAN::Array::Base::norm_wwpn($_) } @$t;
    }
    return {
        fabric => $p{fabric},
        %$info,
        ports => [ map { { %$_, wwpn => PVE::SAN::Array::Base::colon_wwpn($_->{wwpn}),
            wwnn => defined($_->{wwnn}) ? PVE::SAN::Array::Base::colon_wwpn($_->{wwnn}) : undef,
            owner => $owner{$_->{wwpn}} // '' } } sort { $a->{wwpn} cmp $b->{wwpn} } @$ns ],
    };
}

1;
