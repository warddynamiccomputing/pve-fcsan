use strict;
use warnings;

use Test::More;

use PVE::SAN::Util qw(fmt_wwn normalize_wwid parse_wwid_list valid_alias);

is(fmt_wwn('0x21000024ff3d5e10'), '21:00:00:24:ff:3d:5e:10', 'WWN with 0x prefix');
is(fmt_wwn('0x0'), undef, 'zero WWN is undef');
is(fmt_wwn('0xffffffffffffffff'), undef, 'all-ones WWN (link down fabric) is undef');
is(fmt_wwn('0x24ff3d5e10'), '00:00:00:24:ff:3d:5e:10', 'short WWN is zero padded');
is(fmt_wwn(undef), undef, 'undef WWN');

is(normalize_wwid('naa.600A098038303053453F463045727A41'), '3600a098038303053453f463045727a41', 'naa form');
is(normalize_wwid('eui.0025385b71b07e2f'), '20025385b71b07e2f', 'eui form');
is(normalize_wwid('/dev/mapper/3600a098038303053453f463045727a41'), '3600a098038303053453f463045727a41', 'mapper path');
is(normalize_wwid('3600A098038303053453F463045727A41'), '3600a098038303053453f463045727a41', 'hex lowercased');
is(normalize_wwid('bad wwid'), undef, 'spaces rejected');
is(normalize_wwid('x'), undef, 'too short rejected');

is_deeply(parse_wwid_list('3600a0980383030534, naa.600a0980383030535;3600a0980383030534'),
    ['3600a0980383030534', '3600a0980383030535'], 'list parsing dedups and normalizes');
eval { parse_wwid_list('3600a0980383030534,bad id') };
like($@, qr/invalid WWID/, 'invalid list entry dies');

ok(valid_alias('ds1-00'), 'plain alias');
ok(!valid_alias('1ds'), 'alias must start with a letter');
ok(!valid_alias('a/b'), 'no slashes');

done_testing();
