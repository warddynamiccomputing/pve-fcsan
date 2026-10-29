package PVE::SAN::Array::IBMSV;

# Driver for IBM Spectrum Virtualize / Storage Virtualize arrays
# (FlashSystem 5x00/7x00/9x00, SVC, Storwize) through the REST API on
# port 7443 (code level 8.1.3+).
#
# The REST API wraps the CLI: POST /rest/v1/<command>[/<object>] with the
# command's options as a JSON body. Authentication is a token from
# POST /rest/v1/auth.

use strict;
use warnings;

use JSON::PP;

use base qw(PVE::SAN::Array::Base);

sub description { return 'IBM FlashSystem / Spectrum Virtualize'; }

# multipath-tools queues I/O on these LUNs forever when all paths are gone
sub default_no_path_retry { return 12; }
sub default_port { return 7443; }
sub default_policy { return 'alua'; }

sub base_url {
    my ($self) = @_;
    return "https://" . $self->host_port . "/rest/v1";
}

my $json = PVE::SAN::Array::Base::json();
*short = \&PVE::SAN::Array::Base::short;

sub escape_path { return PVE::SAN::Array::Base::escape($_[0]); }

# One POST. Returns (status code, body). Tests inject 'transport' taking
# ($path, $headers, $body).
sub http {
    my ($self, $path, $headers, $body) = @_;
    return $self->{transport}->($path, $headers, $body) if $self->{transport};
    my ($code, $content) = $self->request('POST', "/rest/v1$path", $headers, $body);
    return ($code, $content);
}

sub login {
    my ($self) = @_;

    my ($code, $content) = $self->http('/auth', {
        'X-Auth-Username' => $self->{username},
        'X-Auth-Password' => $self->{password},
    }, undef);
    die "array login to $self->{address} failed (HTTP $code): " . short($content) . "\n" if $code != 200;

    my $data = PVE::SAN::Array::Base::decode($content) // {};
    $self->{token} = $data->{token} // die "array login: no token in response\n";
}

# Run one CLI command. $object is the positional argument (id or name).
sub cmd {
    my ($self, $command, $object, $params) = @_;

    $self->login() if !$self->{token};

    my $path = "/$command" . (defined($object) ? '/' . escape_path($object) : '');
    my ($code, $content);
    for my $attempt (1, 2) {
        ($code, $content) = $self->http($path, { 'X-Auth-Token' => $self->{token} }, $params // {});
        last if $code != 401 && $code != 403;
        last if $attempt == 2;
        $self->login(); # token expired
    }
    die "array command '$command" . (defined($object) ? " $object" : '') . "' failed (HTTP $code): "
        . short($content) . "\n" if $code < 200 || $code >= 300;

    return undef if $content !~ /\S/;
    return PVE::SAN::Array::Base::decode($content) // die "array command '$command': invalid JSON reply\n";
}

sub list {
    my ($self, $command, $params) = @_;
    my $r = $self->cmd($command, undef, $params);
    return ref($r) eq 'ARRAY' ? $r : ($r ? [$r] : []);
}

sub num {
    my ($v) = @_;
    return defined($v) && $v =~ /^\d+$/ ? $v + 0 : undef;
}

# --- read side ---

sub system_info {
    my ($self) = @_;
    my $s = $self->cmd('lssystem');
    return { name => $s->{name}, product => $s->{product_name}, code_level => $s->{code_level}, id => $s->{id} };
}

sub pools {
    my ($self) = @_;
    return [ map {
        { id => $_->{id}, name => $_->{name}, status => $_->{status},
          capacity => num($_->{capacity}), free => num($_->{free_capacity}) }
    } grep { ($_->{type} // 'parent') ne 'child_thin' } @{$self->list('lsmdiskgrp', { bytes => JSON::PP::true })} ];
}

# Detailed lshost replies list ports differently across code levels
# (repeated "WWPN" keys folded into an array, or a "nodes" list of port
# objects). Collect every 16-hex-digit value under a key named WWPN.
sub extract_wwpns {
    my ($data) = @_;
    my %found;
    walk_wwpns($data, \%found);
    return [ sort keys %found ];
}

sub walk_wwpns {
    my ($x, $found) = @_;
    if (ref($x) eq 'HASH') {
        for my $k (keys %$x) {
            my $v = $x->{$k};
            if (lc($k) eq 'wwpn') {
                for my $w (ref($v) eq 'ARRAY' ? @$v : ($v)) {
                    $found->{uc($w)} = 1 if defined($w) && !ref($w) && $w =~ /^[0-9A-Fa-f]{16}$/;
                }
            } elsif (ref($v)) {
                walk_wwpns($v, $found);
            }
        }
    } elsif (ref($x) eq 'ARRAY') {
        walk_wwpns($_, $found) for @$x;
    }
}

sub hosts {
    my ($self) = @_;
    my @res;
    for my $h (@{$self->list('lshost')}) {
        my $detail = $self->cmd('lshost', $h->{id});
        push @res, {
            id => $h->{id},
            name => $h->{name},
            status => $h->{status},
            hostcluster => (defined($h->{host_cluster_name}) && length($h->{host_cluster_name}))
                ? $h->{host_cluster_name} : undef,
            wwpns => extract_wwpns($detail),
        };
    }
    return \@res;
}

sub host_clusters {
    my ($self) = @_;
    return [ map { { id => $_->{id}, name => $_->{name}, status => $_->{status} } } @{$self->list('lshostcluster')} ];
}

sub volume_from {
    my ($v) = @_;
    my $uid = $v->{vdisk_UID} // '';
    return {
        id => $v->{id},
        name => $v->{name},
        pool => $v->{mdisk_grp_name},
        capacity => num($v->{capacity}),
        uid => $uid,
        wwid => length($uid) ? '3' . lc($uid) : undef, # multipath WWID = NAA designator with type prefix 3
    };
}

sub volume {
    my ($self, $vol) = @_;
    return volume_from($self->cmd('lsvdisk', $vol, { bytes => JSON::PP::true }));
}

sub find_volume_by_wwid {
    my ($self, $wwid) = @_;
    return undef if $wwid !~ /^3([0-9a-f]{32})$/;
    my $uid = uc($1);
    my ($v) = @{$self->list('lsvdisk', { bytes => JSON::PP::true, filtervalue => "vdisk_UID=$uid" })};
    return $v ? volume_from($v) : undef;
}

# --- host registration primitives (see Base::ensure_hostcluster) ---

sub create_hostcluster {
    my ($self, $name) = @_;
    $self->cmd('mkhostcluster', undef, { name => $name });
}

# force: ports need not be logged in yet (zoning may come later)
sub create_host {
    my ($self, $name, $wwpns) = @_;
    $self->cmd('mkhost', undef, { name => $name, fcwwpn => join(':', @$wwpns), force => JSON::PP::true });
    return { name => $name, hostcluster => undef, wwpns => [@$wwpns] };
}

sub add_host_ports {
    my ($self, $host, $wwpns) = @_;
    $self->cmd('addhostport', $host->{name}, { fcwwpn => join(':', @$wwpns), force => JSON::PP::true });
}

sub add_to_hostcluster {
    my ($self, $hcname, $host) = @_;
    $self->cmd('addhostclustermember', $hcname, { host => $host->{name} });
}

# --- volumes ---

# size_gib: whole GiB (Spectrum Virtualize "gb" is binary)
sub create_volume {
    my ($self, %p) = @_;

    die "invalid volume name '$p{name}'\n" if !$self->valid_name($p{name});
    die "size must be a whole number of GiB\n" if $p{size_gib} !~ /^\d+$/ || $p{size_gib} < 1;

    my $r = $self->cmd('mkvolume', undef, {
        name => $p{name},
        pool => $p{pool},
        size => "$p{size_gib}",
        unit => 'gb',
        ($p{thin} ? (thin => JSON::PP::true) : ()),
    });
    my $id = (ref($r) eq 'HASH' ? $r->{id} : undef) // $p{name};
    return $self->volume($id);
}

sub map_to_hostcluster {
    my ($self, $vol, $hcname) = @_;
    $self->cmd('mkvolumehostclustermap', $vol, { hostcluster => $hcname });
}

sub unmap_from_hostcluster {
    my ($self, $vol, $hcname) = @_;
    $self->cmd('rmvolumehostclustermap', $vol, { hostcluster => $hcname });
}

sub delete_volume {
    my ($self, $vol) = @_;
    $self->cmd('rmvolume', $vol);
}

sub expand_volume {
    my ($self, $vol, $add_bytes) = @_;
    die "expansion must be a positive multiple of 512 bytes\n" if $add_bytes <= 0 || $add_bytes % 512;
    $self->cmd('expandvdisksize', $vol, { size => "$add_bytes", unit => 'b' });
}

1;
