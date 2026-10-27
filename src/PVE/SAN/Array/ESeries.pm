package PVE::SAN::Array::ESeries;

# Driver for NetApp E-Series / EF-Series (SANtricity OS 11.50+) through the
# embedded SANtricity Web Services REST API (port 8443, /devmgr/v2).
#
# Checked against NetApp's SANtricity Ansible collection
# (netappeseries/santricity: na_santricity_volume, _host, _hostgroup,
# _lun_mapping). All under storage-systems/<ssid>/ (ssid 1 = embedded):
#   volume      POST volumes {name, poolId, sizeUnit: bytes, size, segSize}
#               POST volumes/<id>/expand {sizeUnit, expansionSize = new total}
#               DELETE volumes/<id>
#   host        POST hosts {name, hostType: {index}, ports: [{type, port, label}]}
#               POST hosts/<id> {ports: [...]}           (add ports)
#               POST hosts/<id>/move {group: <clusterRef>} (join a group)
#   host group  POST host-groups {name, hosts: []}; id = clusterRef
#   mapping     POST volume-mappings {mappableObjectId, targetId}
#               DELETE volume-mappings/<lunMappingRef>
#
# Thick volumes only: E-Series thin volumes need DDP repository sizing,
# which is out of scope.

use strict;
use warnings;

use JSON::PP ();

use base qw(PVE::SAN::Array::Base);

my $NO_GROUP = '0000000000000000000000000000000000000000';

sub description { return 'NetApp E-Series'; }
sub default_port { return 8443; }
sub max_name_length { return 30; }
sub options { return { system_id => 0 }; }

sub valid_name {
    my ($class, $name) = @_;
    return defined($name) && length($name) <= 30 && $name =~ /^[A-Za-z0-9_-]+$/;
}

sub object_name_for {
    my ($class, $name) = @_;
    $name =~ s/[^A-Za-z0-9_-]/_/g;
    return substr($name, 0, 26);
}

*short = \&PVE::SAN::Array::Base::short;

sub error_text {
    my ($content) = @_;
    my $d = PVE::SAN::Array::Base::decode($content);
    if (ref($d) eq 'HASH') {
        my $m = $d->{errorMessage} // $d->{localizedMessage};
        return join(': ', grep { defined && length } $d->{retcode}, $m) if $m;
    }
    return short($content);
}

sub ssid { return $_[0]->{system_id} // '1'; }

sub call {
    my ($self, $method, $path, $query, $body) = @_;
    my $base = '/devmgr/v2/storage-systems/' . $self->ssid;
    return $self->json_call($method, "$base$path", $query, $body,
        { Authorization => $self->basic_auth }, \&error_text, 'SANtricity');
}

sub system_info {
    my ($self) = @_;
    my $s = $self->call('GET', '') // {};
    return { name => $s->{name}, product => 'NetApp E-Series ' . ($s->{model} // ''), code_level => $s->{fwVersion}, id => $s->{wwn} };
}

sub num {
    my ($v) = @_;
    return defined($v) && $v =~ /^\d+$/ ? $v + 0 : undef;
}

sub pools {
    my ($self) = @_;
    return [ map {
        { id => $_->{id}, name => $_->{name}, status => $_->{raidStatus} // 'optimal',
          capacity => num($_->{totalRaidedSpace}), free => num($_->{freeSpace}) }
    } @{$self->call('GET', '/storage-pools') // []} ];
}

sub host_clusters {
    my ($self) = @_;
    return [ map { { id => $_->{clusterRef} // $_->{id}, name => $_->{name} } } @{$self->call('GET', '/host-groups') // []} ];
}

sub hosts {
    my ($self) = @_;
    my %group = map { $_->{id} => $_->{name} } @{$self->host_clusters()};
    return [ map {
        my $h = $_;
        my $ref = $h->{clusterRef} // $NO_GROUP;
        {
            id => $h->{id} // $h->{hostRef},
            name => $h->{name} // $h->{label},
            hostcluster => $ref ne $NO_GROUP ? $group{$ref} : undef,
            wwpns => [ sort grep { defined } map { PVE::SAN::Array::Base::norm_wwpn($_->{address}) }
                grep { lc($_->{type} // '') eq 'fc' } @{$h->{hostSidePorts} // []} ],
        }
    } @{$self->call('GET', '/hosts') // []} ];
}

# Linux with DM-MP (ALUA) host type index from the array's own list.
sub linux_host_type {
    my ($self) = @_;
    return $self->{host_type} if defined($self->{host_type});
    my @types = @{(eval { $self->call('GET', '/host-types') }) // []};
    my ($t) = grep { ($_->{name} // '') =~ /linux.*dm-?mp/i || ($_->{code} // '') eq 'LnxDHP' } @types;
    ($t) = grep { ($_->{name} // '') =~ /^linux/i } @types if !$t;
    return $self->{host_type} = $t ? $t->{index} : 28; # 28 = Linux DM-MP on current firmware
}

sub port_entries {
    my ($name, $wwpns, $start) = @_;
    my $i = $start // 0;
    return [ map { { type => 'fc', port => lc($_), label => substr("$name-p" . $i++, 0, 30) } } @$wwpns ];
}

sub create_hostcluster {
    my ($self, $name) = @_;
    $self->call('POST', '/host-groups', undef, { name => $name, hosts => [] });
}

sub create_host {
    my ($self, $name, $wwpns) = @_;
    my $h = $self->call('POST', '/hosts', undef,
        { name => $name, hostType => { index => $self->linux_host_type }, ports => port_entries($name, $wwpns) }) // {};
    return { id => $h->{id} // $h->{hostRef}, name => $name, hostcluster => undef, wwpns => [@$wwpns] };
}

sub add_host_ports {
    my ($self, $host, $wwpns) = @_;
    $self->call('POST', "/hosts/$host->{id}", undef,
        { ports => port_entries($host->{name}, $wwpns, scalar(@{$host->{wwpns} // []})) });
}

sub group_ref {
    my ($self, $name) = @_;
    my ($g) = grep { $_->{name} eq $name } @{$self->host_clusters()};
    return $g ? $g->{id} : undef;
}

sub add_to_hostcluster {
    my ($self, $hcname, $host) = @_;
    my $ref = $self->group_ref($hcname) // die "E-Series host group '$hcname' not found\n";
    $self->call('POST', "/hosts/$host->{id}/move", undef, { group => $ref });
}

sub volume_from {
    my ($v) = @_;
    my $wwn = $v->{wwn} // $v->{worldWideName};
    return {
        id => $v->{id} // $v->{volumeRef},
        name => $v->{name} // $v->{label},
        capacity => num($v->{capacity}) // num($v->{totalSizeInBytes}),
        uid => $wwn,
        wwid => PVE::SAN::Array::Base::naa_to_wwid($wwn),
    };
}

sub volume {
    my ($self, $id) = @_;
    return volume_from($self->call('GET', "/volumes/$id") // {});
}

sub find_volume_by_wwid {
    my ($self, $wwid) = @_;
    for my $v (@{$self->call('GET', '/volumes') // []}) {
        my $vol = volume_from($v);
        return $vol if ($vol->{wwid} // '') eq $wwid;
    }
    return undef;
}

sub create_volume {
    my ($self, %p) = @_;

    die "invalid E-Series volume name '$p{name}' (30 chars, letters, digits, '_', '-')\n" if !$self->valid_name($p{name});
    die "size must be a whole number of GiB\n" if $p{size_gib} !~ /^\d+$/ || $p{size_gib} < 1;
    print "note: thick volume - E-Series thin volumes are not supported by pvesan\n" if $p{thin};

    my ($pool) = grep { $_->{name} eq $p{pool} } @{$self->pools()};
    die "E-Series pool '$p{pool}' not found\n" if !$pool;
    my $v = $self->call('POST', '/volumes', undef, {
        name => $p{name},
        poolId => $pool->{id},
        sizeUnit => 'bytes',
        size => $p{size_gib} * $PVE::SAN::Array::Base::GIB,
        segSize => 128,
        dataAssuranceEnabled => JSON::PP::false,
    });
    return volume_from($v // {});
}

sub map_to_hostcluster {
    my ($self, $vol, $hcname) = @_;
    my $ref = $self->group_ref($hcname) // die "E-Series host group '$hcname' not found\n";
    $self->call('POST', '/volume-mappings', undef, { mappableObjectId => $vol, targetId => $ref });
}

sub unmap_from_hostcluster {
    my ($self, $vol, $hcname) = @_;
    my $ref = $self->group_ref($hcname) // die "E-Series host group '$hcname' not found\n";
    my @maps = grep { ($_->{volumeRef} // '') eq $vol && ($_->{mapRef} // '') eq $ref }
        @{$self->call('GET', '/volume-mappings') // []};
    for my $m (@maps) {
        $self->call('DELETE', '/volume-mappings/' . ($m->{lunMappingRef} // $m->{id}), undef, undef);
    }
}

# expansionSize is the new total size (as the SANtricity collection uses it)
sub expand_volume {
    my ($self, $vol, $add_bytes) = @_;
    die "expansion must be a positive multiple of 512 bytes\n" if $add_bytes <= 0 || $add_bytes % 512;
    my $cur = $self->volume($vol);
    $self->call('POST', "/volumes/$vol/expand", undef, { sizeUnit => 'bytes', expansionSize => $cur->{capacity} + $add_bytes });
}

sub delete_volume {
    my ($self, $vol) = @_;
    $self->call('DELETE', "/volumes/$vol", undef, undef);
}

1;
