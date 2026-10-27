package PVE::SAN::Config;

# Cluster-wide pvesan state, kept on pmxcfs so every node renders the same
# multipath aliases and policies.
#
# {
#   "version": 1,
#   "devices":    { "<wwid>": { "alias": "...", "policy": "...", "detached": 0,
#                               "datastore": "<storeid>" } },
#   "datastores": { "<storeid>": { "label": "...", "created": <epoch> } }
# }

use strict;
use warnings;

use JSON::PP;

use PVE::Cluster;
use PVE::Tools;

our $DIR = '/etc/pve/pvesan';
our $FILE = "$DIR/config.json";

sub empty {
    return { version => 1, devices => {}, datastores => {} };
}

sub load {
    return empty() if ! -f $FILE;
    my $raw = PVE::Tools::file_get_contents($FILE);
    my $cfg = eval { JSON::PP->new->decode($raw) };
    die "unable to parse $FILE - $@" if $@;
    $cfg->{devices} //= {};
    $cfg->{datastores} //= {};
    return $cfg;
}

sub save {
    my ($cfg) = @_;
    mkdir($DIR) if ! -d $DIR;
    PVE::Tools::file_set_contents($FILE, JSON::PP->new->canonical->pretty->encode($cfg));
}

# Read-modify-write under the cluster-wide 'pvesan' lock. $code gets the
# config, may change it in place and returns the result for the caller.
sub update {
    my ($code) = @_;

    my $res = PVE::Cluster::cfs_lock_domain('pvesan', 30, sub {
        my $cfg = load();
        my $r = $code->($cfg);
        save($cfg);
        return $r;
    });
    die $@ if $@;
    return $res;
}

sub alias_owner {
    my ($cfg, $alias) = @_;
    for my $wwid (keys %{$cfg->{devices}}) {
        return $wwid if ($cfg->{devices}->{$wwid}->{alias} // '') eq $alias;
    }
    return undef;
}

1;
