package CtrlExecMCP::Server;

use strict;
use warnings;
use JSON::PP ();
use CtrlExecMCP::JsonRpc qw(:all);

# The transport-agnostic MCP method dispatcher. It speaks JSON-RPC 2.0 and
# implements the MCP lifecycle (initialize) and the tools capability
# (tools/list, tools/call). The actual tool set and execution are injected as
# a `catalog` and a `runner`, so the protocol core is testable in isolation and
# the discovery/run backends are wired in separately.
#
#   catalog->list_tools            -> arrayref of MCP tool definitions
#   catalog->has_tool($name)       -> bool
#   runner->call($name, \%args)    -> MCP tool result { content => [...], ... }
#                                     (may die; a failure becomes isError)

# MCP protocol revision this server implements.
our $PROTOCOL_VERSION = '2025-06-18';

sub new {
    my ($class, %opts) = @_;
    die "catalog required" unless $opts{catalog};
    die "runner required"  unless $opts{runner};
    my $self = {
        catalog          => $opts{catalog},
        runner           => $opts{runner},
        name             => $opts{name}    // 'ctrl-exec-mcp',
        version          => $opts{version} // '0.0.0',
        protocol_version => $opts{protocol_version} // $PROTOCOL_VERSION,
        initialized      => 0,
    };
    return bless $self, $class;
}

# Handle one decoded JSON-RPC message. Returns a response object to send, or
# undef when nothing should be sent (notifications).
sub handle {
    my ($self, $msg) = @_;

    unless (valid_message($msg)) {
        my $id = (ref $msg eq 'HASH') ? $msg->{id} : undef;
        return rpc_error($id, JR_INVALID_REQUEST, 'invalid JSON-RPC 2.0 request');
    }

    my $notification = is_notification($msg);
    my $id           = $msg->{id};
    my $method       = $msg->{method};
    my $params       = ref $msg->{params} eq 'HASH' ? $msg->{params} : {};

    # Notifications never get a reply; we only act on the ones we recognise.
    if ($notification) {
        $self->{initialized} = 1 if $method eq 'notifications/initialized';
        return undef;
    }

    return $self->_initialize($id, $params) if $method eq 'initialize';
    return rpc_result($id, {})              if $method eq 'ping';

    if ($method eq 'tools/list' || $method eq 'tools/call') {
        return rpc_error($id, JR_INVALID_REQUEST, 'received before initialize')
            unless $self->{initialized};
        return $self->_tools_list($id, $params) if $method eq 'tools/list';
        return $self->_tools_call($id, $params);
    }

    return rpc_error($id, JR_METHOD_NOT_FOUND, "method not found: $method");
}

# --- handlers ---

sub _initialize {
    my ($self, $id, $params) = @_;
    $self->{initialized} = 1;
    # Respond with the protocol revision we implement. (A future revision may
    # negotiate against $params->{protocolVersion}; for now we state ours.)
    return rpc_result($id, {
        protocolVersion => $self->{protocol_version},
        capabilities    => { tools => { listChanged => JSON::PP::true } },
        serverInfo      => { name => $self->{name}, version => $self->{version} },
    });
}

sub _tools_list {
    my ($self, $id, $params) = @_;
    my $tools = $self->{catalog}->list_tools // [];
    return rpc_result($id, { tools => $tools });
}

sub _tools_call {
    my ($self, $id, $params) = @_;

    my $name = $params->{name};
    return rpc_error($id, JR_INVALID_PARAMS, 'tools/call requires a string "name"')
        unless defined $name && !ref $name;

    my $args = ref $params->{arguments} eq 'HASH' ? $params->{arguments} : {};

    return rpc_error($id, JR_INVALID_PARAMS, "unknown tool: $name")
        unless $self->{catalog}->has_tool($name);

    my $result = eval { $self->{runner}->call($name, $args) };
    if (my $err = $@) {
        chomp $err;
        # A tool-execution failure is reported as a tool result with isError,
        # not as a JSON-RPC protocol error (per the MCP tools spec).
        return rpc_result($id, {
            content => [ { type => 'text', text => "tool execution failed: $err" } ],
            isError => JSON::PP::true,
        });
    }
    return rpc_result($id, $result);
}

1;
