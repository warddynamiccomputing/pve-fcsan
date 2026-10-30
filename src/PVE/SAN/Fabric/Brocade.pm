package PVE::SAN::Fabric::Brocade;

# Driver for Brocade (Broadcom) FC switches through the FOS REST API
# (Fabric OS 8.2.1 or later, HTTPS).
#
# Session: POST /rest/login with Basic auth returns the session in the
# Authorization response header ("Custom_Basic ..."), sent on every later
# request; POST /rest/logout ends it (FOS allows few REST sessions per user).
# Data is YANG JSON (application/yang-data+json), wrapped as
# { "Response": { <container>: ... } }; errors as { "errors": { "error": ... } }.
# A virtual fabric is addressed with ?vf-id=<n> on every request.
#
# Zoning (brocade-zone module), as in the FOS REST API reference and
# Broadcom's Ansible collection (brocade.fos, zoning_*):
#   GET   running/brocade-zone/defined-configuration     cfg, zone, alias lists
#   GET   running/brocade-zone/effective-configuration   cfg-name, checksum,
#         transaction-token, enabled-zone
#   POST  .../defined-configuration/zone/zone-name/<z>   {member-entry: {entry-name: [..]}}
#         creates the zone, or adds the members to an existing one
#   POST  .../defined-configuration/cfg/cfg-name/<c>     {member-zone: {zone-name: [..]}}
#         creates the cfg, or adds the zones to an existing one
#   PATCH .../effective-configuration/cfg-name/<c>       {checksum}  save and enable
#   PATCH .../effective-configuration/cfg-action/4       {checksum}  abort the transaction
# Name server: GET running/brocade-name-server/fibrechannel-name-server.

use strict;
use warnings;

use base qw(PVE::SAN::Fabric::Base);

sub description { return 'Brocade FOS'; }
sub options { return { vf_id => 0 }; }

my $CT = 'application/yang-data+json';
my $ZONE = '/rest/running/brocade-zone';

*as_list = \&PVE::SAN::Fabric::Base::as_list;
*norm_wwpn = \&PVE::SAN::Fabric::Base::norm_wwpn;
*colon_wwpn = \&PVE::SAN::Fabric::Base::colon_wwpn;
*short = \&PVE::SAN::Fabric::Base::short;

sub error_text {
    my ($content) = @_;
    my $d = PVE::SAN::Fabric::Base::decode($content);
    if (ref($d) eq 'HASH' && ref($d->{errors}) eq 'HASH') {
        my @msg = map { $_->{'error-message'} // $_->{'error-tag'} // () } grep { ref($_) eq 'HASH' } as_list($d->{errors}->{error});
        return join('; ', @msg) if @msg;
    }
    return short($content);
}

sub url {
    my ($self, $path) = @_;
    return $path . (defined($self->{vf_id}) && length($self->{vf_id}) ? "?vf-id=$self->{vf_id}" : '');
}

sub login {
    my ($self) = @_;
    my ($code, $content, $h) = $self->request('POST', '/rest/login', { Authorization => $self->basic_auth }, undef, $CT);
    die "switch login to $self->{address} failed (HTTP $code): " . error_text($content) . "\n" if $code != 200;
    $self->{session} = $h->{authorization} // die "switch login: no session in the reply\n";
}

sub logout {
    my ($self) = @_;
    return if !$self->{session};
    eval { $self->request('POST', '/rest/logout', { Authorization => $self->{session} }, undef, $CT) };
    delete $self->{session};
}

# Run $code inside one REST session; always log out.
sub session {
    my ($self, $code) = @_;
    my $own = !$self->{session};
    $self->login() if $own;
    my @res = eval { $code->() };
    my $err = $@;
    $self->logout() if $own;
    die $err if $err;
    return wantarray ? @res : $res[0];
}

# One call; returns the decoded "Response" container (or undef).
sub call {
    my ($self, $method, $path, $body) = @_;
    my ($code, $content) = $self->request($method, $self->url($path), { Authorization => $self->{session} }, $body, $CT);
    die "switch $method $path failed (HTTP $code): " . error_text($content) . "\n" if $code < 200 || $code >= 300;
    my $d = PVE::SAN::Fabric::Base::decode($content);
    return ref($d) eq 'HASH' ? $d->{Response} : undef;
}

sub system_info {
    my ($self) = @_;
    return $self->session(sub {
        my $r = $self->call('GET', '/rest/running/brocade-fabric/fabric-switch') // {};
        # every switch of the fabric; the one we talk to is not marked, so name the principal or the first
        my @sw = grep { ref($_) eq 'HASH' } as_list($r->{'fabric-switch'});
        my ($s) = ((grep { $_->{'principal'} } @sw), @sw);
        $s //= {};
        return {
            name => $s->{'switch-user-friendly-name'} // $s->{name},
            model => 'Brocade' . (defined($s->{'model'}) ? " $s->{'model'}" : ''),
            version => $s->{'firmware-version'},
            switches => scalar(@sw),
        };
    });
}

sub name_server {
    my ($self) = @_;
    return $self->session(sub {
        my $r = $self->call('GET', '/rest/running/brocade-name-server/fibrechannel-name-server') // {};
        return [ map {
            {
                wwpn => norm_wwpn($_->{'port-name'}),
                wwnn => norm_wwpn($_->{'node-name'}),
                role => PVE::SAN::Fabric::Base::role_of($_->{'fc4-features'}, $_->{'name-server-device-type'}),
                symbolic => join(' ', grep { defined && length } $_->{'node-symbolic-name'}, $_->{'port-symbolic-name'}),
            }
        } grep { ref($_) eq 'HASH' && norm_wwpn($_->{'port-name'}) } as_list($r->{'fibrechannel-name-server'}) ];
    });
}

# Zone members: WWPNs, aliases of WWPNs; "domain,port" members are skipped.
sub resolve {
    my ($entries, $aliases) = @_;
    my %w;
    for my $e (@$entries) {
        if (defined(my $x = norm_wwpn($e))) { $w{$x} = 1; next; }
        $w{$_} = 1 for @{$aliases->{$e} // []};
    }
    return [ sort keys %w ];
}

sub zone_entries {
    my ($z) = @_;
    my $m = ref($z->{'member-entry'}) eq 'HASH' ? $z->{'member-entry'} : {};
    return [ as_list($m->{'entry-name'}), as_list($m->{'principal-entry-name'}) ];
}

sub effective {
    my ($self) = @_;
    my $r = $self->call('GET', "$ZONE/effective-configuration") // {};
    return ref($r->{'effective-configuration'}) eq 'HASH' ? $r->{'effective-configuration'} : {};
}

sub zoning {
    my ($self) = @_;
    return $self->session(sub {
        my $d = ($self->call('GET', "$ZONE/defined-configuration") // {})->{'defined-configuration'} // {};
        my $eff = $self->effective();

        my %alias;
        for my $a (grep { ref($_) eq 'HASH' } as_list($d->{alias})) {
            my $m = ref($a->{'member-entry'}) eq 'HASH' ? $a->{'member-entry'} : {};
            $alias{$a->{'alias-name'}} = [ grep { defined } map { norm_wwpn($_) } as_list($m->{'alias-entry-name'}) ];
        }
        my %zones = map { ($_->{'zone-name'} => resolve(zone_entries($_), \%alias)) }
            grep { ref($_) eq 'HASH' && defined($_->{'zone-name'}) } as_list($d->{zone});
        my %cfgs = map {
            my $m = ref($_->{'member-zone'}) eq 'HASH' ? $_->{'member-zone'} : {};
            ($_->{'cfg-name'} => [ as_list($m->{'zone-name'}) ])
        } grep { ref($_) eq 'HASH' && defined($_->{'cfg-name'}) } as_list($d->{cfg});
        my %active = map { ($_->{'zone-name'} => resolve(zone_entries($_), \%alias)) }
            grep { ref($_) eq 'HASH' && defined($_->{'zone-name'}) } as_list($eff->{'enabled-zone'});

        my $token = $eff->{'transaction-token'};
        return {
            active_cfg => (defined($eff->{'cfg-name'}) && length($eff->{'cfg-name'})) ? $eff->{'cfg-name'} : undef,
            cfgs => \%cfgs,
            zones => \%zones,
            active_zones => \%active,
            busy => ($token && $token ne '0') ? "a zoning transaction is open on the fabric (token $token)" : undef,
        };
    });
}

# $zones: [ { name, members => [WWPN], add_to_cfg => 0|1 } ]
sub apply_zones {
    my ($self, $cfg, $zones) = @_;
    my @log;
    return $self->session(sub {
        my $ok = eval {
            for my $z (grep { @{$_->{members}} } @$zones) {
                $self->call('POST', "$ZONE/defined-configuration/zone/zone-name/$z->{name}",
                    { 'member-entry' => { 'entry-name' => [ map { colon_wwpn($_) } @{$z->{members}} ] } });
                push @log, "zone $z->{name}: " . join(' ', map { colon_wwpn($_) } @{$z->{members}});
            }
            my @add = map { $_->{name} } grep { $_->{add_to_cfg} } @$zones;
            if (@add) {
                $self->call('POST', "$ZONE/defined-configuration/cfg/cfg-name/$cfg", { 'member-zone' => { 'zone-name' => \@add } });
                push @log, "cfg $cfg: added " . join(' ', @add);
            }
            my $cs = $self->effective()->{checksum} // die "no zoning checksum from the switch\n";
            $self->call('PATCH', "$ZONE/effective-configuration/cfg-name/$cfg", { checksum => $cs });
            push @log, "cfg $cfg saved and enabled";
            1;
        };
        if (!$ok) {
            my $err = $@;
            eval {
                my $cs = $self->effective()->{checksum};
                $self->call('PATCH', "$ZONE/effective-configuration/cfg-action/4", { checksum => $cs });
            };
            die $err . ($@ ? '' : "zoning transaction aborted, nothing was changed on the fabric\n");
        }
        return \@log;
    });
}

1;
