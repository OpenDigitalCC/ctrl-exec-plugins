#!/usr/bin/perl
# Tests for the T-049 forgot-'--' hint and the non-ASCII-space argument refusal.
# A stub API (a forked one-shot HTTP server) captures the POST /run body; the
# CLI is run as a subprocess. SENTINEL is a secret value that must never appear
# in any CLI output (stdout, stderr, --json), on success or on error.
use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use IO::Socket::INET;
use JSON::PP qw(encode_json decode_json);
use File::Temp qw(tempdir);

my $cli = $ENV{CE_CLI_UNDER_TEST} // "$Bin/../ctrl-exec-cli";
my $tmp = tempdir(CLEANUP => 1);

sub spew { my ($f, $c) = @_; open my $o, '>:raw', $f or die $!; print $o $c; close $o; $f }

# Start a stub that answers one request; returns ($port, $pid, $capfile).
sub stub {
    my ($status, $reply) = @_;
    my $srv = IO::Socket::INET->new(Listen => 1, LocalAddr => '127.0.0.1',
        LocalPort => 0, ReuseAddr => 1) or die $!;
    my $port = $srv->sockport;
    my $cap  = "$tmp/cap-$port";
    my $pid  = fork // die;
    if (!$pid) {
        my $c = $srv->accept;
        my $hdr = '';
        while ($hdr !~ /\r\n\r\n/) { sysread($c, my $b, 1) or last; $hdr .= $b }
        my ($len) = $hdr =~ /content-length:\s*(\d+)/i;
        my $body = '';
        while (length($body) < ($len // 0)) { sysread($c, my $b, $len - length $body) or last; $body .= $b }
        spew($cap, $body);
        my $r = encode_json($reply);
        print $c "HTTP/1.1 $status X\r\nContent-Type: application/json\r\n"
               . "Content-Length: " . length($r) . "\r\nConnection: close\r\n\r\n$r";
        close $c;
        exit 0;
    }
    close $srv;
    return ($port, $pid, $cap);
}

# Run the CLI with args (list) and optional stdin file; returns ($rc, $out, $err, $body).
sub cli {
    my ($opts, @args) = @_;
    my ($port, $pid, $cap) = stub(@{ $opts->{stub} // [200, { ok => 1, reqid => 'abc123', results => [
        { host => 'h1', exit => 0, rtt => '1ms', stdout => "done\n" } ] }] });
    my $stdin = $opts->{stdin} ? "< '$opts->{stdin}'" : '< /dev/null';
    my $cmd = "HOME='$tmp/nohome' '$cli' --url http://127.0.0.1:$port --token tok --username u @args "
            . "> '$tmp/out' 2> '$tmp/err' $stdin";
    system('bash', '-c', $cmd);
    my $rc = $? >> 8;
    kill 'TERM', $pid; waitpid $pid, 0;
    my $slurp = sub { open my $i, '<:raw', $_[0] or return ''; local $/; scalar <$i> // '' };
    my $body = -f $cap ? decode_json($slurp->($cap)) : undef;
    unlink $cap;
    return ($rc, $slurp->("$tmp/out"), $slurp->("$tmp/err"), $body);
}


my $NB = "\xc2\xa0";   # UTF-8 bytes of U+00A0, as argv delivers them
my $ZW = "\xe2\x80\x8b";
my $unknown = [404, { ok => JSON::PP::false, error => 'unknown agent',
    detail => 'not a registered agent: ' }];
sub unk { [404, { ok => JSON::PP::false, error => 'unknown agent', detail => "not a registered agent: $_[0]" }] }
my $hint = qr/script arguments go after --: ctrl-exec-cli run <hosts> --script <name> -- <args>/;

# --- the reported case: paths and words after --script -----------------------
{
    my ($rc, $out, $err) = cli({ stub => unk('/srv/data/certs, app.example.net, users') },
        'run host1.example.net --script deploy-certs /srv/data/certs app.example.net users');
    is($rc, 255, 'unknown agent -> error exit');
    like($err, qr/unknown agent: not a registered agent: \/srv\/data\/certs/, 'API error still shown');
    like($err, $hint, 'hint shown for paths after --script');
}
# --- a bare word after --script that is not a path ----------------------------
{
    my ($rc, undef, $err) = cli({ stub => unk('users') }, 'run host1 --script deploy users');
    like($err, $hint, 'hint shown for a plain word after --script');
}
# --- name that cannot be a hostname, even before --script ----------------------
{
    my ($rc, undef, $err) = cli({ stub => unk('key=value') }, 'run key=value --script deploy');
    like($err, $hint, 'hint shown for a name containing =');
}
# --- genuinely unknown hostname before --script: no hint -----------------------
{
    my ($rc, undef, $err) = cli({ stub => unk('nosuchhost.example.net') },
        'run nosuchhost.example.net --script deploy -- a b');
    is($rc, 255, 'unknown host -> error exit');
    like($err, qr/not a registered agent: nosuchhost\.example\.net/, 'API error shown');
    unlike($err, qr/script arguments go after/, 'no hint for an ordinary unknown hostname');
}
# --- other API errors get no hint ---------------------------------------------
{
    my ($rc, undef, $err) = cli({ stub => [403, { ok => JSON::PP::false, error => 'denied', detail => '/x' }] },
        'run h1 --script s /x');
    unlike($err, qr/script arguments go after/, 'no hint for a non-unknown-agent error');
}

# --- non-ASCII whitespace refused before anything is sent -----------------------
{
    my ($rc, $out, $err, $b) = cli({}, "run host1 --script deploy '--${NB}${NB}--test'");
    is($rc, 2, 'NBSP between -- and the next word: exit 2');
    like($err, qr/<U\+00A0><U\+00A0>/, 'argument shown with the NBSPs made visible');
    like($err, qr/copy-paste/, 'copy-paste named');
    is($b, undef, 'nothing sent to the API');
}
{
    my ($rc, undef, $err, $b) = cli({}, "run 'host1.example.net${NB}' --script deploy");
    is($rc, 2, 'trailing NBSP on a hostname: exit 2');
    like($err, qr/host1\.example\.net<U\+00A0>/, 'trailing NBSP shown');
    is($b, undef, 'nothing sent');
}
{
    my ($rc, undef, $err, $b) = cli({}, "run host1 --script 'dep${ZW}loy'");
    is($rc, 2, 'zero-width space: exit 2');
    like($err, qr/dep<U\+200B>loy/, 'zero-width space shown');
}
{
    my ($rc, undef, $err) = cli({}, "ping 'h1${NB}'");
    is($rc, 2, 'other subcommands refuse too');
}
# --- legitimate UTF-8 still goes through ----------------------------------------
{
    my ($rc, undef, $err, $b) = cli({}, "run h1 --script s -- caf\xc3\xa9");
    is($rc, 0, 'accented script argument accepted');
    is_deeply($b->{args}, ["caf\xc3\xa9"], 'argument sent unchanged');
}

done_testing();
