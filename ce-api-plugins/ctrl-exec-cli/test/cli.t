#!/usr/bin/perl
# Unit tests for ctrl-exec-cli's _print_status: it renders both the async
# (/status/{reqid}, hosts-as-hash) and sync (/run results-array) shapes, and
# its return value drives the command exit code (0 = ok / still pending,
# 1 = a host failed). The script guards its entry point with
# `main() unless caller;`, so we can `do` it and call the sub directly.
use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);

my $script = "$Bin/../ctrl-exec-cli";
ok(-f $script, "ctrl-exec-cli script present");

# Load the script as a library; the caller-guard keeps main() from running.
{
    local $@;
    do $script;
    die "failed to load $script: $@" if $@;
}
ok(defined &main::_print_status, "_print_status loaded");

# Capture STDOUT+STDERR around a _print_status call and return ($rc, $out, $err).
sub run_status {
    my ($data) = @_;
    my ($out, $err) = ('', '');
    my $rc;
    {
        local *STDOUT;
        local *STDERR;
        open STDOUT, '>', \$out or die $!;
        open STDERR, '>', \$err or die $!;
        $rc = main::_print_status($data);
    }
    return ($rc, $out, $err);
}

# --- async: still pending -------------------------------------------------
{
    my ($rc, $out) = run_status({
        mode     => 'async',
        reqid    => 'a1b2c3d4',
        script   => 'long-job',
        complete => 0,
        pending  => ['web-02'],
        hosts    => {
            'web-01' => { status => 'done', exit => 0, stdout => "ok\n" },
            'web-02' => { status => 'running' },
        },
    });
    is($rc, 0, "async pending -> rc 0 (pending is not failure)");
    like($out, qr/reqid:\s+a1b2c3d4/,        "async renders reqid");
    like($out, qr/state:\s+pending/,         "async pending renders state pending");
    like($out, qr/pending:\s+web-02/,        "async renders pending host list");
    like($out, qr/web-01.*done\s+exit:0/s,   "async renders a completed host");
    like($out, qr/web-02.*running/s,         "async renders a running host");
}

# --- async: complete, all hosts succeeded ---------------------------------
{
    my ($rc, $out) = run_status({
        mode     => 'async',
        reqid    => 'deadbeef',
        script   => 'audit',
        complete => 1,
        hosts    => {
            'web-01' => { status => 'done', exit => 0, stdout => "fine" },
            'db-01'  => { status => 'done', exit => 0, stdout => "fine" },
        },
    });
    is($rc, 0, "async complete, all exit 0 -> rc 0");
    like($out, qr/state:\s+complete/, "async complete renders state complete");
}

# --- async: complete, a host failed (nonzero exit) ------------------------
{
    my ($rc, undef, undef) = run_status({
        mode     => 'async',
        reqid    => 'feedface',
        complete => 1,
        hosts    => {
            'web-01' => { status => 'done', exit => 0 },
            'db-01'  => { status => 'done', exit => 3, stderr => "boom\n" },
        },
    });
    is($rc, 1, "async complete with a nonzero host exit -> rc 1");
}

# --- async: complete, a host in error state -------------------------------
{
    my ($rc) = run_status({
        mode     => 'async',
        reqid    => 'cafef00d',
        complete => 1,
        hosts    => {
            'web-01' => { status => 'error', error => 'unreachable' },
        },
    });
    is($rc, 1, "async complete with a host in error state -> rc 1");
}

# --- sync: all hosts ok ---------------------------------------------------
{
    my ($rc, $out) = run_status({
        reqid     => 'sync-1',
        script    => 'uptime',
        hosts     => ['web-01', 'db-01'],
        completed => 1_700_000_000,
        results   => [
            { host => 'web-01', exit => 0, rtt => '12ms', stdout => "up 1d\n" },
            { host => 'db-01',  exit => 0, rtt => '9ms',  stdout => "up 2d\n" },
        ],
    });
    is($rc, 0, "sync all-ok -> rc 0");
    like($out, qr/web-01.*ok/s,  "sync renders ok host");
    like($out, qr/up 1d/,        "sync renders stdout");
}

# --- sync: a host failed --------------------------------------------------
{
    my ($rc, $out, $err) = run_status({
        reqid   => 'sync-2',
        script  => 'deploy',
        hosts   => ['web-01'],
        results => [
            { host => 'web-01', exit => 2, rtt => '5ms', error => 'nonzero' },
        ],
    });
    is($rc, 1, "sync with a failed host -> rc 1");
    like($out, qr/web-01.*exit:2/s, "sync renders the failing exit code");
    like($err, qr/error: nonzero/,  "sync routes the error to STDERR");
}

done_testing();
