package FakeArray;

# Route-table fake for array drivers that use PVE::SAN::Array::Base::request:
#   my ($drv, $calls) = FakeArray::driver($class, \%cfg, [ [METHOD, qr{path}, sub {...}], ... ]);
# A handler gets ($captures_arrayref, \%query, $body, $headers) and returns
# (code, perl-data-or-string[, \%response_headers]). Unrouted requests: 404.

use strict;
use warnings;

use JSON::PP;

my $json = JSON::PP->new->canonical->allow_nonref;

sub unescape { my ($s) = @_; $s =~ s/%([0-9A-F]{2})/chr(hex($1))/ge; return $s; }

sub driver {
    my ($class, $cfg, $routes) = @_;
    my @calls;
    my $transport = sub {
        my ($method, $url, $headers, $body) = @_;
        push @calls, { method => $method, url => $url, headers => $headers, body => $body };
        my ($path, $qs) = split(/\?/, $url, 2);
        my %q = map { my ($k, $v) = split(/=/, $_, 2); (unescape($k) => unescape($v // '')) } split(/&/, $qs // '');
        for my $r (@$routes) {
            my ($m, $re, $h) = @$r;
            next if $m ne $method;
            my @cap = $path =~ $re or next;
            my ($code, $data, $rh) = $h->(\@cap, \%q, $body, $headers);
            my $content = ref($data) ? $json->encode($data) : ($data // '');
            return ($code, $content, $rh // {});
        }
        return (404, "no route for $method $path", {});
    };
    my $drv = $class->new(address => 'array', username => 'pvesan', password => 'secret',
        transport => $transport, %$cfg);
    return ($drv, \@calls);
}

sub find_call {
    my ($calls, $method, $re) = @_;
    my ($c) = grep { $_->{method} eq $method && $_->{url} =~ $re } @$calls;
    return $c;
}

1;
