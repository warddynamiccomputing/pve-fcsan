package PVE::SAN::Array::Base;

# Shared parts of all array drivers: TLS-pinned HTTP client, naming rules
# and the vendor-neutral host / host-cluster registration logic.
#
# A driver implements these primitives (names are array object names):
#
#   system_info()                      -> { name, product, code_level }
#   pools()                            -> [ { name, capacity, free, status } ]
#   host_clusters()                    -> [ { name, id } ]
#   hosts()                            -> [ { name, id, hostcluster, wwpns => [WWPN],
#                                             iqns => [IQN] } ]
#   create_hostcluster($name)
#   create_host($name, \@wwpns, \@iqns) -> host (same shape as hosts())
#   add_host_ports($host, \@wwpns, \@iqns)
#   add_to_hostcluster($hcname, $host)
#   create_volume(name, pool, size_gib, thin) -> volume
#   volume($id), find_volume_by_wwid($wwid)   -> { id, name, capacity, uid, wwid }
#   map_to_hostcluster($vol_id, $hc), unmap_from_hostcluster($vol_id, $hc)
#   expand_volume($vol_id, $add_bytes), delete_volume($vol_id)
#
# Array snapshots (optional; supports_snapshots() says whether a driver has
# them, the defaults below die with "not supported yet"):
#
#   snapshot_create(\@vol_ids, $name)  -> [ snapshot ]  one point in time for
#                                         all volumes (consistency group or
#                                         group snapshot when there are several)
#   snapshots(\@vol_ids)               -> [ snapshot ]
#   snapshot_delete($snapshot)         a snapshot taken as a group goes as a whole
#   snapshot_clone($snapshot, $name)   -> volume: a new writable, unmapped volume
#   snapshot_restore($vol_id, $snapshot)  overwrite the volume with the snapshot
#
#   snapshot = { id, name, volume (source volume id), created (epoch seconds),
#                size (bytes), group (array object deleted with it, if any) }
#   'name' is the pvesan snapshot name, the same for every member of one set.
#
# WWPNs are passed around as 16 upper-case hex digits without colons, iSCSI
# names (iqn./eui.) in lower case. Only drivers whose supports_iscsi() is
# true are handed IQNs; ensure_hostcluster refuses them for the others.
#
# iSCSI (optional, with supports_iscsi()):
#
#   target_portals()                   -> [ { address, port, iqn } ] the array's
#                                         iSCSI portals and their target names

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
# Options: system_id, svm, portgroup, srp, slo, target_ports, copy_rate.
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
sub target_portals { return undef; }
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
    return undef if $w =~ /^(?:IQN|EUI)\./; # an iSCSI name, not a WWPN
    $w =~ s/[^0-9A-F]//g;
    return length($w) == 16 ? $w : undef;
}

# iSCSI names (RFC 3720): iqn.yyyy-mm.<reversed domain>[:<anything>] or
# eui.<16 hex digits>; compared case-insensitively, kept in lower case.
sub norm_iqn {
    my ($n) = @_;
    $n = lc($n // '');
    $n =~ s/^\s+|\s+$//g;
    $n =~ s/,.*$//; # "<iqn>,t,0x1": target portal group suffix
    return $n if $n =~ /^iqn\.\d{4}-\d{2}\.[a-z0-9][a-z0-9.:-]*$/ && length($n) <= 223;
    return $n if $n =~ /^eui\.[0-9a-f]{16}$/;
    return undef;
}

# Node ports -> (\@wwpns, \@iqns), normalised, without duplicates.
sub split_ports {
    my ($ports) = @_;
    my (@w, @i, %seen);
    for my $p (@{$ports // []}) {
        if (defined(my $q = norm_iqn($p))) {
            push @i, $q if !$seen{$q}++;
        } elsif (defined(my $w = norm_wwpn($p))) {
            push @w, $w if !$seen{$w}++;
        }
    }
    return (\@w, \@i);
}

sub norm_port {
    my ($p) = @_;
    return norm_iqn($p) // norm_wwpn($p);
}

# --- iSCSI ---

sub supports_iscsi { return 0; }

sub check_iscsi {
    my ($self) = @_;
    die $self->description . ": iSCSI host registration is not supported yet by the pvesan driver\n"
        if !$self->supports_iscsi;
}

# Which kinds of node ports the array is set to use (array setting
# 'protocol': fc, iscsi or both).
sub protocols {
    my ($self) = @_;
    my $p = $self->{protocol} // 'fc';
    return $p eq 'both' ? [ 'fc', 'iscsi' ] : [ $p ];
}

# Array setting check when an array is added or changed.
sub check_protocol {
    my ($class, $protocol) = @_;
    die "unknown protocol '$protocol' (fc, iscsi or both)\n" if $protocol !~ /^(?:fc|iscsi|both)$/;
    $class->check_iscsi if $protocol ne 'fc';
}

# --- snapshots ---

sub supports_snapshots { return 0; }

# Can one point-in-time snapshot cover several volumes?
sub supports_group_snapshots { return 0; }

# pvesan snapshot names: valid as a Pure suffix, an InfiniBox or PowerStore
# name part, and in an LVM VG name.
sub valid_snapshot_name {
    my ($class, $name) = @_;
    return defined($name) && $name =~ /^[A-Za-z][A-Za-z0-9-]{0,39}$/ && $name !~ /-$/;
}

sub not_supported {
    my ($self, $what) = @_;
    die $self->description . ": $what is not supported yet by the pvesan driver\n";
}

sub snapshot_create { $_[0]->not_supported('array snapshots') }
sub snapshots { $_[0]->not_supported('array snapshots') }
sub snapshot_delete { $_[0]->not_supported('array snapshots') }
sub snapshot_clone { $_[0]->not_supported('cloning array snapshots') }
sub snapshot_restore { $_[0]->not_supported('restoring array snapshots') }

# --- one array volume per VM disk (storage type fcsanvol) ---
#
# Optional; supports_disk_volumes() says whether a driver has them:
#
#   volumes_named($prefix)           -> [ volume ] whose name starts with $prefix
#   volume_by_name($name)            -> volume or undef
#   host_lun($vol_id, $hcname)       -> LUN number the host cluster sees it as
#   copy_volume($vol_id, $name)      -> volume: a new, independent, unmapped copy
#   rename_volume($vol_id, $name)

sub supports_disk_volumes { return 0; }

# --- replication to a second array (disaster recovery) ---
#
# Optional; supports_replication() says whether a driver has it. On the
# source array:
#
#   replication_partners()              -> [ { name, status, type } ] connected arrays
#   replication_enable(\@vol_ids, $partner, $interval_s, $retain_s) -> group
#                                          replicate the volumes as one consistent
#                                          group every $interval_s, keep replicas
#                                          on the partner for $retain_s
#   replication_disable(\@vol_ids, $partner)
#   replicate_now(\@vol_ids, $name)     take a snapshot set $name and send it now
#   replication_status(\@vol_ids)       -> { group, partners => [name], interval,
#                                            transfers => [ transfer ] } newest first
#
# On the partner (DR) array:
#
#   replicas()                          -> [ { id, source (array), group } ] incoming groups
#   replica_snapshots($replica_id)      -> [ { name, created, completed,
#                                            members => [ { id, volume } ] } ] oldest first;
#                                          only fully received ones; 'volume' is the
#                                          source volume's name
#   replica_clone($member, $name)       -> volume: new writable, unmapped copy
#
#   transfer = { name, started, completed, progress (0..1), bytes }

sub supports_replication { return 0; }

sub replication_partners { $_[0]->not_supported('replication') }
sub replication_enable { $_[0]->not_supported('replication') }
sub replication_disable { $_[0]->not_supported('replication') }
sub replicate_now { $_[0]->not_supported('replication') }
sub replication_status { $_[0]->not_supported('replication') }
sub replicas { $_[0]->not_supported('replication') }
sub replica_snapshots { $_[0]->not_supported('replication') }
sub replica_clone { my ($self, $m, $name) = @_; return $self->snapshot_clone($m, $name); }

sub volumes_named { $_[0]->not_supported('volumes per VM disk') }
sub volume_by_name { $_[0]->not_supported('volumes per VM disk') }
sub host_lun { $_[0]->not_supported('volumes per VM disk') }
sub copy_volume { $_[0]->not_supported('copying volumes') }
sub rename_volume { $_[0]->not_supported('renaming volumes') }

# Common argument checks for snapshot_create.
sub check_snapshot_args {
    my ($self, $vols, $name) = @_;
    die "invalid snapshot name '" . ($name // '') . "' (letters, digits and '-', starting with a letter)\n"
        if !$self->valid_snapshot_name($name);
    die "no volumes to snapshot\n" if !@$vols;
    die $self->description . ": a consistent snapshot of several volumes is not supported yet by the pvesan driver\n"
        if @$vols > 1 && !$self->supports_group_snapshots;
}

sub volume_name_for {
    my ($self, $storeid) = @_;
    return $self->valid_name($storeid) ? $storeid : $self->object_name_for($storeid);
}

# { node => [WWPN or IQN, ...] } -> { node => [\@wwpns, \@iqns] }. Every
# node needs at least one port; IQNs only for drivers with iSCSI support.
sub node_port_sets {
    my ($self, $node_ports) = @_;
    my %res;
    for my $node (sort keys %$node_ports) {
        my ($w, $i) = split_ports($node_ports->{$node});
        die "node '$node' has no FC ports or iSCSI initiator name\n" if !@$w && !@$i;
        $self->check_iscsi if @$i;
        $res{$node} = [ $w, $i ];
    }
    return \%res;
}

# Make sure every node's ports are in a host object and every such host is
# in host cluster $hcname. $node_ports = { node => [WWPN or IQN, ...] }.
# Existing hosts that already own a node's ports are reused; a host in a
# different host cluster or ports split across hosts are refused (that is
# an admin decision on the array).
sub ensure_hostcluster {
    my ($self, $hcname, $node_ports, $log) = @_;
    $log //= sub { print "$_[0]\n" };

    die "invalid host cluster name '$hcname' for this array\n" if !$self->valid_hostcluster_name($hcname);
    my $sets = $self->node_port_sets($node_ports);

    if (!grep { $_->{name} eq $hcname } @{$self->host_clusters()}) {
        $log->("creating host cluster '$hcname'");
        $self->create_hostcluster($hcname);
    }

    my $hosts = $self->hosts();
    my %owner;
    for my $h (@$hosts) { $owner{$_} = $h for @{$h->{wwpns} // []}, @{$h->{iqns} // []}; }
    my %taken = map { $_->{name} => 1 } @$hosts;

    my %result;
    for my $node (sort keys %$sets) {
        my ($ww, $wi) = @{$sets->{$node}};
        my @want = (@$ww, @$wi);

        my %owners = map { $_->{name} => $_ } grep { defined } map { $owner{$_} } @want;
        die "ports of node '$node' are split across array hosts " . join(', ', sort keys %owners)
            . " - merge them on the array first\n" if keys %owners > 1;

        my ($host) = values %owners;
        my $r = $result{$node} = { created => 0, added_ports => [], joined => 0 };

        if ($host) {
            my %have = map { $_ => 1 } @{$host->{wwpns} // []}, @{$host->{iqns} // []};
            my @mw = grep { !$have{$_} } @$ww;
            my @mi = grep { !$have{$_} } @$wi;
            if (@mw || @mi) {
                $log->("adding ports " . join(' ', @mw, @mi) . " to array host '$host->{name}' ($node)");
                $self->add_host_ports($host, \@mw, \@mi);
                $r->{added_ports} = [ @mw, @mi ];
            }
        } else {
            my $name = $self->valid_name($node) ? $node : $self->object_name_for($node);
            $name .= '-pve' if $taken{$name};
            die "array already has hosts '$node' and '$name'\n" if $taken{$name};
            $log->("creating array host '$name' for node $node with ports @want");
            $host = $self->create_host($name, $ww, $wi);
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
