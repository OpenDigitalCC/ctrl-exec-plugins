#!/usr/bin/perl
# log-review - return a bounded slice of a named log source on this host.
#
#   log-review <name> [--lines N] [--since DURATION] [--text]
#                                        the last N lines of the source, or the
#                                        lines of the last DURATION (at most N)
#   log-review --list                    every source: name, kind, target,
#                                        whether it can be read, whether filtered
#   log-review --check-config FILE       parse FILE like the config, run nothing:
#                                        list its sources and settings (exit 0 if
#                                        it parses, 3 with an error if not); FILE
#                                        must be in the config's own folder
#
# The caller names a source and a window. It never sends a path, unit,
# pattern or search string: this host's config says what each name reads
# (/etc/log-review/sources.conf, or $LOG_REVIEW_CONF in tests).
#
#   max_lines     = 1000       # most lines a caller may ask for (never above 1000)
#   default_lines = 100        # lines when --lines is not given
#   max_span      = 7d         # longest --since (s m h d; never above 7d)
#   timeout       = 15         # seconds for the reader (journalctl), default 15
#   auth          = journal id=sshd
#   web           = journal unit=nginx.service priority=warning match=error|crit
#   syslog        = file /var/log/syslog match=^\w{3} +\d+ [\d:]+ \S+ (?!cron)
#
# 'key = value' lines, '#' comment lines. The four settings above are fixed
# names; every other key is a source name ([A-Za-z0-9_][A-Za-z0-9_-]*). The value is
#   journal unit=NAME | id=IDENT [priority=0-7|name] [match=REGEX]
#   file /absolute/path [match=REGEX]
# match= is an agent-set Perl regex, last on the line (the rest of the line is
# the regex), compiled at load; only lines it matches are returned.
#
# Output: one JSON document {host,name,kind,target,lines,count,truncated,
# since?,duration_ms}, or with --text just the lines. Errors are
# {host,error} (text mode: a line on stderr). Exit: 0 ok, 1 the source could
# not be read, 2 usage or a value out of bounds, 3 config error.
#
# Test-only environment: LOG_REVIEW_CONF (config path), LOG_REVIEW_JOURNALCTL
# (path of a journalctl stand-in). Leave both unset on a real host.
use strict;
use warnings;
use Cwd qw(realpath);
use Encode ();
use Fcntl qw(O_RDONLY O_NONBLOCK O_NOFOLLOW SEEK_SET);
use JSON::PP;
use POSIX ();
use Sys::Hostname qw(hostname);
use Time::HiRes qw(time);
use Time::Local qw(timegm timelocal);

my $CONF    = $ENV{LOG_REVIEW_CONF} // '/etc/log-review/sources.conf';
my $CAP_LINES = 1000;         # the caller cap can be lowered, never raised
my $CAP_SPAN  = 7 * 86400;
my $BOUND     = 20000;        # most lines read to find N matches or a window
my $MAXLINE   = 2000;
my $TAILBYTES = 64 * 1024 * 1024;
my $json = JSON::PP->new->utf8->canonical;
my $HOST = hostname();
my $TEXT = 0;
my $CHILD;

sub out_error {
    my ($code, $msg) = @_;
    if ($TEXT) { print STDERR "log-review: $msg\n" }
    else       { print $json->encode({ host => $HOST, error => $msg }), "\n" }
    exit $code;
}

sub usage {
    print STDERR "usage: log-review <name> [--lines N] [--since <N>s|m|h|d] [--text]\n"
               . "       log-review --list\n"
               . "       log-review --check-config FILE\n";
    exit 2;
}

sub span_secs {    # '90m' -> seconds, undef if not <int><s|m|h|d>
    my $s = shift // '';
    $s =~ /^([1-9][0-9]{0,8})([smhd])$/ or return undef;
    return $1 * { s => 1, m => 60, h => 3600, d => 86400 }->{$2};
}

sub valid_path {    # undef if fine, else the reason
    my $p = shift;
    return 'path must be absolute' unless $p =~ m{^/};
    return 'path has characters outside printable ASCII' if $p =~ /[^\x21-\x7e]/;
    return 'path must be normalised (no //, ., .. or trailing /)'
        if $p =~ m{//} || $p =~ m{/\.\.?(?:/|$)} || $p =~ m{./$} || $p eq '/';
    return undef;
}

sub load_conf {
    my $path = shift;
    open my $fh, '<', $path or out_error(3, "cannot read config $path as user " . (getpwuid($>) // $>) . ": $!");
    my %cfg = (max_lines => $CAP_LINES, default_lines => 100, max_span => $CAP_SPAN,
               timeout => 15, source => {}, order => []);
    my ($dl_set, %at);
    while (my $line = <$fh>) {
        $line =~ s/^\s+|\s+$//g;
        next if $line eq '' || $line =~ /^#/;
        my ($k, $v) = $line =~ /^(\S+?)\s*=\s*(.*)$/ or out_error(3, "$path line $.: expected 'key = value'");
        my $at = "$path line $.";
        if ($k eq 'max_lines' || $k eq 'default_lines') {
            $v =~ /^[1-9][0-9]{0,5}$/ or out_error(3, "$at: $k must be a whole number of lines");
            out_error(3, "$at: $k must not be above $CAP_LINES") if $k eq 'max_lines' && $v > $CAP_LINES;
            $cfg{$k} = $v + 0;
            if ($k eq 'default_lines') { $dl_set = 1; $at{dl} = $. }
        }
        elsif ($k eq 'max_span') {
            my $s = span_secs($v) // out_error(3, "$at: max_span must be a number and one of s m h d, like 7d");
            out_error(3, "$at: max_span must not be above 7d") if $s > $CAP_SPAN;
            $cfg{max_span} = $s;
        }
        elsif ($k eq 'timeout') {
            $v =~ /^[1-9][0-9]{0,2}$/ && $v <= 600 or out_error(3, "$at: timeout must be 1 to 600 seconds");
            $cfg{timeout} = $v + 0;
        }
        else {
            $k =~ /^[A-Za-z0-9_][A-Za-z0-9_-]*$/ or out_error(3, "$at: bad source name '" . substr($k =~ s/[^\x21-\x7e]//gr, 0, 40) . "'");
            exists $cfg{source}{$k} and out_error(3, "$at: source '$k' defined twice");
            my $s = parse_source($v);
            ref $s or out_error(3, "$at: $s");
            $cfg{source}{$k} = $s;
            push @{ $cfg{order} }, $k;
        }
    }
    if ($dl_set) {
        out_error(3, "$path line $at{dl}: default_lines must not be above max_lines ($cfg{max_lines})")
            if $cfg{default_lines} > $cfg{max_lines};
    }
    elsif ($cfg{default_lines} > $cfg{max_lines}) { $cfg{default_lines} = $cfg{max_lines} }
    return \%cfg;
}

# A source value to a hashref, or a string with the reason it is refused.
sub parse_source {
    my $v = shift;
    my ($match, $re);
    if ($v =~ s/(?:^|\s)match=(.*)$//s) {
        $match = $1;
        length $match or return 'match= is empty';
        $re = eval { no warnings; qr/$match/ };
        defined $re or return 'match= is not a valid regex';
    }
    $v =~ s/\s+$//;
    my ($kind, @tok) = split ' ', $v;
    defined $kind or return "expected 'journal ...' or 'file ...'";
    my %s = (kind => $kind, match => $match, re => $re);
    if ($kind eq 'journal') {
        for my $t (@tok) {
            my ($o, $val) = $t =~ /^([A-Za-z0-9_]{1,20})=(.+)$/
                or return "journal: expected unit=NAME, id=IDENT or priority=LEVEL, not a bare word";
            $o =~ /^(?:unit|id|priority)$/ or return "journal: unknown option '$o'";
            exists $s{$o} and return "journal: '$o' given twice";
            $s{$o} = $val;
        }
        return "journal: name a unit= or an id=" unless defined $s{unit} || defined $s{id};
        return "journal: give unit= or id=, not both" if defined $s{unit} && defined $s{id};
        return "journal: unit must look like name.service" if defined $s{unit} && $s{unit} !~ /^[A-Za-z0-9_][A-Za-z0-9:_@.\\-]*$/;
        return "journal: id must be a syslog identifier (letters, digits, . _ @ -)" if defined $s{id} && $s{id} !~ /^[A-Za-z0-9_][A-Za-z0-9_.@-]*$/;
        return "journal: priority must be 0-7 or emerg alert crit err warning notice info debug"
            if defined $s{priority} && $s{priority} !~ /^(?:[0-7]|emerg|alert|crit|err|warning|notice|info|debug)$/;
        $s{target} = $s{unit} // $s{id};
    }
    elsif ($kind eq 'file') {
        @tok == 1 or return @tok ? 'file: one path only (match= goes last)' : 'file: no path given';
        my $why = valid_path($tok[0]);
        return "file: $why" if $why;
        $s{path} = $s{target} = $tok[0];
    }
    else { return "kind must be journal or file" }
    return \%s;
}

# ---- reading --------------------------------------------------------------

sub clean {    # bytes -> text without control characters (tab kept)
    my $s = Encode::decode('UTF-8', shift);
    $s =~ s/[\x00-\x08\x0a-\x1f\x7f-\x9f]//g;
    return $s;
}
sub cap { my $s = shift; length $s > $MAXLINE ? substr($s, 0, $MAXLINE) . ' [line cut]' : $s }

sub journalctl_path {
    return -x $ENV{LOG_REVIEW_JOURNALCTL} ? $ENV{LOG_REVIEW_JOURNALCTL} : undef if $ENV{LOG_REVIEW_JOURNALCTL};
    for my $d (qw(/usr/bin /bin)) { return "$d/journalctl" if -x "$d/journalctl" }
    return undef;
}

# Run journalctl by argv (no shell) for at most $limit seconds, calling
# $on_line with each stdout line (bytes). Returns (status, stderr, timed_out).
sub run_journal {
    my ($jc, $limit, $on_line, @args) = @_;
    pipe(my $rd, my $wr) or return (undef, "pipe failed: $!", 0);
    pipe(my $erd, my $ewr) or return (undef, "pipe failed: $!", 0);
    my $pid = fork;
    return (undef, "fork failed: $!", 0) unless defined $pid;
    if (!$pid) {
        setpgrp(0, 0);    # own process group, so a timeout can kill the lot
        open STDIN,  '<',  '/dev/null';
        open STDOUT, '>&', $wr;
        open STDERR, '>&', $ewr;
        close $rd; close $erd;
        local $ENV{LC_ALL} = 'C';
        { no warnings 'exec'; exec {$jc} 'journalctl', @args }
        print STDERR "exec failed: $!\n";
        POSIX::_exit(127);
    }
    $CHILD = $pid;
    close $wr; close $ewr;
    my ($pending, $err, $timed_out, $odone, $edone) = ('', '', 0, 0, 0);
    my $deadline = time + $limit;
    while (!$odone || !$edone) {
        my $left = $deadline - time;
        if ($left <= 0) { $timed_out = 1; last }
        my $rin = '';
        vec($rin, fileno($rd), 1) = 1 unless $odone;
        vec($rin, fileno($erd), 1) = 1 unless $edone;
        select(my $rout = $rin, undef, undef, $left) > 0 or next;
        if (!$odone && vec($rout, fileno($rd), 1)) {
            my $n = sysread($rd, my $chunk, 65536);
            if (!$n) { $odone = 1; next }
            $pending .= $chunk;
            my $start = 0;
            while ((my $i = index($pending, "\n", $start)) >= 0) {
                $on_line->(substr($pending, $start, $i - $start));
                $start = $i + 1;
            }
            $pending = substr($pending, $start);
            $pending = substr($pending, 0, 65536) if length $pending > 65536;
        }
        if (!$edone && vec($rout, fileno($erd), 1)) {
            my $n = sysread($erd, my $chunk, 4096);
            if (!$n) { $edone = 1; next }
            $err .= $chunk if length $err < 4096;
        }
    }
    $on_line->($pending) if !$timed_out && length $pending;
    my $reaped = 0;
    until ($reaped = waitpid($pid, POSIX::WNOHANG)) {
        if (time >= $deadline) { $timed_out = 1; last }
        select(undef, undef, undef, 0.02);
    }
    kill 'KILL', -$pid;    # the group: strays, or everything on a timeout
    if (!$reaped) { kill 'KILL', $pid; waitpid($pid, 0) }
    undef $CHILD;
    return ($?, $err, $timed_out);
}

sub err_line {    # first line of journalctl's stderr, safe to show
    my $e = Encode::decode('UTF-8', shift // '');
    $e =~ s/[\x00-\x08\x0a-\x1f\x7f-\x9f]/ /g;
    $e =~ s/^\s+|\s+$//g;
    return substr($e, 0, 200);
}

# Can the journal be read at all? (1) or (0, reason). Asked once.
my %probe;
sub journal_probe {
    my $cfg = shift;
    return @{ $probe{r} } if $probe{r};
    my @r;
    my $jc = journalctl_path();
    if (!$jc) { @r = (0, 'journalctl not found') }
    else {
        my ($st, $err, $to) = run_journal($jc, $cfg->{timeout}, sub { }, qw(--no-pager -o short-iso -n 1));
        if    ($to)                     { @r = (0, "journalctl timed out after $cfg->{timeout}s") }
        elsif (!defined $st)            { @r = (0, $err) }
        elsif ($st & 127 || $st >> 8)   { @r = (0, 'journalctl failed: ' . (err_line($err) || 'exit ' . ($st >> 8))) }
        elsif ($err =~ /permission|No journal files/i) {
            @r = (0, 'no permission to read the journal (user ' . (getpwuid($>) // $>) . ' needs group systemd-journal or adm)');
        }
        else { @r = (1) }
    }
    $probe{r} = \@r;
    return @r;
}

# Open a source file: (handle) or (undef, reason).
sub open_file {
    my $p = shift;
    lstat($p) or return (undef, $!{EACCES} ? 'permission denied for user ' . (getpwuid($>) // $>) : 'file not found');
    return (undef, 'symlink refused') if -l _;
    return (undef, 'not a regular file') unless -f _;
    sysopen(my $fh, $p, O_RDONLY | O_NONBLOCK | O_NOFOLLOW)
        or return (undef, $!{EACCES} ? 'permission denied for user ' . (getpwuid($>) // $>) : "cannot open: $!");
    -f $fh or return (undef, 'not a regular file');
    return $fh;
}

# The last $want lines of the open file, as byte strings, read backwards in
# blocks. Returns (\@lines, $reached_start).
sub tail_lines {
    my ($fh, $want) = @_;
    my $pos = -s $fh;
    my ($buf, $total) = ('', 0);
    while ($pos > 0 && ($buf =~ tr/\n//) < $want + 1 && $total < $TAILBYTES) {
        my $n = $pos < 65536 ? $pos : 65536;
        $pos -= $n;
        sysseek($fh, $pos, SEEK_SET) or last;
        my $got = sysread($fh, my $blk, $n);
        last unless $got;
        $buf = $blk . $buf;
        $total += $got;
    }
    my @l = split /\n/, $buf, -1;
    pop @l if @l && $l[-1] eq '' && $buf =~ /\n\z/;
    shift @l if $pos > 0 && @l;    # the first one is a fragment
    splice(@l, 0, @l - $want) if @l > $want;
    return (\@l, $pos == 0);
}

my %MON = do { my $i = 0; map { $_ => $i++ } qw(Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec) };
sub line_ts {    # epoch seconds from a leading ISO-8601 or syslog timestamp, else undef
    my ($l, $now) = @_;
    my $t = eval {
        if ($l =~ m{^(\d{4})[-/](\d\d)[-/](\d\d)[T ](\d\d):(\d\d):(\d\d)(?:[.,]\d+)?\s*(Z|[+-]\d\d:?\d\d)?}) {
            my ($y, $mo, $d, $h, $mi, $s, $tz) = ($1, $2, $3, $4, $5, $6, $7);
            if (!defined $tz) { timelocal($s, $mi, $h, $d, $mo - 1, $y) }
            else {
                my $e = timegm($s, $mi, $h, $d, $mo - 1, $y);
                $tz eq 'Z' ? $e : do { my ($sg, $oh, $om) = $tz =~ /^([+-])(\d\d):?(\d\d)$/; $e - ($sg eq '-' ? -1 : 1) * ($oh * 3600 + $om * 60) }
            }
        }
        elsif ($l =~ /^([A-Z][a-z]{2})\s+(\d{1,2}) (\d\d):(\d\d):(\d\d)\b/ && exists $MON{$1}) {
            my $y = (localtime $now)[5] + 1900;
            my $e = timelocal($5, $4, $3, $2, $MON{$1}, $y);
            $e > $now + 86400 ? timelocal($5, $4, $3, $2, $MON{$1}, $y - 1) : $e;
        }
        else { undef }
    };
    return $t;
}

sub read_file {
    my ($src, $n, $span, $cfg) = @_;
    my ($fh, $why) = open_file($src->{path});
    return { error => "$src->{path}: $why" } unless $fh;
    my $re = $src->{re};
    my $now = time;
    my $filter_or_window = $re || defined $span;
    my ($raw, $start) = tail_lines($fh, $filter_or_window ? $BOUND : $n);
    close $fh;
    my @lines = map { clean($_) } @$raw;
    my $truncated = 0;
    if (defined $span) {
        my $cut = $now - $span;
        my @last = grep { length } @lines[ ($#lines > 40 ? $#lines - 40 : 0) .. $#lines ];
        (grep { defined line_ts($_, $now) } @last)
            or return { error => '--since is not supported for this file (its lines do not start with an ISO-8601 or syslog timestamp)' };
        my ($in, $first, @win) = (0, undef);
        for my $l (@lines) {
            my $t = line_ts($l, $now);
            if (defined $t) { $in = $t >= $cut; $first //= $in }
            push @win, $l if $in;
        }
        @lines = @win;
        $truncated = 1 if !$start && $first;    # the window starts before what was read
    }
    @lines = grep { $_ =~ $re } @lines if $re;
    my $short = @lines < $n;
    if (@lines > $n) { splice(@lines, 0, @lines - $n); $truncated = 1 if defined $span }
    $truncated = 1 if !defined $span && $re && $short && !$start;    # the search stopped at the read bound
    return { lines => [ map { cap($_) } @lines ], truncated => $truncated };
}

sub read_journal {
    my ($src, $n, $span, $cfg) = @_;
    my $jc = journalctl_path() or return { error => 'journalctl not found' };
    my $re = $src->{re};
    my $ask = $re ? $BOUND : defined $span ? $n + 1 : $n;
    my @args = (qw(--no-pager -o short-iso -q -n), $ask);
    push @args, defined $src->{unit} ? ('-u', $src->{unit}) : ('-t', $src->{id});
    push @args, ('-p', $src->{priority}) if defined $src->{priority};
    push @args, "--since=-$span seconds" if defined $span;
    my (@ring, $read, $matched);
    my $keep = $n + 1;
    my ($st, $err, $to) = run_journal($jc, $cfg->{timeout}, sub {
        $read++;
        my $l = clean(shift);
        return if $re && $l !~ $re;
        $matched++;
        push @ring, cap($l);
        shift @ring if @ring > $keep;
    }, @args);
    return { error => "journalctl timed out after $cfg->{timeout}s" } if $to;
    return { error => $err } unless defined $st;
    return { error => 'journalctl killed by signal ' . ($st & 127) } if $st & 127;
    return { error => 'journalctl failed: ' . (err_line($err) || 'exit ' . ($st >> 8)) } if $st >> 8;
    $read //= 0; $matched //= 0;
    if (!$read) {    # -q hides the permission warning: ask again without it
        my ($ok, $why) = journal_probe($cfg);
        return { error => "journal not readable: $why" } unless $ok;
    }
    my $truncated = 0;
    if ($re) {
        $truncated = 1 if defined $span ? ($matched > $n || $read >= $ask) : ($matched < $n && $read >= $ask);
    }
    elsif (defined $span) { $truncated = 1 if $read > $n }
    shift @ring while @ring > $n;
    return { lines => \@ring, truncated => $truncated };
}

# ---- listing ----------------------------------------------------------------

sub source_rows {
    my ($cfg, $probe) = @_;
    my @rows;
    for my $name (@{ $cfg->{order} }) {
        my $s = $cfg->{source}{$name};
        my %r = (name => $name, kind => $s->{kind}, target => $s->{target},
                 filter => defined $s->{match} ? JSON::PP::true : JSON::PP::false);
        $r{priority} = $s->{priority} if defined $s->{priority};
        if ($probe) {
            my ($ok, $why);
            if ($s->{kind} eq 'file') {
                my $fh;
                ($fh, $why) = open_file($s->{path});
                $ok = $fh ? 1 : 0;
                close $fh if $fh;
            }
            else { ($ok, $why) = journal_probe($cfg) }
            $r{readable} = $ok ? JSON::PP::true : JSON::PP::false;
            $r{reason} = $why unless $ok;
        }
        push @rows, \%r;
    }
    return \@rows;
}

sub settings {
    my $c = shift;
    return { max_lines => $c->{max_lines}, default_lines => $c->{default_lines},
             max_span_seconds => $c->{max_span}, timeout => $c->{timeout} };
}

sub main {
    my (%o, @names);
    while (@ARGV) {
        my $a = shift @ARGV;
        if ($a eq '--list' || $a eq '--text') {
            my $k = substr($a, 2);
            $o{$k}++ and usage();
        }
        elsif ($a eq '--lines' || $a eq '--since' || $a eq '--check-config') {
            my $k = substr($a, 2);
            defined(my $v = shift @ARGV) or usage();
            exists $o{$k} and usage();
            $o{$k} = $v;
        }
        elsif ($a =~ /^-/) { usage() }
        else { push @names, $a }
    }
    my $t0 = time;
    if (exists $o{'check-config'}) {
        usage() if @names || keys %o > 1;
        my $f = $o{'check-config'};
        # Only a file in the config's own folder (where config-deploy stages
        # it): the caller must not get keys and values of other files back.
        my ($cdir) = $CONF =~ m{^(.*)/[^/]*$};
        my $fdir = realpath($f =~ m{/} ? ($f =~ m{^(.*)/[^/]*$})[0] || '/' : '.');
        my $want = realpath(length $cdir ? $cdir : '/');
        defined $fdir && defined $want && $fdir eq $want && !-l $f
            or out_error(3, "--check-config only reads files in " . (length $cdir ? $cdir : '/'));
        my $cfg = load_conf($f);
        print $json->encode({ host => $HOST, config => $f, settings => settings($cfg),
                              sources => source_rows($cfg, 0) }), "\n";
        exit 0;
    }
    if ($o{list}) {
        usage() if @names || keys %o > 1;
        my $cfg = load_conf($CONF);
        print $json->encode({ host => $HOST, settings => settings($cfg), sources => source_rows($cfg, 1) }), "\n";
        exit 0;
    }
    usage() unless @names == 1;
    $TEXT = $o{text} ? 1 : 0;
    my $name = $names[0];
    $name =~ /^[A-Za-z0-9_][A-Za-z0-9_-]*$/ or out_error(2, 'bad source name');
    my $cfg = load_conf($CONF);
    my $src = $cfg->{source}{$name}
        or out_error(2, "unknown source '$name'; known: " . (join(', ', @{ $cfg->{order} }) || 'none'));

    my $n = $cfg->{default_lines};
    if (defined $o{lines}) {
        $o{lines} =~ /^[0-9]{1,6}$/ or out_error(2, '--lines must be a whole number');
        $o{lines} >= 1 && $o{lines} <= $cfg->{max_lines}
            or out_error(2, "--lines must be 1 to $cfg->{max_lines}");
        $n = $o{lines} + 0;
    }
    my $span;
    if (defined $o{since}) {
        $span = span_secs($o{since}) // out_error(2, '--since must be a number and one of s m h d, like 90m');
        $span <= $cfg->{max_span} or out_error(2, "--since must not be longer than $cfg->{max_span} seconds");
    }

    $SIG{ALRM} = sub { kill 'KILL', -$CHILD if $CHILD; out_error(1, 'timed out reading the source') };
    alarm($cfg->{timeout} + 5);
    my $r = $src->{kind} eq 'file' ? read_file($src, $n, $span, $cfg) : read_journal($src, $n, $span, $cfg);
    alarm(0);
    out_error(1, $r->{error}) if $r->{error};

    if ($TEXT) {
        binmode STDOUT, ':encoding(UTF-8)';
        print "$_\n" for @{ $r->{lines} };
        print STDERR "log-review: truncated: the window holds more lines than returned\n" if $r->{truncated};
    }
    else {
        print $json->encode({ host => $HOST, name => $name, kind => $src->{kind}, target => $src->{target},
                              lines => $r->{lines}, count => scalar @{ $r->{lines} },
                              truncated => $r->{truncated} ? JSON::PP::true : JSON::PP::false,
                              defined $span ? (since => $o{since}) : (),
                              duration_ms => int((time - $t0) * 1000) }), "\n";
    }
    exit 0;
}

main();
