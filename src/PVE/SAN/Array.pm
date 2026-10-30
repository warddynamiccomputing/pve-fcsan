package PVE::SAN::Array;

# Registry of storage arrays pvesan can drive (create volumes, map them to
# the cluster). Non-secret settings live in the cluster DB under "arrays";
# passwords live root-only in /etc/pve/priv/pvesan/<id>.pw.

use strict;
use warnings;

use PVE::SAN::Cluster;
use PVE::SAN::Config;

our $PASSWORD_DIR = '/etc/pve/priv/pvesan';

# type => driver class. New vendors register here.
our $DRIVERS = {
    'ibm-sv' => 'PVE::SAN::Array::IBMSV',
    'pure' => 'PVE::SAN::Array::Pure',
    'infinidat' => 'PVE::SAN::Array::Infinidat',
    'dell-powerstore' => 'PVE::SAN::Array::PowerStore',
    'dell-powermax' => 'PVE::SAN::Array::PowerMax',
    'netapp-ontap' => 'PVE::SAN::Array::ONTAP',
    'netapp-eseries' => 'PVE::SAN::Array::ESeries',
    'hitachi-vsp' => 'PVE::SAN::Array::Hitachi',
    'fujitsu-eternus' => 'PVE::SAN::Array::Eternus',
    'dell-unity' => 'PVE::SAN::Array::Unity',
    'hpe-nimble' => 'PVE::SAN::Array::Nimble',
    'hpe-3par' => 'PVE::SAN::Array::HPE3PAR',
};

# vendor specific array settings (API name => config/driver key)
our $OPTION_KEYS = {
    'system-id' => 'system_id',
    'svm' => 'svm',
    'portgroup' => 'portgroup',
    'srp' => 'srp',
    'slo' => 'slo',
    'target-ports' => 'target_ports',
    'copy-rate' => 'copy_rate', # IBM FlashCopy background copy rate
    'protocol' => 'protocol', # fc, iscsi or both
    'auto-register' => 'auto_register', # not a driver setting: pvesan-monitor registers new nodes
};

sub types {
    return [ sort keys %$DRIVERS ];
}

sub driver_class {
    my ($type) = @_;
    my $class = $DRIVERS->{$type} // die "unknown array type '$type'\n";
    (my $file = "$class.pm") =~ s|::|/|g;
    require $file;
    return $class;
}

sub password_file {
    my ($id) = @_;
    return "$PASSWORD_DIR/$id.pw";
}

sub write_password {
    my ($id, $password) = @_;
    require PVE::Tools;
    mkdir($PASSWORD_DIR) if ! -d $PASSWORD_DIR;
    PVE::Tools::file_set_contents(password_file($id), "$password\n", 0600);
}

sub read_password {
    my ($id) = @_;
    require PVE::Tools;
    my $f = password_file($id);
    die "no stored password for array '$id'\n" if ! -f $f;
    my $pw = PVE::Tools::file_get_contents($f);
    chomp($pw);
    return $pw;
}

sub delete_password {
    my ($id) = @_;
    unlink(password_file($id));
}

sub config {
    my ($id) = @_;
    my $a = PVE::SAN::Config::load()->{arrays}->{$id} or die "array '$id' is not configured\n";
    return { %$a, id => $id };
}

# Default host cluster name on the array: the Proxmox cluster name.
sub default_hostcluster {
    my $name = 'pve';
    if (open(my $fh, '<', '/etc/pve/corosync.conf')) {
        while (my $line = <$fh>) {
            if ($line =~ /^\s*cluster_name:\s*(\S+)/) { $name = $1; last; }
        }
        close($fh);
    }
    # letters, digits and '-' only: valid on every supported array
    $name =~ s/[^A-Za-z0-9-]/-/g;
    $name = "pve-$name" if $name !~ /^[A-Za-z]/;
    $name =~ s/-+$//;
    return $name;
}

sub hostcluster {
    my ($cfg) = @_;
    return $cfg->{hostcluster} || default_hostcluster();
}

sub default_port {
    my ($type) = @_;
    return driver_class($type)->default_port();
}

# Connected driver for a configured array.
sub driver {
    my ($id) = @_;
    my $cfg = config($id);
    my $class = driver_class($cfg->{type});
    return $class->new(
        address => $cfg->{address},
        port => $cfg->{port},
        username => $cfg->{username},
        password => read_password($id),
        fingerprint => $cfg->{fingerprint},
        hostcluster => hostcluster($cfg), # PowerMax derives its storage group from it
        (map { $_ => $cfg->{$_} } grep { defined($cfg->{$_}) } values %$OPTION_KEYS),
    );
}

# Fetch the TLS certificate fingerprint so the admin can confirm it
# (trust on first use, like ssh). Nothing is trusted here.
sub probe_certificate {
    my ($address, $port) = @_;

    require IO::Socket::SSL;
    my $sock = IO::Socket::SSL->new(
        PeerHost => $address,
        PeerPort => $port,
        SSL_verify_mode => 0, # we only read the certificate
        Timeout => 10,
    ) or die "unable to connect to $address:$port - "
        . ($! ? "$!" : ($IO::Socket::SSL::SSL_ERROR || 'unknown error')) . "\n";

    my $res = {
        fingerprint => $sock->get_fingerprint('sha256'),
        subject => $sock->peer_certificate('subject'),
        issuer => $sock->peer_certificate('issuer'),
    };
    $sock->close();
    return $res;
}

# FC WWPNs per online node ({ node => [WWPN, ...] }), from each node's API.
sub node_wwpns {
    my ($nodes) = @_;
    $nodes //= PVE::SAN::Cluster::nodes();
    my $res = PVE::SAN::Cluster::on_nodes($nodes, 'reading FC ports', 'GET', 'adapters');
    my $out = {};
    for my $node (@$nodes) {
        $out->{$node} = [
            map { uc($_->{wwpn} =~ s/://gr) }
            grep { $_->{transport} eq 'fc' && $_->{wwpn} } @{$res->{$node} // []}
        ];
    }
    return $out;
}

# { WWPN => WWNN } of the online nodes' FC ports (Unity names an FC
# initiator by both).
sub node_wwnns {
    my ($nodes) = @_;
    $nodes //= PVE::SAN::Cluster::nodes();
    my $res = PVE::SAN::Cluster::on_nodes($nodes, 'reading FC ports', 'GET', 'adapters');
    my $out = {};
    for my $ad (map { @{$res->{$_} // []} } @$nodes) {
        next if $ad->{transport} ne 'fc' || !$ad->{wwpn} || !$ad->{wwnn};
        $out->{uc($ad->{wwpn} =~ s/://gr)} = uc($ad->{wwnn} =~ s/://gr);
    }
    return $out;
}

# iSCSI initiator name per online node ({ node => [IQN] }), read by each
# node from /etc/iscsi/initiatorname.iscsi.
sub node_iqns {
    my ($nodes) = @_;
    $nodes //= PVE::SAN::Cluster::nodes();
    my $res = PVE::SAN::Cluster::on_nodes($nodes, 'reading iSCSI initiator name', 'GET', 'iscsi');
    return { map {
        my $iqn = ($res->{$_} // {})->{initiator};
        ($_ => [ $iqn ? lc($iqn) : () ])
    } @$nodes };
}

sub protocol {
    my ($cfg) = @_;
    return $cfg->{protocol} // 'fc';
}

# Ports per online node for an array protocol (fc, iscsi or both):
# { node => [WWPN or IQN, ...] }.
sub node_ports {
    my ($protocol, $nodes) = @_;
    $protocol //= 'fc';
    my $fc = $protocol ne 'iscsi' ? node_wwpns($nodes) : {};
    my $iscsi = $protocol ne 'fc' ? node_iqns($nodes) : {};
    my %all = map { ($_ => 1) } keys %$fc, keys %$iscsi;
    return { map { ($_ => [ @{$fc->{$_} // []}, @{$iscsi->{$_} // []} ]) } keys %all };
}

# Arrays as listed in the API/GUI (no secrets).
sub list {
    my $cfg = PVE::SAN::Config::load();
    my @res;
    for my $id (sort keys %{$cfg->{arrays} // {}}) {
        my $a = $cfg->{arrays}->{$id};
        my @linked = grep { ($cfg->{datastores}->{$_}->{array} // '') eq $id } keys %{$cfg->{datastores}};
        push @res, {
            array => $id,
            type => $a->{type},
            address => $a->{address},
            port => $a->{port},
            username => $a->{username},
            hostcluster => hostcluster($a),
            fingerprint => $a->{fingerprint},
            description => $a->{description},
            system => $a->{system},
            datastores => join(',', sort @linked),
            (map { my $k = $OPTION_KEYS->{$_}; defined($a->{$k}) ? ($_ => $a->{$k}) : () } keys %$OPTION_KEYS),
        };
    }
    return \@res;
}

1;
