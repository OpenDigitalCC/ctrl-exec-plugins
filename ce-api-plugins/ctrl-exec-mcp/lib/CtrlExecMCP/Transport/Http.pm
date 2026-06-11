package CtrlExecMCP::Transport::Http;

use strict;
use warnings;
use JSON::PP qw(encode_json decode_json);
use CtrlExecMCP::JsonRpc qw(rpc_error JR_PARSE_ERROR JR_INVALID_REQUEST);

# The MCP Streamable HTTP transport. A single endpoint accepts POSTed JSON-RPC
# messages and returns the JSON-RPC response (application/json); notifications
# return 202 with no body. We do not offer the optional server->client SSE
# stream (no server-initiated messages yet), so GET returns 405.
#
# Lifecycle / identity: `initialize` mints a session (returned in the
# Mcp-Session-Id header) and a per-session MCP server bound to the token from
# the request's Authorization: Bearer header - so each HTTP client's identity is
# forwarded to ctrl-exec's auth hook. Subsequent requests carry the session id;
# an unknown/absent session for a non-initialize method is rejected so the
# client re-initialises.
#
# `make_server->($token)` builds a fully-wired MCP server for an identity.
# Socket handling lives in the entry point; this module is pure request->response
# and is unit-tested without networking.

sub new {
    my ($class, %opts) = @_;
    die "make_server required" unless ref $opts{make_server} eq 'CODE';
    return bless {
        make_server  => $opts{make_server},
        idgen        => $opts{idgen} // \&_random_id,
        max_sessions => $opts{max_sessions} // 256,
        sessions     => {},          # id => { server => $srv, seq => $n }
        seq          => 0,
    }, $class;
}

# Handle one parsed HTTP request. Args: method, path, headers (hashref with
# lowercase keys), body (string). Returns { status, headers, body }.
sub handle_request {
    my ($self, %r) = @_;
    my $method  = uc($r{method} // '');
    my $headers = $r{headers} // {};
    my $sid     = $headers->{'mcp-session-id'};

    if ($method eq 'DELETE') {
        delete $self->{sessions}{$sid} if defined $sid;
        return _resp(200, {}, '');
    }
    if ($method eq 'GET') {
        return _resp(405, { Allow => 'POST, DELETE' },
            encode_json(rpc_error(undef, JR_INVALID_REQUEST,
                'GET (server-stream) not supported; POST JSON-RPC messages')));
    }
    if ($method ne 'POST') {
        return _resp(405, { Allow => 'POST, DELETE' }, '');
    }

    my $msg = eval { decode_json($r{body} // '') };
    if ($@ || !defined $msg) {
        return _resp(400, { 'Content-Type' => 'application/json' },
            encode_json(rpc_error(undef, JR_PARSE_ERROR, 'parse error')));
    }
    my $id = ref $msg eq 'HASH' ? $msg->{id} : undef;

    my ($server, $new_sid);
    if (ref $msg eq 'HASH' && ($msg->{method} // '') eq 'initialize') {
        my $token = _bearer_token($headers);
        ($new_sid, $server) = $self->_new_session($token);
    }
    else {
        my $sess = defined $sid ? $self->{sessions}{$sid} : undef;
        unless ($sess) {
            return _resp(404, { 'Content-Type' => 'application/json' },
                encode_json(rpc_error($id, JR_INVALID_REQUEST,
                    'no active session; send initialize first')));
        }
        $server = $sess->{server};
    }

    my $response = $server->handle($msg);

    my %hdr;
    $hdr{'Mcp-Session-Id'} = $new_sid if defined $new_sid;
    return _resp(202, \%hdr, '') unless defined $response;   # notification

    $hdr{'Content-Type'} = 'application/json';
    return _resp(200, \%hdr, encode_json($response));
}

# --- sessions ---

sub _new_session {
    my ($self, $token) = @_;
    # Bound the session table; evict the oldest when full.
    if (keys %{ $self->{sessions} } >= $self->{max_sessions}) {
        my ($oldest) = sort {
            $self->{sessions}{$a}{seq} <=> $self->{sessions}{$b}{seq}
        } keys %{ $self->{sessions} };
        delete $self->{sessions}{$oldest};
    }
    my $id  = $self->{idgen}->();
    my $srv = $self->{make_server}->($token);
    $self->{sessions}{$id} = { server => $srv, seq => ++$self->{seq} };
    return ($id, $srv);
}

# --- helpers ---

sub _bearer_token {
    my ($headers) = @_;
    my $a = $headers->{authorization} // '';
    return $1 if $a =~ /^Bearer\s+(.+?)\s*$/i;
    return '';
}

sub _resp {
    my ($status, $headers, $body) = @_;
    return { status => $status, headers => $headers // {}, body => $body // '' };
}

sub _random_id {
    my $buf;
    if (open my $fh, '<:raw', '/dev/urandom') {
        sysread $fh, $buf, 16;
        close $fh;
    }
    return unpack('H*', $buf) if defined $buf && length $buf == 16;
    return join '', map { sprintf '%08x', int(rand(0xffffffff)) } 1 .. 4;
}

1;
