use strict;
use warnings;

use Test::More;

# Static checks of the GUI layout in www/pvesan.js (no JavaScript engine in
# the test environment; CI also runs node --check on the file).

open(my $fh, '<', 'www/pvesan.js') or die "www/pvesan.js: $!";
my $js = do { local $/; <$fh> };
close($fh);

open($fh, '<', 'src/PVE/API2/SAN.pm') or die "src/PVE/API2/SAN.pm: $!";
my $api = do { local $/; <$fh> };
close($fh);

sub class_body {
    my ($name) = @_;
    my ($body) = $js =~ /Ext\.define\('\Q$name\E', \{(.*?)\n\}\);/s;
    return $body;
}

# ---------------- Datacenter > Storage > SAN / Fibre Channel ----------------
{
    my $hook = class_body('PVE.san.NodeConfigHook') // '';
    like($hook, qr/\$className === 'PVE\.dc\.Config'/, 'the config hook handles the datacenter panel');
    like($hook, qr/findIndex\(item => item\.itemId === 'storage'\)/, 'it looks for Datacenter > Storage');
    like($hook, qr/splice\(idx \+ 1, 0, \{\s*xtype: 'pveSanDcPanel'.*?groups: \['storage'\]/s,
        'the SAN entry goes right after Storage, as its sub-entry');
    like($hook, qr/caps\.nodes\['Sys\.Audit'\]/, 'shown only to users who may read node SAN data');
    like($hook, qr/try \{.*\} catch \(err\)/s, 'a failure only drops the SAN entry');

    my $dc = class_body('PVE.san.DcPanel') // '';
    my @tabs = $dc =~ /xtype: '(pveSan\w+)'/g;
    is_deeply(\@tabs, [ qw(pveSanDatastoreGrid pveSanSnapshotGrid pveSanReplicationPanel pveSanArrayGrid
        pveSanFabricGrid pveSanClusterLunGrid pveSanClusterGrid pveSanClusterGrid pveSanClusterGrid pveSanClusterGrid) ],
        'datacenter tabs: cluster-wide ones, then all nodes at once');
    like($dc, qr/me\.nodename \|\| Proxmox\.NodeName/, 'cluster actions go through the node serving the GUI');

    # every per-node path the datacenter view fans out to is a GET endpoint of the API
    my @paths = ($dc =~ /sanPath: '([\w-]+)'/g, 'devices');
    for my $p (@paths) {
        like($api, qr/path => '\Q$p\E',\s*method => 'GET'/, "GET /nodes/{node}/san/$p exists");
    }
}

# ---------------- Node > Disks keeps the node's own tabs ----------------
{
    my $node = class_body('PVE.san.Panel') // '';
    my @tabs = $node =~ /xtype: '(pveSan\w+)'/g;
    is_deeply(\@tabs, [ qw(pveSanDeviceGrid pveSanPathGrid pveSanAdapterGrid pveSanIOStatsGrid pveSanHealthGrid) ],
        'node panel: only node-local tabs');
    like(class_body('PVE.san.NodeConfigHook') // '', qr/\$className === 'PVE\.node\.Config'.*?groups: \['storage'\]/s,
        'node panel still under Disks');
}

# ---------------- asking every node ----------------
{
    my ($every) = $js =~ /fromEveryNode: function\(path, waitTarget, done\) \{(.*?)\n    \},/s;
    ok(defined($every), 'fromEveryNode found');
    $every //= '';
    unlike($every, qr/^\s*callback:/m, 'no API2Request callback (Proxmox runs it before success, rows would be lost)');
    like($every, qr/success: r => \{ results\.push.*?one\(\); \}/s, 'a node that answers is counted after its rows');
    like($every, qr/failure: r => \{ missing\.push.*?one\(\); \}/s, 'a node that fails is counted and named');
    like($every, qr/status !== 'online'.*?missing\.push/s, 'offline nodes are named, not asked');
    like($every, qr/encodeURIComponent\(n\.node\)/, 'node names are URL-encoded');

    my ($missing) = $js =~ /showMissing: function\(grid, missing\) \{(.*?)\n    \},/s;
    like($missing // '', qr/Ext\.htmlEncode\(m\.node\)/, 'node names in the status bar are HTML-encoded');

    my ($np) = $js =~ /renderNodePaths: function\(p\) \{(.*?)\n    \},/s;
    like($np // '', qr/Number\(p\.total\).*Number\(p\.active\)/s, 'per-node path counts are rendered as numbers only');
    like(class_body('PVE.san.ClusterLunGrid') // '', qr/header: Ext\.htmlEncode\(n\)/, 'node column headers are HTML-encoded');
}

done_testing();
