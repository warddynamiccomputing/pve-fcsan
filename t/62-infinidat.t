use strict;
use warnings;

use Test::More;
use JSON::PP;
use MIME::Base64;

use PVE::SAN::Array::Infinidat;

my $json = JSON::PP->new->canonical;
my $GIB = 1024 ** 3;

# Fake InfiniBox REST API with state.
sub fake_ibox {
    my (%opt) = @_;
    my $st = {
        hosts => [ { id => 11, name => 'pvenode01', ports => [
            { type => 'FC', address => '50:00:00:00:00:00:00:01' }, { type => 'ISCSI', address => 'iqn.x' } ] } ],
        clusters => [ { id => 5, name => 'vmware', hosts => [] } ],
        volumes => {},
        luns => [],
        next_id => 100,
    };
    my @calls;
    my $t = sub {
        my ($method, $url, $headers, $body) = @_;
        push @calls, { method => $method, url => $url, headers => $headers, body => $body };
        my ($path, $qs) = split(/\?/, $url, 2);
        my %q = map { split(/=/, $_, 2) } split(/&/, $qs // '');
        my $res = sub { (200, $json->encode({ result => $_[0], error => undef, metadata => $_[1] // { ready => JSON::PP::true } }), {}) };
        my $err = sub { ($_[0], $json->encode({ result => undef, error => { code => $_[1], message => $_[2] } }), {}) };

        return $err->(401, 'UNAUTHORIZED', 'bad credentials')
            if ($headers->{Authorization} // '') ne 'Basic ' . encode_base64('pvesan:secret', '');
        return $err->(404, 'NOT_FOUND', 'no route') if $path !~ s|^/api/rest||;
        # like a real InfiniBox: unapproved changes are refused
        return $err->(403, 'APPROVAL_REQUIRED', 'operation requires approval')
            if $method ne 'GET' && ($q{approved} // '') ne 'true';

        if ($path eq '/system') { return $res->({ name => 'ibox-3201', model => 'F6230', version => '7.3.10.0', serial => 3201 }); }
        if ($path eq '/pools') {
            my @p = ({ id => 1, name => 'pve-pool', physical_capacity => 100 * $GIB, free_physical_space => 60 * $GIB },
                     { id => 2, name => 'other', physical_capacity => 10 * $GIB, free_physical_space => 1 * $GIB });
            # this fake pages one pool at a time, reported via number_of_objects only
            my $page = $q{page} // 1;
            return $res->([ $p[$page - 1] ], { page => $page, page_size => 1, number_of_objects => 2 });
        }
        if ($path eq '/hosts' && $method eq 'GET') { return $res->($st->{hosts}, { pages_total => 1 }); }
        if ($path eq '/hosts' && $method eq 'POST') {
            my $h = { id => $st->{next_id}++, name => $body->{name}, ports => [] };
            push @{$st->{hosts}}, $h;
            return $res->($h);
        }
        if ($path =~ m|^/hosts/(\d+)/ports$|) {
            my ($h) = grep { $_->{id} == $1 } @{$st->{hosts}};
            push @{$h->{ports}}, $body;
            return $res->($body);
        }
        if ($path eq '/clusters' && $method eq 'GET') { return $res->($st->{clusters}, { pages_total => 1 }); }
        if ($path eq '/clusters' && $method eq 'POST') {
            my $c = { id => $st->{next_id}++, name => $body->{name}, hosts => [] };
            push @{$st->{clusters}}, $c;
            return $res->($c);
        }
        if ($path =~ m|^/clusters/(\d+)/hosts$|) {
            my ($c) = grep { $_->{id} == $1 } @{$st->{clusters}};
            my ($h) = grep { $_->{id} == $body->{id} } @{$st->{hosts}};
            push @{$c->{hosts}}, { id => $h->{id}, name => $h->{name} };
            return $res->($c);
        }
        if ($path =~ m|^/clusters/(\d+)$| && $method eq 'GET') {
            my $cid = $1;
            my ($c) = grep { $_->{id} == $cid } @{$st->{clusters}};
            return $res->({ id => $cid, luns => [ grep { $_->{host_cluster_id} == $cid } @{$st->{luns}} ] })
                if ($q{fields} // '') eq 'luns';
            return $res->($c);
        }
        if ($path =~ m|^/clusters/(\d+)/luns$| && $method eq 'POST') {
            my $lun = 1 + scalar(@{$st->{luns}});
            push @{$st->{luns}}, { lun => $lun, volume_id => $body->{volume_id}, host_cluster_id => $1, clustered => JSON::PP::true };
            return $res->($st->{luns}->[-1]);
        }
        if ($path =~ m|^/clusters/(\d+)/luns/lun/(\d+)$| && $method eq 'DELETE') {
            my ($cid, $lun) = ($1, $2);
            my $before = @{$st->{luns}};
            $st->{luns} = [ grep { !($_->{host_cluster_id} == $cid && $_->{lun} == $lun) } @{$st->{luns}} ];
            return $err->(404, 'LUN_NOT_FOUND', 'no such lun') if @{$st->{luns}} == $before;
            return $res->(undef);
        }
        if ($path eq '/volumes' && $method eq 'POST') {
            my $id = $st->{next_id}++;
            my $v = $st->{volumes}->{$id} = { id => $id, name => $body->{name}, size => $body->{size},
                pool_id => $body->{pool_id}, provtype => $body->{provtype},
                serial => sprintf('742b0f000004e2b0000000000%06x', $id) }; # 31 hex digits
            return $res->($v);
        }
        if ($path eq '/volumes' && $method eq 'GET') { return $res->([ values %{$st->{volumes}} ], { pages_total => 1 }); }
        if ($path =~ m|^/volumes/(\d+)$|) {
            my $v = $st->{volumes}->{$1} // return $err->(404, 'VOLUME_NOT_FOUND', 'no volume');
            return $res->($v) if $method eq 'GET';
            if ($method eq 'PUT') { $v->{$_} = $body->{$_} for keys %$body; return $res->($v); }
            if ($method eq 'DELETE') { delete $st->{volumes}->{$1}; return $res->($v); }
        }
        return $err->(404, 'NOT_FOUND', "no route $method $path");
    };
    my $drv = PVE::SAN::Array::Infinidat->new(address => 'ibox', username => 'pvesan',
        password => $opt{password} // 'secret', transport => $t);
    return ($drv, \@calls, $st);
}

# --- connection, pools ---
{
    my ($drv, $calls) = fake_ibox();
    my $info = $drv->system_info();
    is($info->{name}, 'ibox-3201', 'system name');
    is($info->{code_level}, '7.3.10.0', 'version');
    is($calls->[0]->{url}, '/api/rest/system', 'REST base path');

    my $pools = $drv->pools();
    is(scalar(@$pools), 2, 'pools from two pages (number_of_objects paging)');
    is($pools->[0]->{free}, 60 * $GIB, 'free physical space');
    like($calls->[-1]->{url}, qr/page=2&page_size=1000/, 'paged request');
    is(scalar(grep { $_->{url} =~ m|/pools| } @$calls), 2, 'stops after the last object');
    unlike($calls->[0]->{url}, qr/approved/, 'GET requests are not approved');
}
{
    my ($drv) = fake_ibox(password => 'wrong');
    eval { $drv->system_info() };
    like($@, qr/GET \/system failed \(HTTP 401\): UNAUTHORIZED: bad credentials/, 'error envelope reported');
}
eval { PVE::SAN::Array::Infinidat->new(address => 'x', password => 'p', fingerprint => 'sha256$0') };
like($@, qr/username missing/, 'username required');

# --- serial to WWID ---
is(PVE::SAN::Array::Infinidat::serial_to_wwid('742b0f00000098b00000000000adfd5'),
    '36742b0f00000098b00000000000adfd5', '31-digit serial gets NAA type 6');
is(PVE::SAN::Array::Infinidat::serial_to_wwid('6742B0F00000098B00000000000ADFD5'),
    '36742b0f00000098b00000000000adfd5', '32-digit form with type nibble');
is(PVE::SAN::Array::Infinidat::serial_to_wwid('xyz'), undef, 'junk serial');

# --- volumes ---
{
    my ($drv, $calls, $st) = fake_ibox();
    my $v = $drv->create_volume(name => 'gold_01', pool => 'pve-pool', size_gib => 512, thin => 0);
    my ($mk) = grep { $_->{method} eq 'POST' && $_->{url} =~ m|^/api/rest/volumes\?| } @$calls;
    is_deeply($mk->{body}, { name => 'gold_01', pool_id => 1, size => 512 * $GIB, provtype => 'THICK' }, 'create body');
    like($v->{wwid}, qr/^36742b0f000004e2b0000000000[0-9a-f]{6}$/, 'WWID from serial');

    eval { $drv->create_volume(name => 'x', pool => 'nosuch', size_gib => 1) };
    like($@, qr/pool 'nosuch' not found/, 'unknown pool');

    like($mk->{url}, qr/\?approved=true$/, 'create is approved like InfiniSDK does');

    my ($c) = $drv->call('POST', '/clusters', undef, { name => 'pvelab' });
    $drv->map_to_hostcluster($v->{id}, 'pvelab');
    is_deeply($calls->[-1]->{body}, { volume_id => $v->{id} + 0 }, 'map body');
    is($calls->[-1]->{url}, "/api/rest/clusters/$c->{id}/luns?approved=true", 'map URL');

    $drv->expand_volume($v->{id}, 512 * $GIB);
    like($calls->[-1]->{url}, qr/\?approved=true$/, 'resize approved');
    is($st->{volumes}->{$v->{id}}->{size}, 1024 * $GIB, 'new size');

    is($drv->find_volume_by_wwid($v->{wwid})->{name}, 'gold_01', 'find by WWID');

    # another volume on LUN 2 must survive the unmap of the first
    push @{$st->{luns}}, { lun => 2, volume_id => 999, host_cluster_id => $c->{id} };
    $drv->unmap_from_hostcluster($v->{id}, 'pvelab');
    is($calls->[-2]->{url}, "/api/rest/clusters/$c->{id}?fields=luns", 'LUN list read first');
    is($calls->[-1]->{url}, "/api/rest/clusters/$c->{id}/luns/lun/1?approved=true", 'unmap by LUN number');
    is_deeply([ map { $_->{volume_id} } @{$st->{luns}} ], [999], 'only that LUN unmapped');

    @$calls = ();
    $drv->unmap_from_hostcluster($v->{id}, 'pvelab');
    is(scalar(grep { $_->{method} eq 'DELETE' } @$calls), 0, 'already unmapped: nothing deleted');

    $drv->delete_volume($v->{id});
    is($calls->[-1]->{method}, 'DELETE', 'delete');
    is_deeply($st->{volumes}, {}, 'volume gone');
}

# --- cluster registration through the shared logic ---
{
    my ($drv, $calls, $st) = fake_ibox();
    my $res = $drv->ensure_hostcluster('pvelab', {
        pvenode01 => ['50:00:00:00:00:00:00:01', '50:00:00:00:00:00:00:02'],
        pvenode03 => ['50:00:00:00:00:00:00:04'],
    }, sub {});
    my ($hc) = grep { $_->{name} eq 'pvelab' } @{$st->{clusters}};
    ok($hc, 'cluster created');
    is_deeply($res->{pvenode01}->{added_ports}, ['5000000000000002'], 'iSCSI port ignored, missing FC port added');
    my ($port) = grep { $_->{url} eq '/api/rest/hosts/11/ports?approved=true' } @$calls;
    is_deeply($port->{body}, { type => 'fc', address => '50:00:00:00:00:00:00:02' }, 'port as InfiniSDK sends it');
    is($res->{pvenode03}->{created}, 1, 'host created');
    is_deeply([ sort map { $_->{name} } @{$hc->{hosts}} ], ['pvenode01', 'pvenode03'], 'both in the cluster');

    @$calls = ();
    $drv->ensure_hostcluster('pvelab', {
        pvenode01 => ['5000000000000001', '5000000000000002'], pvenode03 => ['5000000000000004'] }, sub {});
    is(scalar(grep { $_->{method} eq 'POST' } @$calls), 0, 'idempotent');
}

done_testing();
