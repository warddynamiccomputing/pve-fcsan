package PVE::SAN::Array::PowerStore;

# Driver for Dell PowerStore (PowerStoreOS 2+) through its REST API.
#
# Checked against Dell's PyPowerStore (PyPowerStore/client.py,
# provisioning.py, utils/constants.py):
#   login         GET  /api/rest/login_session (Basic) -> DELL-EMC-TOKEN header
#                 + auth_cookie cookie, both sent on every later request
#   volume        POST /volume {name, size}; GET /volume/<id>?select=...wwn
#                 PATCH /volume/<id> {size}; DELETE /volume/<id>
#   map / unmap   POST /volume/<id>/attach | detach {host_group_id}
#   host          POST /host {name, os_type, initiators}; PATCH {add_initiators}
#                 fields: host_group_id, host_initiators
#                 initiators: [{port_name, port_type: FC | iSCSI}]
#   iSCSI portals GET /ip_pool_address?purposes=cs.{Storage_Iscsi_Target}
#                 &select=address,ip_port(target_iqn) (Cinder's PowerStore
#                 driver, dell_emc/powerstore/client.py and adapter.py)
#   host group    POST /host_group {name, host_ids}; PATCH {add_host_ids}
#   snapshots     POST /volume/<id>/snapshot {name}; list GET /volume with
#                 protection_data->>source_id=eq.<id> and type=eq.Snapshot
#                 (protection.py); DELETE /volume/<snap id>
#   clone         POST /volume/<id>/clone {name} -> {id}
#   restore       POST /volume/<id>/restore {from_snap_id, create_backup_snap}
#
# PowerStore volumes are always thin; the appliance is one capacity pool.

use strict;
use warnings;

use JSON::PP;

use base qw(PVE::SAN::Array::Base);

sub description { return 'Dell PowerStore'; }
sub max_name_length { return 128; }

sub valid_name {
    my ($class, $name) = @_;
    return defined($name) && length($name) <= 128 && $name =~ /^[A-Za-z0-9_.-]+$/;
}

*short = \&PVE::SAN::Array::Base::short;

sub error_text {
    my ($content) = @_;
    my $d = PVE::SAN::Array::Base::decode($content);
    if (ref($d) eq 'HASH' && ref($d->{messages}) eq 'ARRAY') {
        return join('; ', map { join(': ', grep { defined && length } $_->{code}, $_->{message_l10n} // $_->{message}) }
            @{$d->{messages}});
    }
    return short($content);
}

sub login {
    my ($self) = @_;
    my ($code, $content, $h) = $self->request('GET', '/api/rest/login_session', { Authorization => $self->basic_auth }, undef);
    die "PowerStore login to $self->{address} failed (HTTP $code): " . error_text($content) . "\n" if $code != 200;
    $self->{token} = $h->{'dell-emc-token'} // die "PowerStore login: no DELL-EMC-TOKEN in response\n";
    my ($cookie) = ($h->{'set-cookie'} // '') =~ /(auth_cookie=[^;]+)/;
    $self->{cookie} = $cookie;
}

sub call {
    my ($self, $method, $path, $query, $body) = @_;

    $self->login() if !$self->{token};
    my $url = "/api/rest$path" . PVE::SAN::Array::Base::query_string($query);
    my ($code, $content);
    for my $attempt (1, 2) {
        my %h = ('DELL-EMC-TOKEN' => $self->{token}, Authorization => $self->basic_auth);
        $h{Cookie} = $self->{cookie} if $self->{cookie};
        ($code, $content) = $self->request($method, $url, \%h, $body);
        last if ($code != 401 && $code != 403) || $attempt == 2;
        $self->login();
    }
    die "PowerStore $method $path failed (HTTP $code): " . error_text($content) . "\n" if $code < 200 || $code >= 300;
    return PVE::SAN::Array::Base::decode($content);
}

sub system_info {
    my ($self) = @_;
    my ($c) = @{$self->call('GET', '/cluster', { select => 'id,name' }) // []};
    my ($sw) = @{(eval { $self->call('GET', '/software_installed', { select => 'release_version', is_cluster => 'eq.true' }) }) // []};
    return { name => $c->{name}, product => 'Dell PowerStore', code_level => $sw ? $sw->{release_version} : undef, id => $c->{id} };
}

sub pools {
    return [ { name => 'default', status => 'online', capacity => undef, free => undef } ];
}

sub host_clusters {
    my ($self) = @_;
    return [ map { { id => $_->{id}, name => $_->{name} } } @{$self->call('GET', '/host_group', { select => 'id,name' }) // []} ];
}

sub hosts {
    my ($self) = @_;
    my %hg = map { $_->{id} => $_->{name} } @{$self->host_clusters()};
    return [ map {
        my $h = $_;
        my @init = @{$h->{host_initiators} // []};
        {
            id => $h->{id},
            name => $h->{name},
            hostcluster => $h->{host_group_id} ? $hg{$h->{host_group_id}} : undef,
            wwpns => [ sort grep { defined } map { PVE::SAN::Array::Base::norm_wwpn($_->{port_name}) }
                grep { uc($_->{port_type} // 'FC') eq 'FC' } @init ],
            iqns => [ sort grep { defined } map { PVE::SAN::Array::Base::norm_iqn($_->{port_name}) }
                grep { lc($_->{port_type} // '') eq 'iscsi' } @init ],
        }
    } @{$self->call('GET', '/host', { select => 'id,name,host_group_id,host_initiators' }) // []} ];
}

sub initiators {
    my ($wwpns, $iqns) = @_;
    return [
        (map { { port_name => PVE::SAN::Array::Base::colon_wwpn($_), port_type => 'FC' } } @$wwpns),
        (map { { port_name => $_, port_type => 'iSCSI' } } @{$iqns // []}),
    ];
}

# PowerStore creates a host group together with its first member.
sub create_hostcluster {
    my ($self, $name) = @_;
    $self->{pending_group}->{$name} = 1;
}

sub create_host {
    my ($self, $name, $wwpns, $iqns) = @_;
    my $r = $self->call('POST', '/host', undef, { name => $name, os_type => 'Linux', initiators => initiators($wwpns, $iqns) });
    return { id => $r->{id}, name => $name, hostcluster => undef, wwpns => [@$wwpns], iqns => [@{$iqns // []}] };
}

sub add_host_ports {
    my ($self, $host, $wwpns, $iqns) = @_;
    $self->call('PATCH', "/host/$host->{id}", undef, { add_initiators => initiators($wwpns, $iqns) });
}

sub supports_iscsi { return 1; }

sub target_portals {
    my ($self) = @_;
    my $r = $self->call('GET', '/ip_pool_address',
        { purposes => 'cs.{Storage_Iscsi_Target}', select => 'address,ip_port(target_iqn)' }) // [];
    return [ map {
        { address => $_->{address}, port => 3260,
          iqn => PVE::SAN::Array::Base::norm_iqn(ref($_->{ip_port}) eq 'HASH' ? $_->{ip_port}->{target_iqn} : undef) }
    } grep { $_->{address} } @$r ];
}

sub group_id {
    my ($self, $name) = @_;
    my ($g) = grep { $_->{name} eq $name } @{$self->host_clusters()};
    return $g ? $g->{id} : undef;
}

sub add_to_hostcluster {
    my ($self, $hcname, $host) = @_;
    if (my $gid = $self->group_id($hcname)) {
        $self->call('PATCH', "/host_group/$gid", undef, { add_host_ids => [ $host->{id} ] });
    } else {
        $self->call('POST', '/host_group', undef, { name => $hcname, host_ids => [ $host->{id} ] });
        delete $self->{pending_group}->{$hcname};
    }
}

# --- monitoring and lifecycle ---
# (logical_used is selectable on PowerStoreOS 3+, see the volume detail
# queries in PyPowerStore utils/constants.py; modify_host_group
# {remove_host_ids}; delete_host: DELETE /host/<id>)

sub volume_space {
    my ($self, $ids) = @_;
    return [ map {
        my $id = $_;
        my $v = eval { $self->call('GET', "/volume/$id", { select => 'id,size,logical_used' }) }
            // $self->call('GET', "/volume/$id", { select => 'id,size' }); # older PowerStoreOS
        { id => $id, provisioned => $v->{size}, written => $v->{logical_used} }
    } @$ids ];
}

sub remove_host {
    my ($self, $host, $hcname) = @_;
    if (($host->{hostcluster} // '') eq $hcname) {
        my $gid = $self->group_id($hcname) // die "PowerStore host group '$hcname' not found\n";
        $self->call('PATCH', "/host_group/$gid", undef, { remove_host_ids => [ $host->{id} ] });
    }
    $self->call('DELETE', "/host/$host->{id}", undef, undef);
}

sub volume_from {
    my ($v) = @_;
    return {
        id => $v->{id},
        name => $v->{name},
        pool => 'default',
        capacity => $v->{size},
        uid => $v->{wwn},
        wwid => PVE::SAN::Array::Base::naa_to_wwid($v->{wwn}),
    };
}

my $VOL_FIELDS = 'id,name,size,wwn';

sub volume {
    my ($self, $id) = @_;
    return volume_from($self->call('GET', "/volume/$id", { select => $VOL_FIELDS }));
}

sub find_volume_by_wwid {
    my ($self, $wwid) = @_;
    return undef if $wwid !~ /^3(6[0-9a-f]{31})$/;
    my ($v) = @{$self->call('GET', '/volume', { select => $VOL_FIELDS, wwn => "eq.naa.$1" }) // []};
    return $v ? volume_from($v) : undef;
}

sub create_volume {
    my ($self, %p) = @_;
    die "invalid volume name '$p{name}'\n" if !$self->valid_name($p{name});
    die "size must be a whole number of GiB\n" if $p{size_gib} !~ /^\d+$/ || $p{size_gib} < 1;
    print "note: PowerStore volumes are always thin provisioned\n" if defined($p{thin}) && !$p{thin};
    my $r = $self->call('POST', '/volume', undef, { name => $p{name}, size => $p{size_gib} * $PVE::SAN::Array::Base::GIB });
    return $self->volume($r->{id});
}

sub map_to_hostcluster {
    my ($self, $vol, $hcname) = @_;
    my $gid = $self->group_id($hcname) // die "PowerStore host group '$hcname' not found\n";
    $self->call('POST', "/volume/$vol/attach", undef, { host_group_id => $gid });
}

sub unmap_from_hostcluster {
    my ($self, $vol, $hcname) = @_;
    my $gid = $self->group_id($hcname) // die "PowerStore host group '$hcname' not found\n";
    $self->call('POST', "/volume/$vol/detach", undef, { host_group_id => $gid });
}

sub expand_volume {
    my ($self, $vol, $add_bytes) = @_;
    die "expansion must be a positive multiple of 512 bytes\n" if $add_bytes <= 0 || $add_bytes % 512;
    my $cur = $self->volume($vol);
    $self->call('PATCH', "/volume/$vol", undef, { size => $cur->{capacity} + $add_bytes });
}

sub delete_volume {
    my ($self, $vol) = @_;
    $self->call('DELETE', "/volume/$vol", undef, undef);
}

# --- snapshots ---

sub supports_snapshots { return 1; }

# "2024-05-01T10:20:30.123Z" / "...+00:00" -> epoch
sub parse_timestamp {
    my ($ts) = @_;
    my ($y, $mo, $d, $h, $mi, $s, $tz) = ($ts // '') =~
        /^(\d{4})-(\d\d)-(\d\d)T(\d\d):(\d\d):(\d\d)(?:\.\d+)?(Z|[+-]\d\d:?\d\d)?$/ or return undef;
    require Time::Local;
    my $t = Time::Local::timegm($s, $mi, $h, $d, $mo - 1, $y);
    if ($tz && $tz =~ /^([+-])(\d\d):?(\d\d)$/) {
        $t -= ($1 eq '-' ? -1 : 1) * ($2 * 3600 + $3 * 60);
    }
    return $t;
}

my $SNAP_FIELDS = 'id,name,size,creation_timestamp,protection_data';

sub snapshot_from {
    my ($s, $parent_name) = @_;
    my $name = $s->{name} // '';
    $name =~ s/^\Q$parent_name\E\.// if defined($parent_name);
    my $pd = ref($s->{protection_data}) eq 'HASH' ? $s->{protection_data} : {};
    return {
        id => $s->{id},
        name => $name,
        volume => $pd->{source_id},
        created => parse_timestamp($s->{creation_timestamp}),
        size => $s->{size},
    };
}

# Datastores on several volumes: a write-order consistent volume group
# "pvesan-<first volume name>" holds the volumes and is snapshotted as a
# whole (PyPowerStore provisioning.create_volume_group, add_members_to_volume_group,
# restore_volume_group; protection.create_volume_group_snapshot,
# get_volume_group_snapshots, delete_volume_group_snapshot; constants
# SELECT_ALL_VOL_GROUP with volumes(name,id)). The members of a snapshot
# set are volume snapshots of the member volumes.

sub supports_group_snapshots { return 1; }

sub vgroup_name {
    my ($self, $vols) = @_;
    return substr('pvesan-' . $self->volume($vols->[0])->{name}, 0, 128);
}

sub ensure_vgroup {
    my ($self, $vols) = @_;
    my $name = $self->vgroup_name($vols);
    my ($g) = @{$self->call('GET', '/volume_group', { select => 'id,name,volumes(name,id)', name => "eq.$name" }) // []};
    if (!$g) {
        print "creating volume group '$name'\n";
        my $r = $self->call('POST', '/volume_group', undef,
            { name => $name, volume_ids => [ @$vols ], is_write_order_consistent => JSON::PP::true });
        return $r->{id};
    }
    my %in = map { $_->{id} => 1 } @{$g->{volumes} // []};
    my @add = grep { !$in{$_} } @$vols;
    if (@add) {
        print "adding @add to volume group '$name'\n";
        $self->call('POST', "/volume_group/$g->{id}/add_members", undef, { volume_ids => \@add });
    }
    return $g->{id};
}

# Snapshot sets of the volumes' group: { set id => { name, created, members => [ snapshot ] } }
sub group_sets {
    my ($self, $vols) = @_;
    my $name = $self->vgroup_name($vols);
    my ($g) = @{$self->call('GET', '/volume_group', { select => 'id,name', name => "eq.$name" }) // []};
    return {} if !$g;
    my %sets;
    my $list = $self->call('GET', '/volume_group', {
        select => 'id,name,creation_timestamp,volumes(name,id)',
        'protection_data->>source_id' => "eq.$g->{id}",
        type => 'eq.Snapshot',
    }) // [];
    for my $set (@$list) {
        my @members = map {
            my $m = snapshot_from($self->call('GET', "/volume/$_->{id}", { select => $SNAP_FIELDS }));
            +{ %$m, name => $set->{name}, group => $set->{id}, vgroup => $g->{id} }
        } @{$set->{volumes} // []};
        $sets{$set->{id}} = { name => $set->{name}, members => \@members };
    }
    return \%sets;
}

sub snapshots {
    my ($self, $vols) = @_;
    my (@res, %in_set);
    if (@$vols > 1) {
        my $sets = $self->group_sets($vols);
        for my $set (map { $sets->{$_} } sort keys %$sets) {
            push @res, @{$set->{members}};
            $in_set{$_->{id}} = 1 for @{$set->{members}};
        }
    }
    for my $id (@$vols) {
        my $parent = $self->volume($id);
        my $list = $self->call('GET', '/volume', {
            select => $SNAP_FIELDS,
            'protection_data->>source_id' => "eq.$id",
            type => 'eq.Snapshot',
        }) // [];
        push @res, map { snapshot_from($_, $parent->{name}) } grep { !$in_set{$_->{id}} } @$list;
    }
    return [ sort { ($a->{created} // 0) <=> ($b->{created} // 0) } @res ];
}

sub snapshot_create {
    my ($self, $vols, $name) = @_;
    $self->check_snapshot_args($vols, $name);
    if (@$vols > 1) {
        my $vg = $self->ensure_vgroup($vols);
        $self->call('POST', "/volume_group/$vg/snapshot", undef, { name => $name });
        return [ grep { $_->{name} eq $name && $_->{group} } @{$self->snapshots($vols)} ];
    }
    my $parent = $self->volume($vols->[0]);
    my $r = $self->call('POST', "/volume/$vols->[0]/snapshot", undef, { name => substr("$parent->{name}.$name", 0, 128) });
    my $s = $self->call('GET', "/volume/$r->{id}", { select => $SNAP_FIELDS });
    return [ snapshot_from($s, $parent->{name}) ];
}

# A set taken of the volume group is deleted as a whole.
sub snapshot_delete {
    my ($self, $snap) = @_;
    if ($snap->{group}) {
        $self->call('DELETE', "/volume_group/$snap->{group}", undef, undef);
    } else {
        $self->call('DELETE', "/volume/$snap->{id}", undef, undef);
    }
}

sub snapshot_clone {
    my ($self, $snap, $name) = @_;
    die "invalid volume name '$name'\n" if !$self->valid_name($name);
    my $r = $self->call('POST', "/volume/$snap->{id}/clone", undef, { name => $name });
    return $self->volume($r->{id});
}

# PowerStore keeps a backup snapshot of the current state. A member of a
# volume group set restores the whole group, once.
sub snapshot_restore {
    my ($self, $vol, $snap) = @_;
    if ($snap->{group}) {
        return if ($self->{restored_set} // '') eq $snap->{group};
        $self->call('POST', "/volume_group/$snap->{vgroup}/restore", undef,
            { from_snap_id => $snap->{group}, create_backup_snap => JSON::PP::true });
        $self->{restored_set} = $snap->{group};
        return;
    }
    $self->call('POST', "/volume/$vol/restore", undef, { from_snap_id => $snap->{id}, create_backup_snap => JSON::PP::true });
}

1;
