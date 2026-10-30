package PVE::SAN::Array::PowerMax;

# Driver for Dell PowerMax / VMAX All Flash through Unisphere for PowerMax
# REST (port 8443).
#
# Checked against Dell's PyU4V (PyU4V/provisioning.py). All objects live
# under /univmax/restapi/<version>/sloprovisioning/symmetrix/<symid>/:
#   host        POST host {hostId, initiatorId[]}
#               (initiators are FC WWPNs or iSCSI names)
#               PUT  host/<id> {editHostActionParam: {addInitiatorParam: {initiator[]}}}
#   host group  POST hostgroup {hostGroupId, hostId[]}
#               PUT  hostgroup/<id> {editHostGroupActionParam: {addHostParam: {host[]}}}
#   SG          POST storagegroup {storageGroupId, srpId, emulation, sloBasedStorageGroupParam}
#   MV          POST maskingview {maskingViewId, portGroupSelection,
#                    hostOrHostGroupSelection, storageGroupSelection}
#   new volume  PUT  storagegroup/<sg> {editStorageGroupActionParam:
#                    {expandStorageGroupParam: {addVolumeParam: {...volumeIdentifier}}}}
#   unmap       PUT  storagegroup/<sg> {...removeVolumeParam: {volumeId[]}}
#   grow        PUT  volume/<dev> {editVolumeActionParam: {expandVolumeParam: {volumeAttribute}}}
#   delete      PUT  volume/<dev> {...freeVolumeParam: {free_volume: true}}, then DELETE volume/<dev>
#   iSCSI       GET portgroup/<pg> symmetrixPortKey; GET system/symmetrix/<id>/director/
#               <dir>/port/<port> symmetrixPort {ip_addresses, identifier} (system.py)
#
# Mapping model: the Proxmox cluster gets a host group, a storage group
# <hc>_SG (in the configured SRP / service level) and a masking view <hc>_MV
# joining them with the configured port group. A volume is presented by
# being in <hc>_SG, so new volumes are created straight into it.

use strict;
use warnings;

use JSON::PP ();

use base qw(PVE::SAN::Array::Base);

sub description { return 'Dell PowerMax / VMAX'; }
sub default_port { return 8443; }
sub max_name_length { return 64; }
sub options { return { system_id => 1, portgroup => 1, srp => 0, slo => 0 }; }

sub valid_name {
    my ($class, $name) = @_;
    return defined($name) && length($name) <= 64 && $name =~ /^[A-Za-z0-9_-]+$/;
}

sub object_name_for {
    my ($class, $name) = @_;
    $name =~ s/[^A-Za-z0-9_-]/_/g;
    return substr($name, 0, 60);
}

*short = \&PVE::SAN::Array::Base::short;

sub error_text {
    my ($content) = @_;
    my $d = PVE::SAN::Array::Base::decode($content);
    return $d->{message} if ref($d) eq 'HASH' && $d->{message};
    return short($content);
}

sub api_version {
    my ($self) = @_;
    return $self->{api_version} if $self->{api_version};
    my $d = eval {
        $self->json_call('GET', '/univmax/restapi/version', undef, undef,
            { Authorization => $self->basic_auth }, \&error_text, 'Unisphere');
    } // {};
    my $v = $d->{api_version} // (($d->{version} // '') =~ /^[VT]?(\d+)\.(\d)/ ? "$1$2" : undef);
    return $self->{api_version} = $v // '100';
}

sub sg { return "$_[1]_SG"; }
sub mv { return "$_[1]_MV"; }

sub call {
    my ($self, $method, $path, $query, $body) = @_;
    my $base = '/univmax/restapi/' . $self->api_version . "/sloprovisioning/symmetrix/$self->{system_id}";
    return $self->json_call($method, "$base$path", $query, $body,
        { Authorization => $self->basic_auth }, \&error_text, 'Unisphere');
}

sub system_info {
    my ($self) = @_;
    my $s = $self->json_call('GET', '/univmax/restapi/' . $self->api_version . "/system/symmetrix/$self->{system_id}",
        undef, undef, { Authorization => $self->basic_auth }, \&error_text, 'Unisphere') // {};
    return {
        name => $s->{symmetrixId} // $self->{system_id},
        product => 'Dell ' . ($s->{model} // 'PowerMax'),
        code_level => $s->{ucode},
        id => $s->{symmetrixId},
    };
}

sub pools {
    my ($self) = @_;
    my $ids = ($self->call('GET', '/srp') // {})->{srpId} // [];
    return [ map {
        my $s = $self->call('GET', "/srp/$_") // {};
        my $cap = $s->{srp_capacity} // {};
        my $tb = 1024 ** 4;
        {
            name => $_,
            status => 'online',
            capacity => defined($cap->{usable_total_tb}) ? int($cap->{usable_total_tb} * $tb) : undef,
            free => defined($cap->{usable_total_tb}) && defined($cap->{usable_used_tb})
                ? int(($cap->{usable_total_tb} - $cap->{usable_used_tb}) * $tb) : undef,
        }
    } @$ids ];
}

sub host_clusters {
    my ($self) = @_;
    return [ map { { id => $_, name => $_ } } @{($self->call('GET', '/hostgroup') // {})->{hostGroupId} // []} ];
}

sub hosts {
    my ($self) = @_;
    my @res;
    for my $id (@{($self->call('GET', '/host') // {})->{hostId} // []}) {
        my $h = $self->call('GET', "/host/$id") // {};
        my @hg = @{$h->{hostGroup} // []};
        my @init = @{$h->{initiator} // []};
        push @res, {
            id => $id,
            name => $id,
            hostcluster => $hg[0],
            wwpns => [ sort grep { defined } map { PVE::SAN::Array::Base::norm_wwpn($_) } @init ],
            iqns => [ sort grep { defined } map { PVE::SAN::Array::Base::norm_iqn($_) } @init ],
        };
    }
    return \@res;
}

sub create_hostcluster {
    my ($self, $name) = @_;
    $self->{pending_group}->{$name} = 1; # created with its first host
}

# initiatorId takes WWPNs or iSCSI names alike (PyU4V create_host; Cinder's
# PowerMax masking.py find_initiator_names)
sub create_host {
    my ($self, $name, $wwpns, $iqns) = @_;
    $iqns //= [];
    $self->call('POST', '/host', undef, { hostId => $name, initiatorId => [ (map { lc } @$wwpns), @$iqns ] });
    return { id => $name, name => $name, hostcluster => undef, wwpns => [@$wwpns], iqns => [@$iqns] };
}

sub add_host_ports {
    my ($self, $host, $wwpns, $iqns) = @_;
    $self->call('PUT', "/host/$host->{name}", undef,
        { editHostActionParam => { addInitiatorParam => { initiator => [ (map { lc } @$wwpns), @{$iqns // []} ] } } });
}

sub add_to_hostcluster {
    my ($self, $hcname, $host) = @_;
    if (grep { $_->{name} eq $hcname } @{$self->host_clusters()}) {
        $self->call('PUT', "/hostgroup/$hcname", undef,
            { editHostGroupActionParam => { addHostParam => { host => [ $host->{name} ] } } });
    } else {
        $self->call('POST', '/hostgroup', undef, { hostGroupId => $hcname, hostId => [ $host->{name} ] });
    }
}

sub supports_iscsi { return 1; }

# The iSCSI ports of the configured port group: PyU4V get_port_group
# (symmetrixPortKey [{directorId, portId}]) and get_iscsi_ip_address_and_iqn
# (GET system/symmetrix/<id>/director/<dir>/port/<port> -> symmetrixPort
# {ip_addresses, identifier = target IQN}). Cinder's PowerMax driver uses
# port 3260.
sub target_portals {
    my ($self) = @_;
    my $pg = $self->call('GET', "/portgroup/$self->{portgroup}") // {};
    my @res;
    for my $k (@{$pg->{symmetrixPortKey} // []}) {
        my ($dir, $port) = ($k->{directorId}, $k->{portId});
        next if !defined($dir) || !defined($port);
        ($dir, $port) = split(/:/, $port, 2) if $port =~ /:/; # "SE-1E:000"
        my $d = $self->json_call('GET', '/univmax/restapi/' . $self->api_version
            . "/system/symmetrix/$self->{system_id}/director/" . PVE::SAN::Array::Base::escape($dir)
            . '/port/' . PVE::SAN::Array::Base::escape($port),
            undef, undef, { Authorization => $self->basic_auth }, \&error_text, 'Unisphere') // {};
        my $sp = $d->{symmetrixPort} // {};
        my $iqn = PVE::SAN::Array::Base::norm_iqn($sp->{identifier}) // next; # FC port: a WWN
        push @res, map { { address => $_, port => 3260, iqn => $iqn } } @{$sp->{ip_addresses} // []};
    }
    return \@res;
}

# Host group as usual, then the storage group and masking view that
# present the cluster's volumes through the configured port group.
sub ensure_hostcluster {
    my ($self, $hcname, $node_wwpns, $log) = @_;
    $log //= sub { print "$_[0]\n" };

    my $res = $self->SUPER::ensure_hostcluster($hcname, $node_wwpns, $log);

    my $sg = $self->sg($hcname);
    my $sgs = ($self->call('GET', '/storagegroup') // {})->{storageGroupId} // [];
    if (!grep { $_ eq $sg } @$sgs) {
        $log->("creating storage group '$sg' in SRP " . ($self->{srp} // 'SRP_1'));
        $self->call('POST', '/storagegroup', undef, {
            storageGroupId => $sg,
            srpId => $self->{srp} // 'SRP_1',
            emulation => 'FBA',
            sloBasedStorageGroupParam => [ { sloId => $self->{slo} // 'None', workloadSelection => 'None' } ],
        });
    }

    my $mv = $self->mv($hcname);
    my $mvs = ($self->call('GET', '/maskingview') // {})->{maskingViewId} // [];
    if (!grep { $_ eq $mv } @$mvs) {
        $log->("creating masking view '$mv' (host group '$hcname', port group '$self->{portgroup}', storage group '$sg')");
        $self->call('POST', '/maskingview', undef, {
            maskingViewId => $mv,
            portGroupSelection => { useExistingPortGroupParam => { portGroupId => $self->{portgroup} } },
            hostOrHostGroupSelection => { useExistingHostGroupParam => { hostGroupId => $hcname } },
            storageGroupSelection => { useExistingStorageGroupParam => { storageGroupId => $sg } },
        });
    }
    return $res;
}

sub volume_from {
    my ($v) = @_;
    my $wwn = $v->{effective_wwn} // $v->{wwn};
    return {
        id => $v->{volumeId},
        name => $v->{volume_identifier} // $v->{volumeId},
        capacity => defined($v->{cap_mb}) ? int($v->{cap_mb} * 1024 * 1024)
            : defined($v->{cap_gb}) ? int($v->{cap_gb} * $PVE::SAN::Array::Base::GIB) : undef,
        uid => $wwn,
        wwid => PVE::SAN::Array::Base::naa_to_wwid($wwn),
        storage_groups => $v->{storageGroupId} // [],
    };
}

sub volume {
    my ($self, $dev) = @_;
    return volume_from($self->call('GET', "/volume/$dev") // {});
}

sub list_volume_ids {
    my ($self, $query) = @_;
    my $r = $self->call('GET', '/volume', $query) // {};
    my @ids;
    for my $list (@{$r->{resultList}->{result} // []}) { push @ids, $list->{volumeId} if $list->{volumeId}; }
    return \@ids;
}

sub find_volume_by_wwid {
    my ($self, $wwid) = @_;
    return undef if $wwid !~ /^3([0-9a-f]{32})$/;
    my ($id) = @{$self->list_volume_ids({ wwn => uc($1) })};
    return $id ? $self->volume($id) : undef;
}

# Created straight into the cluster's storage group = presented at once.
# 'pool' must be the SRP of that storage group.
sub create_volume {
    my ($self, %p) = @_;

    die "invalid volume name '$p{name}'\n" if !$self->valid_name($p{name});
    die "size must be a whole number of GiB\n" if $p{size_gib} !~ /^\d+$/ || $p{size_gib} < 1;
    my $srp = $self->{srp} // 'SRP_1';
    die "PowerMax volumes are created in the cluster storage group's SRP '$srp', not '$p{pool}'\n"
        if defined($p{pool}) && length($p{pool}) && $p{pool} ne $srp;
    my $hc = $self->{hostcluster} // die "PowerMax: host cluster name unknown\n";

    $self->call('PUT', '/storagegroup/' . $self->sg($hc), undef, {
        editStorageGroupActionParam => { expandStorageGroupParam => { addVolumeParam => {
            emulation => 'FBA',
            create_new_volumes => JSON::PP::true,
            volumeAttributes => [ {
                num_of_vols => 1,
                volume_size => "" . ($p{size_gib} * 1024),
                capacityUnit => 'MB',
                volumeIdentifier => { identifier_name => $p{name}, volumeIdentifierChoice => 'identifier_name' },
            } ],
        } } },
    });

    my ($id) = @{$self->list_volume_ids({ storageGroupId => $self->sg($hc), volume_identifier => $p{name} })};
    die "PowerMax: new volume '$p{name}' not found in " . $self->sg($hc) . "\n" if !$id;
    return $self->volume($id);
}

sub map_to_hostcluster {
    my ($self, $dev, $hcname) = @_;
    my $sg = $self->sg($hcname);
    return if grep { $_ eq $sg } @{$self->volume($dev)->{storage_groups}};
    $self->call('PUT', "/storagegroup/$sg", undef, { editStorageGroupActionParam => {
        expandStorageGroupParam => { addSpecificVolumeParam => { volumeId => [ $dev ] } } } });
}

sub unmap_from_hostcluster {
    my ($self, $dev, $hcname) = @_;
    my $sg = $self->sg($hcname);
    return if !grep { $_ eq $sg } @{$self->volume($dev)->{storage_groups}};
    $self->call('PUT', "/storagegroup/$sg", undef,
        { editStorageGroupActionParam => { removeVolumeParam => { volumeId => [ $dev ] } } });
}

sub expand_volume {
    my ($self, $dev, $add_bytes) = @_;
    die "expansion must be a positive multiple of 1 MiB on PowerMax\n" if $add_bytes <= 0 || $add_bytes % (1024 * 1024);
    my $cur = $self->volume($dev);
    my $new_mb = int(($cur->{capacity} + $add_bytes) / (1024 * 1024));
    $self->call('PUT', "/volume/$dev", undef, { editVolumeActionParam => { expandVolumeParam => {
        volumeAttribute => { volume_size => "$new_mb", capacityUnit => 'MB' } } } });
}

sub delete_volume {
    my ($self, $dev) = @_;
    $self->call('PUT', "/volume/$dev", undef,
        { editVolumeActionParam => { freeVolumeParam => { free_volume => 'true' } } }); # as PyU4V sends it
    $self->call('DELETE', "/volume/$dev", undef, undef);
}

1;
