use strict;
use warnings;

use Test::More;

use PVE::SAN::LVM;

my $json = <<'EOF';
  {
      "report": [
          {
              "pv": [
                  {"pv_name":"/dev/mapper/ds1", "vg_name":"san_ds1", "pv_size":"1069547520", "pv_free":"536870912", "pv_uuid":"abc"},
                  {"pv_name":"/dev/sdz", "vg_name":"", "pv_size":"10737418240", "pv_free":"10737418240", "pv_uuid":"def"}
              ]
          }
      ]
  }
EOF

my $rows = PVE::SAN::LVM::parse_report($json, 'pv');
is(scalar(@$rows), 2, 'two PVs');
is($rows->[0]->{pv_size}, 1069547520, 'size numified');
is($rows->[0]->{vg_name}, 'san_ds1', 'vg name');
is($rows->[1]->{vg_name}, '', 'orphan PV');
is_deeply(PVE::SAN::LVM::parse_report('', 'pv'), [], 'empty output');
is_deeply(PVE::SAN::LVM::parse_report($json, 'vg'), [], 'missing kind');

done_testing();
