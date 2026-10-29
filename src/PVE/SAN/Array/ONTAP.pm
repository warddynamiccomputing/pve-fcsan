package PVE::SAN::Array::ONTAP;

# Driver for NetApp ONTAP (AFF / ASA / FAS, ONTAP 9.8+) through the ONTAP
# REST API (/api).
#
# Checked against NetApp's Ansible collection (netapp.ontap modules
# na_ontap_lun, na_ontap_lun_map, na_ontap_igroup):
#   LUN      POST storage/luns {svm.name, name, os_type, space.size,
#                 space.guarantee.requested}; PATCH space.size; DELETE
#   igroup   POST protocols/san/igroups {name, svm, os_type, protocol, initiators}
#            POST protocols/san/igroups/<uuid>/initiators {records: [{name}]}
#   map      POST protocols/san/lun-maps {svm, igroup, lun}
#   unmap    DELETE protocols/san/lun-maps/<lun.uuid>/<igroup.uuid>
#   changes run as jobs: ?return_timeout=120, then poll cluster/jobs/<uuid>
#
# Layout: each datastore LUN gets its own FlexVol (/vol/<name>/lun0) in the
# chosen aggregate - NetApp's recommendation for VMware datastores, and it
# keeps snapshots and efficiency per datastore. The cluster is one FCP
# igroup (os_type linux) holding every node's WWPNs.
#
# Multipath WWID: 3 + NAA 600a0980 + hex of the 12-character LUN serial.

use strict;
use warnings;

use JSON::PP ();

use base qw(PVE::SAN::Array::Base);

sub description { return 'NetApp ONTAP'; }

# multipath-tools queues I/O on these LUNs forever when all paths are gone
sub default_no_path_retry { return 12; }
sub options { return { svm => 1 }; }
sub max_name_length { return 64; }

# FlexVol names: letters, digits and '_' (no '-' or '.')
sub valid_name {
    my ($class, $name) = @_;
    return defined($name) && length($name) <= 64 && $name =~ /^[A-Za-z_][A-Za-z0-9_]*$/;
}

sub object_name_for {
    my ($class, $name) = @_;
    $name =~ s/[^A-Za-z0-9_]/_/g;
    $name = "pve_$name" if $name !~ /^[A-Za-z_]/;
    return substr($name, 0, 60);
}

# igroup names are more liberal than FlexVol names
sub valid_igroup_name {
    my ($name) = @_;
    return defined($name) && length($name) <= 96 && $name =~ /^[A-Za-z0-9_.-]+$/;
}

sub valid_hostcluster_name { return valid_igroup_name($_[1]); }

*short = \&PVE::SAN::Array::Base::short;

sub error_text {
    my ($content) = @_;
    my $d = PVE::SAN::Array::Base::decode($content);
    if (ref($d) eq 'HASH' && ref($d->{error}) eq 'HASH') {
        return join(': ', grep { defined && length } $d->{error}->{code}, $d->{error}->{message});
    }
    return short($content);
}

sub call {
    my ($self, $method, $path, $query, $body) = @_;
    my %q = %{$query // {}};
    $q{return_timeout} = 120 if $method ne 'GET';
    my $d = $self->json_call($method, "/api$path", \%q, $body,
        { Authorization => $self->basic_auth }, \&error_text, 'ONTAP');
    $self->wait_job($d->{job}->{uuid}) if ref($d) eq 'HASH' && ref($d->{job}) eq 'HASH' && $d->{job}->{uuid};
    return $d;
}

sub wait_job {
    my ($self, $uuid) = @_;
    for (1 .. 300) {
        my $j = $self->json_call('GET', "/api/cluster/jobs/$uuid", { fields => 'state,message,error' }, undef,
            { Authorization => $self->basic_auth }, \&error_text, 'ONTAP');
        my $state = $j->{state} // '';
        return if $state eq 'success';
        die "ONTAP job $uuid failed: " . ($j->{message} // ($j->{error} // {})->{message} // $state) . "\n"
            if $state eq 'failure';
        sleep(2);
    }
    die "ONTAP job $uuid did not finish in 10 minutes\n";
}

sub records {
    my ($self, $path, $query) = @_;
    my $d = $self->call('GET', $path, { max_records => 10000, %{$query // {}} }) // {};
    return $d->{records} // [];
}

sub system_info {
    my ($self) = @_;
    my $c = $self->call('GET', '/cluster', { fields => 'name,uuid,version' }) // {};
    return {
        name => $c->{name},
        product => "NetApp ONTAP (SVM $self->{svm})",
        code_level => ref($c->{version}) eq 'HASH' ? $c->{version}->{full} : undef,
        id => $c->{uuid},
    };
}

# pools = aggregates
sub pools {
    my ($self) = @_;
    return [ map {
        my $bs = ref($_->{space}) eq 'HASH' ? ($_->{space}->{block_storage} // {}) : {};
        { name => $_->{name}, status => $_->{state} // 'online', capacity => $bs->{size}, free => $bs->{available} }
    } @{$self->records('/storage/aggregates', { fields => 'name,state,space.block_storage' })} ];
}

# --- cluster registration: one FCP igroup ---

sub igroup {
    my ($self, $name) = @_;
    my ($g) = @{$self->records('/protocols/san/igroups',
        { 'svm.name' => $self->{svm}, name => $name, fields => 'uuid,name,initiators,protocol,os_type' })};
    return $g;
}

sub ensure_hostcluster {
    my ($self, $hcname, $node_wwpns, $log) = @_;
    $log //= sub { print "$_[0]\n" };

    die "invalid igroup name '$hcname'\n" if !valid_igroup_name($hcname);

    my %want; # WWPN => node
    for my $node (sort keys %$node_wwpns) {
        my @w = grep { defined } map { PVE::SAN::Array::Base::norm_wwpn($_) } @{$node_wwpns->{$node}};
        die "node '$node' has no FC ports\n" if !@w;
        $want{$_} = $node for @w;
    }

    my %result = map { $_ => { host => "igroup $hcname", created => 0, added_ports => [], joined => 0 } } keys %$node_wwpns;
    my $g = $self->igroup($hcname);
    if (!$g) {
        $log->("creating FCP igroup '$hcname' in SVM $self->{svm} with " . scalar(keys %want) . " initiators");
        $self->call('POST', '/protocols/san/igroups', undef, {
            name => $hcname,
            svm => { name => $self->{svm} },
            os_type => 'linux',
            protocol => 'fcp',
            initiators => [ map { { name => PVE::SAN::Array::Base::colon_wwpn($_) } } sort keys %want ],
        });
        $_->{joined} = 1 for values %result;
        return \%result;
    }

    die "igroup '$hcname' exists with protocol '$g->{protocol}', not fcp/mixed\n"
        if ($g->{protocol} // 'fcp') !~ /^(?:fcp|mixed)$/;
    my %have = map { (PVE::SAN::Array::Base::norm_wwpn($_->{name}) // '') => 1 } @{$g->{initiators} // []};
    my @missing = sort grep { !$have{$_} } keys %want;
    if (@missing) {
        $log->("adding initiators @missing to igroup '$hcname'");
        $self->call('POST', "/protocols/san/igroups/$g->{uuid}/initiators", undef,
            { records => [ map { { name => PVE::SAN::Array::Base::colon_wwpn($_) } } @missing ] });
        push @{$result{$want{$_}}->{added_ports}}, $_ for @missing;
    }
    return \%result;
}

# --- LUNs (id = LUN uuid) ---

# 600a0980 + the serial's ASCII bytes in hex
sub serial_to_wwid {
    my ($serial) = @_;
    return undef if !defined($serial) || length($serial) != 12;
    return '3600a0980' . unpack('H*', $serial);
}

sub wwid_to_serial {
    my ($wwid) = @_;
    return undef if $wwid !~ /^3600a0980([0-9a-f]{24})$/;
    return pack('H*', $1);
}

my $LUN_FIELDS = 'uuid,name,serial_number,space.size,location.volume';

sub volume_from {
    my ($l) = @_;
    my $vol = ref($l->{location}) eq 'HASH' ? ($l->{location}->{volume} // {}) : {};
    return {
        id => $l->{uuid},
        name => $l->{name},
        flexvol => $vol->{name},
        flexvol_uuid => $vol->{uuid},
        capacity => ref($l->{space}) eq 'HASH' ? $l->{space}->{size} : undef,
        uid => $l->{serial_number},
        wwid => serial_to_wwid($l->{serial_number}),
    };
}

sub volume {
    my ($self, $uuid) = @_;
    return volume_from($self->call('GET', "/storage/luns/$uuid", { fields => $LUN_FIELDS }) // {});
}

sub find_volume_by_wwid {
    my ($self, $wwid) = @_;
    my $serial = wwid_to_serial($wwid) // return undef;
    my ($l) = @{$self->records('/storage/luns', { 'svm.name' => $self->{svm}, serial_number => $serial, fields => $LUN_FIELDS })};
    return $l ? volume_from($l) : undef;
}

sub create_volume {
    my ($self, %p) = @_;

    die "invalid ONTAP volume name '$p{name}' (letters, digits, '_')\n" if !$self->valid_name($p{name});
    die "size must be a whole number of GiB\n" if $p{size_gib} !~ /^\d+$/ || $p{size_gib} < 1;
    my $bytes = $p{size_gib} * $PVE::SAN::Array::Base::GIB;

    # FlexVol with 10% headroom for LUN metadata and snapshot reserve 0
    $self->call('POST', '/storage/volumes', undef, {
        name => $p{name},
        svm => { name => $self->{svm} },
        aggregates => [ { name => $p{pool} } ],
        size => int($bytes * 1.1),
        guarantee => { type => $p{thin} ? 'none' : 'volume' },
        space => { snapshot => { reserve_percent => 0 } },
    });

    my $path = "/vol/$p{name}/lun0";
    eval {
        $self->call('POST', '/storage/luns', undef, {
            svm => { name => $self->{svm} },
            name => $path,
            os_type => 'linux',
            space => { size => $bytes, guarantee => { requested => $p{thin} ? JSON::PP::false : JSON::PP::true } },
        });
    };
    if (my $err = $@) {
        eval { $self->delete_flexvol($p{name}) };
        die $err;
    }
    my ($l) = @{$self->records('/storage/luns', { 'svm.name' => $self->{svm}, name => $path, fields => $LUN_FIELDS })};
    die "ONTAP: LUN $path not found after creation\n" if !$l;
    return volume_from($l);
}

sub map_to_hostcluster {
    my ($self, $uuid, $hcname) = @_;
    $self->call('POST', '/protocols/san/lun-maps', undef,
        { svm => { name => $self->{svm} }, igroup => { name => $hcname }, lun => { uuid => $uuid } });
}

sub unmap_from_hostcluster {
    my ($self, $uuid, $hcname) = @_;
    my $g = $self->igroup($hcname) // die "ONTAP igroup '$hcname' not found\n";
    $self->call('DELETE', "/protocols/san/lun-maps/$uuid/$g->{uuid}", undef, undef);
}

sub expand_volume {
    my ($self, $uuid, $add_bytes) = @_;
    die "expansion must be a positive multiple of 512 bytes\n" if $add_bytes <= 0 || $add_bytes % 512;
    my $cur = $self->volume($uuid);
    my $new = $cur->{capacity} + $add_bytes;
    if ($cur->{flexvol_uuid}) {
        my $v = $self->call('GET', "/storage/volumes/$cur->{flexvol_uuid}", { fields => 'size' }) // {};
        my $want = int($new * 1.1);
        $self->call('PATCH', "/storage/volumes/$cur->{flexvol_uuid}", undef, { size => $want })
            if ($v->{size} // 0) < $want;
    }
    $self->call('PATCH', "/storage/luns/$uuid", undef, { space => { size => $new } });
}

sub delete_flexvol {
    my ($self, $name) = @_;
    my ($v) = @{$self->records('/storage/volumes', { 'svm.name' => $self->{svm}, name => $name, fields => 'uuid' })};
    $self->call('DELETE', "/storage/volumes/$v->{uuid}", undef, undef) if $v;
}

# --- snapshots (FlexVol snapshots; one LUN per FlexVol) ---
#
# Checked against NetApp's Ansible collection: na_ontap_snapshot
# (POST/GET/DELETE storage/volumes/<uuid>/snapshots), na_ontap_volume
# (PATCH storage/volumes/<uuid> {restore_to.snapshot.name}) and
# na_ontap_volume_clone (POST storage/volumes {name, clone.parent_volume.name,
# clone.parent_snapshot.name, clone.is_flexclone, svm.name}).
#
# A snapshot of the FlexVol that holds only the datastore's LUN is a
# snapshot of that LUN. A copy is a FlexClone of the FlexVol at the
# snapshot; its lun0 gets its own serial number. Datastores on several
# LUNs (several FlexVols) would need a consistency group: not yet.

sub supports_snapshots { return 1; }

sub iso_epoch {
    my ($t) = @_;
    my ($Y, $m, $d, $H, $M, $S, $tz) = ($t // '') =~ /^(\d{4})-(\d\d)-(\d\d)T(\d\d):(\d\d):(\d\d)(?:\.\d+)?(Z|[+-]\d\d:?\d\d)?$/
        or return undef;
    require Time::Local;
    my $e = Time::Local::timegm($S, $M, $H, $d, $m - 1, $Y);
    if ($tz && $tz ne 'Z') {
        my ($sign, $th, $tm) = $tz =~ /^([+-])(\d\d):?(\d\d)$/;
        $e -= ($sign eq '+' ? 1 : -1) * ($th * 3600 + $tm * 60);
    }
    return $e;
}

# The FlexVol of a pvesan LUN (/vol/<flexvol>/lun0, nothing else in it).
sub lun_flexvol {
    my ($self, $uuid) = @_;
    my $l = $self->volume($uuid);
    die "ONTAP LUN $uuid is not in a FlexVol of its own (/vol/<name>/lun0) - snapshots need pvesan's layout\n"
        if ($l->{name} // '') !~ m|^/vol/[^/]+/lun0$| || !$l->{flexvol_uuid};
    return $l;
}

sub snapshots {
    my ($self, $vols) = @_;
    my @res;
    for my $uuid (@$vols) {
        my $l = $self->lun_flexvol($uuid);
        for my $s (@{$self->records("/storage/volumes/$l->{flexvol_uuid}/snapshots", { fields => 'uuid,name,create_time' })}) {
            # ONTAP's own (hourly.*, snapmirror.*) have a dot; pvesan names never do
            next if ($s->{name} // '.') =~ /\./;
            push @res, {
                id => "$l->{flexvol_uuid}/$s->{uuid}",
                name => $s->{name},
                volume => $uuid,
                created => iso_epoch($s->{create_time}),
                size => $l->{capacity},
                flexvol => $l->{flexvol},
            };
        }
    }
    return [ sort { ($a->{created} // 0) <=> ($b->{created} // 0) } @res ];
}

sub snapshot_create {
    my ($self, $vols, $name) = @_;
    $self->check_snapshot_args($vols, $name);
    my $l = $self->lun_flexvol($vols->[0]);
    $self->call('POST', "/storage/volumes/$l->{flexvol_uuid}/snapshots", undef,
        { name => $name, svm => { name => $self->{svm} } });
    return [ grep { $_->{name} eq $name } @{$self->snapshots($vols)} ];
}

sub snapshot_delete {
    my ($self, $snap) = @_;
    my ($fv, $su) = split(m|/|, $snap->{id}, 2);
    $self->call('DELETE', "/storage/volumes/$fv/snapshots/$su", undef, undef);
}

sub snapshot_clone {
    my ($self, $snap, $name) = @_;
    die "invalid ONTAP volume name '$name' (letters, digits, '_')\n" if !$self->valid_name($name);
    my $parent = $snap->{flexvol} // $self->volume($snap->{volume})->{flexvol};
    $self->call('POST', '/storage/volumes', undef, {
        name => $name,
        'clone.parent_volume.name' => $parent,
        'clone.parent_snapshot.name' => $snap->{name},
        'clone.is_flexclone' => JSON::PP::true,
        'svm.name' => $self->{svm},
    });
    my $path = "/vol/$name/lun0";
    my ($l) = @{$self->records('/storage/luns', { 'svm.name' => $self->{svm}, name => $path, fields => "$LUN_FIELDS,enabled" })};
    die "ONTAP: LUN $path not found in the FlexClone\n" if !$l;
    my $v = volume_from($l);
    my $src = $self->volume($snap->{volume});
    die "ONTAP: the cloned LUN kept the serial number of the original - not importing it\n"
        if defined($v->{uid}) && defined($src->{uid}) && $v->{uid} eq $src->{uid};
    $self->call('PATCH', "/storage/luns/$v->{id}", undef, { enabled => JSON::PP::true })
        if defined($l->{enabled}) && !$l->{enabled};
    return $v;
}

# Whole-FlexVol restore; the FlexVol holds only this LUN.
sub snapshot_restore {
    my ($self, $uuid, $snap) = @_;
    my $l = $self->lun_flexvol($uuid);
    $self->call('PATCH', "/storage/volumes/$l->{flexvol_uuid}", undef, { 'restore_to.snapshot.name' => $snap->{name} });
}

# Deletes the LUN, and its FlexVol when pvesan created it (/vol/<x>/lun0
# and nothing else left in it).
sub delete_volume {
    my ($self, $uuid) = @_;
    my $cur = $self->volume($uuid);
    $self->call('DELETE', "/storage/luns/$uuid", undef, undef);
    if (($cur->{name} // '') =~ m|^/vol/([^/]+)/lun0$| && $cur->{flexvol_uuid}) {
        my $left = $self->records('/storage/luns', { 'location.volume.uuid' => $cur->{flexvol_uuid}, fields => 'uuid' });
        if (!@$left) {
            print "deleting FlexVol '$1'\n";
            $self->call('DELETE', "/storage/volumes/$cur->{flexvol_uuid}", undef, undef);
        }
    }
}

1;
