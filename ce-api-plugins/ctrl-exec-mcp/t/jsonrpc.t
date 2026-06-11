#!/usr/bin/perl
use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../lib";

use CtrlExecMCP::JsonRpc qw(:all);

# --- error code constants ---
is JR_PARSE_ERROR,      -32700, 'parse error code';
is JR_INVALID_REQUEST,  -32600, 'invalid request code';
is JR_METHOD_NOT_FOUND, -32601, 'method not found code';
is JR_INVALID_PARAMS,   -32602, 'invalid params code';
is JR_INTERNAL_ERROR,   -32603, 'internal error code';

# --- rpc_result ---
{
    my $r = rpc_result(7, { ok => 1 });
    is $r->{jsonrpc}, '2.0',  'result is 2.0';
    is $r->{id},      7,      'result echoes id';
    is_deeply $r->{result}, { ok => 1 }, 'result payload carried';
    ok !exists $r->{error}, 'result has no error member';
}

# --- rpc_error, with and without data ---
{
    my $e = rpc_error(7, JR_INVALID_PARAMS, 'bad', { field => 'name' });
    is $e->{jsonrpc},     '2.0',            'error is 2.0';
    is $e->{id},          7,                'error echoes id';
    is $e->{error}{code}, JR_INVALID_PARAMS,'error code carried';
    is $e->{error}{message}, 'bad',         'error message carried';
    is_deeply $e->{error}{data}, { field => 'name' }, 'error data carried';
    ok !exists $e->{result}, 'error has no result member';

    my $e2 = rpc_error(undef, JR_PARSE_ERROR, 'parse error');
    ok !exists $e2->{error}{data}, 'data omitted when not given';
    ok exists $e2->{id} && !defined $e2->{id}, 'null id preserved';
}

# --- valid_message ---
ok  valid_message({ jsonrpc => '2.0', method => 'ping' }), 'well-formed request is valid';
ok  valid_message({ jsonrpc => '2.0', method => 'x', id => 1, params => {} }), 'with id/params valid';
ok !valid_message({ method => 'ping' }),               'missing jsonrpc invalid';
ok !valid_message({ jsonrpc => '1.0', method => 'p' }),'wrong version invalid';
ok !valid_message({ jsonrpc => '2.0' }),               'missing method invalid';
ok !valid_message({ jsonrpc => '2.0', method => {} }), 'non-scalar method invalid';
ok !valid_message([ 1, 2 ]),                            'array (batch) invalid';
ok !valid_message('nope'),                              'scalar invalid';

# --- is_notification ---
ok  is_notification({ jsonrpc => '2.0', method => 'notifications/initialized' }), 'no id => notification';
ok !is_notification({ jsonrpc => '2.0', method => 'ping', id => 1 }), 'with id => not notification';
ok !is_notification({ jsonrpc => '2.0', method => 'p', id => undef }), 'explicit null id => request';

done_testing;
