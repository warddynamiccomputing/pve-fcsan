package PVE::SAN::Array::Eternus;

# Driver for Fujitsu ETERNUS DX S5 / AF S3 (and DX8100/8900 S4) through the
# ETERNUS RESTful API (controller firmware V11L40 or later; the API must be
# enabled and port 5665 opened in the array's firewall settings).
#
# Checked against "ETERNUS RESTful API Reference" (P3AG-5492-05ENZ0):
#   base       https://<master CM management LAN>:5665/api/v1
#   session    POST session {user_name, password} -> {session_id, token};
#              then "Authorization: Bearer <token>"; DELETE session/<id>
#   async      POST/PATCH/DELETE answer 202 {job_id, job_href}; GET job/<id>
#              -> {status: Queued|Running|Success|Error|Partial_Error|Canceled,
#              resource_href_list, error_code, error_message}; DELETE job/<id>
#   pools      GET tpp -> tpp_list [{tpp_id, name, status, physical_capacity,
#              used_capacity}] (MB)
#   volume     POST volume {name, capacity (MB), tpp_id, is_thick_provisioned}
#              GET volume[/<id>] -> {volume_id, name, capacity (MB), uid}
#              POST volume/<id>/expand {new_capacity}; DELETE volume/<id>
#   host       POST host {type: FC, name (16), wwn}; GET host?type=FC
#   connection POST connection/host/<h>/volume/<v>[?force=true] {hlun}
#              GET connection/host/<h>, GET connection/volume/<v>
#              -> connection_href_list; DELETE <connection_href>?force=true
#
# Mapping model: the RESTful API has no host groups (it cannot create
# connections through host, port or LUN groups). Each FC host is one WWN, so
# every HBA port of every node is registered as its own host
# (<node>_<n>) and each volume is connected to all of them, with the same
# host LUN everywhere. The array picks the CA ports itself: every port with
# host affinity enabled that the WWN is logged in to. The "host cluster" is
# therefore the set of hosts that own the cluster nodes' WWPNs.

use strict;
use warnings;

use JSON::PP ();

use base qw(PVE::SAN::Array::Base);

my $MB = 1024 * 1024;
my $API = '/api/v1';

sub description { return 'Fujitsu ETERNUS DX/AF'; }
sub default_port { return 5665; }
sub max_name_length { return 32; }
sub max_host_name_length { return 16; }

sub valid_name {
    my ($class, $name) = @_;
    return defined($name) && $name =~ /^[A-Za-z0-9_.-]{1,32}$/;
}

sub valid_hostcluster_name {
    my ($class, $name) = @_;
    return defined($name) && length($name); # not an array object
}

sub object_name_for {
    my ($class, $name) = @_;
    $name =~ s/[^A-Za-z0-9_.-]/_/g;
    return substr($name, 0, 28);
}

*short = \&PVE::SAN::Array::Base::short;

sub error_text {
    my ($content) = @_;
    my $d = PVE::SAN::Array::Base::decode($content);
    if (ref($d) eq 'HASH') {
        my $m = join(' ', grep { defined && length } $d->{error_code}, $d->{message} // $d->{error_message});
        return $m if length($m);
    }
    return short($content);
}

sub login {
    my ($self) = @_;
    my $d = $self->json_call('POST', "$API/session", undef,
        { user_name => $self->{username}, password => $self->{password} }, undef, \&error_text, 'ETERNUS');
    die "ETERNUS login: no token\n" if ref($d) ne 'HASH' || !$d->{token};
    $self->{token} = $d->{token};
    $self->{session_id} = $d->{session_id};
}

sub DESTROY {
    my ($self) = @_;
    return if !$self->{session_id};
    local ($@, $!, $?);
    eval {
        $self->request('DELETE', "$API/session/$self->{session_id}", { Authorization => "Bearer $self->{token}" });
    };
}

# One API call; $path is below /api/v1 unless it already starts with it (hrefs).
sub raw {
    my ($self, $method, $path, $query, $body) = @_;
    $self->login() if !$self->{token};
    my $url = ($path =~ m{^\Q$API\E/} ? $path : "$API$path") . PVE::SAN::Array::Base::query_string($query);
    my ($code, $content) = $self->request($method, $url, { Authorization => "Bearer $self->{token}" }, $body);
    if ($code == 401) { # token lifetime is 30 minutes
        $self->login();
        ($code, $content) = $self->request($method, $url, { Authorization => "Bearer $self->{token}" }, $body);
    }
    return ($code, $content);
}

sub get {
    my ($self, $path, $query) = @_;
    my ($code, $content) = $self->raw('GET', $path, $query);
    die "ETERNUS GET $path failed (HTTP $code): " . error_text($content) . "\n" if $code < 200 || $code >= 300;
    return PVE::SAN::Array::Base::decode($content) // {};
}

# GET a list resource, following next_href.
sub list {
    my ($self, $path, $key, $query) = @_;
    my @all;
    my $d = $self->get($path, $query);
    while (1) {
        push @all, @{$d->{$key} // []};
        my $next = $d->{next_href} or last;
        $d = $self->get($next);
    }
    return \@all;
}

# POST/PATCH/DELETE: wait for the job; returns the finished job.
sub change {
    my ($self, $method, $path, $query, $body) = @_;
    my ($code, $content) = $self->raw($method, $path, $query, $body);
    die "ETERNUS $method $path failed (HTTP $code): " . error_text($content) . "\n" if $code < 200 || $code >= 300;
    my $d = PVE::SAN::Array::Base::decode($content);
    return $d if ref($d) ne 'HASH' || !defined($d->{job_id});

    my $deadline = time() + ($self->{job_timeout} // 900);
    my $job;
    while (1) {
        $job = $self->get("/job/$d->{job_id}");
        my $st = $job->{status} // '';
        last if $st =~ /^(Success|Error|Partial_Error|Canceled)$/;
        die "ETERNUS $method $path: job $d->{job_id} still $st after timeout\n" if time() > $deadline;
        sleep($self->{poll_interval} // 2);
    }
    eval { $self->raw('DELETE', "/job/$d->{job_id}") }; # the array keeps at most 512 jobs
    if ($job->{status} ne 'Success') {
        my @failed = map { $_->{operation} } grep { ($_->{result} // '') eq 'Failed' } @{$job->{operation_list} // []};
        die "ETERNUS $method $path: job $d->{job_id} " . lc($job->{status}) . ": "
            . join(' ', grep { defined && length } $job->{error_code}, $job->{error_message})
            . (@failed ? " (@failed)" : '') . "\n";
    }
    return $job;
}

sub created_id {
    my ($job, $kind) = @_;
    for my $h (@{$job->{resource_href_list} // []}) {
        return $1 if $h =~ m{/\Q$kind\E/(\d+)$};
    }
    return undef;
}

sub system_info {
    my ($self) = @_;
    my $s = $self->get('/storagesystem');
    return {
        name => $s->{storage_system_name} // $s->{serial_number},
        product => 'Fujitsu ETERNUS ' . ($s->{model_name} // 'DX'),
        code_level => $s->{firmware_version},
        id => $s->{serial_number},
    };
}

sub pools {
    my ($self) = @_;
    return [ map {
        my $cap = defined($_->{physical_capacity}) ? $_->{physical_capacity} * $MB : undef;
        { id => $_->{tpp_id}, name => $_->{name}, status => $_->{status}, capacity => $cap,
          free => defined($cap) && defined($_->{used_capacity}) ? $cap - $_->{used_capacity} * $MB : undef }
    } @{$self->list('/tpp', 'tpp_list')} ];
}

# --- hosts: one ETERNUS FC host per WWN ---

sub fc_hosts {
    my ($self) = @_;
    return [ map { { id => $_->{host_id}, name => $_->{name},
        wwn => PVE::SAN::Array::Base::norm_wwpn($_->{wwn}), shared => $_->{is_shared_host_exist} } }
        @{$self->list('/host', 'host_list', { type => 'FC' })} ];
}

# { node => [WWPN, ...] } of the cluster; set by ensure_hostcluster or read
# from the nodes.
sub cluster_wwpns {
    my ($self) = @_;
    return $self->{node_wwpns} //= do { require PVE::SAN::Array; PVE::SAN::Array::node_wwpns() };
}

sub host_clusters {
    my ($self) = @_;
    my $hc = $self->{hostcluster} // 'pve';
    return [ { name => $hc, id => $hc } ];
}

# Hosts as the shared code sees them: the WWN hosts of one node merged into
# one host that is in the (virtual) host cluster; other hosts as they are.
sub hosts {
    my ($self) = @_;
    my %node_of;
    my $nw = $self->cluster_wwpns;
    for my $node (keys %$nw) {
        $node_of{$_} = $node for grep { defined } map { PVE::SAN::Array::Base::norm_wwpn($_) } @{$nw->{$node}};
    }
    my (%by_node, @res);
    for my $h (@{$self->fc_hosts}) {
        next if !$h->{wwn};
        if (my $node = $node_of{$h->{wwn}}) {
            push @{$by_node{$node}}, $h;
        } else {
            push @res, { name => $h->{name}, id => $h->{id}, hostcluster => undef, wwpns => [ $h->{wwn} ] };
        }
    }
    for my $node (sort keys %by_node) {
        my @h = sort { $a->{name} cmp $b->{name} } @{$by_node{$node}};
        push @res, { name => join('+', map { $_->{name} } @h), id => [ map { $_->{id} } @h ],
            hostcluster => $self->{hostcluster} // 'pve', wwpns => [ map { $_->{wwn} } @h ] };
    }
    return \@res;
}

sub host_name_for {
    my ($self, $node, $taken) = @_;
    (my $base = $node) =~ s/[^A-Za-z0-9_.-]/_/g;
    for my $i (1 .. 99) {
        (my $name = substr($base, 0, $self->max_host_name_length - 1 - length($i))) =~ s/[-_.]+$//;
        $name .= "_$i";
        return $name if !$taken->{$name};
    }
    die "no free ETERNUS host name for node '$node'\n";
}

sub ensure_hostcluster {
    my ($self, $hcname, $node_wwpns, $log) = @_;
    $log //= sub { print "$_[0]\n" };

    my $sets = $self->node_port_sets($node_wwpns); # IQNs: not supported yet
    $self->{node_wwpns} = $node_wwpns;
    my $hosts = $self->fc_hosts;
    my %have = map { $_->{wwn} => $_ } grep { $_->{wwn} } @$hosts;
    my %taken = map { $_->{name} => 1 } @$hosts;

    my %result;
    for my $node (sort keys %$node_wwpns) {
        my @want = grep { defined } map { PVE::SAN::Array::Base::norm_wwpn($_) } @{$node_wwpns->{$node}};
        die "node '$node' has no FC ports\n" if !@want;
        my $r = $result{$node} = { created => 0, added_ports => [], joined => 0 };
        my @names;
        for my $w (@want) {
            if (my $h = $have{$w}) {
                push @names, $h->{name};
                next;
            }
            my $name = $self->host_name_for($node, \%taken);
            $log->("registering FC host '$name' (WWN $w) for node $node");
            $self->change('POST', '/host', undef, { type => 'FC', name => $name, wwn => lc($w) });
            $taken{$name} = 1;
            push @names, $name;
            push @{$r->{added_ports}}, $w;
            $r->{created} = 1;
        }
        $r->{host} = join('+', @names);
    }
    return \%result;
}

# ETERNUS hosts (id => host) that own the cluster's WWPNs; all must exist.
sub cluster_hosts {
    my ($self) = @_;
    my %by_wwn = map { $_->{wwn} => $_ } grep { $_->{wwn} } @{$self->fc_hosts};
    my (@hosts, @missing);
    my $nw = $self->cluster_wwpns;
    for my $node (sort keys %$nw) {
        for my $w (grep { defined } map { PVE::SAN::Array::Base::norm_wwpn($_) } @{$nw->{$node}}) {
            if ($by_wwn{$w}) { push @hosts, $by_wwn{$w}; } else { push @missing, "$node:$w"; }
        }
    }
    die "WWPNs not registered on the ETERNUS: @missing - register the cluster first\n" if @missing;
    die "no cluster hosts on the ETERNUS\n" if !@hosts;
    return \@hosts;
}

# --- volumes (id = RESTful API volume ID) ---

sub volume_from {
    my ($v) = @_;
    return {
        id => $v->{volume_id},
        name => $v->{name},
        capacity => defined($v->{capacity}) ? $v->{capacity} * $MB : undef,
        uid => $v->{uid},
        wwid => PVE::SAN::Array::Base::naa_to_wwid($v->{uid}),
    };
}

sub volume {
    my ($self, $id) = @_;
    return volume_from($self->get("/volume/$id"));
}

sub find_volume_by_wwid {
    my ($self, $wwid) = @_;
    for my $v (@{$self->list('/volume', 'volume_list')}) {
        my $vol = volume_from($v);
        return $vol if ($vol->{wwid} // '') eq $wwid;
    }
    return undef;
}

sub create_volume {
    my ($self, %p) = @_;

    die "invalid ETERNUS volume name '$p{name}' (1-32 of A-Z a-z 0-9 _ . -)\n" if !$self->valid_name($p{name});
    die "size must be a whole number of GiB\n" if $p{size_gib} !~ /^\d+$/ || $p{size_gib} < 1;
    my ($pool) = grep { $_->{name} eq $p{pool} } @{$self->pools()};
    die "ETERNUS thin provisioning pool '$p{pool}' not found\n" if !$pool;

    my $job = $self->change('POST', '/volume', undef, {
        name => $p{name},
        capacity => $p{size_gib} * 1024,
        tpp_id => $pool->{id} + 0,
        is_thick_provisioned => (defined($p{thin}) && !$p{thin}) ? JSON::PP::true : JSON::PP::false,
    });
    my $id = created_id($job, 'volume');
    if (!defined($id)) { # older firmware: find it by its (unique) name
        my ($v) = grep { ($_->{name} // '') eq $p{name} } @{$self->list('/volume', 'volume_list')};
        $id = $v->{volume_id} if $v;
    }
    die "ETERNUS: volume '$p{name}' not found after creation\n" if !defined($id);
    return $self->volume($id);
}

sub host_connections {
    my ($self, $host_id) = @_;
    return $self->list("/connection/host/$host_id", 'connection_list');
}

sub connection {
    my ($self, $host_id, $vol_id) = @_;
    my ($code, $content) = $self->raw('GET', "/connection/host/$host_id/volume/$vol_id");
    return undef if $code == 404;
    die "ETERNUS GET connection host $host_id volume $vol_id failed (HTTP $code): " . error_text($content) . "\n"
        if $code < 200 || $code >= 300;
    return PVE::SAN::Array::Base::decode($content);
}

sub href_id { return $_[0] =~ m{/(\d+)$} ? $1 : undef; }

sub map_to_hostcluster {
    my ($self, $id, $hcname) = @_;

    my $hosts = $self->cluster_hosts;
    my %cluster = map { $_->{id} => 1 } @$hosts;

    # one host LUN that is free on every cluster host
    my (%used, %shared);
    for my $h (@$hosts) {
        my $conns = $self->host_connections($h->{id});
        $used{$_->{hlun}} = 1 for grep { defined($_->{hlun}) } @$conns;
        if ($h->{shared}) {
            my @other = grep { defined && !$cluster{$_} } map { href_id($_) }
                map { @{$_->{shared_host_href_list} // []} } @$conns;
            die "ETERNUS host '$h->{name}' shares its LUN group with hosts outside this cluster (IDs @other)"
                . " - give the cluster's hosts their own LUN group on the array\n" if @other;
            $shared{$h->{id}} = 1;
        }
    }
    my ($hlun) = grep { !$used{$_} } 0 .. 255;
    die "ETERNUS: no host LUN free on all cluster hosts\n" if !defined($hlun);

    for my $h (@$hosts) {
        next if $self->connection($h->{id}, $id); # already there (shared LUN group)
        $self->change('POST', "/connection/host/$h->{id}/volume/$id",
            $shared{$h->{id}} ? { force => 'true' } : undef, { hlun => $hlun });
        my $c = $self->connection($h->{id}, $id);
        print "warning: ETERNUS host '$h->{name}' is not logged in to any CA port with host affinity enabled"
            . " - check zoning and the port settings\n" if $c && !@{$c->{caport_href_list} // []};
    }
}

sub unmap_from_hostcluster {
    my ($self, $id, $hcname) = @_;
    my $d = $self->get("/connection/volume/$id");
    for my $href (@{$d->{connection_href_list} // []}) {
        $self->change('DELETE', $href, { force => 'true' });
    }
}

sub expand_volume {
    my ($self, $id, $add_bytes) = @_;
    die "expansion must be a positive multiple of 1 MiB\n" if $add_bytes <= 0 || $add_bytes % $MB;
    my $cur = $self->get("/volume/$id");
    $self->change('POST', "/volume/$id/expand", undef, { new_capacity => $cur->{capacity} + $add_bytes / $MB });
}

sub delete_volume {
    my ($self, $id) = @_;
    $self->change('DELETE', "/volume/$id");
}

1;
