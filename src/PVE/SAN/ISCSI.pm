package PVE::SAN::ISCSI;

# Software iSCSI (open-iscsi) on this node: the initiator name the arrays
# register, the sessions, and logging in to array target portals.
#
# Logins are idempotent: targets this node already has a session to are left
# alone. Every portal logged in to is recorded in the cluster-wide pvesan
# config (iscsi.portals), and node records get node.startup=automatic, so
# open-iscsi logs in again at boot; pvesan-sync.service (pvesan
# iscsi-restore) also logs in to recorded portals a node has no session to,
# e.g. on a node that joined the cluster later.

use strict;
use warnings;

use PVE::SAN::Util qw(run_cmd sysfs_path);

our $INITIATOR_FILE = '/etc/iscsi/initiatorname.iscsi';

# Read through sysfs_path() so tests can point it at a fixture tree.
sub initiator {
    open(my $fh, '<', sysfs_path($INITIATOR_FILE)) or return undef;
    my $iqn;
    while (my $line = <$fh>) {
        next if $line =~ /^\s*#/;
        if ($line =~ /^\s*InitiatorName\s*=\s*(\S+)/) {
            $iqn = lc($1);
            last;
        }
    }
    close($fh);
    return $iqn;
}

# "10.0.0.5", "10.0.0.5:3260", "[fd00::5]:3260", "fd00::5" -> "addr:port"
# (IPv6 in brackets). Dies on anything else.
sub norm_portal {
    my ($p) = @_;
    $p //= '';
    $p =~ s/^\s+|\s+$//g;
    $p =~ s/,\d+$//; # target portal group tag from discovery output
    my ($addr, $port);
    if ($p =~ /^\[([0-9A-Fa-f:.]+)\](?::(\d+))?$/) {
        ($addr, $port) = ("[$1]", $2);
    } elsif ($p =~ /^([0-9A-Fa-f]*:[0-9A-Fa-f:.]*:[0-9A-Fa-f:.]*)$/) {
        $addr = "[$1]"; # bare IPv6 address, no port
    } elsif ($p =~ /^([A-Za-z0-9][A-Za-z0-9.-]*)(?::(\d+))?$/) {
        ($addr, $port) = ($1, $2);
    } else {
        die "invalid iSCSI portal '$p' (address or address:port)\n";
    }
    $port //= 3260;
    die "invalid iSCSI port $port\n" if $port < 1 || $port > 65535;
    return "$addr:$port";
}

# "tcp: [3] 10.0.0.5:3260,1 iqn.2010-06.com.example:target (non-flash)"
sub parse_sessions {
    my ($out) = @_;
    my @res;
    for my $line (split(/\n/, $out // '')) {
        my ($sid, $portal, $target) = $line =~ /^\S+:\s+\[(\d+)\]\s+(\S+?),\d+\s+(\S+)/ or next;
        push @res, { sid => int($sid), portal => norm_portal($portal), target => lc($target) };
    }
    return \@res;
}

# iscsiadm exits 21 ("no objects found") without sessions.
sub sessions {
    return [] if !iscsiadm_present();
    return parse_sessions(run_cmd(['iscsiadm', '-m', 'session'], noerr => 1));
}

# "10.0.0.5:3260,1 iqn.2010-06.com.example:target"
sub parse_discovery {
    my ($out) = @_;
    my @res;
    for my $line (split(/\n/, $out // '')) {
        my ($portal, $target) = $line =~ /^(\S+?),\d+\s+(\S+)/ or next;
        push @res, { portal => norm_portal($portal), target => $target };
    }
    return \@res;
}

sub iscsiadm_present {
    return grep { -x "$_/iscsiadm" } qw(/usr/sbin /sbin /usr/bin);
}

sub discover {
    my ($portal) = @_;
    my $out = run_cmd(['iscsiadm', '-m', 'discovery', '-t', 'sendtargets', '-p', $portal], timeout => 60);
    return parse_discovery($out);
}

# Discover targets on $portal and log in to every portal/target pair it
# returns ($target limits it to one target). Returns what was done.
sub login {
    my (%p) = @_;

    die "open-iscsi is not installed on this node (apt install open-iscsi)\n" if !iscsiadm_present();
    my $portal = norm_portal($p{portal});
    my $want = defined($p{target}) && length($p{target}) ? lc($p{target}) : undef;

    print "discovering targets on $portal\n";
    my @found = grep { !$want || lc($_->{target}) eq $want } @{discover($portal)};
    die "portal $portal offers no target" . ($want ? " named $want" : '') . "\n" if !@found;

    my %have = map { ("$_->{target} $_->{portal}" => 1) } @{sessions()};
    my (@new, @already, @failed);
    for my $f (@found) {
        my @node = ('iscsiadm', '-m', 'node', '-T', $f->{target}, '-p', $f->{portal});
        eval { run_cmd([@node, '--op', 'update', '-n', 'node.startup', '-v', 'automatic']) };
        warn "setting node.startup for $f->{target} on $f->{portal} failed: $@" if $@;
        if ($have{lc($f->{target}) . " $f->{portal}"}) {
            push @already, "$f->{portal} $f->{target}";
            next;
        }
        print "logging in to $f->{target} on $f->{portal}\n";
        eval { run_cmd([@node, '--login'], timeout => 150) };
        if (my $err = $@) {
            chomp($err);
            print "login to $f->{target} on $f->{portal} failed: $err\n";
            push @failed, "$f->{portal} $f->{target}";
        } else {
            push @new, "$f->{portal} $f->{target}";
        }
    }
    die "no iSCSI session to portal $portal could be established\n" if !@new && !@already;

    record_portal($portal, $want, $p{array}) if $p{record} // 1;
    my %targets = map { ($_->{target} => 1) } @found;
    return {
        portal => $portal,
        targets => join(',', sort keys %targets),
        logged_in => \@new,
        already => \@already,
        failed => \@failed,
    };
}

sub record_portal {
    my ($portal, $target, $array) = @_;
    require PVE::SAN::Config;
    PVE::SAN::Config::update(sub {
        my ($cfg) = @_;
        my $r = $cfg->{iscsi}->{portals}->{$portal} //= {};
        if ($target) { $r->{target} = $target; } else { delete $r->{target}; }
        $r->{array} = $array if $array;
    });
}

sub recorded_portals {
    require PVE::SAN::Config;
    return (PVE::SAN::Config::load()->{iscsi} // {})->{portals} // {};
}

# Log in to every recorded portal this node has no session to. Failures are
# reported, not fatal: a missing portal must not stop the rest of the boot.
sub restore {
    my $portals = recorded_portals();
    return { portals => 0 } if !%$portals;
    if (!iscsiadm_present()) {
        print "iSCSI portals are recorded, but open-iscsi is not installed on this node\n";
        return { portals => scalar(keys %$portals), failed => [ sort keys %$portals ] };
    }
    my $sessions = sessions();
    my (@ok, @failed);
    for my $portal (sort keys %$portals) {
        my $t = $portals->{$portal}->{target};
        if (grep { $_->{portal} eq $portal && (!$t || $_->{target} eq $t) } @$sessions) {
            push @ok, $portal;
            next;
        }
        eval { login(portal => $portal, target => $t, record => 0) };
        if (my $err = $@) {
            print "WARNING: iSCSI portal $portal: $err";
            push @failed, $portal;
        } else {
            push @ok, $portal;
        }
    }
    return { portals => scalar(keys %$portals), ok => \@ok, failed => \@failed };
}

# What the node API reports.
sub status {
    my $portals = recorded_portals();
    return {
        initiator => initiator(),
        installed => iscsiadm_present() ? 1 : 0,
        sessions => sessions(),
        portals => [ map { { portal => $_, %{$portals->{$_}} } } sort keys %$portals ],
    };
}

1;
