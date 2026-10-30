use strict;
use warnings;

use Test::More;

use StubPVE;

# Load every module. On a PVE host this compiles against the real PVE
# libraries; elsewhere missing PVE modules are stubbed (see StubPVE).
my @modules = qw(
    PVE::SAN::Util
    PVE::SAN::Sysfs
    PVE::SAN::Multipath
    PVE::SAN::LVM
    PVE::SAN::Config
    PVE::SAN::Inventory
    PVE::SAN::ISCSI
    PVE::SAN::Ops
    PVE::SAN::Cluster
    PVE::SAN::Datastore
    PVE::SAN::Monitor
    PVE::SAN::Array
    PVE::SAN::Array::Base
    PVE::SAN::Array::IBMSV
    PVE::SAN::Array::Pure
    PVE::SAN::Array::Infinidat
    PVE::SAN::Array::PowerStore
    PVE::SAN::Array::PowerMax
    PVE::SAN::Array::ONTAP
    PVE::SAN::Array::ESeries
    PVE::SAN::Array::Hitachi
    PVE::SAN::Array::Eternus
    PVE::SAN::Array::Unity
    PVE::SAN::Array::Nimble
    PVE::SAN::Array::HPE3PAR
    PVE::SAN::Provision
    PVE::SAN::Snapshot
    PVE::SAN::DR
    PVE::SAN::Volume
    PVE::Storage::Custom::FCSANPlugin
    PVE::Storage::Custom::FCSANVolPlugin
    PVE::API2::SAN
    PVE::CLI::pvesan
);

# compile warnings (like "Useless use of ... in void context") are bugs here
my @warnings;
local $SIG{__WARN__} = sub { push @warnings, $_[0] };
require_ok($_) for @modules;
is_deeply(\@warnings, [], 'no compile warnings') or diag(@warnings);

diag("stubbed: " . join(' ', sort keys %StubPVE::STUBBED)) if %StubPVE::STUBBED;

for my $script ('bin/pvesan-integrate') {
    my $out = `$^X -c $script 2>&1`;
    like($out, qr/syntax OK/, "$script compiles");
}

done_testing();
