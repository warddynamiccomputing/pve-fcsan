package PVE::SAN::Array::Infinidat;

# Driver for INFINIDAT InfiniBox through its REST API (/api/rest).
#
# Authentication: HTTP Basic with an InfiniBox user (Pool Admin or Admin
# role). Replies are wrapped as { result, error, metadata }; lists are
# paged (page / page_size, metadata.pages_total).
#
# InfiniBox specifics:
#  - pools have physical and virtual capacity; volumes are THIN or THICK
#  - host clusters are "clusters"; mappings are LUNs on the cluster
#  - destructive calls need ?approved=true
#  - the multipath WWID is 3 + "6" + the volume serial (InfiniBox NAA,
#    IEEE OUI 742b0f)
#
# The REST calls below are checked against InfiniSDK's source (branch
# 'external', infinisdk/infinibox/*.py and infinisdk/core/*.py):
#   host_cluster.py   add_host: POST clusters/<id>/hosts {id}
#   system_object.py  map_volume: POST <cluster>/luns {volume_id[, lun]}
#   lun.py            unmap: DELETE <cluster>/luns/lun/<lun> (404 = gone)
#   translators_and_types.py  ports: {type: "fc", address: str(WWN)}
#   dataset.py        size (bytes), provtype THICK|THIN, pool_id; resize
#                     = update of 'size'
#   scsi_serial.py    serial = 742b0f (IEEE id) + 25 hex digits, no NAA nibble
#   core/api/api.py   non-GET requests carry ?approved=true; Basic auth works
# All paths live in %PATH.

use strict;
use warnings;

use MIME::Base64 ();

use base qw(PVE::SAN::Array::Base);

my %PATH = (
    system => '/system',
    pools => '/pools',
    volumes => '/volumes',
    hosts => '/hosts',
    clusters => '/clusters',
    cluster => '/clusters/%s',                # GET ?fields=luns
    host_ports => '/hosts/%s/ports',          # POST { type => 'fc', address }
    cluster_hosts => '/clusters/%s/hosts',    # POST { id => host_id }
    cluster_luns => '/clusters/%s/luns',      # POST { volume_id }
    cluster_lun => '/clusters/%s/luns/lun/%s', # DELETE
);

sub description { return 'INFINIDAT InfiniBox'; }

# multipath-tools queues I/O on these LUNs forever when all paths are gone
sub default_no_path_retry { return 12; }
sub default_port { return 443; }
sub max_name_length { return 65; }

sub valid_name {
    my ($class, $name) = @_;
    return defined($name) && length($name) <= 65 && $name =~ /^[A-Za-z_][A-Za-z0-9_.-]*$/;
}

*short = \&PVE::SAN::Array::Base::short;

sub auth_header {
    my ($self) = @_;
    return 'Basic ' . MIME::Base64::encode_base64("$self->{username}:$self->{password}", '');
}

sub error_text {
    my ($content) = @_;
    my $d = PVE::SAN::Array::Base::decode($content);
    if (ref($d) eq 'HASH' && ref($d->{error}) eq 'HASH') {
        return join(': ', grep { defined && length } $d->{error}->{code}, $d->{error}->{message});
    }
    return short($content);
}

# One API call; returns ('result', 'metadata'). Like InfiniSDK in
# non-interactive mode, every non-GET request is pre-approved
# (?approved=true); without it the array refuses "dangerous" operations.
# %opts: allow_404 => 1 returns (undef, undef) on 404.
sub call {
    my ($self, $method, $path, $query, $body, %opts) = @_;

    my %q = %{$query // {}};
    $q{approved} = 'true' if $method ne 'GET';
    my $url = "/api/rest$path" . PVE::SAN::Array::Base::query_string(\%q);

    my ($code, $content) = $self->request($method, $url, { Authorization => $self->auth_header }, $body);
    return (undef, undef) if $code == 404 && $opts{allow_404};
    my $d = PVE::SAN::Array::Base::decode($content);
    if ($code < 200 || $code >= 300 || (ref($d) eq 'HASH' && $d->{error})) {
        die "InfiniBox $method $path failed (HTTP $code): " . error_text($content) . "\n";
    }
    return ref($d) eq 'HASH' ? ($d->{result}, $d->{metadata}) : (undef, undef);
}

# Paged GET. Stops on pages_total, on number_of_objects, or on a short page.
sub list {
    my ($self, $path, $query) = @_;
    my $size = 1000;
    my @all;
    for (my $page = 1; $page <= 10000; $page++) {
        my ($res, $meta) = $self->call('GET', $path, { %{$query // {}}, page => $page, page_size => $size });
        my @got = @{ref($res) eq 'ARRAY' ? $res : []};
        push @all, @got;
        $meta //= {};
        last if $meta->{pages_total} && $page >= $meta->{pages_total};
        last if defined($meta->{number_of_objects}) && @all >= $meta->{number_of_objects};
        last if @got < ($meta->{page_size} // $size);
    }
    return \@all;
}

# --- read side ---

sub system_info {
    my ($self) = @_;
    my ($s) = $self->call('GET', $PATH{system});
    return {
        name => $s->{name},
        product => 'InfiniBox' . ($s->{model} ? " $s->{model}" : ''),
        code_level => $s->{version} // ($s->{release} ? $s->{release}->{version} : undef),
        id => $s->{serial},
    };
}

sub pools {
    my ($self) = @_;
    return [ map {
        {
            id => $_->{id},
            name => $_->{name},
            status => $_->{state} // 'NORMAL',
            capacity => $_->{physical_capacity},
            free => $_->{free_physical_space},
            free_virtual => $_->{free_virtual_space},
        }
    } @{$self->list($PATH{pools})} ];
}

sub pool_id {
    my ($self, $name) = @_;
    my ($p) = grep { $_->{name} eq $name } @{$self->pools()};
    die "InfiniBox pool '$name' not found\n" if !$p;
    return $p->{id};
}

sub host_clusters {
    my ($self) = @_;
    return [ map {
        { id => $_->{id}, name => $_->{name}, host_ids => [ map { $_->{id} } @{$_->{hosts} // []} ] }
    } @{$self->list($PATH{clusters})} ];
}

sub cluster_id {
    my ($self, $name) = @_;
    my ($c) = grep { $_->{name} eq $name } @{$self->host_clusters()};
    die "InfiniBox host cluster '$name' not found\n" if !$c;
    return $c->{id};
}

sub hosts {
    my ($self) = @_;
    my %in;
    for my $c (@{$self->host_clusters()}) { $in{$_} = $c->{name} for @{$c->{host_ids}}; }
    return [ map {
        my $h = $_;
        {
            id => $h->{id},
            name => $h->{name},
            hostcluster => $in{$h->{id}},
            wwpns => [ sort grep { defined } map { PVE::SAN::Array::Base::norm_wwpn($_->{address}) }
                grep { uc($_->{type} // '') eq 'FC' } @{$h->{ports} // []} ],
        }
    } @{$self->list($PATH{hosts})} ];
}

sub wwpn_colon {
    my ($w) = @_;
    return lc(join(':', $w =~ /(..)/g));
}

sub create_hostcluster {
    my ($self, $name) = @_;
    $self->call('POST', $PATH{clusters}, undef, { name => $name });
}

sub create_host {
    my ($self, $name, $wwpns) = @_;
    my ($h) = $self->call('POST', $PATH{hosts}, undef, { name => $name });
    my $host = { id => $h->{id}, name => $name, hostcluster => undef, wwpns => [] };
    $self->add_host_ports($host, $wwpns);
    $host->{wwpns} = [@$wwpns];
    return $host;
}

sub add_host_ports {
    my ($self, $host, $wwpns) = @_;
    for my $w (@$wwpns) {
        $self->call('POST', sprintf($PATH{host_ports}, $host->{id}), undef, { type => 'fc', address => wwpn_colon($w) });
    }
}

sub add_to_hostcluster {
    my ($self, $hcname, $host) = @_;
    $self->call('POST', sprintf($PATH{cluster_hosts}, $self->cluster_id($hcname)), undef, { id => $host->{id} });
}

# --- monitoring and lifecycle ---
# (dataset.py fields size, used, capacity_savings; host_cluster.py
# remove_host: DELETE clusters/<id>/hosts/<host id>)

sub volume_space {
    my ($self, $ids) = @_;
    return [ map {
        my ($v) = $self->call('GET', "$PATH{volumes}/$_");
        { id => $_, provisioned => $v->{size}, written => $v->{used}, saved => $v->{capacity_savings} }
    } @$ids ];
}

sub remove_host {
    my ($self, $host, $hcname) = @_;
    if (($host->{hostcluster} // '') eq $hcname) {
        $self->call('DELETE', sprintf($PATH{cluster_hosts}, $self->cluster_id($hcname)) . "/$host->{id}", undef, undef);
    }
    $self->call('DELETE', "$PATH{hosts}/$host->{id}", undef, undef);
}

# --- volumes ---

# InfiniBox reports the serial with or without the NAA type nibble.
sub serial_to_wwid {
    my ($serial) = @_;
    my $s = lc($serial // '');
    $s =~ s/[^0-9a-f]//g;
    return "3$s" if length($s) == 32 && $s =~ /^6/;
    return "36$s" if length($s) == 31;
    return undef;
}

sub volume_from {
    my ($v) = @_;
    return {
        id => $v->{id},
        name => $v->{name},
        pool => $v->{pool_name} // $v->{pool_id},
        capacity => $v->{size},
        uid => $v->{serial},
        wwid => serial_to_wwid($v->{serial}),
    };
}

sub volume {
    my ($self, $id) = @_;
    my ($v) = $self->call('GET', "$PATH{volumes}/$id");
    die "InfiniBox volume $id not found\n" if !$v;
    return volume_from($v);
}

sub find_volume_by_wwid {
    my ($self, $wwid) = @_;
    for my $v (@{$self->list($PATH{volumes})}) {
        my $vol = volume_from($v);
        return $vol if ($vol->{wwid} // '') eq $wwid;
    }
    return undef;
}

sub create_volume {
    my ($self, %p) = @_;

    die "invalid volume name '$p{name}'\n" if !$self->valid_name($p{name});
    die "size must be a whole number of GiB\n" if $p{size_gib} !~ /^\d+$/ || $p{size_gib} < 1;

    my ($v) = $self->call('POST', $PATH{volumes}, undef, {
        name => $p{name},
        pool_id => $self->pool_id($p{pool}),
        size => $p{size_gib} * $PVE::SAN::Array::Base::GIB,
        provtype => $p{thin} ? 'THIN' : 'THICK',
    });
    return volume_from($v);
}

sub map_to_hostcluster {
    my ($self, $vol, $hcname) = @_;
    $self->call('POST', sprintf($PATH{cluster_luns}, $self->cluster_id($hcname)), undef, { volume_id => $vol + 0 });
}

# LUNs mapped to a cluster: [ { lun, volume_id, ... } ]
sub cluster_luns {
    my ($self, $cid) = @_;
    my ($c) = $self->call('GET', sprintf($PATH{cluster}, $cid), { fields => 'luns' });
    return ref($c) eq 'HASH' && ref($c->{luns}) eq 'ARRAY' ? $c->{luns} : [];
}

# Unmap by LUN number (as InfiniSDK does); already unmapped is fine.
sub unmap_from_hostcluster {
    my ($self, $vol, $hcname) = @_;
    my $cid = $self->cluster_id($hcname);
    my @luns = grep { ($_->{volume_id} // '') eq $vol } @{$self->cluster_luns($cid)};
    if (!@luns) {
        print "volume $vol is not mapped to cluster '$hcname'\n";
        return;
    }
    for my $l (@luns) {
        $self->call('DELETE', sprintf($PATH{cluster_lun}, $cid, $l->{lun}), undef, undef, allow_404 => 1);
    }
}

sub expand_volume {
    my ($self, $vol, $add_bytes) = @_;
    die "expansion must be a positive multiple of 512 bytes\n" if $add_bytes <= 0 || $add_bytes % 512;
    my $cur = $self->volume($vol);
    $self->call('PUT', "$PATH{volumes}/$vol", undef, { size => $cur->{capacity} + $add_bytes });
}

sub delete_volume {
    my ($self, $vol) = @_;
    $self->call('DELETE', "$PATH{volumes}/$vol", undef, undef);
}

1;
