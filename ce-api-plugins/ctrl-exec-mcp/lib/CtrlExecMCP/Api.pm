package CtrlExecMCP::Api;

use strict;
use warnings;
use JSON::PP qw(encode_json decode_json);

# Client for the ctrl-exec API operations the runner needs: async dispatch
# (POST /run with async) and result polling (GET /status/{reqid}). The operator
# token is forwarded for the auth hook. The HTTP agent is injectable for tests.
#
# Each call returns { ok, status, data, raw } where ok is true for a 2xx
# response and data is the decoded JSON body (or undef).

sub new {
    my ($class, %opts) = @_;
    my $ua = $opts{ua};
    unless ($ua) {
        require HTTP::Tiny;
        $ua = HTTP::Tiny->new(timeout => $opts{timeout} // 30);
    }
    (my $url = $opts{url} // 'http://localhost:7445') =~ s{/+$}{};
    return bless { url => $url, token => $opts{token} // '', ua => $ua }, $class;
}

# Submit an async run. opts: hosts (arrayref), script, args (arrayref).
sub run {
    my ($self, %opts) = @_;
    return $self->_post('/run', {
        hosts  => $opts{hosts}  // [],
        script => $opts{script},
        args   => $opts{args}   // [],
        token  => $self->{token},
        async  => JSON::PP::true,
    });
}

# Fetch the aggregated status record for a request id.
sub status {
    my ($self, $reqid) = @_;
    return $self->_get("/status/$reqid");
}

# --- private ---

sub _post {
    my ($self, $path, $body) = @_;
    my $r = $self->{ua}->post("$self->{url}$path", {
        headers => { 'Content-Type' => 'application/json' },
        content => encode_json($body),
    });
    return _wrap($r);
}

sub _get {
    my ($self, $path) = @_;
    return _wrap($self->{ua}->get("$self->{url}$path"));
}

sub _wrap {
    my ($r) = @_;
    my $ok   = (ref $r eq 'HASH' && $r->{success}) ? 1 : 0;
    my $data = (ref $r eq 'HASH' && defined $r->{content})
        ? eval { decode_json($r->{content}) } : undef;
    return {
        ok     => $ok,
        status => (ref $r eq 'HASH' ? ($r->{status} // 0) : 0),
        data   => $data,
        raw    => $r,
    };
}

1;
