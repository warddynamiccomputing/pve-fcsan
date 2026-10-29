package PVE::SAN::Array::Base;

# Shared parts of all array drivers: TLS-pinned HTTP client, naming rules
# and the vendor-neutral host / host-cluster registration logic.
#
# A driver implements these primitives (names are array object names):
#
#   system_info()                      -> { name, product, code_level }
#   pools()                            -> [ { name, capacity, free, status } ]
#   host_clusters()                    -> [ { name, id } ]
#   hosts()                            -> [ { name, id, hostcluster, wwpns => [WWPN] } ]
#   create_hostcluster($name)
#   create_host($name, \@wwpns)        -> host (same shape as hosts())
#   add_host_ports($host, \@wwpns)
#   add_to_hostcluster($hcname, $host)
#   create_volume(name, pool, size_gib, thin) -> volume
#   volume($id), find_volume_by_wwid($wwid)   -> { id, name, capacity, uid, wwid }
#   map_to_hostcluster($vol_id, $hc), unmap_from_hostcluster($vol_id, $hc)
#   expand_volume($vol_id, $add_bytes), delete_volume($vol_id)
#
# WWPNs are passed around as 16 upper-case hex digits without colons.

use strict;
use warnings;

use JSON::PP;

our $GIB = 1024 * 1024 * 1024;

my $json = JSON::PP->new->allow_nonref->canonical;
sub json { return $json; }

# --- per driver defaults, overridden where the vendor differs ---

sub default_port { return 443; }
sub needs_username { return 1; }
sub default_policy { return 'array-default'; } # multipath-tools' built-in table for the array
sub max_name_length { return 63; }

# Vendor specific settings this driver uses: { option => required? }.
# Options: system_id, svm, portgroup, srp, slo, target_ports.
sub options { return {}; }

sub check_options {
    my ($class, $cfg) = @_;
    my $opts = $class->options;
    for my $o (sort keys %$opts) {
        next if !$opts->{$o};
        die "array setting '" . ($o =~ s/_/-/gr) . "' is required for " . $class->description . "\n"
            if !defined($cfg->{$o}) || !length($cfg->{$o});
    }
}

# Some arrays only report a volume's WWID once it is mapped (Hitachi).
sub wwid_after_map { return 0; }

# --- monitoring and lifecycle (optional; undef = not reported) ---
#
#   volume_space(\@vol_ids) -> [ { id, provisioned, written, reduction, saved } ]
#   health()                -> { status => ok|warning|critical, alerts => [ { severity, summary } ] }
#   target_ports()          -> [ WWPN ] of the array's FC target ports
#   remove_host($host, $hcname)  take a host out of the host cluster and delete it

# Every driver can report provisioned size through volume().
sub volume_space {
    my ($self, $ids) = @_;
    return [ map { my $v = $self->volume($_); { id => $_, provisioned => $v->{capacity} } } @$ids ];
}

sub health { return undef; }
sub target_ports { return undef; }
sub remove_host { die $_[0]->description . ": removing hosts is not supported yet by the pvesan driver\n" }

# no_path_retry pvesan sets for this array's LUNs when it provisions them.
# Only where multipath-tools' built-in table queues I/O forever ("queue"):
# 12 checks x 5 s polling interval = about one minute of queueing.
sub default_no_path_retry { return undef; }

sub valid_name {
    my ($class, $name) = @_;
    return defined($name) && $name =~ /^[A-Za-z_][A-Za-z0-9_.-]*$/ && length($name) <= $class->max_name_length;
}

# Name rules for the cluster object (host cluster / host group / igroup);
# the same as volume names unless a driver says otherwise.
sub valid_hostcluster_name {
    my ($class, $name) = @_;
    return $class->valid_name($name);
}

# Turn a Proxmox name (node, storage ID) into a valid array object name.
sub object_name_for {
    my ($class, $name) = @_;
    $name =~ s/[^A-Za-z0-9_.-]/_/g;
    $name = "pve_$name" if $name !~ /^[A-Za-z_]/;
    return substr($name, 0, $class->max_name_length - 4);
}

sub new {
    my ($class, %cfg) = @_;

    die "array address missing\n" if !$cfg{address};
    die "array username missing\n" if $class->needs_username && !(defined($cfg{username}) && length($cfg{username}));
    die "array password missing\n" if !defined($cfg{password}) || !length($cfg{password});
    die "array certificate fingerprint missing - probe and confirm it first\n"
        if !$cfg{fingerprint} && !$cfg{transport};

    $class->check_options(\%cfg);

    my $self = bless { %cfg }, $class;
    $self->{port} //= $class->default_port;
    return $self;
}

sub host_port {
    my ($self) = @_;
    my $host = $self->{address};
    $host = "[$host]" if $host =~ /:/; # IPv6
    return "$host:$self->{port}";
}

sub short {
    my ($text) = @_;
    $text //= '';
    $text =~ s/\s+/ /g;
    return length($text) > 300 ? substr($text, 0, 300) . '...' : $text;
}

sub escape {
    my ($s) = @_;
    $s =~ s/([^A-Za-z0-9_.~-])/sprintf('%%%02X', ord($1))/ge;
    return $s;
}

sub query_string {
    my ($query) = @_;
    return '' if !$query || !%$query;
    return '?' . join('&', map { escape($_) . '=' . escape($query->{$_}) } sort keys %$query);
}

# The array's certificate is trusted only by its pinned SHA-256 fingerprint
# (array certificates are usually self-signed).
sub ua {
    my ($self) = @_;
    require LWP::UserAgent;
    return $self->{ua} //= LWP::UserAgent->new(
        timeout => 120,
        agent => 'pve-fcsan',
        ssl_opts => {
            verify_hostname => 0,
            SSL_verify_mode => 1, # SSL_VERIFY_PEER, satisfied by the fingerprint
            SSL_fingerprint => $self->{fingerprint},
        },
    );
}

# Generic HTTPS request. Returns (code, body, { lower-case header => value }).
# Tests inject 'transport' => sub ($method, $path_and_query, $headers, $body).
sub request {
    my ($self, $method, $url_path, $headers, $body) = @_;

    return $self->{transport}->($method, $url_path, $headers, $body) if $self->{transport};

    require HTTP::Request;
    my $req = HTTP::Request->new($method => "https://" . $self->host_port . $url_path);
    $req->header('Accept' => 'application/json');
    $req->header($_ => $headers->{$_}) for keys %{$headers // {}};
    if (defined($body)) {
        $req->header('Content-Type' => 'application/json');
        $req->content($json->encode($body));
    }
    my $res = $self->ua->request($req);
    my %h = map { lc($_) => scalar($res->header($_)) } $res->header_field_names;
    return ($res->code, $res->decoded_content // '', \%h);
}

sub decode {
    my ($content) = @_;
    return undef if !defined($content) || $content !~ /\S/;
    return eval { $json->decode($content) };
}

sub basic_auth {
    my ($self) = @_;
    require MIME::Base64;
    return 'Basic ' . MIME::Base64::encode_base64("$self->{username}:$self->{password}", '');
}

# Plain-JSON call helper for REST APIs with Basic auth. Returns decoded body.
# $errfn turns an error body into text.
sub json_call {
    my ($self, $method, $path, $query, $body, $headers, $errfn, $what) = @_;
    my $url = $path . query_string($query);
    my ($code, $content, $h) = $self->request($method, $url, $headers, $body);
    if ($code < 200 || $code >= 300) {
        my $msg = $errfn ? $errfn->($content) : short($content);
        die(($what // 'array') . " $method $path failed (HTTP $code): $msg\n");
    }
    return wantarray ? (decode($content), $code, $h) : decode($content);
}

sub colon_wwpn {
    my ($w) = @_;
    return lc(join(':', $w =~ /(..)/g));
}

# NAA designator from a hex string ("naa.6...", "60:0a:...", "600A...") -> multipath WWID
sub naa_to_wwid {
    my ($naa) = @_;
    my $h = lc($naa // '');
    $h =~ s/^naa\.//;
    $h =~ s/[^0-9a-f]//g;
    return length($h) == 32 && $h =~ /^6/ ? "3$h" : undef;
}

sub norm_wwpn {
    my ($w) = @_;
    $w = uc($w // '');
    $w =~ s/[^0-9A-F]//g;
    return length($w) == 16 ? $w : undef;
}

sub volume_name_for {
    my ($self, $storeid) = @_;
    return $self->valid_name($storeid) ? $storeid : $self->object_name_for($storeid);
}

# Make sure every node's ports are in a host object and every such host is
# in host cluster $hcname. $node_wwpns = { node => [WWPN, ...] }.
# Existing hosts that already own a node's ports are reused; a host in a
# different host cluster or ports split across hosts are refused (that is
# an admin decision on the array).
sub ensure_hostcluster {
    my ($self, $hcname, $node_wwpns, $log) = @_;
    $log //= sub { print "$_[0]\n" };

    die "invalid host cluster name '$hcname' for this array\n" if !$self->valid_hostcluster_name($hcname);

    if (!grep { $_->{name} eq $hcname } @{$self->host_clusters()}) {
        $log->("creating host cluster '$hcname'");
        $self->create_hostcluster($hcname);
    }

    my $hosts = $self->hosts();
    my %owner;
    for my $h (@$hosts) { $owner{$_} = $h for @{$h->{wwpns}}; }
    my %taken = map { $_->{name} => 1 } @$hosts;

    my %result;
    for my $node (sort keys %$node_wwpns) {
        my @want = grep { defined } map { norm_wwpn($_) } @{$node_wwpns->{$node}};
        die "node '$node' has no FC ports\n" if !@want;

        my %owners = map { $_->{name} => $_ } grep { defined } map { $owner{$_} } @want;
        die "ports of node '$node' are split across array hosts " . join(', ', sort keys %owners)
            . " - merge them on the array first\n" if keys %owners > 1;

        my ($host) = values %owners;
        my $r = $result{$node} = { created => 0, added_ports => [], joined => 0 };

        if ($host) {
            my %have = map { $_ => 1 } @{$host->{wwpns}};
            my @missing = grep { !$have{$_} } @want;
            if (@missing) {
                $log->("adding ports @missing to array host '$host->{name}' ($node)");
                $self->add_host_ports($host, \@missing);
                $r->{added_ports} = \@missing;
            }
        } else {
            my $name = $self->valid_name($node) ? $node : $self->object_name_for($node);
            $name .= '-pve' if $taken{$name};
            die "array already has hosts '$node' and '$name'\n" if $taken{$name};
            $log->("creating array host '$name' for node $node with ports @want");
            $host = $self->create_host($name, \@want);
            $taken{$name} = 1;
            $r->{created} = 1;
        }
        $r->{host} = $host->{name};

        my $in = $host->{hostcluster};
        if (defined($in) && $in ne $hcname) {
            die "array host '$host->{name}' ($node) already belongs to host cluster '$in'\n";
        } elsif (!defined($in)) {
            $log->("adding host '$host->{name}' to host cluster '$hcname'");
            $self->add_to_hostcluster($hcname, $host);
            $r->{joined} = 1;
        }
    }
    return \%result;
}

1;
