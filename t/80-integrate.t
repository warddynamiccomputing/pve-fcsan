use strict;
use warnings;

use Test::More;
use File::Path qw(make_path);
use File::Temp qw(tempdir);

# Run bin/pvesan-integrate against a fake pve-manager tree, then load the
# patched Nodes.pm with a working and a broken PVE::API2::SAN.

my $root = tempdir(CLEANUP => 1);
my $nodes = "$root/usr/share/perl5/PVE/API2/Nodes.pm";
my $index = "$root/usr/share/pve-manager/index.html.tpl";
my $lib = "$root/lib";
make_path("$root/usr/share/perl5/PVE/API2", "$root/usr/share/pve-manager", "$lib/PVE/API2");

my $NODES = <<'EOF';
package PVE::API2::Nodes::Nodeinfo;
use strict;
use warnings;
our @REGISTERED;
sub register_method { my ($class, $info) = @_; push @REGISTERED, $info->{path}; }
__PACKAGE__->register_method({
    subclass => "PVE::API2::Disks",
    path => 'disks',
});
__PACKAGE__->register_method({ subclass => "PVE::API2::Other", path => 'other' });
1;
EOF
my $INDEX = <<'EOF';
    <script type="text/javascript" src="/pve2/js/pvemanagerlib.js?ver=[% version %]"></script>
  </head>
EOF
my $OLD_LINE = "use PVE::API2::SAN; __PACKAGE__->register_method({ subclass => \"PVE::API2::SAN\", path => 'san' }); # pvesan-integration\n";

sub write_file {
    my ($file, $content) = @_;
    open(my $fh, '>', $file) or die "$file: $!";
    print $fh $content;
    close($fh);
}

sub read_file {
    my ($file) = @_;
    open(my $fh, '<', $file) or die "$file: $!";
    local $/;
    return scalar(<$fh>);
}

sub fake_san {
    my ($broken) = @_;
    write_file("$lib/PVE/API2/SAN.pm", $broken
        ? "package PVE::API2::SAN;\ndie \"Can't locate PVE/Missing.pm in \@INC\\n\";\n1;\n"
        : "package PVE::API2::SAN;\n1;\n");
}

# run the script with the fake root; returns (exit code, stdout+stderr)
sub integrate {
    my ($cmd) = @_;
    local $ENV{PVESAN_INTEGRATE_ROOT} = $root;
    local $ENV{PERL5LIB} = $lib;
    my $out = qx("$^X" bin/pvesan-integrate $cmd 2>&1);
    return ($? >> 8, $out);
}

# load the patched Nodes.pm like pveproxy does; returns (registered, stderr)
sub load_nodes {
    my $code = "require q{$nodes}; print join(q{,}, \@PVE::API2::Nodes::Nodeinfo::REGISTERED)";
    my $out = qx("$^X" -I"$lib" -e "$code" 2>&1);
    return ($? >> 8, $out);
}

sub marked_lines { my @l = grep { /pvesan-integration/ } split(/^/, read_file($_[0])); return scalar(@l) }

write_file($nodes, $NODES);
write_file($index, $INDEX);

fake_san(0);
my ($rc, $out) = integrate('apply');
is($rc, 0, 'apply succeeds') or diag($out);
like($out, qr/Nodes\.pm: integrated/, 'Nodes.pm integrated');
like($out, qr/index\.html\.tpl: integrated/, 'index.html.tpl integrated');
is(marked_lines($nodes), 1, 'one marked line in Nodes.pm');
like(read_file($nodes), qr/path => 'disks',\n\}\);\neval \{ require PVE::API2::SAN;/, 'API line follows the Disks subclass');
like(read_file($index), qr/pvemanagerlib\.js.*\n.*pvesan\.js/, 'GUI script follows pvemanagerlib.js');

($rc, $out) = load_nodes();
is($rc, 0, 'Nodes.pm loads with a working pve-fcsan') or diag($out);
like($out, qr/^disks,san,other$/m, 'san registered between disks and other');

($rc, $out) = integrate('apply');
like($out, qr/Nodes\.pm: already integrated/, 'second apply changes nothing');
($rc, $out) = integrate('status');
is($rc, 0, 'status exits 0');
like($out, qr/Nodes\.pm: integrated\n/, 'status: Nodes.pm integrated');
like($out, qr/PVE::API2::SAN: loads/, 'status: API module loads');

# a broken pve-fcsan must not take the rest of the API down
fake_san(1);
($rc, $out) = load_nodes();
is($rc, 0, 'Nodes.pm still loads with a broken pve-fcsan') or diag($out);
like($out, qr/^disks,other$/m, 'other subclasses still registered, san skipped');
like($out, qr/pve-fcsan: SAN API disabled - Can't locate PVE\/Missing\.pm/, 'warning names the cause');

($rc, $out) = integrate('status');
is($rc, 1, 'status exits 1 when the module fails');
like($out, qr/FAILS to load/, 'status reports the failure');
($rc, $out) = integrate('apply');
is($rc, 1, 'apply exits 1 when the module fails');
like($out, qr/rest of the Proxmox VE API is not affected/, 'apply explains the effect');
fake_san(0);

# upgrade from the 1.3.0 line, which loaded the module unguarded
write_file($nodes, $NODES =~ s/(path => 'disks',\n\}\);\n)/$1$OLD_LINE/r);
($rc, $out) = integrate('status');
like($out, qr/older pve-fcsan/, 'status spots the old line');
($rc, $out) = integrate('apply');
like($out, qr/Nodes\.pm: updated/, 'apply replaces the old line');
is(marked_lines($nodes), 1, 'still one marked line');
unlike(read_file($nodes), qr/^use PVE::API2::SAN/m, 'old unguarded line gone');

# a Nodes.pm without the anchor is left alone
write_file($nodes, "package PVE::API2::Nodes::Nodeinfo;\n1;\n");
($rc, $out) = integrate('apply');
is($rc, 1, 'apply fails without the anchor');
like($out, qr/anchor \(Disks subclass\) not found/, 'and says why');
is(read_file($nodes), "package PVE::API2::Nodes::Nodeinfo;\n1;\n", 'Nodes.pm untouched');

# remove
write_file($nodes, $NODES);
integrate('apply');
($rc, $out) = integrate('remove');
like($out, qr/Nodes\.pm: removed/, 'remove Nodes.pm');
is(read_file($nodes), $NODES, 'Nodes.pm restored exactly');
is(read_file($index), $INDEX, 'index.html.tpl restored exactly');

done_testing();
