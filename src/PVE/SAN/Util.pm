package PVE::SAN::Util;

# Small helpers shared by all pvesan modules.
#
# Everything in this file is pure Perl (no PVE modules at compile time) so
# the discovery and parsing code can be unit tested on any machine.

use strict;
use warnings;

use Exporter qw(import);

our @EXPORT_OK = qw(
    sysfs_root sysfs_path read_attr first_attr write_attr list_dir
    fmt_wwn normalize_wwid parse_wwid_list valid_alias run_cmd
);

# All sysfs access goes through sysfs_path() so tests (and dry runs) can
# point the code at a fixture tree via PVESAN_SYSFS_ROOT.
sub sysfs_root {
    return $ENV{PVESAN_SYSFS_ROOT} // '';
}

# Windows can't store ':' in file names, so fixture trees on Windows encode
# it as '%3A'. Only applies to fixture roots; real sysfs paths are unchanged.
my $ENCODE_COLON = $^O eq 'MSWin32';

sub sysfs_path {
    my ($rel) = @_;
    my $root = sysfs_root();
    $rel =~ s/:/%3A/g if $ENCODE_COLON && length($root);
    return $root . $rel;
}

sub read_attr {
    my ($path) = @_;

    my $full = sysfs_path($path);
    open(my $fh, '<', $full) or return undef;
    local $/;
    my $value = <$fh>;
    close($fh);
    return undef if !defined($value);

    $value =~ s/^\s+//;
    $value =~ s/\s+$//;
    return $value;
}

# Return the first attribute that exists below $dir. HBA drivers disagree on
# attribute names (qla2xxx: model_name, lpfc: modelname, ...).
sub first_attr {
    my ($dir, @names) = @_;

    for my $name (@names) {
        my $value = read_attr("$dir/$name");
        return $value if defined($value) && length($value);
    }
    return undef;
}

# sysfs reports errors on close(), so check both print and close.
sub write_attr {
    my ($path, $value) = @_;

    my $full = sysfs_path($path);
    open(my $fh, '>', $full) or die "unable to open '$full' for writing - $!\n";
    print $fh $value or die "write to '$full' failed - $!\n";
    close($fh) or die "write to '$full' failed - $!\n";
}

sub list_dir {
    my ($path) = @_;

    my $full = sysfs_path($path);
    opendir(my $dh, $full) or return ();
    my @entries = grep { !/^\./ } readdir($dh);
    closedir($dh);
    s/%3A/:/g for @entries;
    return sort @entries;
}

# "0x21000024ff3d5e10" -> "21:00:00:24:ff:3d:5e:10"; zero/absent -> undef
sub fmt_wwn {
    my ($raw) = @_;

    return undef if !defined($raw);
    my $hex = lc($raw);
    $hex =~ s/^0x//;
    $hex =~ s/[^0-9a-f]//g;
    # all zeros / all ones = no fabric (link down)
    return undef if !length($hex) || $hex =~ /^0+$/ || $hex =~ /^f{16}$/;
    $hex = ('0' x (16 - length($hex))) . $hex if length($hex) < 16;
    return join(':', $hex =~ /(..)/g);
}

# Bring a user-supplied or sysfs identifier into the form multipath uses as
# WWID (the udev ID_SERIAL / scsi_id form): NAA ids get the "3" prefix, EUI-64
# ids the "2" prefix. Returns undef for anything that can't be a WWID.
sub normalize_wwid {
    my ($id) = @_;

    return undef if !defined($id);
    $id =~ s/^\s+//;
    $id =~ s/\s+$//;
    $id =~ s|^/dev/mapper/||;

    if ($id =~ /^naa\.([0-9a-fA-F]+)$/) {
        return '3' . lc($1);
    } elsif ($id =~ /^eui\.([0-9a-fA-F]+)$/) {
        return '2' . lc($1);
    } elsif ($id =~ /^[0-9a-fA-F]{17,64}$/) {
        return lc($id);
    } elsif ($id =~ /^[0-9A-Za-z][0-9A-Za-z_.:-]{7,127}$/) {
        return $id; # vendor specific (t10.*, SATA serials, ...)
    }
    return undef;
}

sub parse_wwid_list {
    my ($text) = @_;

    my (@res, %seen);
    for my $item (split(/[\s,;]+/, $text // '')) {
        next if !length($item);
        my $wwid = normalize_wwid($item) // die "invalid WWID '$item'\n";
        push @res, $wwid if !$seen{$wwid}++;
    }
    return \@res;
}

# Multipath aliases become /dev/mapper names, keep them boring.
sub valid_alias {
    my ($alias) = @_;
    return defined($alias) && $alias =~ /^[A-Za-z][A-Za-z0-9_.+-]{0,63}$/;
}

# Run a command and return its stdout. Dies with stderr in the message so
# task logs show *why* LVM or multipath refused. PVE::Tools is loaded lazily
# to keep this module usable in plain-Perl unit tests.
sub run_cmd {
    my ($cmd, %opts) = @_;

    require PVE::Tools;

    my ($out, $err) = ('', '');
    eval {
        PVE::Tools::run_command(
            $cmd,
            outfunc => sub { $out .= "$_[0]\n"; },
            errfunc => sub { $err .= "$_[0]\n"; },
            timeout => $opts{timeout} // 120,
            ($opts{input} ? (input => $opts{input}) : ()),
        );
    };
    if (my $e = $@) {
        return undef if $opts{noerr};
        chomp($err);
        die $e . ($err ? "$err\n" : '');
    }
    print $err if $opts{verbose} && $err;
    return $out;
}

1;
