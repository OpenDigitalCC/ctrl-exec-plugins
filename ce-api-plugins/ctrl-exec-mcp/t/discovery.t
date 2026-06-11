#!/usr/bin/perl
use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../lib";
use JSON::PP qw(encode_json);

use CtrlExecMCP::Discovery;

# A fake HTTP agent that records the request and returns a canned response.
{
    package FakeUA;
    sub new { bless { resp => $_[1] }, $_[0] }
    sub post {
        my ($self, $url, $args) = @_;
        $self->{last_url}  = $url;
        $self->{last_args} = $args;
        return $self->{resp};
    }
}

# --- success: returns the hosts map and posts the token to /discovery ---
{
    my $body = encode_json({ ok => JSON::PP::true, hosts => {
        'web-01' => { status => 'ok', scripts => [ { name => 'check-disk' } ] },
    } });
    my $ua = FakeUA->new({ success => 1, status => 200, content => $body });
    my $d  = CtrlExecMCP::Discovery->new(url => 'http://api:7445/', token => 'tok', ua => $ua);

    my $hosts = $d->hosts;
    is_deeply [ sort keys %$hosts ], ['web-01'], 'returns the hosts map';
    is $hosts->{'web-01'}{scripts}[0]{name}, 'check-disk', 'scripts carried through';

    like $ua->{last_url}, qr{^http://api:7445/discovery$},
        'trailing slash trimmed, posts to /discovery';
    like $ua->{last_args}{content}, qr/"token"\s*:\s*"tok"/, 'token forwarded in body';
}

# --- transport failure -> empty map (degrade, do not crash) ---
{
    my $ua = FakeUA->new({ success => 0, status => 599, content => 'connect failed' });
    my $d  = CtrlExecMCP::Discovery->new(ua => $ua);
    is_deeply $d->hosts, {}, 'unsuccessful response yields empty map';
}

# --- malformed JSON / missing hosts -> empty map ---
{
    my $ua1 = FakeUA->new({ success => 1, status => 200, content => 'not json' });
    is_deeply(CtrlExecMCP::Discovery->new(ua => $ua1)->hosts, {}, 'invalid JSON yields empty map');

    my $ua2 = FakeUA->new({ success => 1, status => 200, content => '{"ok":true}' });
    is_deeply(CtrlExecMCP::Discovery->new(ua => $ua2)->hosts, {}, 'missing hosts yields empty map');
}

done_testing;
