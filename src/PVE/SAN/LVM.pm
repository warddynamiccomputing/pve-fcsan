package PVE::SAN::LVM;

# Thin wrappers around the LVM commands pvesan needs. Reports use LVM's JSON
# output so parsing does not depend on column widths.

use strict;
use warnings;

use JSON::PP;

use PVE::SAN::Util qw(run_cmd);

my @REPORT_OPTS = ('--reportformat', 'json', '--units', 'b', '--nosuffix');

sub parse_report {
    my ($json, $kind) = @_;

    return [] if !defined($json) || $json !~ /\S/;
    my $data = JSON::PP->new->decode($json);
    my @rows;
    for my $report (@{$data->{report} // []}) {
        push @rows, @{$report->{$kind} // []};
    }
    for my $row (@rows) {
        for my $k (keys %$row) {
            $row->{$k} = $row->{$k} + 0 if $k =~ /_(?:size|free|count)$/ && ($row->{$k} // '') =~ /^\d+$/;
        }
    }
    return \@rows;
}

sub pvs {
    my $out = run_cmd(['pvs', @REPORT_OPTS, '-o', 'pv_name,vg_name,pv_size,pv_free,pv_uuid'], noerr => 1);
    return parse_report($out, 'pv');
}

sub vgs {
    my $out = run_cmd(['vgs', @REPORT_OPTS, '-o', 'vg_name,vg_size,vg_free,vg_uuid,pv_count,lv_count,vg_tags'], noerr => 1);
    return { map { $_->{vg_name} => $_ } @{parse_report($out, 'vg')} };
}

sub lvs {
    my ($vg) = @_;
    my $out = run_cmd(['lvs', @REPORT_OPTS, '-o', 'lv_name,lv_size,lv_attr', $vg], noerr => 1);
    my $rows = parse_report($out, 'lv');
    for my $lv (@$rows) {
        my $attr = $lv->{lv_attr} // '';
        $lv->{active} = substr($attr, 4, 1) eq 'a' ? 1 : 0;
        $lv->{open} = substr($attr, 5, 1) eq 'o' ? 1 : 0;
    }
    return $rows;
}

# LVM 2.03.12+ can restrict itself to a devices file; when enabled every
# node must list the multipath device or the VG stays invisible there.
sub devicesfile_enabled {
    my $out = run_cmd(['lvmconfig', '--typeconfig', 'full', 'devices/use_devicesfile'], noerr => 1) // '';
    return $out =~ /use_devicesfile\s*=\s*1/ ? 1 : 0;
}

sub devicesfile_add {
    my ($devpath) = @_;
    run_cmd(['lvmdevices', '--adddev', $devpath], noerr => 1);
}

sub pvcreate {
    my ($dev) = @_;
    run_cmd(['pvcreate', '--yes', $dev]);
}

sub vgcreate {
    my ($vg, @pvs) = @_;
    run_cmd(['vgcreate', '--yes', '--addtag', 'pvesan', $vg, @pvs]);
}

sub vgextend {
    my ($vg, @pvs) = @_;
    run_cmd(['vgextend', '--yes', $vg, @pvs]);
}

sub pvresize {
    my ($dev) = @_;
    run_cmd(['pvresize', $dev]);
}

sub vgrename {
    my ($old, $new) = @_;
    run_cmd(['vgrename', $old, $new]);
}

sub vg_deactivate {
    my ($vg) = @_;
    run_cmd(['vgchange', '-an', $vg]);
}

sub vgremove {
    my ($vg) = @_;
    run_cmd(['vgremove', '--yes', '--force', $vg]);
}

sub pvremove {
    my ($dev) = @_;
    run_cmd(['pvremove', '--yes', $dev], noerr => 1);
}

sub wipefs {
    my ($dev) = @_;
    run_cmd(['wipefs', '--all', $dev]);
}

1;
