package PVE::SAN::Fabric::Cisco;

# Driver for Cisco MDS 9000 switches through NX-API (NX-OS 8.x or later,
# "feature nxapi", HTTPS). One configured switch = one VSAN of a fabric.
#
# NX-API "ins_api": POST /ins with Basic auth and
#   { ins_api: { version, type: cli_show | cli_show_ascii | cli_conf, chunk: "0",
#                sid, input: "cmd1 ;cmd2", output_format: "json" } }
# The reply is { ins_api: { outputs: { output: <one or a list> } } }, each
# output { input, code, msg, body } (code "200" = success; clierror on failure).
#
# Commands used (MDS 9000 NX-OS Fabric Configuration Guide, zoning chapter):
#   show version
#   show fcns database detail vsan <v>      name server
#   show zone vsan <v>                      defined zones and their members
#   show zoneset vsan <v>                   defined zone sets (zone names)
#   show zoneset active vsan <v>            the active zone set
#   show zone status vsan <v>               basic or enhanced mode, open session
#   zone name <z> vsan <v> / member pwwn <wwpn>
#   zoneset name <s> vsan <v> / member <z>
#   zoneset activate name <s> vsan <v>
#   zone commit vsan <v>                    enhanced mode: release the session lock
#   no zone commit vsan <v>                 enhanced mode: discard the changes
# The JSON field names of show output differ between NX-OS releases, so the
# parsers below walk the reply for WWPN-valued fields instead of fixed paths.

use strict;
use warnings;

use base qw(PVE::SAN::Fabric::Base);

sub description { return 'Cisco MDS'; }
sub options { return { vsan => 1 }; }

*as_list = \&PVE::SAN::Fabric::Base::as_list;
*norm_wwpn = \&PVE::SAN::Fabric::Base::norm_wwpn;
*colon_wwpn = \&PVE::SAN::Fabric::Base::colon_wwpn;
*short = \&PVE::SAN::Fabric::Base::short;

# Run commands; returns the list of output bodies, one per command.
sub run {
    my ($self, $type, @cmds) = @_;
    my $body = { ins_api => {
        version => '1.0', type => $type, chunk => '0', sid => '1',
        input => join(' ;', @cmds), output_format => 'json',
    } };
    my ($code, $content) = $self->request('POST', '/ins', { Authorization => $self->basic_auth }, $body);
    die "switch $self->{address}: NX-API request failed (HTTP $code): " . short($content) . "\n"
        if $code == 401 || $code == 403 || $code >= 500 && $content !~ /ins_api/;
    my $d = PVE::SAN::Fabric::Base::decode($content);
    die "switch $self->{address}: invalid NX-API reply (HTTP $code): " . short($content) . "\n"
        if ref($d) ne 'HASH' || ref($d->{ins_api}) ne 'HASH';
    my @out = as_list(($d->{ins_api}->{outputs} // {})->{output});
    for my $i (0 .. $#out) {
        my $o = $out[$i];
        next if ref($o) eq 'HASH' && ($o->{code} // '') eq '200';
        my $what = ref($o) eq 'HASH' ? ($o->{input} // $cmds[$i]) : $cmds[$i];
        my $err = ref($o) eq 'HASH' ? join(': ', grep { defined && !ref && length } $o->{msg}, $o->{clierror}) : 'no output';
        die "switch $self->{address}: '" . ($what // '?') . "' failed: $err\n";
    }
    return map { ref($_) eq 'HASH' ? $_->{body} : undef } @out;
}

sub show {
    my ($self, $cmd) = @_;
    my ($body) = $self->run('cli_show', $cmd);
    return $body;
}

# Every hash in a reply, depth first.
sub hashes {
    my ($x, $out) = @_;
    $out //= [];
    if (ref($x) eq 'HASH') {
        push @$out, $x;
        hashes($_, $out) for values %$x;
    } elsif (ref($x) eq 'ARRAY') {
        hashes($_, $out) for @$x;
    }
    return $out;
}

# WWPNs anywhere below $x, from colon-separated values ("21:00:00:...").
sub wwpns_in {
    my ($x) = @_;
    my %w;
    for my $h (@{hashes($x)}) {
        for my $k (keys %$h) {
            next if ref($h->{$k}) || $k =~ /node|nwwn|wwnn/i;
            my $v = $h->{$k} // '';
            $w{norm_wwpn($v)} = 1 if $v =~ /^\s*(?:[0-9A-Fa-f]{2}:){7}[0-9A-Fa-f]{2}\s*$/;
        }
    }
    return [ sort keys %w ];
}

sub system_info {
    my ($self) = @_;
    my $v = $self->show('show version') // {};
    return {
        name => $v->{host_name},
        model => 'Cisco ' . ($v->{chassis_id} // 'MDS'),
        version => $v->{sys_ver_str} // $v->{kickstart_ver_str},
    };
}

sub name_server {
    my ($self) = @_;
    my $body = $self->show("show fcns database detail vsan $self->{vsan}");
    my (@res, %seen);
    for my $h (@{hashes($body)}) {
        my ($pk) = grep { /^(?:pwwn|port_name|port_wwn)$/i } keys %$h;
        next if !$pk;
        my $w = norm_wwpn($h->{$pk}) // next;
        next if $seen{$w}++;
        my ($nk) = grep { /^(?:nwwn|node_name|node_wwn)$/i } keys %$h;
        my @fc4 = map { $h->{$_} } grep { /fc4/i } keys %$h;
        my @sym = map { $h->{$_} } grep { /symbolic|vendor/i } sort keys %$h;
        push @res, {
            wwpn => $w,
            wwnn => $nk ? norm_wwpn($h->{$nk}) : undef,
            role => PVE::SAN::Fabric::Base::role_of(@fc4),
            symbolic => join(' ', grep { defined && !ref && length } @sym),
        };
    }
    return \@res;
}

# { zone name => [WWPN] } from "show zone" / "show zoneset active" output
sub zones_in {
    my ($body) = @_;
    my %z;
    for my $h (@{hashes($body)}) {
        next if !defined($h->{zone_name}) || ref($h->{zone_name});
        $z{$h->{zone_name}} = wwpns_in($h);
    }
    return \%z;
}

sub zoning {
    my ($self) = @_;
    my $v = $self->{vsan};
    my ($zones, $sets, $active, $status) = $self->run('cli_show',
        "show zone vsan $v", "show zoneset vsan $v", "show zoneset active vsan $v", "show zone status vsan $v");

    my %cfgs;
    for my $h (@{hashes($sets)}) {
        next if !defined($h->{zoneset_name}) || ref($h->{zoneset_name});
        $cfgs{$h->{zoneset_name}} = [ sort keys %{{ map { ($_->{zone_name} => 1) }
            grep { defined($_->{zone_name}) && !ref($_->{zone_name}) } @{hashes($h)} }} ];
    }
    my ($act) = grep { defined($_->{zoneset_name}) && !ref($_->{zoneset_name}) } @{hashes($active)};

    my ($mode, $session);
    for my $h (@{hashes($status)}) {
        for my $k (keys %$h) {
            next if ref($h->{$k});
            $mode = lc($h->{$k}) if !$mode && ($h->{$k} // '') =~ /^\s*(?:enhanced|basic)\s*$/i;
            $session = $h->{$k} if $k =~ /session/i && !defined($session);
        }
    }
    $mode //= 'basic';
    $mode =~ s/\s//g;
    $self->{zone_mode} = $mode;
    my $busy = $mode eq 'enhanced' && defined($session) && $session !~ /^\s*(?:none|-)?\s*$/i
        ? "a zoning session is open on VSAN $v ($session)" : undef;

    return {
        active_cfg => $act ? $act->{zoneset_name} : undef,
        cfgs => \%cfgs,
        zones => zones_in($zones),
        active_zones => $act ? zones_in($active) : {},
        busy => $busy,
        mode => $mode,
    };
}

# $zones: [ { name, members => [WWPN], add_to_cfg => 0|1 } ]
sub apply_zones {
    my ($self, $cfg, $zones) = @_;
    my $v = $self->{vsan};
    $self->zoning() if !$self->{zone_mode};
    my $enhanced = $self->{zone_mode} eq 'enhanced';

    my (@cmds, @log);
    for my $z (grep { @{$_->{members}} } @$zones) {
        push @cmds, "zone name $z->{name} vsan $v", map { "member pwwn " . colon_wwpn($_) } @{$z->{members}};
        push @log, "zone $z->{name}: " . join(' ', map { colon_wwpn($_) } @{$z->{members}});
    }
    my @add = map { $_->{name} } grep { $_->{add_to_cfg} } @$zones;
    if (@add) {
        push @cmds, "zoneset name $cfg vsan $v", map { "member $_" } @add;
        push @log, "zone set $cfg: added @add";
    }
    push @cmds, "zoneset activate name $cfg vsan $v";
    push @cmds, "zone commit vsan $v" if $enhanced;

    eval { $self->run('cli_conf', @cmds) };
    if (my $err = $@) {
        if ($enhanced) {
            eval { $self->run('cli_conf', "no zone commit vsan $v") };
            die $err . ($@ ? '' : "zoning changes discarded, nothing was changed on the fabric\n");
        }
        die $err . "basic zoning mode: zones defined before the error stay defined but are not active\n";
    }
    push @log, "zone set $cfg activated on VSAN $v" . ($enhanced ? ' and committed' : '');
    eval { $self->run('cli_show_ascii', 'copy running-config startup-config') };
    push @log, $@ ? "warning: saving the running configuration failed: $@" : 'running configuration saved';
    return \@log;
}

1;
