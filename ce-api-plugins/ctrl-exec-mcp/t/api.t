#!/usr/bin/perl
use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../lib";
use JSON::PP qw(encode_json decode_json);

use CtrlExecMCP::Api;

# Fake HTTP agent recording the last call and returning a canned response.
{
    package FakeUA;
    sub new { bless { resp => $_[1], calls => [] }, $_[0] }
    sub post {
        my ($self, $url, $args) = @_;
        push @{ $self->{calls} }, { method => 'POST', url => $url, args => $args };
        return $self->{resp};
    }
    sub get {
        my ($self, $url) = @_;
        push @{ $self->{calls} }, { method => 'GET', url => $url };
        return $self->{resp};
    }
}

# --- run(): posts async to /run with the token, parses 202 ---
{
    my $body = encode_json({ ok => JSON::PP::true, async => JSON::PP::true, reqid => 'r1' });
    my $ua = FakeUA->new({ success => 1, status => 202, content => $body });
    my $api = CtrlExecMCP::Api->new(url => 'http://api:7445/', token => 'tok', ua => $ua);

    my $res = $api->run(hosts => ['web-01'], script => 'check-disk', args => ['90']);
    ok $res->{ok},               'run reports ok for 202';
    is $res->{status}, 202,      'status carried';
    is $res->{data}{reqid}, 'r1','reqid parsed';

    my $call = $ua->{calls}[0];
    is $call->{method}, 'POST',  'run uses POST';
    is $call->{url}, 'http://api:7445/run', 'posts to /run (slash trimmed)';
    my $sent = decode_json($call->{args}{content});
    is_deeply $sent->{hosts}, ['web-01'], 'hosts sent';
    is $sent->{script}, 'check-disk',     'script sent';
    is_deeply $sent->{args}, ['90'],      'args sent';
    is $sent->{token}, 'tok',             'token sent';
    ok $sent->{async},                    'async flag set';
}

# --- status(): GETs /status/{reqid} ---
{
    my $body = encode_json({ ok => JSON::PP::true, reqid => 'r1', complete => JSON::PP::true,
                             hosts => { 'web-01' => { status => 'done', exit => 0 } } });
    my $ua = FakeUA->new({ success => 1, status => 200, content => $body });
    my $api = CtrlExecMCP::Api->new(url => 'http://api:7445', ua => $ua);

    my $res = $api->status('r1');
    ok $res->{ok}, 'status ok';
    is $ua->{calls}[0]{method}, 'GET', 'status uses GET';
    is $ua->{calls}[0]{url}, 'http://api:7445/status/r1', 'gets /status/{reqid}';
    ok $res->{data}{complete}, 'parsed complete flag';
}

# --- failure -> ok false, data undef-safe ---
{
    my $ua = FakeUA->new({ success => 0, status => 500, content => 'boom' });
    my $api = CtrlExecMCP::Api->new(ua => $ua);
    my $res = $api->status('r1');
    ok !$res->{ok},        'unsuccessful response -> ok false';
    is $res->{status}, 500,'status carried on failure';
}

done_testing;
