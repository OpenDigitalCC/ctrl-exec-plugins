#!/usr/bin/perl
# Tests for ctrl-exec-cli run --input / --input-fields (T-013 piece 4).
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

my $cli = "$Bin/../ctrl-exec-cli";
my $tmp = tempdir(CLEANUP => 1);
my $SENTINEL = 'S3NT1NEL-do-not-print-' . $$;

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
    my $cmd = "'$cli' --url http://127.0.0.1:$port --token tok --username u @args "
            . "> '$tmp/out' 2> '$tmp/err' $stdin";
    system('bash', '-c', $cmd);
    my $rc = $? >> 8;
    kill 'TERM', $pid; waitpid $pid, 0;
    my $slurp = sub { open my $i, '<:raw', $_[0] or return ''; local $/; scalar <$i> // '' };
    my $body = -f $cap ? decode_json($slurp->($cap)) : undef;
    unlink $cap;
    return ($rc, $slurp->("$tmp/out"), $slurp->("$tmp/err"), $body);
}

my $sec = spew("$tmp/secret.txt", "line1 $SENTINEL\nline2 \x{c3}\x{a9}\n");

# --- --input FILE -> {input: {input: content}} ------------------------------
{
    my ($rc, $out, $err, $b) = cli({}, 'run h1 --script s --input', $sec);
    is($rc, 0, '--input FILE succeeds');
    is_deeply($b->{input}, { input => "line1 $SENTINEL\nline2 \x{e9}\n" }, '--input sends one field named input');
    is($b->{script}, 's', 'rest of the body unchanged');
    unlike("$out$err", qr/\Q$SENTINEL\E/, 'value not in output');
}

# --- --input - reads stdin -----------------------------------------------------
{
    my ($rc, undef, undef, $b) = cli({ stdin => $sec }, 'run h1 --script s --input -');
    is($rc, 0, '--input - succeeds');
    is($b->{input}{input}, "line1 $SENTINEL\nline2 \x{e9}\n", '--input - sends stdin content');
}

# --- --input-fields FILE and - -----------------------------------------------
my $fields = spew("$tmp/fields.json", encode_json({ cert => "C $SENTINEL", 'key.pem' => "K", 'a-b_c.d' => '' }));
{
    my ($rc, $out, $err, $b) = cli({}, 'run h1 h2 --script s --input-fields', $fields, '-- --flag x');
    is($rc, 0, '--input-fields FILE succeeds');
    is_deeply($b->{input}, { cert => "C $SENTINEL", 'key.pem' => 'K', 'a-b_c.d' => '' }, 'fields sent unchanged');
    is_deeply($b->{args}, ['--flag', 'x'], 'script args still passed');
    is_deeply($b->{hosts}, ['h1', 'h2'], 'hosts still passed');
    unlike("$out$err", qr/\Q$SENTINEL\E/, 'value not in output');
    my (undef, undef, undef, $b2) = cli({ stdin => $fields }, 'run h1 --script s --input-fields -');
    is($b2->{input}{cert}, "C $SENTINEL", '--input-fields - reads stdin');
}

# --- no input -> no key -----------------------------------------------------------
{
    my (undef, undef, undef, $b) = cli({}, 'run h1 --script s');
    ok(!exists $b->{input}, 'no input option, no input key');
}

# Refusals: nothing is sent, so the stub is never reached; just check message and
# that the sentinel is not echoed. (cli() kills the stub afterwards.)
sub refused {
    my ($name, $re, @args) = @_;
    my ($rc, $out, $err, $b) = cli(@args > 0 && ref $args[0] ? shift(@args) : {}, @args);
    isnt($rc, 0, "$name: non-zero exit");
    like($err, $re, "$name: message");
    ok(!defined $b, "$name: nothing sent");
    unlike("$out$err", qr/\Q$SENTINEL\E/, "$name: no value in output");
}

refused('mutual exclusion', qr/mutually exclusive/, 'run h1 --script s --input', $sec, '--input-fields', $fields);
refused('no input on command line', qr/not accepted on the command line/, "run h1 --script s --input-value=$SENTINEL");
refused('missing file', qr/cannot read/, 'run h1 --script s --input', "$tmp/nope");
refused('bad JSON', qr/not valid JSON/, 'run h1 --script s --input-fields',
    spew("$tmp/bad.json", "{\"a\": \"$SENTINEL\""));
refused('non-object (array)', qr/must be a JSON object/, 'run h1 --script s --input-fields',
    spew("$tmp/arr.json", encode_json(["$SENTINEL"])));
refused('non-object (string)', qr/must be a JSON object/, 'run h1 --script s --input-fields',
    spew("$tmp/str.json", encode_json("$SENTINEL")));
refused('non-string value (number)', qr/field 'n' is not a string/, 'run h1 --script s --input-fields',
    spew("$tmp/num.json", qq({"ok":"$SENTINEL","n":5})));
refused('non-string value (null)', qr/field 'z' is not a string/, 'run h1 --script s --input-fields',
    spew("$tmp/null.json", qq({"z":null})));
refused('non-string value (bool)', qr/field 'b' is not a string/, 'run h1 --script s --input-fields',
    spew("$tmp/bool.json", qq({"b":true})));
refused('non-string value (nested)', qr/field 'o' is not a string/, 'run h1 --script s --input-fields',
    spew("$tmp/nest.json", qq({"o":{"x":"$SENTINEL"}})));
refused('bad name (space)', qr/invalid field name/, 'run h1 --script s --input-fields',
    spew("$tmp/n1.json", encode_json({ 'bad name' => $SENTINEL })));
refused('bad name (slash)', qr/invalid field name/, 'run h1 --script s --input-fields',
    spew("$tmp/n2.json", encode_json({ '../x' => $SENTINEL })));
refused('name too long', qr/invalid field name/, 'run h1 --script s --input-fields',
    spew("$tmp/n3.json", encode_json({ ('a' x 65) => $SENTINEL })));
refused('too many fields', qr/at most 32/, 'run h1 --script s --input-fields',
    spew("$tmp/many.json", encode_json({ map { ("f$_" => $SENTINEL) } 1 .. 33 })));
refused('empty object', qr/no fields/, 'run h1 --script s --input-fields', spew("$tmp/empty.json", '{}'));
refused('binary --input', qr/not valid UTF-8.*base64/, 'run h1 --script s --input',
    spew("$tmp/bin", "\xff\xfe$SENTINEL\x80"));
refused('binary --input-fields', qr/not valid UTF-8.*base64/, 'run h1 --script s --input-fields',
    spew("$tmp/bin2", "{\"a\":\"\xff$SENTINEL\"}"));

# Exactly 32 fields is allowed.
{
    my $f = spew("$tmp/32.json", encode_json({ map { ("f$_" => 'v') } 1 .. 32 }));
    my ($rc, undef, undef, $b) = cli({}, 'run h1 --script s --input-fields', $f);
    is($rc, 0, '32 fields accepted');
    is(scalar keys %{ $b->{input} }, 32, '32 fields sent');
}

# --- API 400 about input is shown, with no values ---------------------------------
{
    my ($rc, $out, $err) = cli({ stdin => $sec,
        stub => [400, { ok => JSON::PP::false, error => 'input too large', detail => 'exceeds max_input_bytes' }] },
        'run h1 --script s --input -');
    is($rc, 255, 'API 400 -> error exit');
    like($err, qr/input too large: exceeds max_input_bytes/, 'API input error shown');
    unlike("$out$err", qr/\Q$SENTINEL\E/, 'value not in output on API error');
}

# --- --json output carries no input ----------------------------------------------
{
    my ($rc, $out, $err) = cli({}, 'run h1 --script s --json --input', $sec);
    is($rc, 0, '--json run ok');
    unlike("$out$err", qr/\Q$SENTINEL\E/, '--json output has no input value');
}

# --- help text and the debug surface ------------------------------------------------
{
    my $help = `'$cli' run --help 2>&1`;   # the global --help is consumed first, so usage arrives on stderr
    like($help, qr/--input FILE\|-/, 'help names --input');
    like($help, qr/--input-fields FILE\|-/, 'help names --input-fields');
    like($help, qr/mutually exclusive/, 'help states exclusion');
    my $src = do { local (@ARGV, $/) = ($cli); <> };
    unlike($src, qr/--verbose|--debug|Data::Dumper/, 'the CLI has no verbose/debug/dump surface to leak through');
}

done_testing();
