package PVE::SAN::Array::Pure;

# Driver for Pure Storage FlashArray through REST API 2.x (Purity//FA 6+).
#
# Authentication: an API token (created on the array for a user with the
# Storage Admin role) is exchanged at POST /api/2.x/login for a session
# token returned in the x-auth-token response header.
#
# Endpoints, parameters and body fields are checked against Pure's
# generated SDK docs (go-pure-client, flasharray/FA_2_50/docs: VolumesAPI,
# HostsAPI, HostGroupsAPI, ConnectionsAPI, AuthorizationAPI, VolumePost,
# VolumePatch, HostPost, Host, ArraySpace, Space).
#
# FlashArray specifics:
#  - one capacity pool for the whole array; volumes are always thin
#  - host clusters are "host groups"; mapping is a "connection"
#  - the multipath WWID is 3 + "624a9370" (Pure's NAA prefix) + serial
#  - deleting a volume destroys it: it stays recoverable on the array for
#    the eradication delay (24 h by default) before it is gone

use strict;
use warnings;

use JSON::PP;

use base qw(PVE::SAN::Array::Base);

my $NAA_PREFIX = '624a9370';

sub description { return 'Pure Storage FlashArray'; }
sub default_port { return 443; }
sub needs_username { return 0; } # the API token identifies the user
sub max_name_length { return 63; }

# Purity object names: letters, digits and '-', must start and end with a
# letter or digit.
sub valid_name {
    my ($class, $name) = @_;
    return defined($name) && length($name) <= 63
        && $name =~ /^[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?$/;
}

sub object_name_for {
    my ($class, $name) = @_;
    $name =~ s/[^A-Za-z0-9-]/-/g;
    $name =~ s/^-+|-+$//g;
    $name = "pve-$name" if !length($name);
    return substr($name, 0, 59);
}

sub api_version {
    my ($self) = @_;
    return $self->{api_version} if $self->{api_version};

    my ($code, $content) = $self->request('GET', '/api/api_version', {}, undef);
    die "FlashArray $self->{address}: cannot read API versions (HTTP $code): " . short($content) . "\n"
        if $code != 200;
    my $d = PVE::SAN::Array::Base::decode($content) // {};
    my @v2 = sort { vcmp($a, $b) } grep { /^2\.\d+$/ } @{$d->{version} // []};
    die "FlashArray $self->{address} does not offer REST API 2.x (Purity//FA 6 or newer needed)\n" if !@v2;
    return $self->{api_version} = $v2[-1];
}

sub vcmp {
    my ($x, $y) = @_;
    my ($xa, $xb) = split(/\./, $x);
    my ($ya, $yb) = split(/\./, $y);
    return $xa <=> $ya || $xb <=> $yb;
}

*short = \&PVE::SAN::Array::Base::short;

sub login {
    my ($self) = @_;
    my $ver = $self->api_version();
    my ($code, $content, $headers) = $self->request('POST', "/api/$ver/login", { 'api-token' => $self->{password} }, undef);
    die "FlashArray login to $self->{address} failed (HTTP $code): " . error_text($content) . "\n" if $code != 200;
    $self->{token} = $headers->{'x-auth-token'} // die "FlashArray login: no x-auth-token in response\n";
}

sub error_text {
    my ($content) = @_;
    my $d = PVE::SAN::Array::Base::decode($content);
    if (ref($d) eq 'HASH' && ref($d->{errors}) eq 'ARRAY') {
        return join('; ', map { join(': ', grep { defined && length } $_->{context}, $_->{message}) } @{$d->{errors}});
    }
    return short($content);
}

# One API call. Returns the decoded body.
sub call {
    my ($self, $method, $path, $query, $body) = @_;

    $self->login() if !$self->{token};
    my $ver = $self->api_version();
    my $url = "/api/$ver$path" . PVE::SAN::Array::Base::query_string($query);

    my ($code, $content);
    for my $attempt (1, 2) {
        ($code, $content) = $self->request($method, $url, { 'x-auth-token' => $self->{token} }, $body);
        last if $code != 401 || $attempt == 2;
        $self->login(); # session expired
    }
    die "FlashArray $method $path failed (HTTP $code): " . error_text($content) . "\n" if $code < 200 || $code >= 300;
    return PVE::SAN::Array::Base::decode($content) // {};
}

# GET with continuation-token paging; returns all items.
sub items {
    my ($self, $path, $query) = @_;
    my @all;
    my %q = %{$query // {}};
    for (1 .. 1000) {
        my $r = $self->call('GET', $path, \%q, undef);
        push @all, @{$r->{items} // []};
        my $next = $r->{continuation_token} // last;
        $q{continuation_token} = $next;
    }
    return \@all;
}

# --- read side ---

sub system_info {
    my ($self) = @_;
    my ($arr) = @{$self->items('/arrays')};
    return {
        name => $arr->{name},
        product => 'Pure FlashArray ' . ($arr->{os} // 'Purity'),
        code_level => $arr->{version},
        id => $arr->{id},
    };
}

# A FlashArray has a single capacity pool; it is offered as "default".
sub pools {
    my ($self) = @_;
    my ($s) = @{$self->items('/arrays/space')};
    my $cap = $s->{capacity};
    # total_used replaces the deprecated total_physical in newer API versions
    my $sp = ref($s->{space}) eq 'HASH' ? $s->{space} : {};
    my $used = $sp->{total_used} // $sp->{total_physical};
    return [ {
        name => 'default',
        status => 'online',
        capacity => $cap,
        free => (defined($cap) && defined($used)) ? $cap - $used : undef,
    } ];
}

sub hosts {
    my ($self) = @_;
    return [ map {
        my $hg = ref($_->{host_group}) eq 'HASH' ? $_->{host_group}->{name} : undef;
        {
            id => $_->{name},
            name => $_->{name},
            hostcluster => (defined($hg) && length($hg)) ? $hg : undef,
            wwpns => [ sort grep { defined } map { PVE::SAN::Array::Base::norm_wwpn($_) } @{$_->{wwns} // []} ],
        }
    } @{$self->items('/hosts')} ];
}

sub host_clusters {
    my ($self) = @_;
    return [ map { { id => $_->{name}, name => $_->{name} } } @{$self->items('/host-groups')} ];
}

# POST /host-groups and /connections take a JSON body (HostGroupPost,
# ConnectionPost) whose fields are all optional - send an empty one.
sub create_hostcluster {
    my ($self, $name) = @_;
    $self->call('POST', '/host-groups', { names => $name }, {});
}

sub create_host {
    my ($self, $name, $wwpns) = @_;
    $self->call('POST', '/hosts', { names => $name }, { wwns => [@$wwpns] });
    return { id => $name, name => $name, hostcluster => undef, wwpns => [@$wwpns] };
}

sub add_host_ports {
    my ($self, $host, $wwpns) = @_;
    $self->call('PATCH', '/hosts', { names => $host->{name} }, { add_wwns => [@$wwpns] });
}

sub add_to_hostcluster {
    my ($self, $hcname, $host) = @_;
    $self->call('POST', '/host-groups/hosts', { group_names => $hcname, member_names => $host->{name} }, undef);
}

# --- monitoring and lifecycle ---
# (VolumesAPI / VolumeSpaceCommon, AlertsAPI / Alert, PortsAPI / Port,
# HostGroupsAPI HostGroupsHostsDelete, HostsAPI HostsDelete)

sub volume_space {
    my ($self, $ids) = @_;
    return [] if !@$ids;
    return [ map {
        my $sp = ref($_->{space}) eq 'HASH' ? $_->{space} : {};
        {
            id => $_->{name},
            provisioned => $_->{provisioned},
            written => $sp->{virtual},
            reduction => $sp->{data_reduction},
        }
    } @{$self->items('/volumes', { names => join(',', @$ids) })} ];
}

sub health {
    my ($self) = @_;
    my @alerts = map { { severity => $_->{severity} // 'info', summary => $_->{summary} // $_->{description} // '' } }
        @{$self->items('/alerts', { filter => "state='open'" })};
    my $status = (grep { $_->{severity} eq 'critical' } @alerts) ? 'critical'
        : (grep { $_->{severity} eq 'warning' } @alerts) ? 'warning' : 'ok';
    return { status => $status, alerts => \@alerts };
}

sub target_ports {
    my ($self) = @_;
    return [ sort grep { defined } map { PVE::SAN::Array::Base::norm_wwpn($_->{wwn}) } @{$self->items('/ports')} ];
}

sub remove_host {
    my ($self, $host, $hcname) = @_;
    $self->call('DELETE', '/host-groups/hosts', { group_names => $hcname, member_names => $host->{name} }, undef)
        if ($host->{hostcluster} // '') eq $hcname;
    $self->call('DELETE', '/hosts', { names => $host->{name} }, undef);
}

# --- volumes (id = volume name) ---

sub volume_from {
    my ($v) = @_;
    my $serial = lc($v->{serial} // '');
    return {
        id => $v->{name},
        name => $v->{name},
        pool => 'default',
        capacity => $v->{provisioned},
        uid => uc($serial),
        wwid => $serial =~ /^[0-9a-f]{24}$/ ? "3$NAA_PREFIX$serial" : undef,
    };
}

sub volume {
    my ($self, $name) = @_;
    my ($v) = @{$self->items('/volumes', { names => $name })};
    die "FlashArray volume '$name' not found\n" if !$v;
    return volume_from($v);
}

sub find_volume_by_wwid {
    my ($self, $wwid) = @_;
    return undef if $wwid !~ /^3\Q$NAA_PREFIX\E([0-9a-f]{24})$/;
    my $serial = uc($1);
    my ($v) = @{$self->items('/volumes', { filter => "serial='$serial'" })};
    return $v ? volume_from($v) : undef;
}

sub create_volume {
    my ($self, %p) = @_;

    die "invalid FlashArray volume name '$p{name}' (letters, digits and '-')\n" if !$self->valid_name($p{name});
    die "size must be a whole number of GiB\n" if $p{size_gib} !~ /^\d+$/ || $p{size_gib} < 1;
    print "note: FlashArray volumes are always thin provisioned\n" if defined($p{thin}) && !$p{thin};

    my $r = $self->call('POST', '/volumes', { names => $p{name} }, { provisioned => $p{size_gib} * $PVE::SAN::Array::Base::GIB });
    my ($v) = @{$r->{items} // []};
    return $v ? volume_from($v) : $self->volume($p{name});
}

sub map_to_hostcluster {
    my ($self, $vol, $hcname) = @_;
    $self->call('POST', '/connections', { host_group_names => $hcname, volume_names => $vol }, {});
}

sub unmap_from_hostcluster {
    my ($self, $vol, $hcname) = @_;
    $self->call('DELETE', '/connections', { host_group_names => $hcname, volume_names => $vol }, undef);
}

sub expand_volume {
    my ($self, $vol, $add_bytes) = @_;
    die "expansion must be a positive multiple of 512 bytes\n" if $add_bytes <= 0 || $add_bytes % 512;
    my $cur = $self->volume($vol);
    $self->call('PATCH', '/volumes', { names => $vol }, { provisioned => $cur->{capacity} + $add_bytes });
}

# Destroy (recoverable until the array eradicates it).
sub delete_volume {
    my ($self, $vol) = @_;
    $self->call('PATCH', '/volumes', { names => $vol }, { destroyed => JSON::PP::true });
    print "FlashArray volume '$vol' destroyed - recoverable on the array until it is eradicated\n";
}

1;
