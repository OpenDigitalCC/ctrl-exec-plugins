#!/usr/bin/perl
# nagios-check - run named Nagios plugins on this host, answer in JSON.
#
#   nagios-check <check> [<check> ...]   run the named checks
#   nagios-check --all                   run every configured check
#   nagios-check --list                  list the check names this host offers
#
# The caller names the checks; this host's config says how to run each one
# (/etc/ctrl-exec-agent/nagios-checks.conf, or $NAGIOS_CHECKS_CONF):
#
#   plugin_dir = /usr/lib/nagios/plugins     # default
#   timeout    = 30                          # seconds per check, default 30
#   disk_root  = check_disk -w 20% -c 10% -p /
#
# 'key = value' lines, '#' comment lines. plugin_dir and timeout are settings;
# every other key is a check name ([A-Za-z0-9_-]+) whose value is the plugin
# (a file name in plugin_dir) and its arguments. Arguments split on
# whitespace; '...' and "..." group words (no escapes: use the other quote
# for a quote). No shell is involved anywhere.
#
# Output: one JSON document. Exit code: the overall state, the worst of the
# checks (CRITICAL > WARNING > UNKNOWN > OK) as 0/1/2/3. A wrapper error (no
# arguments, bad config, unknown check) is exit 3 with an "error" field.
use strict;
use warnings;
use Cwd qw(realpath);
use Encode ();
use JSON::PP;
use POSIX ();
use Sys::Hostname qw(hostname);
use Time::HiRes qw(time);

my $CONF = $ENV{NAGIOS_CHECKS_CONF} // '/etc/ctrl-exec-agent/nagios-checks.conf';
my @STATE = qw(OK WARNING CRITICAL UNKNOWN);
my %CODE  = map { $STATE[$_] => $_ } 0 .. 3;
my %RANK  = (CRITICAL => 3, WARNING => 2, UNKNOWN => 1, OK => 0);
my $NUM   = qr/[-+]?(?:\d+\.?\d*|\.\d+)(?:[eE][-+]?\d+)?/;
my $MAXOUT = 65536;
my $json  = JSON::PP->new->utf8->canonical;

sub fail {
    print $json->encode({ state => 'UNKNOWN', code => 3, error => shift }), "\n";
    exit 3;
}

# Split an argument string into words; undef on an unterminated quote.
sub split_args {
    my ($s, @w, $cur) = shift;
    while ($s =~ /\G(?:(\s+)|'([^']*)'|"([^"]*)"|([^\s'"]+)|(['"]))/gc) {
        if (defined $1)    { push @w, $cur if defined $cur; undef $cur }
        elsif (defined $5) { return undef }
        else               { $cur = ($cur // '') . ($2 // $3 // $4) }
    }
    push @w, $cur if defined $cur;
    return \@w;
}

sub load_conf {
    open my $fh, '<', $CONF or fail("cannot read config $CONF: $!");
    my %cfg = (plugin_dir => '/usr/lib/nagios/plugins', timeout => 30, check => {}, order => []);
    while (my $line = <$fh>) {
        $line =~ s/^\s+|\s+$//g;
        next if $line eq '' || $line =~ /^#/;
        my ($k, $v) = $line =~ /^(\S+?)\s*=\s*(.*)$/ or fail("$CONF line $.: expected 'key = value'");
        if ($k eq 'plugin_dir') { $cfg{plugin_dir} = $v }
        elsif ($k eq 'timeout') {
            $v =~ /^[1-9]\d*$/ or fail("$CONF line $.: timeout must be a whole number of seconds");
            $cfg{timeout} = $v;
        }
        else {
            $k =~ /^[A-Za-z0-9_-]+$/ or fail("$CONF line $.: bad check name '$k'");
            exists $cfg{check}{$k} and fail("$CONF line $.: check '$k' defined twice");
            my $w = split_args($v) or fail("$CONF line $.: unterminated quote");
            @$w or fail("$CONF line $.: check '$k' names no plugin");
            $cfg{check}{$k} = $w;
            push @{ $cfg{order} }, $k;
        }
    }
    $cfg{real_dir} = realpath($cfg{plugin_dir}) // '';
    return \%cfg;
}

# Run one plugin. Returns (exit code, output, reason); a reason means UNKNOWN.
sub run_plugin {
    my ($cfg, $plugin, @args) = @_;
    return (undef, '', "plugin name '$plugin' must not contain '/'") if $plugin =~ m{/};
    my $path = "$cfg->{plugin_dir}/$plugin";
    my $real = -e $path ? realpath($path) : undef;
    return (undef, '', "plugin not found: $path") unless defined $real;
    return (undef, '', "plugin $path resolves outside plugin_dir")
        unless length $cfg->{real_dir} && index($real, "$cfg->{real_dir}/") == 0;
    return (undef, '', "plugin not executable: $path") unless -f $real && -x $real;

    pipe(my $rd, my $wr) or return (undef, '', "pipe failed: $!");
    my $pid = fork;
    return (undef, '', "fork failed: $!") unless defined $pid;
    if (!$pid) {
        setpgrp(0, 0);    # own process group, so a timeout can kill the lot
        open STDIN,  '<',  '/dev/null';
        open STDOUT, '>&', $wr;
        open STDERR, '>&', $wr;    # one stream, plugins report on stdout anyway
        local $ENV{LC_ALL} = 'C';
        local $ENV{PATH}   = $ENV{PATH} // '/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin';
        { no warnings "exec"; exec {$real} $plugin, @args }
        print "exec failed: $!\n";
        POSIX::_exit(127);
    }
    close $wr;

    my ($buf, $timed_out) = ('', 0);
    my $deadline = time + $cfg->{timeout};
    my $rin = '';
    vec($rin, fileno($rd), 1) = 1;
    while (1) {
        my $left = $deadline - time;
        if ($left <= 0) { $timed_out = 1; last }
        select(my $rout = $rin, undef, undef, $left) > 0 or next;
        my $n = sysread($rd, my $chunk, 65536);
        last unless $n;    # EOF
        $buf .= $chunk if length $buf < $MAXOUT;
    }
    my $reaped = 0;
    until ($reaped = waitpid($pid, POSIX::WNOHANG)) {
        if (time >= $deadline) { $timed_out = 1; last }
        select(undef, undef, undef, 0.02);
    }
    kill 'KILL', -$pid;    # the group: strays, or everything on a timeout
    if (!$reaped) { kill 'KILL', $pid; waitpid($pid, 0) }
    my $st = $?;
    $buf = substr($buf, 0, $MAXOUT);

    return (undef, $buf, "timed out after $cfg->{timeout}s") if $timed_out;
    return (undef, $buf, 'killed by signal ' . ($st & 127)) if $st & 127;
    my $code = $st >> 8;
    return ($code, $buf, "exit code $code is outside 0-3") if $code > 3;
    return ($code, $buf, undef);
}

sub range_field {    # number if numeric, string if a range, null if empty
    my $f = shift;
    return undef unless defined $f && $f ne '';
    return $f =~ /^$NUM$/ ? $f + 0 : $f;
}

# 'label'=value[UOM];[warn];[crit];[min];[max] items, space separated.
sub parse_perf {
    my ($s, @out) = shift;
    while ($s =~ /\G\s*(?:'((?:[^']|'')*)'|([^\s='][^\s=]*))=(\S*)|\G\s*\S+/gc) {
        my ($quoted, $bare, $data) = ($1, $2, $3);
        next unless defined $data;
        my $label = defined $quoted ? $quoted =~ s/''/'/gr : $bare;
        my ($val, @f) = split /;/, $data, 5;
        $val //= '';
        my ($v, $uom);
        if    ($val =~ /^($NUM)(.*)$/) { ($v, $uom) = ($1 + 0, $2) }
        elsif ($val eq 'U')            { ($v, $uom) = (undef, '') }
        else                           { next }
        push @out, { label => $label, value => $v, uom => $uom,
                     map { (qw(warn crit min max))[$_] => range_field($f[$_]) } 0 .. 3 };
    }
    return \@out;
}

# First line 'summary | perfdata'; later lines are long output, and a '|' in
# one starts more perfdata that runs to the end (Nagios plugin guidelines).
sub parse_output {
    my @lines = split /\r?\n/, shift;
    my ($sum, $perf) = split /\|/, shift(@lines) // '', 2;
    my (@long, $in_perf);
    $perf //= '';
    for my $l (@lines) {
        if ($in_perf) { $perf .= " $l" }
        elsif ($l =~ /^(.*?)\s*\|(.*)$/) { push @long, $1; $perf .= " $2"; $in_perf = 1 }
        else { push @long, $l }
    }
    ($sum //= '') =~ s/^\s+|\s+$//g;
    return ($sum, parse_perf($perf), join("\n", @long));
}

sub run_check {
    my ($cfg, $name) = @_;
    my $t0 = time;
    my ($code, $out, $why) = run_plugin($cfg, @{ $cfg->{check}{$name} });
    $out = Encode::decode('UTF-8', $out);    # malformed bytes become U+FFFD
    my ($sum, $perf, $long) = parse_output($out);
    if (defined $why) {
        $code = 3;
        $sum  = length $sum ? "$why: $sum" : $why;
    }
    return { name => $name, state => $STATE[$code], code => $code, summary => $sum,
             perfdata => $perf, long_output => $long,
             duration_ms => int((time - $t0) * 1000) };
}

sub main {
    @ARGV or do {
        print STDERR "usage: nagios-check --list | --all | <check> [<check> ...]\n";
        fail('no arguments: name the checks to run, or --list');
    };
    my $cfg = load_conf();
    my $host = hostname();
    if ($ARGV[0] eq '--list') {
        @ARGV == 1 or fail('--list takes no other arguments');
        print $json->encode({ host => $host, checks => $cfg->{order} }), "\n";
        exit 0;
    }
    my @names = @ARGV == 1 && $ARGV[0] eq '--all' ? @{ $cfg->{order} } : @ARGV;
    @names or fail('no checks are configured');
    for (@names) {
        /^[A-Za-z0-9_-]+$/ or fail("bad check name '$_'");
        exists $cfg->{check}{$_} or fail("unknown check '$_'");
    }
    my %seen;
    my @checks = map { run_check($cfg, $_) } grep { !$seen{$_}++ } @names;
    my ($worst) = sort { $RANK{$b} <=> $RANK{$a} } map { $_->{state} } @checks;
    print $json->encode({ host => $host, state => $worst, code => $CODE{$worst}, checks => \@checks }), "\n";
    exit $CODE{$worst};
}

main();
