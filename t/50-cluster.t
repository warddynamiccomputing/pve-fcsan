use strict;
use warnings;

use Test::More;

use StubPVE;
use PVE::SAN::Cluster;

# Capture the pvesh command line instead of running it.
my @cmds;
{
    no warnings 'redefine';
    *PVE::SAN::Cluster::run_cmd = sub { push @cmds, $_[0]; return '{"ok":1}'; };
}

my $res = PVE::SAN::Cluster::call('pve2', 'POST', 'rescan', { lip => 1, resize => 0 });
is_deeply($cmds[-1],
    ['pvesh', 'create', '/nodes/pve2/san/rescan', '--output-format', 'json', '--lip', 1, '--resize', 0],
    'POST maps to pvesh create with path, format and sorted options');
is_deeply($res, { ok => 1 }, 'JSON output decoded');

PVE::SAN::Cluster::call('pve3', 'GET', 'devices', { all => 1 });
is_deeply($cmds[-1], ['pvesh', 'get', '/nodes/pve3/san/devices', '--output-format', 'json', '--all', 1],
    'GET maps to pvesh get');

PVE::SAN::Cluster::call('pve1', 'PUT', 'devices/3600a0b/x', undef);
is($cmds[-1]->[1], 'set', 'PUT maps to pvesh set');
is($cmds[-1]->[2], '/nodes/pve1/san/devices/3600a0b/x', 'path kept');

eval { PVE::SAN::Cluster::call('pve1', 'PATCH', 'x') };
like($@, qr/bad method PATCH/, 'unknown method dies');

{
    no warnings 'redefine';
    *PVE::SAN::Cluster::run_cmd = sub { return "\n" };
}
is(PVE::SAN::Cluster::call('pve1', 'POST', 'sync'), undef, 'empty output is undef');

done_testing();
