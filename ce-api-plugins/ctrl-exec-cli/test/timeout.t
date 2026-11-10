#!/usr/bin/perl
# Tests for the configurable request timeout (T-085): --timeout,
# CTRL_EXEC_TIMEOUT and the config key `timeout` (flag > env > config >
# default 120) govern BOTH transports - HTTP::Tiny for --url and the
# can_read() wait on the --socket path - and `wait --timeout` keeps its own
# meaning (its deadline). Deterministic: the stubs accept a connection and
# hold it silent until the client gives up and closes; the timeout is 1 s, no
# fixed sleeps. A stub is bounded by alarm so a CLI that ignores the timeout
# cannot hang the suite.
use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use IO::Socket::INET;
use IO::Socket::UNIX;
use File::Temp qw(tempdir);

my $cli = "$Bin/../ctrl-exec-cli";
my $tmp = tempdir(CLEANUP => 1);
$ENV{CTRL_EXEC_CLI_SYSLOG_SOCKET} = "$tmp/no-log.sock";
delete @ENV{qw(CTRL_EXEC_TIMEOUT CTRL_EXEC_API_URL CTRL_EXEC_API_SOCKET CTRL_EXEC_API_CA)};
mkdir "$tmp/nohome";

sub spew { my ($f, $c) = @_; open my $o, '>:raw', $f or die $!; print $o $c; close $o; $f }
sub slurp { open my $i, '<:raw', $_[0] or return ''; local $/; scalar <$i> // '' }

# Load the CLI as a library with HOME pointing at an empty directory, so no
# real config file is read.
{ local $ENV{HOME} = "$tmp/nohome"; local $@; do $cli; die "failed to load $cli: $@" if $@; }

# A server that takes one connection, reads the request head and then says
# nothing until the client closes. Returns the child pid.
sub silent_server {
    my ($srv) = @_;
    my $pid = fork // die;
    if (!$pid) {
        alarm 20;
        my $c = $srv->accept or exit 1;
        my $hdr = '';
        while ($hdr !~ /\r\n\r\n/) { sysread($c, my $b, 1) or last; $hdr .= $b }
        1 while sysread($c, my $b, 4096);    # until the client closes
        exit 0;
    }
    close $srv;
    return $pid;
}
sub unix_stub {
    my $sock = "$tmp/s" . int(rand 1e9) . '.sock';
    my $srv = IO::Socket::UNIX->new(Local => $sock, Type => SOCK_STREAM, Listen => 1) or die $!;
    return ($sock, $srv);
}
sub tcp_stub {
    my $srv = IO::Socket::INET->new(Listen => 1, LocalAddr => '127.0.0.1',
        LocalPort => 0, ReuseAddr => 1) or die $!;
    return ($srv->sockport, $srv);
}

# Run the CLI (args as a shell string, env prefix first); ($rc, $out, $err).
sub cli {
    my ($args, %o) = @_;
    my $home = $o{home} // "$tmp/nohome";
    my $env  = $o{env} // '';
    system('bash', '-c', "env -u CTRL_EXEC_TIMEOUT $env HOME='$home' "
        . "'$cli' --token tok --username u $args > '$tmp/out' 2> '$tmp/err' < /dev/null");
    return ($? >> 8, slurp("$tmp/out"), slurp("$tmp/err"));
}

# --- build_context: precedence, default, validation ------------------------------
{
    local %ENV = %ENV;
    is(main::build_context({}, {})->{timeout}, 120, 'unset: 120');
    is(main::build_context({}, { timeout => 30 })->{timeout}, 30, 'config key');
    $ENV{CTRL_EXEC_TIMEOUT} = 45;
    is(main::build_context({}, { timeout => 30 })->{timeout}, 45, 'env beats config');
    is(main::build_context({ timeout => 600 }, { timeout => 30 })->{timeout}, 600,
        'flag beats env and config');
    $ENV{CTRL_EXEC_TIMEOUT} = '';
    is(main::build_context({}, {})->{timeout}, 120, 'empty env var counts as unset');
    delete $ENV{CTRL_EXEC_TIMEOUT};
    for my $bad (qw(0 abc -5 1.5 10s), '', ' ') {
        next if $bad eq '';
        for my $where (['flag', [{ timeout => $bad }, {}]], ['config', [{}, { timeout => $bad }]]) {
            my ($name, $a) = @$where;
            my $r = eval { main::build_context(@$a); 1 };
            ok(!$r, "$name '$bad': refused");
            like($@, qr/\AError: .*timeout.*positive integer.*\n\z/, "  one-line error") if !$r;
        }
    }
    $ENV{CTRL_EXEC_TIMEOUT} = 'abc';
    ok(!eval { main::build_context({}, {}); 1 }, "env 'abc': refused");
}

# --- both transports use ctx->{timeout} --------------------------------------------
{
    for my $t (undef, 7) {
        my $ctx = { url => 'http://localhost:1', token => 't', username => 'u',
                    timeout => $t // 120 };
        is(main::_make_ua($ctx)->timeout, $t // 120, 'HTTP::Tiny timeout: ' . ($t // 120));
    }
    # can_read() on the socket path: record its argument, answer "nothing to read"
    require IO::Select;
    for my $t (120, 7) {
        my ($sock, $srv) = unix_stub();
        my $pid = silent_server($srv);
        my @seen;
        {
            no warnings 'redefine';
            my $orig = \&IO::Select::can_read;
            local *IO::Select::can_read = sub { push @seen, $_[1]; return };
            my $data = eval { main::api_get({ socket => $sock, timeout => $t }, '/health') };
            like($@, qr/timed out reading from socket/, "socket path with $t s: gives up when nothing to read");
        }
        waitpid $pid, 0;
        is_deeply(\@seen, [$t], "socket can_read() waits $t s");
    }
}

# --- end to end: 1 s against a silent API, over the socket and over TCP --------------
sub gives_up {
    my ($label, $mk, %o) = @_;
    my ($where, $srv) = $mk->();
    my $pid = silent_server($srv);
    my $conf = $o{conf};
    my $home = "$tmp/nohome";
    if (defined $conf) {
        $home = "$tmp/home-" . int(rand 1e9);
        mkdir $home;
        spew("$home/.ctrl-exec-cli.conf", "$conf\n");
    }
    my $target = $mk == \&unix_stub ? "--socket '$where'" : "--url http://127.0.0.1:$where";
    my ($rc, $out, $err) = cli("$target $o{args} health", home => $home, env => $o{env});
    waitpid $pid, 0;
    isnt($rc, 0, "$label: fails");
    like($err, qr/Connection error: .*(?:timed out|Timed out)/i, "$label: timed out, not a hang") or diag $err;
}
for my $path ([ socket => \&unix_stub ], [ http => \&tcp_stub ]) {
    my ($n, $mk) = @$path;
    gives_up("$n --timeout 1", $mk, args => '--timeout 1');
    gives_up("$n CTRL_EXEC_TIMEOUT=1", $mk, args => '', env => 'CTRL_EXEC_TIMEOUT=1');
    gives_up("$n config timeout = 1", $mk, args => '', conf => 'timeout = 1');
    gives_up("$n flag beats config (60)", $mk, args => '--timeout 1', conf => 'timeout = 60');
    gives_up("$n flag beats env (60)", $mk, args => '--timeout 1', env => 'CTRL_EXEC_TIMEOUT=60');
}

# --- bad values are refused before any request ----------------------------------------
for my $bad ('0', 'abc', '-3') {
    my ($sock, $srv) = unix_stub();
    my $pid = fork // die;
    if (!$pid) {     # records whether anyone connected
        alarm 10;
        my $c = $srv->accept or exit 0;
        exit 7;
    }
    close $srv;
    my ($rc, $out, $err) = cli("--socket '$sock' --timeout=$bad health");
    kill 'TERM', $pid; waitpid $pid, 0;
    isnt($rc, 0, "--timeout=$bad: refused");
    like($err, qr/\AError: .*timeout.*positive integer.*\n\z/, "--timeout=$bad: one-line usage error") or diag $err;
    isnt($? >> 8, 7, "--timeout=$bad: no request reached the API");
}
{
    my ($rc, undef, $err) = cli("--socket /nonexistent.sock health", env => 'CTRL_EXEC_TIMEOUT=abc');
    isnt($rc, 0, 'env abc: refused');
    like($err, qr/timeout.*positive integer/, '  with the same message');
    unlike($err, qr/Connection error/, '  before a connection is tried');
}

# --- wait keeps its own --timeout ------------------------------------------------------
{
    my %seen;
    no warnings qw(redefine once);
    local $ENV{HOME} = "$tmp/nohome";
    local *main::cmd_wait = sub { my ($ctx, @a) = @_; %seen = (timeout => $ctx->{timeout}, args => [@a]) };
    local *main::cmd_run  = sub { my ($ctx, @a) = @_; %seen = (timeout => $ctx->{timeout}, args => [@a]) };
    my $go = sub { %seen = (); local @ARGV = @_; main::main(); \%seen };

    my $s = $go->(qw(wait abc123 --timeout 600));
    is($s->{timeout}, 120, 'wait --timeout 600: request timeout stays 120');
    is_deeply($s->{args}, [qw(abc123 --timeout 600)], '  wait still gets its --timeout');

    $s = $go->(qw(wait --timeout=600 abc123));
    is($s->{timeout}, 120, 'wait --timeout=600 (before reqid): request timeout stays 120');
    is_deeply($s->{args}, [qw(--timeout=600 abc123)], '  wait still gets it');

    $s = $go->(qw(--json wait abc123 --timeout 600));
    is_deeply($s->{args}, [qw(abc123 --timeout 600)], '  with a global flag first: same');

    $s = $go->(qw(--timeout 90 wait abc123 --timeout 600));
    is($s->{timeout}, 90, 'global --timeout before wait sets the request timeout');
    is_deeply($s->{args}, [qw(abc123 --timeout 600)], '  and wait keeps its own');

    $s = $go->(qw(run h1 --script s --timeout 600));
    is($s->{timeout}, 600, 'run ... --timeout 600: request timeout 600');
    is_deeply($s->{args}, [qw(h1 --script s)], '  not passed on to run');

    $s = $go->(qw(--timeout=600 run h1 --script s));
    is($s->{timeout}, 600, '--timeout before the command');

    $s = $go->(qw(run h1 --script s -- --timeout 5));
    is($s->{timeout}, 120, 'script argument after -- is left alone');
    is_deeply($s->{args}, [qw(h1 --script s -- --timeout 5)], '  and reaches run');
}

# --- wait --timeout end to end: its deadline, not a request timeout --------------------
{
    my $srv = IO::Socket::INET->new(Listen => 5, LocalAddr => '127.0.0.1',
        LocalPort => 0, ReuseAddr => 1) or die $!;
    my $port = $srv->sockport;
    my $pid = fork // die;
    if (!$pid) {
        alarm 20;
        while (my $c = $srv->accept) {
            my $hdr = '';
            while ($hdr !~ /\r\n\r\n/) { sysread($c, my $b, 1) or last; $hdr .= $b }
            my $r = '{"ok":true,"complete":false,"reqid":"abc123"}';
            print $c "HTTP/1.0 200 OK\r\nContent-Type: application/json\r\n"
                   . "Content-Length: " . length($r) . "\r\n\r\n$r";
            close $c;
        }
        exit 0;
    }
    close $srv;
    my ($rc, undef, $err) = cli("--url http://127.0.0.1:$port wait abc123 --timeout 1");
    kill 'TERM', $pid; waitpid $pid, 0;
    like($err, qr/Timed out after 1s; run still pending/, 'wait --timeout 1: its deadline applies');
}

# --- --help lists it ---------------------------------------------------------------------
{
    my ($rc, $out) = cli('--help');
    is($rc, 0, '--help exits 0');
    like($out, qr/^\s+--timeout <seconds>/m, '--help lists --timeout');
    like($out, qr/CTRL_EXEC_TIMEOUT/, '--help lists CTRL_EXEC_TIMEOUT');
    like($out, qr/^\s+timeout\s*=\s*\d+/m, '--help lists the config key');
    like($out, qr/read_timeout/, '--help mentions the dispatcher read_timeout');
}

done_testing;
