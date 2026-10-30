package PVE::SAN::Fabric::Base;

# Base class for FC switch drivers (one configured switch = one fabric, or
# one VSAN / virtual fabric of it). A driver implements:
#
#   system_info()  -> { name, model, version }
#   name_server()  -> [ { wwpn, wwnn, role, symbolic } ]   every N_Port logged in
#                     to the fabric; role 'initiator', 'target', 'both' or ''
#   zoning()       -> {
#       active_cfg     => name of the active zone set / effective cfg, or undef
#       cfgs           => { cfg name => [ zone name ] }      defined zone sets
#       zones          => { zone name => [ WWPN ] }          defined zones, aliases resolved
#       active_zones   => { zone name => [ WWPN ] }          zones in effect now
#       busy           => text when another zoning change is open on the fabric
#   }
#   apply_zones($cfg, \@zones)  create or extend the zones ({ name, members => [WWPN] }),
#                     add them to zone set $cfg and activate it; returns [ log line ]
#
# WWPNs are 16 upper-case hex digits without colons, as everywhere in pvesan.

use strict;
use warnings;

use JSON::PP;

use PVE::SAN::Array::Base;

my $json = JSON::PP->new->canonical->allow_nonref;
sub json { return $json; }

sub description { return 'FC switch'; }
sub default_port { return 443; }

# Settings this driver uses: { option => required? } (see PVE::SAN::Fabric).
sub options { return {}; }

sub new {
    my ($class, %cfg) = @_;

    die "switch address missing\n" if !$cfg{address};
    die "switch username missing\n" if !(defined($cfg{username}) && length($cfg{username}));
    die "switch password missing\n" if !defined($cfg{password}) || !length($cfg{password});
    die "switch certificate fingerprint missing - probe and confirm it first\n"
        if !$cfg{fingerprint} && !$cfg{transport};
    my $opts = $class->options;
    for my $o (sort grep { $opts->{$_} } keys %$opts) {
        die "switch setting '" . ($o =~ s/_/-/gr) . "' is required for " . $class->description . "\n"
            if !defined($cfg{$o}) || !length($cfg{$o});
    }

    my $self = bless { %cfg }, $class;
    $self->{port} //= $class->default_port;
    return $self;
}

*host_port = \&PVE::SAN::Array::Base::host_port;
*ua = \&PVE::SAN::Array::Base::ua;
*short = \&PVE::SAN::Array::Base::short;
*decode = \&PVE::SAN::Array::Base::decode;
*basic_auth = \&PVE::SAN::Array::Base::basic_auth;
*norm_wwpn = \&PVE::SAN::Array::Base::norm_wwpn;
*colon_wwpn = \&PVE::SAN::Array::Base::colon_wwpn;

# HTTPS request with the pinned certificate (see PVE::SAN::Array::Base::ua).
# Returns (code, body, { lower-case header => value }). Tests inject
# 'transport' => sub ($method, $path_and_query, $headers, $body).
sub request {
    my ($self, $method, $url_path, $headers, $body, $content_type) = @_;

    return $self->{transport}->($method, $url_path, $headers, $body) if $self->{transport};

    $content_type //= 'application/json';
    require HTTP::Request;
    my $req = HTTP::Request->new($method => "https://" . $self->host_port . $url_path);
    $req->header('Accept' => $content_type);
    if (defined($body)) {
        $req->header('Content-Type' => $content_type);
        $req->content($json->encode($body));
    }
    $req->header($_ => $headers->{$_}) for keys %{$headers // {}};
    my $res = $self->ua->request($req);
    my %h = map { lc($_) => scalar($res->header($_)) } $res->header_field_names;
    return ($res->code, $res->decoded_content // '', \%h);
}

# A value that may be one item or a list of them.
sub as_list {
    my ($v) = @_;
    return () if !defined($v);
    return ref($v) eq 'ARRAY' ? @$v : ($v);
}

# Role from a name server entry's FC-4 type/feature text.
sub role_of {
    my (@text) = @_;
    my $t = join(' ', grep { defined && !ref } @text);
    my $tgt = $t =~ /target|tgt/i;
    my $ini = $t =~ /initiator|\binit/i;
    return $tgt && $ini ? 'both' : $tgt ? 'target' : $ini ? 'initiator' : '';
}

# Zone and zone set names valid on Brocade and Cisco: a letter first, then
# letters, digits and '_', at most 64 characters.
sub valid_zone_name {
    my ($name) = @_;
    return defined($name) && $name =~ /^[A-Za-z][A-Za-z0-9_]{0,63}$/;
}

1;
