#!/usr/bin/perl
# Tests for ctrl-exec-cli's API transport (T-013 piece 6): --socket (the API's
# unix socket), --ca (verify an https:// API), the config/env/flag priority of
# url vs socket, and the warning when confidential input would go over plain
# HTTP to an address that is not loopback. Stub APIs are forked one-shot
# servers; the CLI runs as a subprocess, or is loaded as a library for the
# pure helpers (its entry point is guarded by `main() unless caller`).
use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use IO::Socket::INET;
use IO::Socket::UNIX;
use JSON::PP qw(encode_json decode_json);
use File::Temp qw(tempdir);

my $cli = "$Bin/../ctrl-exec-cli";
my $tmp = tempdir(CLEANUP => 1);
my $SENTINEL = 'S3NT1NEL-transport-' . $$;
# Never the host's syslog: warnings go to a socket nobody listens on unless a
# test points CTRL_EXEC_CLI_SYSLOG_SOCKET at its own.
$ENV{CTRL_EXEC_CLI_SYSLOG_SOCKET} = "$tmp/no-log.sock";

sub spew { my ($f, $c) = @_; open my $o, '>:raw', $f or die $!; print $o $c; close $o; $f }
sub slurp { open my $i, '<:raw', $_[0] or return ''; local $/; scalar <$i> // '' }

{ local $@; do $cli; die "failed to load $cli: $@" if $@; }

# Serve one request on $srv in a child; capture the request (head + body) to a
# file and answer with $reply. $wrap upgrades the accepted socket (TLS).
sub serve_one {
    my ($srv, $reply, $wrap) = @_;
    my $cap = "$tmp/cap-" . int(rand 1e9);
    my $pid = fork // die;
    if (!$pid) {
        alarm 15;    # a CLI that never connects must not hang the suite
        my $c = $srv->accept or exit 1;
        if ($wrap) { $c = $wrap->($c) or exit 1 }
        my $hdr = '';
        while ($hdr !~ /\r\n\r\n/) { sysread($c, my $b, 1) or last; $hdr .= $b }
        my ($len) = $hdr =~ /content-length:\s*(\d+)/i;
        my $body = '';
        while (length($body) < ($len // 0)) { sysread($c, my $b, $len - length $body) or last; $body .= $b }
        spew($cap, $hdr . $body);
        my $r = encode_json($reply);
        print $c "HTTP/1.0 200 OK\r\nContent-Type: application/json\r\n"
               . "Content-Length: " . length($r) . "\r\n\r\n$r";
        close $c;
        exit 0;
    }
    close $srv;
    return ($pid, $cap);
}

my $RUN_OK = { ok => 1, reqid => 'abc123', results => [
    { host => 'h1', exit => 0, rtt => '1ms', stdout => "done\n" } ] };

# Run the CLI (args as a shell string); returns ($rc, $out, $err).
sub cli {
    my ($args, $stdin) = @_;
    $stdin = $stdin ? "< '$stdin'" : '< /dev/null';
    my $home = $ENV{CLI_TEST_HOME} // "$tmp/nohome";   # never the tester's own config
    system('bash', '-c', "env -u CTRL_EXEC_API_URL -u CTRL_EXEC_API_SOCKET -u CTRL_EXEC_API_CA HOME='$home' "
        . "'$cli' --token tok --username u $args > '$tmp/out' 2> '$tmp/err' $stdin");
    return ($? >> 8, slurp("$tmp/out"), slurp("$tmp/err"));
}

my $secret = spew("$tmp/secret.txt", "key $SENTINEL\n");

# --- --socket: run with input, end to end against a stub API ------------------
{
    my $sock = "$tmp/api.sock";
    my $srv  = IO::Socket::UNIX->new(Local => $sock, Type => SOCK_STREAM, Listen => 1) or die $!;
    my ($pid, $cap) = serve_one($srv, $RUN_OK);
    my ($rc, $out, $err) = cli("--socket '$sock' run h1 --script s --input '$secret'");
    waitpid $pid, 0;
    is($rc, 0, '--socket: run succeeds') or diag $err;
    like($out, qr/==> h1\s+\[ok/, '--socket: result printed');
    my ($head, $body) = split /\r\n\r\n/, slurp($cap), 2;
    like($head, qr{\APOST /run HTTP/1\.0\r\n}, '--socket: POST /run sent on the socket');
    like($head, qr/^Content-Length: \d+\r$/m, '--socket: Content-Length sent');
    my $b = decode_json($body);
    is($b->{input}{input}, "key $SENTINEL\n", '--socket: input carried');
    is($b->{token}, 'tok', '--socket: rest of the body as over TCP');
    unlike($err, qr/Warning/, '--socket: no plain-HTTP warning');
    unlink $sock;
}

# --- --socket: GET (health) and a socket nobody serves -------------------------
{
    my $sock = "$tmp/api2.sock";
    my $srv  = IO::Socket::UNIX->new(Local => $sock, Type => SOCK_STREAM, Listen => 1) or die $!;
    my ($pid, $cap) = serve_one($srv, { ok => JSON::PP::true, version => '9.9.9' });
    my ($rc, $out) = cli("--socket '$sock' health");
    waitpid $pid, 0;
    is($rc, 0, '--socket health');
    like($out, qr/VERSION\s+9\.9\.9/, '--socket health: version');
    like(slurp($cap), qr{\AGET /health HTTP/1\.0\r\n}, '--socket health: GET /health');
    unlink $sock;

    my $err;
    ($rc, undef, $err) = cli("--socket '$tmp/nothing.sock' health");
    isnt($rc, 0, 'missing socket: fails');
    like($err, qr/Connection error: cannot connect to socket \Q$tmp\E\/nothing\.sock/,
        'missing socket: clear error');
}

# --- --url and --socket together are refused -------------------------------------
{
    my ($rc, undef, $err) = cli("--url http://127.0.0.1:1 --socket /x.sock health");
    isnt($rc, 0, '--url with --socket: refused');
    like($err, qr/--url and --socket are mutually exclusive/, '  clear error');
}

# --- url vs socket priority: flag > env > config file > default --------------------
{
    local %ENV = %ENV;
    delete @ENV{qw(CTRL_EXEC_API_URL CTRL_EXEC_API_SOCKET CTRL_EXEC_API_CA)};
    my $ctx = main::build_context({}, { socket => '/run/a.sock' });
    is($ctx->{socket}, '/run/a.sock', 'config socket used');
    $ctx = main::build_context({ url => 'http://h:1' }, { socket => '/run/a.sock' });
    ok(!$ctx->{socket} && $ctx->{url} eq 'http://h:1', '--url flag overrides a config socket');
    $ctx = main::build_context({ socket => '/s' }, { url => 'http://h:1' });
    is($ctx->{socket}, '/s', '--socket flag overrides a config url');
    $ctx = main::build_context({}, { url => 'http://h:1', socket => '/s' });
    is($ctx->{socket}, '/s', 'config with both: socket');
    $ENV{CTRL_EXEC_API_URL} = 'http://e:2';
    $ctx = main::build_context({}, { socket => '/s' });
    ok(!$ctx->{socket} && $ctx->{url} eq 'http://e:2', 'env url overrides a config socket');
    delete $ENV{CTRL_EXEC_API_URL};
    $ENV{CTRL_EXEC_API_SOCKET} = '/e.sock';
    $ctx = main::build_context({}, { url => 'http://h:1' });
    is($ctx->{socket}, '/e.sock', 'env socket overrides a config url');
    delete $ENV{CTRL_EXEC_API_SOCKET};
    $ctx = main::build_context({}, {});
    ok(!$ctx->{socket} && $ctx->{url} eq 'http://localhost:7445', 'default: http://localhost:7445');
    $ctx = main::build_context({}, { ca => '/c.crt' });
    is($ctx->{ca}, '/c.crt', 'ca from the config file');
    $ctx = main::build_context({ ca => '/f.crt' }, { ca => '/c.crt' });
    is($ctx->{ca}, '/f.crt', '--ca flag overrides the config file');
}

# --- the plain-HTTP warning ------------------------------------------------------------
{
    my $warned = sub {
        my ($ctx) = @_;
        my $err = '';
        # as if stderr were a terminal; the log leg is pointed at nothing
        no warnings 'redefine';
        local *main::warn_to_stderr = sub { 1 };
        local $ENV{CTRL_EXEC_CLI_SYSLOG_SOCKET} = "$tmp/no-such-log.sock";
        { local *STDERR; open STDERR, '>', \$err or die; main::warn_plain_input($ctx); }
        return $err;
    };
    for my $u (qw(http://localhost:7445 http://127.0.0.1:7445 http://127.9.8.7
                  http://[::1]:7445 http://api.localhost:7445 https://10.1.2.3:7445)) {
        is($warned->({ url => $u }), '', "no warning: $u");
    }
    is($warned->({ url => 'http://10.1.2.3:7445', socket => '/s' }), '', 'no warning: socket');
    for my $u (qw(http://10.1.2.3:7445 http://dispatcher.example.net:7445
                  http://[2001:db8::1]:7445 HTTP://192.0.2.7)) {
        like($warned->({ url => $u }), qr/Warning: sending confidential input over plain HTTP/,
            "warning: $u");
    }

    # End to end: 0.0.0.0 reaches the local stub but is not a loopback name.
    my $srv = IO::Socket::INET->new(Listen => 1, LocalAddr => '127.0.0.1',
        LocalPort => 0, ReuseAddr => 1) or die $!;
    my $port = $srv->sockport;
    my ($pid, $cap) = serve_one($srv, $RUN_OK);
    my ($rc, $out, $err) = cli("--url http://0.0.0.0:$port run h1 --script s --input '$secret'");
    waitpid $pid, 0;
    is($rc, 0, 'non-loopback plain HTTP: the run still goes ahead');
    unlike($err, qr/Warning/, 'non-loopback plain HTTP: no warning on a non-tty stderr');
    unlike("$out$err", qr/\Q$SENTINEL\E/, 'the warning does not show the input');
    like(slurp($cap), qr/\Q$SENTINEL\E/, 'input was sent');

    # Without input, no warning.
    $srv = IO::Socket::INET->new(Listen => 1, LocalAddr => '127.0.0.1',
        LocalPort => 0, ReuseAddr => 1) or die $!;
    $port = $srv->sockport;
    ($pid) = serve_one($srv, $RUN_OK);
    ($rc, undef, $err) = cli("--url http://0.0.0.0:$port run h1 --script s");
    waitpid $pid, 0;
    unlike($err, qr/Warning/, 'no input: no warning');
}

# --- T-058: warnings go to the log, never into output a script parses -----------
{
    # A datagram unix socket standing in for /dev/log (the CLI reads
    # CTRL_EXEC_CLI_SYSLOG_SOCKET); the host's syslog is never touched.
    my $logsock = "$tmp/log.sock";
    my $log = IO::Socket::UNIX->new(Local => $logsock, Type => SOCK_DGRAM) or die $!;
    local $ENV{CTRL_EXEC_CLI_SYSLOG_SOCKET} = $logsock;

    my $srv = IO::Socket::INET->new(Listen => 1, LocalAddr => '127.0.0.1',
        LocalPort => 0, ReuseAddr => 1) or die $!;
    my $port = $srv->sockport;
    my ($pid) = serve_one($srv, $RUN_OK);
    # stdout and stderr captured together, as a job doing 2>&1 would
    system('bash', '-c', "env -u CTRL_EXEC_API_URL -u CTRL_EXEC_API_SOCKET -u CTRL_EXEC_API_CA "
        . "HOME='$tmp/nohome' '$cli' --token tok --username u --json "
        . "--url http://0.0.0.0:$port run h1 --script s --input '$secret' > '$tmp/both' 2>&1 < /dev/null");
    waitpid $pid, 0;
    my $both = slurp("$tmp/both");
    my $j = eval { decode_json($both) };
    ok($j && $j->{reqid} eq 'abc123', '2>&1 capture parses as JSON') or diag $both;
    unlike($both, qr/Warning/, '2>&1 capture holds no warning');

    my $got = '';
    my $rin = ''; vec($rin, fileno($log), 1) = 1;
    $log->recv($got, 4096) if select(my $r = $rin, undef, undef, 3);
    like($got, qr/ctrl-exec-cli/, 'the warning reached the log: ident');
    like($got, qr/Warning: sending confidential input over plain HTTP to '0\.0\.0\.0'/,
        'the warning reached the log: text');
    like($got, qr/\A<(?:12)[0-9]*>/, 'the warning reached the log: facility user, priority warning (<12>)');
    unlike($got, qr/\Q$SENTINEL\E/, 'the log does not hold the input');

    # No syslog socket at all: silent, the run is unaffected
    local $ENV{CTRL_EXEC_CLI_SYSLOG_SOCKET} = "$tmp/no-such-log.sock";
    $srv = IO::Socket::INET->new(Listen => 1, LocalAddr => '127.0.0.1',
        LocalPort => 0, ReuseAddr => 1) or die $!;
    $port = $srv->sockport;
    ($pid) = serve_one($srv, $RUN_OK);
    my ($rc, $out, $err) = cli("--url http://0.0.0.0:$port run h1 --script s --input '$secret'");
    waitpid $pid, 0;
    is($rc, 0, 'no syslog socket: the run still succeeds');
    is($err, '', 'no syslog socket: nothing on stderr');

    # The tty decision, directly (no pty module needed)
    ok(!main::warn_to_stderr(), 'stderr not a terminal: no stderr warning')
        unless -t STDERR;
    {
        my $shown = '';
        no warnings 'redefine';
        local *main::warn_to_stderr = sub { 1 };
        { local *STDERR; open STDERR, '>', \$shown or die; main::warn_plain_input({ url => 'http://10.1.2.3:1' }); }
        like($shown, qr/Warning: sending confidential input over plain HTTP/,
            'stderr a terminal: the warning is shown');
    }
}

# --- --ca: verify an https:// API ------------------------------------------------------
SKIP: {
    skip 'openssl not available', 6 unless system('openssl version >/dev/null 2>&1') == 0;
    skip 'IO::Socket::SSL not available', 6 unless eval { require IO::Socket::SSL; 1 };

    my $d = "$tmp/pki";
    mkdir $d;
    my $sh = sub { system("$_[0] 2>/dev/null") == 0 or die "failed: $_[0]" };
    for my $ca (qw(ca rogue)) {
        $sh->("openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes "
            . "-keyout $d/$ca.key -out $d/$ca.crt -subj /CN=test-$ca -days 2");
    }
    spew("$d/api.ext", "subjectAltName=IP:127.0.0.1,DNS:localhost\nextendedKeyUsage=serverAuth\n");
    $sh->("openssl req -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes "
        . "-keyout $d/api.key -out $d/api.csr -subj /CN=localhost");
    $sh->("openssl x509 -req -in $d/api.csr -CA $d/ca.crt -CAkey $d/ca.key -set_serial 7 "
        . "-out $d/api.crt -days 2 -extfile $d/api.ext");

    my $tls = sub {
        my ($c) = @_;
        IO::Socket::SSL->start_SSL($c, SSL_server => 1,
            SSL_cert_file => "$d/api.crt", SSL_key_file => "$d/api.key");
    };
    my $tls_server = sub {
        my $srv = IO::Socket::INET->new(Listen => 1, LocalAddr => '127.0.0.1',
            LocalPort => 0, ReuseAddr => 1) or die $!;
        return ($srv->sockport, serve_one($srv, $RUN_OK, $tls));
    };

    my ($port, $pid, $cap) = $tls_server->();
    my ($rc, $out, $err) = cli("--url https://127.0.0.1:$port --ca '$d/ca.crt' run h1 --script s --input '$secret'");
    waitpid $pid, 0;
    is($rc, 0, '--ca: run over verified TLS succeeds') or diag $err;
    like(slurp($cap), qr/\Q$SENTINEL\E/, '--ca: input delivered over TLS');
    unlike($err, qr/Warning/, 'TLS: no plain-HTTP warning');

    ($port, $pid) = $tls_server->();
    ($rc, undef, $err) = cli("--url https://127.0.0.1:$port --ca '$d/rogue.crt' health");
    kill 'TERM', $pid; waitpid $pid, 0;
    isnt($rc, 0, '--ca with the wrong CA: refused');
    like($err, qr/Connection error/, '  as a connection error');

    ($rc, undef, $err) = cli("--url https://127.0.0.1:1 --ca '$d/missing.crt' health");
    like($err, qr/--ca: cannot read/, '--ca with an unreadable file: clear error');
}

# --- config file: read from the caller's home, not a fixed /root path --------
{
    my $home = "$tmp/home";
    mkdir $home or die $!;
    my $sock = "$tmp/home-api.sock";
    spew("$home/.ctrl-exec-cli.conf", "socket = $sock\n");
    my $srv = IO::Socket::UNIX->new(Local => $sock, Type => SOCK_STREAM, Listen => 1) or die $!;
    my ($pid, $cap) = serve_one($srv, $RUN_OK);
    local $ENV{CLI_TEST_HOME} = $home;
    my ($rc, $out, $err) = cli("run h1 --script s");
    waitpid $pid, 0;
    is($rc, 0, 'config file in $HOME: run succeeds over its socket') or diag $err;
    like(slurp($cap), qr{\APOST /run HTTP/1\.0\r\n}, 'config file in $HOME: socket = was used');
}

done_testing;
