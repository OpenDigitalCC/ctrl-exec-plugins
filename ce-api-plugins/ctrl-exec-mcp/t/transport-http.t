#!/usr/bin/perl
use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../lib";
use JSON::PP qw(encode_json decode_json);

use CtrlExecMCP::Transport::Http;

# A fake MCP server that records the token it was built with and the messages
# it handled; notifications (no id) get no reply.
{
    package FakeServer;
    sub new { bless { token => $_[1], handled => [] }, $_[0] }
    sub handle {
        my ($self, $msg) = @_;
        push @{ $self->{handled} }, $msg;
        return undef unless exists $msg->{id};
        return { jsonrpc => '2.0', id => $msg->{id},
                 result => { method => $msg->{method} } };
    }
}

# Build a transport with a deterministic id and a make_server that records
# every server it creates (so we can assert token mapping and session reuse).
sub transport {
    my @created;
    my $ids = ['sess-1', 'sess-2', 'sess-3'];
    my $t = CtrlExecMCP::Transport::Http->new(
        make_server => sub { my $s = FakeServer->new($_[0]); push @created, $s; $s },
        idgen       => sub { shift @$ids },
    );
    return ($t, \@created);
}

sub post {
    my ($t, $headers, $obj) = @_;
    return $t->handle_request(method => 'POST', path => '/', headers => $headers,
                              body => encode_json($obj));
}

# --- initialize mints a session, maps the bearer token, returns the result ---
{
    my ($t, $created) = transport();
    my $r = post($t, { authorization => 'Bearer op-token' },
        { jsonrpc => '2.0', id => 1, method => 'initialize', params => {} });

    is $r->{status}, 200,                       'initialize -> 200';
    is $r->{headers}{'Mcp-Session-Id'}, 'sess-1','session id returned';
    my $body = decode_json($r->{body});
    is $body->{result}{method}, 'initialize',    'initialize dispatched to the server';
    is scalar(@$created), 1,                     'one server created';
    is $created->[0]{token}, 'op-token',         'bearer token bound to the session server';
}

# --- subsequent request with the session id reuses the same server ---
{
    my ($t, $created) = transport();
    post($t, { authorization => 'Bearer tok' },
        { jsonrpc => '2.0', id => 1, method => 'initialize' });

    my $r = post($t, { 'mcp-session-id' => 'sess-1' },
        { jsonrpc => '2.0', id => 2, method => 'tools/list' });
    is $r->{status}, 200,                'session request -> 200';
    is scalar(@$created), 1,             'no new server created for the session';
    is scalar(@{ $created->[0]{handled} }), 2, 'same server handled both messages';
}

# --- non-initialize without a known session is rejected ---
{
    my ($t) = transport();
    my $r = post($t, {}, { jsonrpc => '2.0', id => 9, method => 'tools/list' });
    is $r->{status}, 404, 'no session -> 404';
    my $body = decode_json($r->{body});
    is $body->{error}{code}, CtrlExecMCP::JsonRpc::JR_INVALID_REQUEST(), 'JSON-RPC error in body';
    is $body->{id}, 9, 'error echoes the request id';

    my $r2 = post($t, { 'mcp-session-id' => 'ghost' },
        { jsonrpc => '2.0', id => 9, method => 'tools/list' });
    is $r2->{status}, 404, 'unknown session id -> 404';
}

# --- notification gets 202 and no body ---
{
    my ($t) = transport();
    post($t, {}, { jsonrpc => '2.0', id => 1, method => 'initialize' });
    my $r = $t->handle_request(method => 'POST', path => '/',
        headers => { 'mcp-session-id' => 'sess-1' },
        body => encode_json({ jsonrpc => '2.0', method => 'notifications/initialized' }));
    is $r->{status}, 202, 'notification -> 202';
    is $r->{body}, '',    'notification has no body';
}

# --- DELETE terminates the session ---
{
    my ($t) = transport();
    post($t, {}, { jsonrpc => '2.0', id => 1, method => 'initialize' });
    my $d = $t->handle_request(method => 'DELETE', path => '/',
        headers => { 'mcp-session-id' => 'sess-1' }, body => '');
    is $d->{status}, 200, 'DELETE -> 200';
    my $r = post($t, { 'mcp-session-id' => 'sess-1' },
        { jsonrpc => '2.0', id => 2, method => 'tools/list' });
    is $r->{status}, 404, 'session gone after DELETE';
}

# --- GET (server stream) is not supported ---
{
    my ($t) = transport();
    my $r = $t->handle_request(method => 'GET', path => '/', headers => {}, body => '');
    is $r->{status}, 405, 'GET -> 405';
    like $r->{headers}{Allow}, qr/POST/, 'Allow header advertises POST';
}

# --- malformed body -> 400 parse error ---
{
    my ($t) = transport();
    my $r = $t->handle_request(method => 'POST', path => '/', headers => {}, body => 'not json');
    is $r->{status}, 400, 'bad body -> 400';
    my $body = decode_json($r->{body});
    is $body->{error}{code}, CtrlExecMCP::JsonRpc::JR_PARSE_ERROR(), 'parse error code';
}

# --- session table is bounded (oldest evicted) ---
{
    my @ids = map { "s$_" } 1 .. 5;
    my $t = CtrlExecMCP::Transport::Http->new(
        make_server  => sub { FakeServer->new($_[0]) },
        idgen        => sub { shift @ids },
        max_sessions => 2,
    );
    post($t, {}, { jsonrpc => '2.0', id => 1, method => 'initialize' });  # s1
    post($t, {}, { jsonrpc => '2.0', id => 1, method => 'initialize' });  # s2
    post($t, {}, { jsonrpc => '2.0', id => 1, method => 'initialize' });  # s3 -> evicts s1
    my $r = post($t, { 'mcp-session-id' => 's1' },
        { jsonrpc => '2.0', id => 2, method => 'tools/list' });
    is $r->{status}, 404, 'oldest session evicted past the cap';
    my $r2 = post($t, { 'mcp-session-id' => 's3' },
        { jsonrpc => '2.0', id => 2, method => 'tools/list' });
    is $r2->{status}, 200, 'newest session still valid';
}

done_testing;
