package PVE::SAN::Cluster;

# Fan-out of node-local steps over the cluster. Every call goes through
# pvesh, so the local node takes the same code path as remote ones and the
# API's own node proxying does the transport.

use strict;
use warnings;

use JSON::PP;

use PVE::Cluster;
use PVE::INotify;
use PVE::Tools;

use PVE::SAN::Util qw(run_cmd);

sub local_node {
    return PVE::INotify::nodename();
}

# Online cluster members, optionally limited to a storage's 'nodes' list.
sub nodes {
    my (%opts) = @_;

    my $members = PVE::Cluster::get_members() // {};
    my @nodes = keys %$members
        ? grep { $members->{$_}->{online} } keys %$members
        : (local_node());

    if (my $restrict = $opts{restrict}) {
        @nodes = grep { $restrict->{$_} } @nodes;
    }
    return [ sort @nodes ];
}

# All configured members, online or not.
sub all_nodes {
    my $members = PVE::Cluster::get_members() // {};
    return keys %$members ? [ sort keys %$members ] : [ local_node() ];
}

sub offline_nodes {
    my (%opts) = @_;
    my $online = { map { $_ => 1 } @{nodes()} };
    my @res = grep { !$online->{$_} } @{all_nodes()};
    @res = grep { $opts{restrict}->{$_} } @res if $opts{restrict};
    return \@res;
}

my $VERB = { GET => 'get', POST => 'create', PUT => 'set', DELETE => 'delete' };

sub call {
    my ($node, $method, $path, $params) = @_;

    my $verb = $VERB->{$method} // die "bad method $method\n";
    my @cmd = ('pvesh', $verb, "/nodes/$node/san/$path", '--output-format', 'json');
    for my $k (sort keys %{$params // {}}) {
        push @cmd, "--$k", $params->{$k};
    }
    my $out = run_cmd(\@cmd, timeout => 300);
    return undef if !defined($out) || $out !~ /\S/;
    return JSON::PP->new->allow_nonref->decode($out);
}

# Run one step on every node, printing progress into the task log. Dies
# after trying all nodes if any failed, naming each failure.
sub on_nodes {
    my ($nodes, $desc, $method, $path, $params) = @_;

    my ($res, @errors) = ({});
    for my $node (@$nodes) {
        print "[$node] $desc\n";
        my $r = eval { call($node, $method, $path, $params) };
        if (my $err = $@) {
            chomp($err);
            print "[$node] FAILED: $err\n";
            push @errors, "$node: $err";
        } else {
            $res->{$node} = $r;
        }
    }
    die "$desc failed on " . scalar(@errors) . " node(s):\n" . join("\n", @errors) . "\n" if @errors;
    return $res;
}

# Guests whose config references a storage. Reads pmxcfs directly so guests
# on every node (including offline ones) are found.
sub guest_refs {
    my ($storeid) = @_;

    my @res;
    for my $file (glob('/etc/pve/nodes/*/qemu-server/*.conf'), glob('/etc/pve/nodes/*/lxc/*.conf')) {
        my ($node, $kind, $vmid) = $file =~ m{^/etc/pve/nodes/([^/]+)/(qemu-server|lxc)/(\d+)\.conf$} or next;
        my $raw = PVE::Tools::file_get_contents($file);
        my $count = () = $raw =~ /^[a-z][a-z0-9_]*:\s+\Q$storeid\E:/mg;
        push @res, { vmid => $vmid, node => $node, type => ($kind eq 'lxc' ? 'lxc' : 'qemu'), file => $file, refs => $count }
            if $count;
    }
    return \@res;
}

# vmid => { status, node } for all guests in the cluster
sub guest_status {
    my $out = run_cmd(['pvesh', 'get', '/cluster/resources', '--type', 'vm', '--output-format', 'json']);
    my $list = JSON::PP->new->decode($out);
    return { map { $_->{vmid} => $_ } @$list };
}

sub running_guests {
    my ($refs, %opts) = @_;
    my $status = guest_status();
    my @running;
    for my $r (@$refs) {
        my $s = $status->{$r->{vmid}} // next;
        next if ($s->{status} // '') ne 'running';
        next if $opts{nodes} && !grep { $_ eq $s->{node} } @{$opts{nodes}};
        push @running, "$r->{vmid} ($s->{node})";
    }
    return \@running;
}

1;
