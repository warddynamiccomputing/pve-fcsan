use strict;
use warnings;

use Test::More;
use JSON::PP;

use PVE::SAN::Array::Pure;

my $json = JSON::PP->new->canonical;
my $GIB = 1024 ** 3;

# Fake FlashArray REST 2.x with state.
sub fake_pure {
    my (%opt) = @_;
    my $st = {
        session => undef,
        hosts => [ { name => 'pvenode01', wwns => ['5000000000000001', '5000000000000002'], host_group => { name => '' } } ],
        groups => [],
        volumes => {},
        connections => [],
        serial => 0x4E2B0,
    };
    my @calls;
    my $t = sub {
        my ($method, $url, $headers, $body) = @_;
        push @calls, { method => $method, url => $url, headers => $headers, body => $body };
        my ($path, $qs) = split(/\?/, $url, 2);
        my %q = map { my ($k, $v) = split(/=/, $_, 2); ($k => $v =~ s/%([0-9A-F]{2})/chr(hex($1))/ger) } split(/&/, $qs // '');
        my $ok = sub { (200, $json->encode({ items => $_[0] // [] }), {}) };

        return (200, '{"version":["1.17","2.2","2.10","2.4"]}', {}) if $url eq '/api/api_version';
        return (404, 'old', {}) if $path !~ m|^/api/2\.10/|;
        $path =~ s|^/api/2\.10||;

        if ($path eq '/login') {
            return (401, '{"errors":[{"message":"invalid API token"}]}', {}) if ($headers->{'api-token'} // '') ne 'T-OK';
            $st->{session} = 'sess-' . scalar(@calls);
            return (200, '{"items":[{"username":"pvesan"}]}', { 'x-auth-token' => $st->{session} });
        }
        return (401, '{"errors":[{"message":"session expired"}]}', {})
            if !$st->{session} || ($headers->{'x-auth-token'} // '') ne $st->{session};

        if ($path eq '/arrays' && $method eq 'GET') {
            return $ok->([ { name => 'pure-x70', os => 'Purity//FA', version => '6.5.8', id => 'a1' } ]);
        }
        if ($path eq '/arrays/space') {
            # newer Purity: total_used; total_physical (deprecated) disagrees on purpose
            return $ok->([ { capacity => 100 * $GIB, space => { total_used => 30 * $GIB, total_physical => 99 * $GIB } } ]);
        }
        if ($path eq '/hosts' && $method eq 'GET') {
            # page the host list in two to exercise continuation tokens
            my @h = @{$st->{hosts}};
            if (!$q{continuation_token} && @h > 1) {
                return (200, $json->encode({ items => [ $h[0] ], continuation_token => 'next1' }), {});
            }
            return $ok->($q{continuation_token} ? [ @h[1 .. $#h] ] : \@h);
        }
        if ($path eq '/hosts' && $method eq 'POST') {
            push @{$st->{hosts}}, { name => $q{names}, wwns => $body->{wwns}, host_group => undef };
            return $ok->([ { name => $q{names} } ]);
        }
        if ($path eq '/hosts' && $method eq 'PATCH') {
            my ($h) = grep { $_->{name} eq $q{names} } @{$st->{hosts}};
            push @{$h->{wwns}}, @{$body->{add_wwns}};
            return $ok->([ $h ]);
        }
        if ($path eq '/host-groups' && $method eq 'GET') { return $ok->([ map { { name => $_ } } @{$st->{groups}} ]); }
        if ($path eq '/host-groups' && $method eq 'POST') { push @{$st->{groups}}, $q{names}; return $ok->([]); }
        if ($path eq '/host-groups/hosts' && $method eq 'POST') {
            my ($h) = grep { $_->{name} eq $q{member_names} } @{$st->{hosts}};
            $h->{host_group} = { name => $q{group_names} };
            return $ok->([]);
        }
        if ($path eq '/volumes' && $method eq 'POST') {
            return (400, '{"errors":[{"context":"' . $q{names} . '","message":"Volume already exists."}]}', {})
                if $st->{volumes}->{$q{names}};
            my $serial = sprintf('A1B2C3D4E5F6A7B8%08X', $st->{serial}++);
            my $v = $st->{volumes}->{$q{names}} = { name => $q{names}, serial => $serial, provisioned => $body->{provisioned} };
            return $ok->([ $v ]);
        }
        if ($path eq '/volumes' && $method eq 'GET') {
            if (my $f = $q{filter}) {
                my ($s) = $f =~ /^serial='([0-9A-F]+)'$/;
                return $ok->([ grep { $_->{serial} eq ($s // '') } values %{$st->{volumes}} ]);
            }
            return $ok->([ grep { defined } $st->{volumes}->{$q{names}} ]);
        }
        if ($path eq '/volumes' && $method eq 'PATCH') {
            my $v = $st->{volumes}->{$q{names}};
            $v->{$_} = $body->{$_} for keys %$body;
            return $ok->([ $v ]);
        }
        if ($path eq '/connections') {
            if ($method eq 'POST') { push @{$st->{connections}}, "$q{host_group_names}/$q{volume_names}"; }
            else { $st->{connections} = [ grep { $_ ne "$q{host_group_names}/$q{volume_names}" } @{$st->{connections}} ]; }
            return $ok->([]);
        }
        return (404, '{"errors":[{"message":"no route"}]}', {});
    };
    my $drv = PVE::SAN::Array::Pure->new(address => 'pure', password => $opt{token} // 'T-OK', transport => $t);
    return ($drv, \@calls, $st);
}

# --- connection ---
{
    my ($drv, $calls, $st) = fake_pure();
    is($drv->api_version, '2.10', 'highest 2.x version (numeric, not string order)');
    my $info = $drv->system_info();
    is($info->{name}, 'pure-x70', 'array name');
    like($info->{product}, qr/Purity\/\/FA/, 'product');
    my ($login) = grep { $_->{url} =~ m|/login$| } @$calls;
    is($login->{headers}->{'api-token'}, 'T-OK', 'API token sent at login');
    is($calls->[-1]->{headers}->{'x-auth-token'}, $st->{session}, 'session token used afterwards');

    $st->{session} = 'expired-elsewhere';
    $drv->system_info();
    is(scalar(grep { $_->{url} =~ m|/login$| } @$calls), 2, 're-login after 401');

    my $pools = $drv->pools();
    is_deeply($pools->[0], { name => 'default', status => 'online', capacity => 100 * $GIB, free => 70 * $GIB },
        'single default pool, free space from total_used');
}
{
    my ($drv) = fake_pure(token => 'bad');
    eval { $drv->system_info() };
    like($@, qr/login to pure failed \(HTTP 401\): invalid API token/, 'bad token reported with array message');
}
ok(!PVE::SAN::Array::Pure->needs_username, 'no username needed');

# --- naming ---
ok(PVE::SAN::Array::Pure->valid_name('ds-01'), 'dash ok');
ok(!PVE::SAN::Array::Pure->valid_name('ds_01'), 'underscore not allowed');
ok(!PVE::SAN::Array::Pure->valid_name('ds-'), 'must end with letter or digit');
is(PVE::SAN::Array::Pure->object_name_for('fs.gold_01'), 'fs-gold-01', 'storage ID adapted');
{
    my ($drv) = fake_pure();
    is($drv->volume_name_for('gold_01'), 'gold-01', 'volume name adapted');
}

# --- volumes ---
{
    my ($drv, $calls, $st) = fake_pure();
    my $v = $drv->create_volume(name => 'gold-01', pool => 'default', size_gib => 2048, thin => 1);
    my ($mk) = grep { $_->{method} eq 'POST' && $_->{url} =~ m|/volumes| } @$calls;
    is($mk->{url}, '/api/2.10/volumes?names=gold-01', 'create URL');
    is_deeply($mk->{body}, { provisioned => 2048 * $GIB }, 'size in bytes');
    is($v->{wwid}, '3624a9370a1b2c3d4e5f6a7b80004e2b0', 'WWID = 3 + 624a9370 + serial (lower case)');

    eval { $drv->create_volume(name => 'gold-01', pool => 'default', size_gib => 1) };
    like($@, qr/gold-01: Volume already exists/, 'array error context and message');

    $drv->map_to_hostcluster('gold-01', 'pvelab');
    is($calls->[-1]->{url}, '/api/2.10/connections?host_group_names=pvelab&volume_names=gold-01', 'connection to host group');
    is_deeply($calls->[-1]->{body}, {}, 'connection POST carries a JSON body (ConnectionPost)');
    is_deeply($st->{connections}, ['pvelab/gold-01'], 'mapped');

    $drv->expand_volume('gold-01', 1024 * $GIB);
    is($st->{volumes}->{'gold-01'}->{provisioned}, 3072 * $GIB, 'expand sets new total');

    my $found = $drv->find_volume_by_wwid('3624a9370a1b2c3d4e5f6a7b80004e2b0');
    like($calls->[-1]->{url}, qr/filter=serial%3D%27A1B2C3D4E5F6A7B80004E2B0%27/, 'serial filter (upper case, quoted)');
    is($found->{name}, 'gold-01', 'found by WWID');
    is($drv->find_volume_by_wwid('36005076810810261f80000000000002a'), undef, 'IBM WWID is not a Pure volume');

    $drv->unmap_from_hostcluster('gold-01', 'pvelab');
    is($calls->[-1]->{method}, 'DELETE', 'unmap is DELETE');
    is_deeply($st->{connections}, [], 'unmapped');

    $drv->delete_volume('gold-01');
    is_deeply($calls->[-1]->{body}, { destroyed => JSON::PP::true }, 'delete = destroy (recoverable)');
}

# --- host group registration through the shared logic ---
{
    my ($drv, $calls, $st) = fake_pure();
    push @{$st->{hosts}}, { name => 'old-esx', wwns => ['2100000000000002'], host_group => { name => 'vmware' } };
    my $res = $drv->ensure_hostcluster('pvelab', {
        pvenode01 => ['50:00:00:00:00:00:00:01', '50:00:00:00:00:00:00:02', '50:00:00:00:00:00:00:03'],
        pvenode02 => ['50:00:00:00:00:00:00:05', '50:00:00:00:00:00:00:06'],
    }, sub {});
    is_deeply($st->{groups}, ['pvelab'], 'host group created');
    my ($hgpost) = grep { $_->{method} eq 'POST' && $_->{url} =~ m|/host-groups\?names=| } @$calls;
    is_deeply($hgpost->{body}, {}, 'host group POST carries a JSON body (HostGroupPost)');
    is_deeply($res->{pvenode01}->{added_ports}, ['5000000000000003'], 'existing host (found on page 2 or 1) gets missing port');
    my ($patch) = grep { $_->{method} eq 'PATCH' && $_->{url} =~ m|/hosts| } @$calls;
    is_deeply($patch->{body}, { add_wwns => ['5000000000000003'] }, 'add_wwns body');
    is($res->{pvenode02}->{created}, 1, 'host created');
    my ($post) = grep { $_->{method} eq 'POST' && $_->{url} =~ m|/hosts\?names=pvenode02| } @$calls;
    is_deeply($post->{body}, { wwns => ['5000000000000005', '5000000000000006'] }, 'host created with WWNs');
    is(scalar(grep { $_->{url} =~ m|/host-groups/hosts\?group_names=pvelab&member_names=| } @$calls), 2,
        'both hosts added to the host group');

    eval { $drv->ensure_hostcluster('pvelab', { pvenode03 => ['2100000000000002'] }, sub {}) };
    like($@, qr/already belongs to host cluster 'vmware'/, 'refuses a host in another host group');
}

done_testing();
