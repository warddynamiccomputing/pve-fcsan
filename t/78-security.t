use strict;
use warnings;

use Test::More;

use StubPVE;
use PVE::SAN::Array::Base;
use PVE::SAN::Fabric::Base;
use PVE::SAN::DR;

my $B = 'PVE::SAN::Array::Base';
my $FP = 'sha256$' . ('ab' x 32);

# ---------------- the certificate pin is the only thing trusted ----------------
{
    no warnings qw(redefine once);
    my $digest;
    local *PVE::SAN::Array::Base::cert_sha256 = sub { $digest };
    my $v = $B->can('pin_verifier')->($FP);

    $digest = 'ab' x 32;
    is($v->(0, undef, '', 0, 'cert', 0), 1, 'server certificate with the pinned fingerprint is accepted');
    is($v->(0, undef, '', 0, 'cert', 0), 1, '... even when CA verification failed (self-signed)');
    $digest = 'cd' x 32;
    is($v->(1, undef, '', 0, 'cert', 0), 0, 'another certificate is refused even when a CA vouches for it');
    is($v->(0, undef, '', 0, 'cert', 1), 1, 'chain certificates do not decide');
    $digest = 'ab' x 32;
    is($B->can('pin_verifier')->(uc($FP) =~ s/^SHA256/sha256/r)->(0, undef, '', 0, 'cert', 0), 1,
        'upper-case fingerprints still match');
    ok(!eval { $B->can('pin_verifier')->('sha256$1234'); 1 }, 'a malformed fingerprint is refused');
    ok(!eval { $B->can('pin_verifier')->(undef); 1 }, 'a missing fingerprint is refused');
}

SKIP: {
    skip 'LWP::UserAgent not installed', 7 if !eval { require LWP::UserAgent; 1 };
    my $self = bless { address => '192.0.2.1', port => 443, fingerprint => $FP }, $B;
    my $ua = $self->ua;
    is($ua->max_redirect, 0, 'redirects are not followed');
    is_deeply($ua->protocols_allowed, ['https'], 'HTTPS only');
    is($ua->max_size, $PVE::SAN::Array::Base::MAX_RESPONSE, 'replies are size-limited');
    my $ssl = { map { $_ => $ua->ssl_opts($_) } $ua->ssl_opts };
    is(ref($ssl->{SSL_verify_callback}), 'CODE', 'certificate checked by the pin callback');
    ok(!exists($ssl->{SSL_fingerprint}), 'SSL_fingerprint (pin plus CA trust) is not used');
    is($ssl->{SSL_verify_mode}, 1, 'peer verification on');

    my $fab = bless { address => '192.0.2.2', port => 443, fingerprint => $FP }, 'PVE::SAN::Fabric::Base';
    is(ref({ map { $_ => $fab->ua->ssl_opts($_) } $fab->ua->ssl_opts }->{SSL_verify_callback}), 'CODE',
        'switch connections use the same pin');
}

# A real TLS handshake: the server's certificate is signed by a CA the client
# trusts, so only the pin can refuse it.
SKIP: {
    skip 'IO::Socket::SSL::Utils not installed', 2
        if !eval { require IO::Socket::SSL; require IO::Socket::SSL::Utils; require Net::SSLeay; 1 };
    skip 'no fork', 2 if $^O eq 'MSWin32';
    IO::Socket::SSL::Utils->import(qw(CERT_create));
    my ($ca, $cakey) = CERT_create(CA => 1, subject => { CN => 'test CA' });
    my ($cert, $key) = CERT_create(issuer => [ $ca, $cakey ], subject => { CN => 'array.test' }, purpose => 'server');
    my $right = 'sha256$' . lc(unpack('H*', Net::SSLeay::X509_digest($cert, Net::SSLeay::EVP_get_digestbyname('sha256'))));

    # Plain TCP listener; the child does each server handshake itself. Every
    # step has a timeout so a stalled handshake fails the test, never hangs it.
    require IO::Socket::INET;
    require POSIX;
    my $srv = IO::Socket::INET->new(Listen => 5, LocalAddr => '127.0.0.1', LocalPort => 0, ReuseAddr => 1)
        or die "listen: $!";
    my $port = $srv->sockport;
    my $pid = fork() // die "fork: $!";
    if (!$pid) {
        alarm(60);
        while (my $c = $srv->accept) {
            IO::Socket::SSL->start_SSL($c, SSL_server => 1, SSL_cert => $cert, SSL_key => $key, Timeout => 10);
            close($c);
        }
        POSIX::_exit(0); # no Test::More END block in the child
    }
    close($srv);
    my $connect = sub {
        my ($opts) = @_;
        my $s = IO::Socket::SSL->new(PeerHost => '127.0.0.1', PeerPort => $port, SSL_ca => [ $ca ],
            Timeout => 10, %$opts);
        close($s) if $s;
        return $s ? 1 : 0;
    };
    is($connect->({ SSL_verify_mode => 1, SSL_verify_callback => $B->can('pin_verifier')->($right),
        SSL_verifycn_scheme => 'none' }), 1, 'pinned certificate: handshake succeeds');
    is($connect->({ SSL_verify_mode => 1, SSL_verify_callback => $B->can('pin_verifier')->($FP),
        SSL_verifycn_scheme => 'none' }), 0, 'CA-signed but not the pinned certificate: refused');
    # For reference only, not a test (it depends on the IO::Socket::SSL
    # version): older versions let a CA-signed certificate through when only
    # SSL_fingerprint is set, which is why pvesan checks the pin itself.
    diag('IO::Socket::SSL ' . IO::Socket::SSL->VERSION . ': SSL_fingerprint alone '
        . ($connect->({ SSL_verify_mode => 1, SSL_fingerprint => $FP, SSL_verifycn_scheme => 'none' })
            ? 'accepts' : 'refuses') . ' a CA-signed certificate that is not pinned');
    kill('TERM', $pid);
    waitpid($pid, 0);
}

# ---------------- DR metadata from a replica is checked ----------------
{
    my $out = '';
    open(my $fh, '>', \$out);
    my $old = select($fh);
    my $g = PVE::SAN::DR::valid_guests([
        { vmid => 101, type => 'qemu', config => "name: a\n" },
        { vmid => '../../storage', type => 'qemu', config => '' },
        { vmid => 5, type => 'qemu', config => '' },
        { vmid => 102, type => 'openvz', config => '' },
        { vmid => 103, type => 'lxc', config => { evil => 1 } },
        'junk',
        { vmid => 1_000_000_000, type => 'lxc', config => '' },
        { vmid => 104, type => 'lxc', config => "hostname: b\n" },
    ]);
    select($old);
    is_deeply([ map { $_->{vmid} } @$g ], [ 101, 104 ], 'only well-formed guest records are imported');
    is(scalar(() = $out =~ /malformed guest record/g), 6, 'each skipped record is reported');
    unlike($out, qr{\.\./}, 'odd VM IDs are not echoed');
    is_deeply(PVE::SAN::DR::valid_guests(undef), [], 'missing guest list');

    my ($text, $notes) = PVE::SAN::DR::dr_guest_config("name: a\nhookscript: local:snippets/x.pl\nargs: -no-hpet\nmemory: 512",
        type => 'qemu', from => 'src', to => 'dst', old => 101, new => 101, storages => {});
    unlike($text, qr/hookscript/, 'a hookscript is not taken over from a replica');
    like($text, qr/^args: -no-hpet$/m, 'args are kept');
    ok((grep { /hookscript .* left out/ } @$notes) && (grep { /args .* check them/ } @$notes), 'both are reported');
}

# ---------------- every GUI grid column list is HTML-safe ----------------
{
    open(my $fh, '<', 'www/pvesan.js') or die "www/pvesan.js: $!";
    my $js = do { local $/; <$fh> };
    close($fh);
    my @lists = $js =~ /\bcolumns:\s*([^\s\d][^\n]{0,40})/g;
    ok(@lists > 10, 'column lists found');
    my @raw = grep { !/^PVE\.san\.Utils\.safeColumns\(/ } @lists;
    is_deeply(\@raw, [], 'every column list goes through PVE.san.Utils.safeColumns');
    like($js, qr/safeColumns: function\(columns\)/, 'safeColumns is defined');
    my @plain = $js =~ /renderer:\s*(?:v|\(v[^)]*\))\s*=>\s*(v\b[^,}\n]*|`\$\{v\}[^`]*`)/g;
    is_deeply(\@plain, [], 'no renderer returns its value unencoded');
    my ($paths) = $js =~ /renderPaths: function\(value, meta, rec\) \{(.*?)\n    \},/s;
    ok(defined($paths) && $paths =~ /Number\(rec\.data\.paths_total\)/ && $paths =~ /Number\(rec\.data\.paths_active\)/,
        'path counts are rendered as numbers only');
}

done_testing();
