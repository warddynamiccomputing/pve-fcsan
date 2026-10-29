use strict;
use warnings;

use Test::More;
use JSON::PP;

use StubPVE;
use FakeArray;
use PVE::SAN::Array;
use PVE::SAN::Array::HPE3PAR;

my $GIB = 1024 ** 3;
my $MIB = 1024 ** 2;
my $A = qr{^/api/v1};
my $C = 'PVE::SAN::Array::HPE3PAR';

my %st = (
    sessions => {}, nkey => 0, expire => 0,
    hosts => { legacy => { id => 1, name => 'legacy', FCPaths => [ { wwn => '10000000C9000099' } ] } },
    hostsets => {}, vols => {}, vsets => {}, vluns => [], tasks => {}, nid => 10, ntask => 0,
);
my $err = sub { my ($code, $n, $desc, $ref) = @_; ($code, { code => $n, desc => $desc, (defined($ref) ? (ref => $ref) : ()) }) };
my $members = sub { (200, { total => scalar(@{$_[0]}), members => $_[0] }) };
my $q = sub { my ($query) = @_; return ($query->{query} // '') =~ /^"(\w+) EQ (.+)"$/ ? ($1, $2) : () };
my $wwn = sub { sprintf('60002AC00000000000000%03X00012345', $_[0]) };
my $new_vol = sub {
    my (%v) = @_;
    my $id = ++$st{nid};
    $st{vols}->{$v{name}} = { id => $id, wwn => $wwn->($id), creationTimeSec => 1_790_000_000 + $id, %v };
};
my $check = sub { # session handling: a forgotten or expired key is refused
    my ($h) = @_;
    my $k = $h->{'X-HP3PAR-WSAPI-SessionKey'} // '';
    return $st{sessions}->{$k} ? () : $err->(403, 6, 'invalid session key');
};
my $guard = sub { my ($h, @ok) = @_; my @e = $check->($h); return @e ? @e : @ok };

my ($drv, $calls) = FakeArray::driver($C, { poll_interval => 0 }, [
    [ POST => qr{$A/credentials$}, sub {
        return $err->(401, 5, 'invalid username or password') if $_[2]->{password} ne 'secret';
        my $k = 'K' . ++$st{nkey}; $st{sessions}->{$k} = 1; (201, { key => $k }) } ],
    [ DELETE => qr{$A/credentials/(\w+)$}, sub { delete $st{sessions}->{$_[0]->[0]}; (200, '') } ],
    [ GET => qr{$A/system$}, sub {
        $guard->($_[3], (200, { id => 4711, name => 'array1', model => 'HPE Alletra 9060', serialNumber => '4UW0001234',
            systemVersion => '9.5.3' })) } ],
    [ GET => qr{$A/cpgs$}, sub {
        $guard->($_[3], $members->([
            { name => 'SSD_r6', SDGrowth => { limitMiB => 1048576 }, UsrUsage => { totalMiB => 262144 },
              SAUsage => { totalMiB => 1024 }, SDUsage => { totalMiB => 3072 } },
            { name => 'FC_r1', SDGrowth => { incrementMiB => 32768 }, UsrUsage => { totalMiB => 10 } } ])) } ],
    [ GET => qr{$A/ports$}, sub {
        $guard->($_[3], $members->([
            { portWWN => '20010002AC012345', protocol => 1, mode => 2, linkState => 4 },
            { portWWN => '20020002AC012345', protocol => 1, mode => 2, linkState => 10 },
            { portWWN => '20030002AC012345', protocol => 1, mode => 3, linkState => 4 },
            { protocol => 2, mode => 2, linkState => 4 } ])) } ],
    [ GET => qr{$A/hostsets$}, sub { $guard->($_[3], $members->([ map { $st{hostsets}->{$_} } sort keys %{$st{hostsets}} ])) } ],
    [ POST => qr{$A/hostsets$}, sub {
        return $err->(409, 101, 'set exists') if $st{hostsets}->{$_[2]->{name}};
        $st{hostsets}->{$_[2]->{name}} = { id => ++$st{nid}, name => $_[2]->{name}, setmembers => [] }; (201, '') } ],
    [ PUT => qr{$A/hostsets/([^/]+)$}, sub {
        my $s = $st{hostsets}->{$_[0]->[0]} or return $err->(404, 102, 'set does not exist');
        my %rm = map { $_ => 1 } @{$_[2]->{setmembers}};
        $s->{setmembers} = $_[2]->{action} == 1 ? [ @{$s->{setmembers}}, @{$_[2]->{setmembers}} ]
            : [ grep { !$rm{$_} } @{$s->{setmembers}} ];
        (200, '') } ],
    [ GET => qr{$A/hosts$}, sub { $guard->($_[3], $members->([ map { $st{hosts}->{$_} } sort keys %{$st{hosts}} ])) } ],
    [ POST => qr{$A/hosts$}, sub {
        my $b = $_[2];
        return $err->(409, 16, 'host exists') if $st{hosts}->{$b->{name}};
        $st{hosts}->{$b->{name}} = { id => ++$st{nid}, name => $b->{name}, persona => $b->{persona},
            FCPaths => [ map { { wwn => $_ } } @{$b->{FCWWNs}} ] };
        (201, '', { location => "/api/v1/hosts/$b->{name}" }) } ],
    [ PUT => qr{$A/hosts/([^/]+)$}, sub {
        push @{$st{hosts}->{$_[0]->[0]}->{FCPaths}}, map { { wwn => $_ } } @{$_[2]->{FCWWNs}} if $_[2]->{pathOperation} == 1;
        (200, '') } ],
    [ DELETE => qr{$A/hosts/([^/]+)$}, sub { delete $st{hosts}->{$_[0]->[0]}; (200, '') } ],
    [ POST => qr{$A/volumes$}, sub {
        my $b = $_[2];
        return $err->(409, 22, 'volume exists') if $st{vols}->{$b->{name}};
        return $err->(404, 15, 'cpg does not exist') if $b->{cpg} ne 'SSD_r6';
        $new_vol->(name => $b->{name}, userCPG => $b->{cpg}, sizeMiB => $b->{sizeMiB}, provisioningType => $b->{tpvv} ? 2 : 1, req => $b);
        (201, '') } ],
    [ GET => qr{$A/volumes$}, sub {
        return $check->($_[3]) if $check->($_[3]);
        my ($f, $v) = $q->($_[1]) or return $err->(400, 1, 'query required by the fake');
        $members->([ grep { ($_->{$f} // '') eq $v } map { $st{vols}->{$_} } sort keys %{$st{vols}} ]) } ],
    [ GET => qr{$A/volumes/([^/]+)$}, sub {
        return $check->($_[3]) if $check->($_[3]);
        my $v = $st{vols}->{$_[0]->[0]} or return $err->(404, 23, 'volume does not exist');
        (200, $v) } ],
    [ PUT => qr{$A/volumes/([^/]+)$}, sub {
        my ($c, $qq, $b) = @_;
        my $v = $st{vols}->{$c->[0]} or return $err->(404, 23, 'volume does not exist');
        if ($b->{action} == 3) { $v->{sizeMiB} += $b->{sizeMiB}; return (200, '') }
        if ($b->{action} == 4) {
            return $err->(409, 78, 'the volume is a base volume') if !$v->{copyOf};
            $st{promoted} = [ $c->[0], $v->{copyOf}, $b->{online} ];
            $st{tasks}->{++$st{ntask}} = [ 2, 1 ]; # active once, then done
            return (200, { taskid => $st{ntask} });
        }
        $err->(400, 40, 'invalid action') } ],
    [ POST => qr{$A/volumes/([^/]+)$}, sub {
        my ($c, $qq, $b) = @_;
        my $src = $st{vols}->{$c->[0]} or return $err->(404, 23, 'volume does not exist');
        my $p = $b->{parameters};
        if ($b->{action} eq 'createSnapshot') {
            return $err->(409, 22, 'volume exists') if $st{vols}->{$p->{name}};
            $new_vol->(name => $p->{name}, copyOf => $src->{name}, copyType => 3, sizeMiB => $src->{sizeMiB},
                comment => $p->{comment}, readOnly => $p->{readOnly});
            return (201, '');
        }
        if ($b->{action} eq 'createPhysicalCopy') {
            $new_vol->(name => $p->{destVolume}, userCPG => $p->{destCPG}, sizeMiB => $src->{sizeMiB}, copyOf => $src->{name}, copyType => 2);
            $st{copy} = $b;
            return (201, { taskid => ++$st{ntask} });
        }
        $err->(400, 40, 'invalid action') } ],
    [ DELETE => qr{$A/volumes/([^/]+)$}, sub {
        my $n = $_[0]->[0];
        return $err->(404, 23, 'volume does not exist') if !$st{vols}->{$n};
        return $err->(409, 34, 'volume is exported') if grep { $_->{volumeName} eq $n } @{$st{vluns}};
        return $err->(409, 32, 'volume has a child') if grep { ($_->{copyOf} // '') eq $n && $_->{copyType} == 3 } values %{$st{vols}};
        return $err->(409, 35, 'volume is in a set') if grep { grep { $_ eq $n } @{$_->{setmembers}} } values %{$st{vsets}};
        delete $st{vols}->{$n}; (200, '') } ],
    [ GET => qr{$A/volumesets$}, sub { $members->([ map { $st{vsets}->{$_} } sort keys %{$st{vsets}} ]) } ],
    [ GET => qr{$A/volumesets/([^/]+)$}, sub { my $s = $st{vsets}->{$_[0]->[0]} or return $err->(404, 102, 'set does not exist'); (200, $s) } ],
    [ POST => qr{$A/volumesets$}, sub { $st{vsets}->{$_[2]->{name}} = { name => $_[2]->{name}, setmembers => [ @{$_[2]->{setmembers}} ] }; (201, '') } ],
    [ PUT => qr{$A/volumesets/([^/]+)$}, sub {
        my $s = $st{vsets}->{$_[0]->[0]};
        my %rm = map { $_ => 1 } @{$_[2]->{setmembers}};
        $s->{setmembers} = $_[2]->{action} == 1 ? [ @{$s->{setmembers}}, @{$_[2]->{setmembers}} ] : [ grep { !$rm{$_} } @{$s->{setmembers}} ];
        (200, '') } ],
    [ DELETE => qr{$A/volumesets/([^/]+)$}, sub { delete $st{vsets}->{$_[0]->[0]}; (200, '') } ],
    [ POST => qr{$A/volumesets/([^/]+)$}, sub {
        my $s = $st{vsets}->{$_[0]->[0]};
        my $p = $_[2]->{parameters};
        my $i = 0;
        for my $m (@{$s->{setmembers}}) {
            (my $n = $p->{name}) =~ s/\@count\@/$i++/e;
            $new_vol->(name => $n, copyOf => $m, copyType => 3, sizeMiB => $st{vols}->{$m}->{sizeMiB}, comment => $p->{comment});
        }
        (201, '') } ],
    [ GET => qr{$A/tasks/(\d+)$}, sub {
        my $t = $st{tasks}->{$_[0]->[0]} // [1];
        my $s = @$t > 1 ? shift(@$t) : $t->[0];
        (200, { id => $_[0]->[0], status => $s, ($s == 4 ? (detailedStatus => 'promote failed') : ()) }) } ],
    [ POST => qr{$A/vluns$}, sub {
        my $b = $_[2];
        my ($set) = $b->{hostname} =~ /^set:(.+)$/ or return $err->(400, 1, 'fake: host set exports only');
        my $lun = 0;
        $lun++ while grep { $_->{lun} == $lun && $_->{hostname} eq $b->{hostname} } @{$st{vluns}};
        push @{$st{vluns}}, { volumeName => $b->{volumeName}, lun => $lun, hostname => $b->{hostname}, active => JSON::PP::false, type => 5 };
        # one active VLUN per member host and path, as the array reports them
        push @{$st{vluns}}, map { { volumeName => $b->{volumeName}, lun => $lun, hostname => $_, active => JSON::PP::true, type => 5 } }
            @{$st{hostsets}->{$set}->{setmembers}};
        (201, '', { location => "/api/v1/vluns/$b->{volumeName},$lun,$b->{hostname}" }) } ],
    [ GET => qr{$A/vluns$}, sub {
        my ($f, $v) = $q->($_[1]);
        $members->([ grep { !defined($f) || $_->{$f} eq $v } @{$st{vluns}} ]) } ],
    [ DELETE => qr{$A/vluns/([^,]+),(\d+),(.+)$}, sub {
        my ($v, $l, $h) = @{$_[0]};
        my ($set) = $h =~ /^set:(.+)$/;
        my %drop = map { $_ => 1 } $h, ($set ? @{$st{hostsets}->{$set}->{setmembers}} : ());
        my $n = @{$st{vluns}};
        $st{vluns} = [ grep { !($_->{volumeName} eq $v && $_->{lun} == $l && $drop{$_->{hostname}}) } @{$st{vluns}} ];
        return $err->(404, 19, 'VLUN does not exist') if @{$st{vluns}} == $n;
        (200, '') } ],
]);

# ---------------- registration and naming ----------------

is(PVE::SAN::Array::driver_class('hpe-3par'), $C, 'registered as hpe-3par');
ok(grep({ $_ eq 'hpe-3par' } @{PVE::SAN::Array::types()}), 'in the type list');
is(PVE::SAN::Array::default_port('hpe-3par'), 443, 'WSAPI on 443 (Primera, Alletra 9000)');
is($C->default_no_path_retry, undef, 'multipath-tools default kept (3PARdata: no_path_retry 18)');
ok($C->valid_name('x' x 31) && !$C->valid_name('x' x 32), 'volume and host names: 31 characters');
ok(!$C->valid_name('a b') && !$C->valid_name(''), 'no spaces, not empty');
ok($C->valid_hostcluster_name('x' x 27) && !$C->valid_hostcluster_name('x' x 28), 'host set names: 27 characters');
is($C->object_name_for('node.with:colon' . 'x' x 30), 'node.with_colon' . 'x' x 12, 'object names cleaned and cut to 27');

# ---------------- auth and errors ----------------

my $info = $drv->system_info();
is_deeply($info, { name => 'array1', product => q(HPE Alletra 9060), code_level => '9.5.3', id => '4UW0001234' }, 'system info')
    or diag(explain($info));
my $login = FakeArray::find_call($calls, 'POST', qr{/credentials$});
is_deeply($login->{body}, { user => 'pvesan', password => 'secret' }, 'login body');
is($calls->[-1]->{headers}->{'X-HP3PAR-WSAPI-SessionKey'}, 'K1', 'session key header');

%{$st{sessions}} = (); # key removed on the array (timeout)
$drv->system_info();
is($calls->[-1]->{headers}->{'X-HP3PAR-WSAPI-SessionKey'}, 'K2', 'logged in again after 403');

{
    my ($bad) = FakeArray::driver($C, { password => 'wrong' }, [ [ POST => qr{/credentials$}, sub { $err->(401, 5, 'invalid username or password') } ] ]);
    eval { $bad->system_info() };
    like($@, qr/^HPE 3PAR login to array failed \(HTTP 401\): 5: invalid username or password$/, 'login error text');
}
is(PVE::SAN::Array::HPE3PAR::error_text('{"code":29,"desc":"volume is already exported","ref":"vol1"}'),
    '29: volume is already exported (vol1)', 'error with code, desc and ref');
is(PVE::SAN::Array::HPE3PAR::error_text('{"message":"Forbidden"}'), 'Forbidden', 'message replies');
is(PVE::SAN::Array::HPE3PAR::error_text('<html>busy</html>'), '<html>busy</html>', 'non-JSON reply passed on');

# ---------------- pools and ports ----------------

my $pools = $drv->pools();
is_deeply($pools->[0], { name => 'SSD_r6', status => 'online', capacity => 1048576 * $MIB, free => (1048576 - 266240) * $MIB },
    'CPG with a growth limit: capacity and free');
is_deeply([ @{$pools->[1]}{qw(name capacity free)} ], [ 'FC_r1', undef, undef ], 'CPG without a limit: capacity unknown');
is_deeply($drv->target_ports(), [ '20010002AC012345' ], 'only ready FC target ports');

# ---------------- registration ----------------

my $res = $drv->ensure_hostcluster('pvelab', {
    pvenode01 => [ '21:00:00:24:ff:00:00:01', '21:00:00:24:ff:00:00:02' ],
    pvenode02 => [ '2100000E1E000005' ],
}, sub {});
is_deeply(FakeArray::find_call($calls, 'POST', qr{/hostsets$})->{body}, { name => 'pvelab' }, 'host set created');
is_deeply(FakeArray::find_call($calls, 'POST', qr{/hosts$})->{body},
    { name => 'pvenode01', FCWWNs => [ '21000024FF000001', '21000024FF000002' ], persona => 2 }, 'host body: WWNs, Generic-ALUA');
is_deeply(FakeArray::find_call($calls, 'PUT', qr{/hostsets/pvelab$})->{body}, { action => 1, setmembers => [ 'pvenode01' ] },
    'host added to the host set');
is_deeply($st{hostsets}->{pvelab}->{setmembers}, [ 'pvenode01', 'pvenode02' ], 'both nodes in the host set');
ok($res->{pvenode01}->{created} && $res->{pvenode02}->{joined}, 'result per node');

my $n = @$calls;
$drv->ensure_hostcluster('pvelab', { pvenode01 => [ '21000024FF000001', '21000024FF000002' ], pvenode02 => [ '2100000E1E000005' ] }, sub {});
is(scalar(grep { $_->{method} ne 'GET' } @{$calls}[$n .. $#$calls]), 0, 'idempotent');

$drv->ensure_hostcluster('pvelab', { pvenode02 => [ '2100000E1E000005', '2100000E1E000006' ] }, sub {});
is_deeply(FakeArray::find_call($calls, 'PUT', qr{/hosts/pvenode02$})->{body}, { pathOperation => 1, FCWWNs => [ '2100000E1E000006' ] },
    'missing port added to the host');

eval { $drv->ensure_hostcluster('pvelab', { pvenode09 => [ '10000000C9000099' ] }, sub {}) };
is($@, '', 'existing host reused');
is_deeply($st{hostsets}->{pvelab}->{setmembers}, [ 'pvenode01', 'pvenode02', 'legacy' ], 'existing host joined the set');

my ($legacy) = grep { $_->{name} eq 'legacy' } @{$drv->hosts()};
$drv->remove_host($legacy, 'pvelab');
ok(!$st{hosts}->{legacy} && !grep({ $_ eq 'legacy' } @{$st{hostsets}->{pvelab}->{setmembers}}), 'host removed from the set and deleted');

# ---------------- volume lifecycle ----------------

my $v = $drv->create_volume(name => 'gold_01', pool => 'SSD_r6', size_gib => 100);
is_deeply($st{vols}->{gold_01}->{req}, { name => 'gold_01', cpg => 'SSD_r6', sizeMiB => 102400, tpvv => JSON::PP::true },
    'volume create body (thin)');
is_deeply($v, { id => 'gold_01', name => 'gold_01', pool => 'SSD_r6', capacity => 100 * $GIB,
    uid => $st{vols}->{gold_01}->{wwn}, wwid => "3" . lc($st{vols}->{gold_01}->{wwn}) }, 'volume record with the WWID from its wwn') or diag(explain($v));
$drv->create_volume(name => 'full_01', pool => 'SSD_r6', size_gib => 1, thin => 0);
is($st{vols}->{full_01}->{req}->{tpvv}, JSON::PP::false, 'thick: tpvv false');

eval { $drv->create_volume(name => 'gold_01', pool => 'SSD_r6', size_gib => 1) };
like($@, qr{^HPE 3PAR POST /volumes failed \(HTTP 409\): 22: volume exists$}, 'array error passed on');
eval { $drv->create_volume(name => 'x' x 32, pool => 'SSD_r6', size_gib => 1) };
like($@, qr/invalid volume name/, 'name checked before the call');
eval { $drv->create_volume(name => 'y', pool => 'SSD_r6', size_gib => 1.5) };
like($@, qr/whole number of GiB/, 'size checked');

my $found = $drv->find_volume_by_wwid("3" . lc($st{vols}->{gold_01}->{wwn}));
is($found->{name}, 'gold_01', 'found by WWID');
like(FakeArray::find_call($calls, 'GET', qr{/volumes\?query=})->{url}, qr{\?query=%22wwn%20EQ%2060002AC0}, 'wwn query, upper case');
is($drv->find_volume_by_wwid('3' . lc($wwn->(0xFFF))), undef, 'unknown WWID');
is($drv->find_volume_by_wwid('2abc'), undef, 'not an NAA WWID');

$drv->map_to_hostcluster('gold_01', 'pvelab');
is_deeply(FakeArray::find_call($calls, 'POST', qr{/vluns$})->{body},
    { volumeName => 'gold_01', lun => 0, autoLun => JSON::PP::true, maxAutoLun => 0, hostname => 'set:pvelab' }, 'host set export');
$n = @$calls;
$drv->map_to_hostcluster('gold_01', 'pvelab');
is(scalar(grep { $_->{method} eq 'POST' } @{$calls}[$n .. $#$calls]), 0, 'mapping again is a no-op');
$drv->map_to_hostcluster('full_01', 'pvelab');
is((grep { $_->{volumeName} eq 'full_01' && !$_->{active} } @{$st{vluns}})[0]->{lun}, 1, 'next free LUN');

$drv->expand_volume('gold_01', 50 * $GIB);
is_deeply(FakeArray::find_call($calls, 'PUT', qr{/volumes/gold_01$})->{body}, { action => 3, sizeMiB => 51200 }, 'grow by the added MiB');
is($drv->volume('gold_01')->{capacity}, 150 * $GIB, 'grown');
eval { $drv->expand_volume('gold_01', 1000) };
like($@, qr/multiple of 1 MiB/, 'growth in whole MiB');

eval { $drv->delete_volume('gold_01') };
like($@, qr/34: volume is exported/, 'exported volume not deleted');
$drv->unmap_from_hostcluster('gold_01', 'pvelab');
ok(FakeArray::find_call($calls, 'DELETE', qr{^/api/v1/vluns/gold_01,0,set:pvelab$}), 'host set VLUN deleted');
is(scalar(grep { $_->{volumeName} eq 'gold_01' } @{$st{vluns}}), 0, 'no VLUNs left');
$drv->unmap_from_hostcluster('gold_01', 'pvelab'); # nothing left: no call
$drv->delete_volume('gold_01');
ok(!$st{vols}->{gold_01}, 'volume deleted');
eval { $drv->volume('gold_01') };
like($@, qr/HTTP 404\): 23: volume does not exist/, 'gone');

# ---------------- snapshots ----------------

ok($drv->supports_snapshots && $drv->supports_group_snapshots, 'snapshots and group snapshots offered');
$drv->unmap_from_hostcluster('full_01', 'pvelab');
$drv->delete_volume('full_01');
$drv->create_volume(name => "ds-$_", pool => 'SSD_r6', size_gib => 10) for qw(a b);
$new_vol->(name => 'sched.ds-a', copyOf => 'ds-a', copyType => 3, sizeMiB => 10240, comment => 'nightly'); # the array's own

$drv->{now} = 1_790_100_000;
my $s = $drv->snapshot_create([ 'ds-a' ], 'before-upgrade');
my $mk = FakeArray::find_call($calls, 'POST', qr{/volumes/ds-a$});
is_deeply($mk->{body}, { action => 'createSnapshot', parameters => {
    name => sprintf('ds-a.%x', 1_790_100_000), comment => '{"pvesan":"before-upgrade"}', readOnly => JSON::PP::false } },
    'createSnapshot body: short name, pvesan name in the comment');
is_deeply([ map { [ @$_{qw(id name volume size)} ] } @$s ], [ [ 'ds-a.6ab2c220', 'before-upgrade', 'ds-a', 10 * $GIB ] ],
    'snapshot record') or diag(explain($s));
like(FakeArray::find_call($calls, 'GET', qr{/volumes\?query=%22copyOf})->{url}, qr{%22copyOf%20EQ%20ds-a%22$}, 'listed by copyOf');
is_deeply([ map { $_->{name} } @{$drv->snapshots([ 'ds-a' ])} ], [ 'before-upgrade' ], 'the array\'s own snapshots are not listed');
is(length(sprintf('%s.%x', 'x' x 18, 4_000_000_000) . '-99'), 30, 'longest generated name fits 31');

eval { $drv->snapshot_create([ 'ds-a' ], 'bad_name') };
like($@, qr/invalid snapshot name/, 'snapshot name checked');

$drv->{now} += 60;
my $g = $drv->snapshot_create([ 'ds-a', 'ds-b' ], 'group1');
is_deeply($st{vsets}->{'pvesan-ds-a'}->{setmembers}, [ 'ds-a', 'ds-b' ], 'volume set created');
my $gs = FakeArray::find_call($calls, 'POST', qr{/volumesets/pvesan-ds-a$});
is($gs->{body}->{action}, 'createSnapshot', 'createSnapshot of the volume set');
is($gs->{body}->{parameters}->{name}, sprintf('ds-a.%x-@count@', $drv->{now}), 'member names counted by the array');
is_deeply([ sort map { "$_->{volume}=$_->{name}" } @$g ], [ 'ds-a=group1', 'ds-b=group1' ], 'one member per volume');

$drv->create_volume(name => 'ds-c', pool => 'SSD_r6', size_gib => 10);
$drv->{now} += 60;
$drv->snapshot_create([ 'ds-a', 'ds-b', 'ds-c' ], 'group2');
is_deeply(FakeArray::find_call($calls, 'PUT', qr{/volumesets/pvesan-ds-a$})->{body}, { action => 1, setmembers => [ 'ds-c' ] },
    'new volume added to the set');
is(scalar(grep { $_->{name} eq 'group2' } @{$drv->snapshots([ qw(ds-a ds-b ds-c) ])}), 3, 'set covers all three');

my ($gb) = grep { $_->{volume} eq 'ds-b' && $_->{name} eq 'group1' } @{$drv->snapshots([ 'ds-b' ])};
my $c = $drv->snapshot_clone($gb, 'ds-b_copy');
is_deeply($st{copy}, { action => 'createPhysicalCopy', parameters => {
    destVolume => 'ds-b_copy', destCPG => 'SSD_r6', online => JSON::PP::true, tpvv => JSON::PP::true } }, 'online copy of the snapshot');
is($c->{name}, 'ds-b_copy', 'clone volume');
ok($c->{wwid} && $c->{wwid} ne $drv->volume('ds-b')->{wwid}, 'clone has its own WWID');
is_deeply([ map { $_->{name} } @{$drv->snapshots([ 'ds-b' ])} ], [ 'group1', 'group2' ], 'physical copies are not snapshots');
eval { $drv->snapshot_clone($gb, 'bad name') };
like($@, qr/invalid volume name/, 'clone name checked');

$drv->snapshot_restore('ds-a', $s->[0]);
is_deeply($st{promoted}, [ 'ds-a.6ab2c220', 'ds-a', JSON::PP::true ], 'virtual copy promoted onto its base, online');
is(scalar(grep { $_->{url} =~ m{/tasks/[0-9]+$} } @$calls), 2, 'waited for the promote task');
eval { $drv->snapshot_restore('ds-b', $s->[0]) };
like($@, qr/is not of volume 'ds-b'/, 'snapshot of another volume refused');
{
    my $orig = $st{tasks};
    local $st{tasks} = { %$orig };
    no warnings 'redefine';
    my $put = $drv->can('call');
    local *PVE::SAN::Array::HPE3PAR::call = sub {
        my $r = $put->(@_);
        $st{tasks}->{$r->{taskid}} = [ 4 ] if $_[1] eq 'PUT' && ref($r) eq 'HASH' && $r->{taskid};
        return $r;
    };
    eval { $drv->snapshot_restore('ds-a', $s->[0]) };
    like($@, qr/task \d+ failed: promote failed/, 'failed promote task reported');
}

for my $m (@{$drv->snapshots([ qw(ds-a ds-b ds-c) ])}) { $drv->snapshot_delete($m); }
ok(FakeArray::find_call($calls, 'DELETE', qr{/volumes/ds-a\.6ab2c220$}), 'snapshot volume deleted');
is_deeply($drv->snapshots([ qw(ds-a ds-b ds-c) ]), [], 'all pvesan snapshots gone');
ok($st{vols}->{'sched.ds-a'}, 'the array\'s own snapshot kept');

delete $st{vols}->{'sched.ds-a'};
$drv->delete_volume('ds-a');
is_deeply($st{vsets}->{'pvesan-ds-a'}->{setmembers}, [ 'ds-b', 'ds-c' ], 'deleted volume left the volume set first');
$drv->delete_volume($_) for qw(ds-b ds-c);
ok(!$st{vsets}->{'pvesan-ds-a'}, 'empty volume set removed');

# ---------------- session end ----------------

my $key = $drv->{session_key};
$drv->logout();
ok(FakeArray::find_call($calls, 'DELETE', qr{/credentials/\Q$key\E$}), 'session deleted on logout');
ok(!$st{sessions}->{$key} && !$drv->{session_key}, 'session gone');
$n = @$calls;
undef $drv;
is(scalar(@$calls), $n, 'nothing left to log out on destruction');
{
    my ($d2, $c2) = FakeArray::driver($C, {}, [
        [ POST => qr{/credentials$}, sub { (201, { key => 'Z9' }) } ],
        [ GET => qr{/system$}, sub { (200, { name => 'x' }) } ],
        [ DELETE => qr{/credentials/Z9$}, sub { (200, '') } ],
    ]);
    $d2->system_info();
    undef $d2;
    ok(FakeArray::find_call($c2, 'DELETE', qr{/credentials/Z9$}), 'session deleted when the driver goes away');
}

done_testing();
