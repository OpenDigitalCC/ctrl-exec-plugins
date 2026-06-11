#!/usr/bin/perl
use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../lib";

use CtrlExecMCP::Server;

# --- fakes: a fixed catalogue and an echoing runner ---
{
    package FakeCatalog;
    sub new { bless { tools => $_[1], refresh => $_[2] }, $_[0] }
    sub list_tools { $_[0]{tools} }
    sub has_tool {
        my ($self, $name) = @_;
        return scalar grep { $_->{name} eq $name } @{ $self->{tools} };
    }
    sub refresh { $_[0]{refresh} ? 1 : 0 }

    package FakeRunner;
    sub new { bless {}, shift }
    sub call {
        my ($self, $name, $args) = @_;
        die "boom\n" if $name eq 'explode';
        return { content => [ { type => 'text', text => "ran $name" } ] };
    }
}

sub new_server {
    my $tools = [
        { name => 'check-disk', description => 'check disk', inputSchema => { type => 'object' } },
        { name => 'pg-backup',  description => 'backup',     inputSchema => { type => 'object' } },
    ];
    return CtrlExecMCP::Server->new(
        catalog => FakeCatalog->new($tools),
        runner  => FakeRunner->new,
        name    => 'ctrl-exec-mcp',
        version => '9.9.9',
        list_changed => 1,
    );
}

# Drive initialize so tools/* are unlocked.
sub init { $_[0]->handle({ jsonrpc => '2.0', id => 0, method => 'initialize', params => {} }) }

# --- initialize handshake ---
{
    my $s = new_server();
    my $r = init($s);
    is $r->{id}, 0, 'initialize echoes id';
    is $r->{result}{protocolVersion}, $CtrlExecMCP::Server::PROTOCOL_VERSION,
        'advertises protocol version';
    ok $r->{result}{capabilities}{tools}{listChanged}, 'declares tools.listChanged';
    is $r->{result}{serverInfo}{name},    'ctrl-exec-mcp', 'serverInfo name';
    is $r->{result}{serverInfo}{version}, '9.9.9',         'serverInfo version';
}

# --- ping ---
{
    my $s = new_server();
    my $r = $s->handle({ jsonrpc => '2.0', id => 1, method => 'ping' });
    is_deeply $r->{result}, {}, 'ping returns empty result';
}

# --- tools/* gated on initialize ---
{
    my $s = new_server();
    my $r = $s->handle({ jsonrpc => '2.0', id => 2, method => 'tools/list' });
    is $r->{error}{code}, CtrlExecMCP::JsonRpc::JR_INVALID_REQUEST(),
        'tools/list before initialize is rejected';
}

# --- tools/list ---
{
    my $s = new_server();
    init($s);
    my $r = $s->handle({ jsonrpc => '2.0', id => 3, method => 'tools/list' });
    is scalar @{ $r->{result}{tools} }, 2, 'lists both tools';
    is $r->{result}{tools}[0]{name}, 'check-disk', 'tool name surfaced';
    ok exists $r->{result}{tools}[0]{inputSchema}, 'inputSchema surfaced';
}

# --- tools/call: success ---
{
    my $s = new_server();
    init($s);
    my $r = $s->handle({ jsonrpc => '2.0', id => 4, method => 'tools/call',
        params => { name => 'check-disk', arguments => { threshold => 90 } } });
    is $r->{result}{content}[0]{text}, 'ran check-disk', 'runner result returned';
    ok !$r->{result}{isError}, 'success is not an error';
}

# --- tools/call: unknown tool -> invalid params ---
{
    my $s = new_server();
    init($s);
    my $r = $s->handle({ jsonrpc => '2.0', id => 5, method => 'tools/call',
        params => { name => 'nope' } });
    is $r->{error}{code}, CtrlExecMCP::JsonRpc::JR_INVALID_PARAMS(), 'unknown tool -> -32602';
}

# --- tools/call: missing name -> invalid params ---
{
    my $s = new_server();
    init($s);
    my $r = $s->handle({ jsonrpc => '2.0', id => 6, method => 'tools/call', params => {} });
    is $r->{error}{code}, CtrlExecMCP::JsonRpc::JR_INVALID_PARAMS(), 'missing name -> -32602';
}

# --- tools/call: runner failure -> isError result, not a protocol error ---
{
    my $s = new_server();
    init($s);
    # 'explode' is not in the catalogue, so add it via a catalogue that knows it.
    $s = CtrlExecMCP::Server->new(
        catalog => FakeCatalog->new([ { name => 'explode' } ]),
        runner  => FakeRunner->new,
    );
    init($s);
    my $r = $s->handle({ jsonrpc => '2.0', id => 7, method => 'tools/call',
        params => { name => 'explode' } });
    ok !exists $r->{error}, 'execution failure is not a JSON-RPC error';
    ok $r->{result}{isError}, 'execution failure sets isError';
    like $r->{result}{content}[0]{text}, qr/boom/, 'failure detail surfaced';
}

# --- unknown method -> method not found ---
{
    my $s = new_server();
    init($s);
    my $r = $s->handle({ jsonrpc => '2.0', id => 8, method => 'resources/list' });
    is $r->{error}{code}, CtrlExecMCP::JsonRpc::JR_METHOD_NOT_FOUND(), 'unknown method -> -32601';
}

# --- notifications get no reply ---
{
    my $s = new_server();
    is $s->handle({ jsonrpc => '2.0', method => 'notifications/initialized' }), undef,
        'initialized notification returns nothing';
    is $s->handle({ jsonrpc => '2.0', method => 'notifications/whatever' }), undef,
        'unknown notification ignored';
    # initialized via notification also unlocks tools/*
    my $r = $s->handle({ jsonrpc => '2.0', id => 9, method => 'tools/list' });
    ok $r->{result}, 'initialized notification unlocked tools/list';
}

# --- malformed request -> invalid request ---
{
    my $s = new_server();
    my $r = $s->handle({ jsonrpc => '2.0' });   # no method
    is $r->{error}{code}, CtrlExecMCP::JsonRpc::JR_INVALID_REQUEST(), 'no method -> -32600';
}

# --- listChanged capability reflects whether the server can push ---
{
    my $with = new_server();   # built with list_changed => 1
    ok init($with)->{result}{capabilities}{tools}{listChanged},
        'listChanged advertised true when the server can push';

    my $without = CtrlExecMCP::Server->new(
        catalog => FakeCatalog->new([]), runner => FakeRunner->new);
    ok !init($without)->{result}{capabilities}{tools}{listChanged},
        'listChanged advertised false by default';
}

# --- poll_list_changed: notifies only when advertised and the set changed ---
{
    my $changed = CtrlExecMCP::Server->new(
        catalog => FakeCatalog->new([], 1), runner => FakeRunner->new, list_changed => 1);
    my $note = $changed->poll_list_changed;
    is $note->{method}, 'notifications/tools/list_changed', 'change -> notification object';
    ok !exists $note->{id}, 'notification has no id';

    my $unchanged = CtrlExecMCP::Server->new(
        catalog => FakeCatalog->new([], 0), runner => FakeRunner->new, list_changed => 1);
    is $unchanged->poll_list_changed, undef, 'no change -> no notification';

    my $disabled = CtrlExecMCP::Server->new(
        catalog => FakeCatalog->new([], 1), runner => FakeRunner->new);  # list_changed off
    is $disabled->poll_list_changed, undef, 'not advertised -> never notifies';
}

done_testing;
