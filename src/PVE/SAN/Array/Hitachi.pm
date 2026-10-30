package PVE::SAN::Array::Hitachi;

# Driver for Hitachi VSP (5000, E, F/G series) through the Configuration
# Manager REST API (embedded on the SVP/GUM, or the Configuration Manager
# server).
#
# Checked against the Hitachi driver in OpenStack Cinder
# (cinder/volume/drivers/hitachi/hbsd_rest_api.py, hbsd_rest.py) and the
# Configuration Manager REST API reference:
#   base       /ConfigurationManager/v1/objects/storages/<storageDeviceId>
#   session    POST sessions (Basic) -> token; then "Authorization: Session <token>"
#   async      headers Response-Job-Status: Completed; Response-Max-Wait;
#              job reply {jobId, status, state, affectedResources}
#   LDEV       POST ldevs {poolId, byteFormatCapacity: "<n>G", isParallelExecutionEnabled}
#              PUT  ldevs/<id> {label}; DELETE ldevs/<id>
#              PUT  ldevs/<id>/actions/expand/invoke {parameters: {additionalByteFormatCapacity}}
#              GET  ldevs/<id> -> naaId (only once an LU path exists)
#   host group POST host-groups {portId, hostGroupName, hostMode}
#   WWN        POST host-wwns {hostWwn, portId, hostGroupNumber}
#   LU path    POST luns {portId, hostGroupNumber, ldevId}; DELETE luns/<port>,<hg>,<lun>
#   iSCSI      GET ports/<id> {portType ISCSI, ipv4Address, tcpPort}; on an
#              iSCSI port the host group is an iSCSI target (its iscsiName)
#              and holds initiators: POST host-iscsis {iscsiName, portId,
#              hostGroupNumber} (hbsd_rest_iscsi.py)
#
# Mapping model: Hitachi host groups belong to one array port. For every
# configured target port the cluster gets a host group named after the
# Proxmox cluster (host mode LINUX/IRIX) holding every node's WWPNs (FC
# ports) or initiator names (iSCSI ports), and each LDEV gets an LU path on
# each of those host groups whose port type the array setting 'protocol'
# includes.

use strict;
use warnings;

use JSON::PP ();

use base qw(PVE::SAN::Array::Base);

sub description { return 'Hitachi VSP'; }
sub options { return { target_ports => 1, system_id => 0 }; }
sub max_name_length { return 32; }
sub wwid_after_map { return 1; }

sub valid_name {
    my ($class, $name) = @_;
    return defined($name) && length($name) <= 32 && $name =~ /^[A-Za-z0-9_.-]+$/;
}

sub valid_hostcluster_name {
    my ($class, $name) = @_;
    return defined($name) && $name =~ /^[A-Za-z0-9_.-]{1,64}$/;
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
        my $e = ref($d->{error}) eq 'HASH' ? $d->{error} : $d;
        my $m = join(' ', grep { defined && length } $e->{messageId}, $e->{message}, $e->{solution});
        return $m if length($m);
    }
    return short($content);
}

sub ports { return [ split(/\s*,\s*/, $_[0]->{target_ports}) ]; }

sub storage_id {
    my ($self) = @_;
    return $self->{system_id} if $self->{system_id};
    my $d = $self->json_call('GET', '/ConfigurationManager/v1/objects/storages', undef, undef,
        { Authorization => $self->basic_auth }, \&error_text, 'Hitachi');
    my @s = @{ref($d) eq 'HASH' ? ($d->{data} // []) : []};
    die "Hitachi: no storage system registered at $self->{address}\n" if !@s;
    die "Hitachi: several storage systems found - set system-id\n" if @s > 1;
    return $self->{system_id} = $s[0]->{storageDeviceId};
}

sub base { return '/ConfigurationManager/v1/objects/storages/' . $_[0]->storage_id; }

sub login {
    my ($self) = @_;
    my ($d) = $self->json_call('POST', $self->base . '/sessions', undef, {},
        { Authorization => $self->basic_auth }, \&error_text, 'Hitachi');
    $self->{token} = $d->{token} // die "Hitachi login: no session token\n";
}

# Non-GET calls wait for their job; returns the job (or the GET body).
sub call {
    my ($self, $method, $path, $query, $body) = @_;

    $self->login() if !$self->{token};
    my %h = (Authorization => "Session $self->{token}");
    if ($method ne 'GET') {
        $h{'Response-Job-Status'} = 'Completed;';
        $h{'Response-Max-Wait'} = '300';
    }
    my $url = $self->base . $path . PVE::SAN::Array::Base::query_string($query);
    my ($code, $content) = $self->request($method, $url, \%h, $body);
    if ($code == 401) {
        $self->login();
        $h{Authorization} = "Session $self->{token}";
        ($code, $content) = $self->request($method, $url, \%h, $body);
    }
    die "Hitachi $method $path failed (HTTP $code): " . error_text($content) . "\n" if $code < 200 || $code >= 300;
    my $d = PVE::SAN::Array::Base::decode($content);
    if ($method ne 'GET' && ref($d) eq 'HASH' && defined($d->{state})) {
        die "Hitachi $method $path: job $d->{jobId} " . lc($d->{status} // '') . ", state $d->{state}: "
            . error_text($content) . "\n" if $d->{state} ne 'Succeeded';
    }
    return $d;
}

sub data {
    my ($self, $path, $query) = @_;
    my $d = $self->call('GET', $path, $query);
    return ref($d) eq 'HASH' ? ($d->{data} // []) : [];
}

# last path element of the job's first affected resource
sub affected_id {
    my ($job) = @_;
    my ($r) = @{ref($job) eq 'HASH' ? ($job->{affectedResources} // []) : []};
    return defined($r) && $r =~ m|/([^/]+)$| ? $1 : undef;
}

sub system_info {
    my ($self) = @_;
    my $s = $self->call('GET', '') // {};
    return {
        name => $s->{serialNumber} ? "VSP $s->{serialNumber}" : $self->storage_id,
        product => 'Hitachi ' . ($s->{model} // 'VSP'),
        code_level => $s->{dkcMicroVersion},
        id => $self->storage_id,
    };
}

sub pools {
    my ($self) = @_;
    my $mb = 1024 * 1024;
    return [ map {
        { id => $_->{poolId}, name => $_->{poolName}, status => $_->{poolStatus},
          capacity => defined($_->{totalPoolCapacity}) ? $_->{totalPoolCapacity} * $mb : undef,
          free => defined($_->{availableVolumeCapacity}) ? $_->{availableVolumeCapacity} * $mb : undef }
    } @{$self->data('/pools')} ];
}

# --- cluster registration: one host group per target port ---

sub host_group {
    my ($self, $port, $name) = @_;
    my ($g) = grep { ($_->{hostGroupName} // '') eq $name } @{$self->data('/host-groups', { portId => $port })};
    return $g;
}

sub ensure_hostcluster {
    my ($self, $hcname, $node_ports, $log) = @_;
    $log //= sub { print "$_[0]\n" };

    die "invalid host group name '$hcname'\n" if !$self->valid_hostcluster_name($hcname);
    my (%wwn, %iqn); # port name => node
    my $sets = $self->node_port_sets($node_ports);
    for my $node (sort keys %$sets) {
        $wwn{$_} = $node for @{$sets->{$node}->[0]};
        $iqn{$_} = $node for @{$sets->{$node}->[1]};
    }
    my %result = map { $_ => { host => "host group $hcname", created => 0, added_ports => [], joined => 0 } } keys %$sets;

    my $used = 0;
    for my $port (@{$self->ports}) {
        my $iscsi = $self->port_is_iscsi($port);
        my ($want, $what) = $iscsi ? (\%iqn, 'iSCSI name') : (\%wwn, 'WWN');
        if (!%$want) {
            $log->("skipping " . ($iscsi ? 'iSCSI' : 'FC') . " port $port: no node ports of that kind");
            next;
        }
        $used++;
        my $g = $self->host_group($port, $hcname);
        if (!$g) {
            $log->("creating host group '$hcname' on port $port (host mode LINUX/IRIX)");
            $self->call('POST', '/host-groups', undef, { portId => $port, hostGroupName => $hcname, hostMode => 'LINUX/IRIX' });
            $g = $self->host_group($port, $hcname) // die "Hitachi: host group '$hcname' on $port not found after creation\n";
        }
        my $q = { portId => $port, hostGroupNumber => $g->{hostGroupNumber} };
        my %have = $iscsi
            ? map { ((PVE::SAN::Array::Base::norm_iqn($_->{iscsiName}) // '') => 1) } @{$self->data('/host-iscsis', $q)}
            : map { ((PVE::SAN::Array::Base::norm_wwpn($_->{hostWwn}) // '') => 1) } @{$self->data('/host-wwns', $q)};
        for my $w (sort grep { !$have{$_} } keys %$want) {
            $log->("registering $what $w ($want->{$w}) in $port host group '$hcname'");
            if ($iscsi) {
                $self->call('POST', '/host-iscsis', undef,
                    { iscsiName => $w, portId => $port, hostGroupNumber => $g->{hostGroupNumber} + 0 });
            } else {
                $self->call('POST', '/host-wwns', undef,
                    { hostWwn => lc($w), portId => $port, hostGroupNumber => $g->{hostGroupNumber} + 0 });
            }
            push @{$result{$want->{$w}}->{added_ports}}, "$port:$w";
        }
    }
    die "Hitachi: none of the target ports (" . join(',', @{$self->ports}) . ") matches the nodes' "
        . (%iqn ? (%wwn ? 'FC or iSCSI' : 'iSCSI') : 'FC') . " ports\n" if !$used;
    return \%result;
}

# GET ports/<id>: portType FIBRE, FCoE or ISCSI; ipv4Address and tcpPort
# for iSCSI (Cinder hbsd_rest_iscsi.py, hbsd_rest_fc.py).
sub port_info {
    my ($self, $port) = @_;
    return $self->{port_info}->{$port} //= ($self->call('GET', "/ports/$port") // {});
}

sub port_is_iscsi {
    my ($self, $port) = @_;
    return 0 if $self->protocols->[0] eq 'fc' && @{$self->protocols} == 1; # FC only: every port is FC
    return uc($self->port_info($port)->{portType} // '') eq 'ISCSI' ? 1 : 0;
}

sub supports_iscsi { return 1; }

# Each iSCSI target port's address; the target is the cluster's host group
# on that port (its iscsiName).
sub target_portals {
    my ($self) = @_;
    my $hc = $self->{hostcluster} // 'pve';
    my @res;
    for my $port (grep { $self->port_is_iscsi($_) } @{$self->ports}) {
        my $info = $self->port_info($port);
        next if !$info->{ipv4Address};
        my $g = $self->host_group($port, $hc);
        push @res, { address => $info->{ipv4Address}, port => ($info->{tcpPort} // 3260) + 0,
            iqn => $g ? PVE::SAN::Array::Base::norm_iqn($g->{iscsiName}) : undef };
    }
    return \@res;
}

# --- LDEVs (id = LDEV number) ---

sub volume_from {
    my ($l) = @_;
    return {
        id => $l->{ldevId},
        name => $l->{label} // "ldev$l->{ldevId}",
        pool => $l->{poolId},
        capacity => defined($l->{blockCapacity}) ? $l->{blockCapacity} * 512 : undef,
        uid => $l->{naaId},
        wwid => PVE::SAN::Array::Base::naa_to_wwid($l->{naaId}),
    };
}

sub volume {
    my ($self, $id) = @_;
    return volume_from($self->call('GET', "/ldevs/$id") // {});
}

sub find_volume_by_wwid {
    my ($self, $wwid) = @_;
    for my $l (@{$self->data('/ldevs', { ldevOption => 'dpVolume', count => 16384 })}) {
        my $v = $self->volume($l->{ldevId});
        return $v if ($v->{wwid} // '') eq $wwid;
    }
    return undef;
}

sub create_volume {
    my ($self, %p) = @_;

    die "invalid LDEV label '$p{name}' (32 chars)\n" if !$self->valid_name($p{name});
    die "size must be a whole number of GiB\n" if $p{size_gib} !~ /^\d+$/ || $p{size_gib} < 1;
    my ($pool) = grep { $_->{name} eq $p{pool} } @{$self->pools()};
    die "Hitachi pool '$p{pool}' not found\n" if !$pool;
    print "note: Hitachi DP volumes are thin provisioned\n" if defined($p{thin}) && !$p{thin};

    my $job = $self->call('POST', '/ldevs', undef, {
        poolId => $pool->{id} + 0,
        byteFormatCapacity => "$p{size_gib}G",
        isParallelExecutionEnabled => JSON::PP::true,
    });
    my $id = affected_id($job) // die "Hitachi: no LDEV id in job result\n";
    $self->call('PUT', "/ldevs/$id", undef, { label => $p{name} });
    return $self->volume($id);
}

sub map_to_hostcluster {
    my ($self, $id, $hcname) = @_;
    my %use = map { ($_ => 1) } @{$self->protocols};
    for my $port (grep { $use{$self->port_is_iscsi($_) ? 'iscsi' : 'fc'} } @{$self->ports}) {
        my $g = $self->host_group($port, $hcname) // die "Hitachi: host group '$hcname' missing on $port\n";
        $self->call('POST', '/luns', undef, { portId => $port, hostGroupNumber => $g->{hostGroupNumber} + 0, ldevId => $id + 0 });
    }
}

sub unmap_from_hostcluster {
    my ($self, $id, $hcname) = @_;
    for my $port (@{$self->ports}) {
        my $g = $self->host_group($port, $hcname) // next;
        for my $l (grep { ($_->{ldevId} // -1) == $id }
            @{$self->data('/luns', { portId => $port, hostGroupNumber => $g->{hostGroupNumber} })}) {
            my $lun_id = $l->{lunId} // "$port,$g->{hostGroupNumber},$l->{lun}";
            $self->call('DELETE', "/luns/$lun_id", undef, undef);
        }
    }
}

sub expand_volume {
    my ($self, $id, $add_bytes) = @_;
    die "expansion must be a positive multiple of 512 bytes\n" if $add_bytes <= 0 || $add_bytes % 512;
    my $param = $add_bytes % $PVE::SAN::Array::Base::GIB == 0
        ? { additionalByteFormatCapacity => ($add_bytes / $PVE::SAN::Array::Base::GIB) . 'G' }
        : { additionalBlockCapacity => $add_bytes / 512 };
    $self->call('PUT', "/ldevs/$id/actions/expand/invoke", undef, { parameters => $param });
}

sub delete_volume {
    my ($self, $id) = @_;
    $self->call('DELETE', "/ldevs/$id", undef, undef);
}

1;
