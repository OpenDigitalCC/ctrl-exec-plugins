package CtrlExecMCP::JsonRpc;

use strict;
use warnings;
use Exporter 'import';

# JSON-RPC 2.0 framing helpers and the standard error codes, shared by the
# transport (stdio / HTTP) and the MCP method dispatcher. Pure data - no IO.

our @EXPORT_OK = qw(
    JR_PARSE_ERROR JR_INVALID_REQUEST JR_METHOD_NOT_FOUND
    JR_INVALID_PARAMS JR_INTERNAL_ERROR
    rpc_result rpc_error valid_message is_notification
);
our %EXPORT_TAGS = (all => \@EXPORT_OK);

use constant {
    JR_PARSE_ERROR      => -32700,
    JR_INVALID_REQUEST  => -32600,
    JR_METHOD_NOT_FOUND => -32601,
    JR_INVALID_PARAMS   => -32602,
    JR_INTERNAL_ERROR   => -32603,
};

# A successful response object for request $id (which may be undef/null).
sub rpc_result {
    my ($id, $result) = @_;
    return { jsonrpc => '2.0', id => $id, result => $result };
}

# An error response object. $data is optional.
sub rpc_error {
    my ($id, $code, $message, $data) = @_;
    my %err = (code => $code, message => $message);
    $err{data} = $data if defined $data;
    return { jsonrpc => '2.0', id => $id, error => \%err };
}

# True if $m is a well-formed JSON-RPC 2.0 object carrying a method name.
sub valid_message {
    my ($m) = @_;
    return 0 unless ref $m eq 'HASH';
    return 0 unless defined $m->{jsonrpc} && $m->{jsonrpc} eq '2.0';
    return 0 unless defined $m->{method} && !ref $m->{method};
    return 1;
}

# A notification is a request with no `id` member (no response is sent).
sub is_notification {
    my ($m) = @_;
    return ref $m eq 'HASH' && !exists $m->{id};
}

1;
