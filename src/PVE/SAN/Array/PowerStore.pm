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
#   host group    POST /host_group {name, host_ids}; PATCH {add_host_ids}
#
# PowerStore volumes are always thin; the appliance is one capacity pool.

use strict;
use warnings;

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
        {
            id => $h->{id},
            name => $h->{name},
            hostcluster => $h->{host_group_id} ? $hg{$h->{host_group_id}} : undef,
            wwpns => [ sort grep { defined } map { PVE::SAN::Array::Base::norm_wwpn($_->{port_name}) }
                grep { uc($_->{port_type} // 'FC') eq 'FC' } @{$h->{host_initiators} // []} ],
        }
    } @{$self->call('GET', '/host', { select => 'id,name,host_group_id,host_initiators' }) // []} ];
}

sub initiators {
    my ($wwpns) = @_;
    return [ map { { port_name => PVE::SAN::Array::Base::colon_wwpn($_), port_type => 'FC' } } @$wwpns ];
}

# PowerStore creates a host group together with its first member.
sub create_hostcluster {
    my ($self, $name) = @_;
    $self->{pending_group}->{$name} = 1;
}

sub create_host {
    my ($self, $name, $wwpns) = @_;
    my $r = $self->call('POST', '/host', undef, { name => $name, os_type => 'Linux', initiators => initiators($wwpns) });
    return { id => $r->{id}, name => $name, hostcluster => undef, wwpns => [@$wwpns] };
}

sub add_host_ports {
    my ($self, $host, $wwpns) = @_;
    $self->call('PATCH', "/host/$host->{id}", undef, { add_initiators => initiators($wwpns) });
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

1;
