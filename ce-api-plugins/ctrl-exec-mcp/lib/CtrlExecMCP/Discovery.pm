package CtrlExecMCP::Discovery;

use strict;
use warnings;
use JSON::PP qw(encode_json decode_json);

# Thin client for the ctrl-exec API's discovery endpoint. POSTs to /discovery
# (so the operator token is forwarded for the auth hook) and returns the hosts
# map. The HTTP agent is injectable for testing.

sub new {
    my ($class, %opts) = @_;
    my $ua = $opts{ua};
    unless ($ua) {
        require HTTP::Tiny;
        $ua = HTTP::Tiny->new(timeout => $opts{timeout} // 30);
    }
    (my $url = $opts{url} // 'http://localhost:7445') =~ s{/+$}{};
    return bless {
        url   => $url,
        token => $opts{token} // '',
        ua    => $ua,
    }, $class;
}

# Return the discovery hosts map { hostname => { status, scripts => [...] } },
# or an empty hashref on any transport or parse failure (so the catalogue
# degrades to an empty tool set rather than crashing the server).
sub hosts {
    my ($self) = @_;
    my $resp = $self->{ua}->post(
        "$self->{url}/discovery",
        {
            headers => { 'Content-Type' => 'application/json' },
            content => encode_json({ token => $self->{token} }),
        },
    );
    return {} unless ref $resp eq 'HASH' && $resp->{success};
    my $data = eval { decode_json($resp->{content} // '') };
    return {} unless ref $data eq 'HASH' && ref $data->{hosts} eq 'HASH';
    return $data->{hosts};
}

1;
