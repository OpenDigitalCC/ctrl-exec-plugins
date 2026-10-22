#!/usr/bin/perl
# agent-config-deploy - write named config files on this host from content the
# dispatcher sends, answer in JSON.
#
#   agent-config-deploy <name>           write the file the map calls <name>
#   agent-config-deploy --test <name>    do everything except the final rename
#   agent-config-deploy --list           list the map's entries and what is installed
#
# The caller sends a name and the contents (input field 'content', so the
# script is declared input=fields in scripts.conf). This host's map says which
# names exist and where each is written, with what owner and mode, and how the
# new contents are checked first:
#
#   /etc/ctrl-exec-agent/config-deploy.conf, or $CONFIG_DEPLOY_MAP
#
#   <name> = <absolute path> [owner=<user>:<group>] [mode=<octal>] [validate=<command and args, {} = staged file>]
#
# '#' comment lines and blank lines are ignored. validate= takes the rest of the
# line, so it comes last; it is run as an argument list (no shell), with every
# {} replaced by the staged file's path. Default owner root:root, mode 0644.
# The map must be owned by root and not group- or world-writable (the test
# suite sets CONFIG_DEPLOY_ALLOW_NONROOT=1 to skip the ownership check).
# Test only: CONFIG_DEPLOY_PROTECTED adds directories that may not be targets;
# CONFIG_DEPLOY_VALIDATE_TIMEOUT shortens the 30 s validate limit.
#
# A write: stage the contents beside the target, set owner and mode, run
# validate on the staged file, keep the old file as <path>.prev, rename the
# staged file over the target. Contents equal to what is installed change
# nothing. The folder must exist; it is never created. A target that is a
# symlink is refused.
#
# Output: one JSON document on stdout. Exit 0 when it worked, 1 when it
# refused or failed (the document has "error"), 2 for bad usage (on stderr).
use strict;
use warnings;
use Cwd qw(realpath);
use Digest::SHA ();
use Encode ();
use Fcntl qw(O_WRONLY O_CREAT O_EXCL);
use File::Basename qw(dirname basename);
use IO::Handle ();
use JSON::PP;
use POSIX ();
use Sys::Hostname qw(hostname);
use Time::HiRes qw(time);

my $MAP     = $ENV{CONFIG_DEPLOY_MAP} // '/etc/ctrl-exec-agent/config-deploy.conf';
my $MAXSIZE = 1024 * 1024;
my $VTIME   = $ENV{CONFIG_DEPLOY_VALIDATE_TIMEOUT} // 30;
my $VOUTMAX = 2000;
my $json    = JSON::PP->new->utf8->canonical;
my @PROTECTED = ('/etc/ctrl-exec-agent', '/etc/ctrl-exec-dispatcher',
                 grep { length } split /:/, $ENV{CONFIG_DEPLOY_PROTECTED} // '');

sub out  { print $json->encode({ host => hostname(), %{ +shift } }), "\n" }
sub fail { out({ error => shift }); exit 1 }

sub usage {
    print STDERR "usage: agent-config-deploy <name> | --test <name> | --list\n";
    exit 2;
}

# --- the map ----------------------------------------------------------------

# Resolve an existing user or group (name or number) to its id, or undef.
sub uid_of { my $u = shift; $u =~ /^\d+$/ ? $u : (getpwnam($u))[2] }
sub gid_of { my $g = shift; $g =~ /^\d+$/ ? $g : (getgrnam($g))[2] }

# The directory part of $path resolved through symlinks, joined to the file
# name; undef when the directory does not exist.
sub resolved {
    my $path = shift;
    my $dir = realpath(dirname($path));
    return undef unless defined $dir;
    return ($dir eq '/' ? '' : $dir) . '/' . basename($path);
}

sub protected_why {
    my ($map_real, $path) = @_;
    my $real = resolved($path) // $path;
    my $linked = -l $path ? realpath($path) : undef;    # where a symlinked target really lies
    for my $r ($real, defined $linked ? $linked : ()) {
        my $w = protected_one($map_real, $path, $r);
        return $w if defined $w;
    }
    return undef;
}

sub protected_one {
    my ($map_real, $path, $real) = @_;
    for my $p (@PROTECTED) {
        my @forms = ($p);
        my $rp = realpath($p);
        push @forms, $rp if defined $rp && $rp ne $p;
        for my $f (@forms) {
            return "is in $p, which this script never writes"
                if $real eq $f || index($real, "$f/") == 0 || $path eq $f || index($path, "$f/") == 0;
        }
    }
    return 'is the map file itself' if defined $map_real && $real eq $map_real;
    if (defined $map_real && -e $path && !-l $path) {
        my @a = stat($path);
        my @b = stat($map_real);
        return 'is the map file itself' if @a && @b && $a[0] == $b[0] && $a[1] == $b[1];
    }
    return undef;
}

sub load_map {
    my $f = $MAP;
    my @st = stat($f) or fail("cannot read config map $f: $!");
    fail("config map $f is not a file") unless -f _;
    fail("config map $f is not owned by root (uid $st[4])")
        if $st[4] != 0 && !$ENV{CONFIG_DEPLOY_ALLOW_NONROOT};
    fail(sprintf('config map %s is group- or world-writable (mode %04o)', $f, $st[2] & 07777))
        if $st[2] & 022;
    open my $fh, '<', $f or fail("cannot read config map $f: $!");
    my $map_real = realpath($f);
    my (%map, @order);
    while (my $line = <$fh>) {
        $line =~ s/^\s+|\s+$//g;
        next if $line eq '' || $line =~ /^#/;
        my $at = "config map $f line $.";
        my ($name, $rest) = $line =~ /^([^\s=]+)\s*=\s*(.*)$/
            or fail("$at: expected '<name> = <absolute path> [options]'");
        $name =~ /^[A-Za-z0-9_-]+$/ or fail("$at: bad name '" . substr($name, 0, 40) . "' (letters, digits, _ and - only)");
        exists $map{$name} and fail("$at: name '$name' defined twice");
        my ($path, $opts) = $rest =~ /^(\S+)\s*(.*)$/
            or fail("$at: '$name' has no path");
        $path =~ m{^/} or fail("$at: path for '$name' is not absolute");
        grep { $_ eq '..' || $_ eq '.' || $_ eq '' } split m{/}, substr($path, 1), -1
            and fail("$at: path for '$name' must be normalised: no '..', '.', '//' or trailing '/'");
        my %e = (name => $name, path => $path, owner => 'root:root', mode => 0644, validate => undef);
        my %seen;
        while (length $opts) {
            if ($opts =~ s/^validate=(.*)$//s) {
                $seen{validate}++ and fail("$at: validate given twice");
                my @argv = split ' ', $1;
                @argv or fail("$at: validate= names no command");
                $argv[0] =~ m{^/} or fail("$at: validate command for '$name' is not an absolute path");
                grep { $_ eq '..' } split m{/}, $argv[0] and fail("$at: validate command for '$name' contains '..'");
                grep { /\{\}/ } @argv or fail("$at: validate for '$name' has no {} for the staged file");
                $e{validate} = \@argv;
            }
            elsif ($opts =~ s/^(owner|mode)=(\S*)\s*//) {
                my ($k, $v) = ($1, $2);
                $seen{$k}++ and fail("$at: $k given twice");
                if ($k eq 'owner') {
                    $v =~ /^([A-Za-z0-9_.-]+):([A-Za-z0-9_.-]+)$/ or fail("$at: owner must be <user>:<group>");
                    defined uid_of($1) or fail("$at: no such user '$1'");
                    defined gid_of($2) or fail("$at: no such group '$2'");
                    $e{owner} = $v;
                }
                else {
                    $v =~ /^0?[0-7]{3,4}$/ or fail("$at: mode must be octal, such as 0644");
                    my $m = oct($v);
                    $m & 07000 and fail("$at: mode must not set setuid, setgid or sticky bits");
                    $e{mode} = $m;
                }
            }
            else {
                my ($k) = $opts =~ /^([A-Za-z0-9_]+)=/;
                fail("$at: " . (defined $k ? "unknown option '$k'" : 'unrecognised text after the path'));
            }
            $opts =~ s/^\s+//;
        }
        my ($uid, $gid) = split /:/, $e{owner};
        @e{qw(uid gid)} = (uid_of($uid), gid_of($gid));
        my $why = protected_why($map_real, $path);
        fail("$at: path for '$name' $why") if defined $why;
        $map{$name} = \%e;
        push @order, $name;
    }
    return (\%map, \@order);
}

# --- files ------------------------------------------------------------------

sub sha_file {
    my $p = shift;
    open my $fh, '<', $p or return undef;
    binmode $fh;
    return Digest::SHA->new(256)->addfile($fh)->hexdigest;
}

sub trimmed {
    my $s = Encode::decode('UTF-8', shift // '');
    $s =~ s/\0//g;
    $s =~ s/^\s+|\s+$//g;
    return length $s > $VOUTMAX ? substr($s, 0, $VOUTMAX - 3) . '...' : $s;
}

# Run the validate command on the staged file, at most $VTIME seconds, stdin
# empty, stdout and stderr merged. Returns (exit code or undef, output).
sub run_validate {
    my ($argv, $staged) = @_;
    my @cmd = map { s/\{\}/$staged/gr } @$argv;
    return (undef, "validate command not found or not executable: $cmd[0]") unless -f $cmd[0] && -x _;
    pipe(my $rd, my $wr) or return (undef, "pipe failed: $!");
    my $pid = fork;
    return (undef, "fork failed: $!") unless defined $pid;
    if (!$pid) {
        setpgrp(0, 0);
        open STDIN,  '<',  '/dev/null';
        open STDOUT, '>&', $wr;
        open STDERR, '>&', $wr;
        local $ENV{LC_ALL} = 'C';
        local $ENV{PATH}   = '/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin';
        { no warnings 'exec'; exec {$cmd[0]} @cmd }
        print "exec failed: $!\n";
        POSIX::_exit(127);
    }
    close $wr;
    my ($buf, $timed_out) = ('', 0);
    my $deadline = time + $VTIME;
    my $rin = '';
    vec($rin, fileno($rd), 1) = 1;
    while (1) {
        my $left = $deadline - time;
        if ($left <= 0) { $timed_out = 1; last }
        select(my $rout = $rin, undef, undef, $left) > 0 or next;
        my $n = sysread($rd, my $chunk, 65536);
        last unless $n;
        $buf .= $chunk if length $buf < 65536;
    }
    my $reaped = 0;
    until ($reaped = waitpid($pid, POSIX::WNOHANG)) {
        if (time >= $deadline) { $timed_out = 1; last }
        select(undef, undef, undef, 0.02);
    }
    kill 'KILL', -$pid;
    if (!$reaped) { kill 'KILL', $pid; waitpid($pid, 0) }
    my $st = $?;
    return (undef, "timed out after ${VTIME}s" . (length $buf ? ": $buf" : '')) if $timed_out;
    return (undef, "killed by signal " . ($st & 127) . (length $buf ? ": $buf" : '')) if $st & 127;
    return ($st >> 8, $buf);
}

sub read_content {
    my $dir = $ENV{CTRL_EXEC_INPUT};
    my $f = defined $dir && length $dir ? "$dir/content" : undef;
    fail("no input received (field 'content')") unless defined $f && -f $f;
    my $size = -s $f;
    fail("content is $size bytes, over the $MAXSIZE byte limit") if $size > $MAXSIZE;
    open my $fh, '<', $f or fail("cannot read input field 'content': $!");
    binmode $fh;
    local $/;
    my $c = <$fh>;
    $c //= '';
    fail("content is over the $MAXSIZE byte limit") if length $c > $MAXSIZE;
    return $c;
}

# copy $src to $dst (new file), same mode, and same owner when root
sub copy_keeping {
    my ($src, $dst) = @_;
    my @st = stat($src) or return "cannot stat $src: $!";
    open my $in, '<', $src or return "cannot read $src: $!";
    binmode $in;
    sysopen(my $o, $dst, O_WRONLY | O_CREAT | O_EXCL, 0600) or return "cannot create $dst: $!";
    binmode $o;
    while (my $n = sysread($in, my $buf, 65536)) { print $o $buf or return "write to $dst failed: $!" }
    $o->flush;
    $o->sync;
    close $o or return "close $dst failed: $!";
    if ($> == 0) { chown $st[4], $st[5], $dst or return "chown $dst failed: $!" }
    chmod $st[2] & 07777, $dst or return "chmod $dst failed: $!";
    return undef;
}

# --- calls ------------------------------------------------------------------

sub do_list {
    my ($map, $order) = @_;
    my @rows;
    for my $n (@$order) {
        my $e = $map->{$n};
        my $p = $e->{path};
        my %r = (name => $n, path => $p, exists => JSON::PP::false, sha256 => undef, size => undef,
                 owner => undef, mode => undef, validate => $e->{validate} ? JSON::PP::true : JSON::PP::false);
        if (-l $p) {
            $r{exists} = JSON::PP::true;
            $r{symlink} = JSON::PP::true;
        }
        elsif (my @st = stat($p)) {
            $r{exists} = JSON::PP::true;
            $r{size}   = $st[7];
            $r{mode}   = sprintf '%04o', $st[2] & 07777;
            $r{owner}  = join ':', scalar(getpwuid($st[4])) // $st[4], scalar(getgrgid($st[5])) // $st[5];
            $r{sha256} = -f _ ? sha_file($p) : undef;
        }
        push @rows, \%r;
    }
    out({ files => \@rows });
    exit 0;
}

sub do_write {
    my ($map, $name, $test) = @_;
    exists $map->{$name} or fail("unknown config name '$name'; known: " . join(', ', sort keys %$map));
    my $e = $map->{$name};
    my $path = $e->{path};

    my $content = read_content();

    my $dir = realpath(dirname($path));
    fail("folder " . dirname($path) . " does not exist for '$name'; it is never created") unless defined $dir && -d $dir;
    my $real = ($dir eq '/' ? '' : $dir) . '/' . basename($path);
    my $map_real = realpath($MAP);
    my $why = protected_why($map_real, $path);
    fail("path for '$name' $why") if defined $why;
    fail("$path is a symlink; refusing to write through it") if -l $path;
    fail("$path exists and is not a regular file") if -e $path && !-f _;

    my $new_sha = Digest::SHA::sha256_hex($content);
    my $old_sha = -e $path ? sha_file($path) : undef;
    fail("cannot read $path to compare it: $!") if -e $path && !defined $old_sha;
    my %doc = (name => $name, path => $path, sha256 => $new_sha, previous_sha256 => $old_sha,
               validate => { ran => JSON::PP::false, exit => undef, output => '' });

    if (defined $old_sha && $old_sha eq $new_sha) {
        out({ %doc, changed => JSON::PP::false, $test ? (test => JSON::PP::true, would_change => JSON::PP::false) : () });
        exit 0;
    }

    my $staged = "$dir/." . basename($path) . ".new.$$";
    sysopen(my $o, $staged, O_WRONLY | O_CREAT | O_EXCL, 0600) or fail("cannot stage $staged: $!");
    my $cleanup = sub { unlink $staged };
    binmode $o;
    (print $o $content) && $o->flush && $o->sync && close($o) or do { $cleanup->(); fail("cannot write $staged: $!") };

    if ($> == 0) {
        chown $e->{uid}, $e->{gid}, $staged or do { my $m = $!; $cleanup->(); fail("cannot set owner $e->{owner} on the staged file: $m") };
    }
    else {
        print STDERR "agent-config-deploy: not root: owner $e->{owner} not applied\n"
            if $e->{uid} != $> || $e->{gid} != (split ' ', $))[0];
    }
    chmod $e->{mode}, $staged or do { my $m = $!; $cleanup->(); fail("cannot set mode on the staged file: $m") };

    if ($e->{validate}) {
        my ($code, $vout) = run_validate($e->{validate}, $staged);
        my $text = trimmed($vout);
        $doc{validate} = { ran => JSON::PP::true, exit => $code, output => $text };
        if (!defined $code || $code != 0) {
            $cleanup->();
            my $what = defined $code ? "validate failed (exit $code)" : 'validate did not finish';
            out({ error => length $text ? "$what: $text" : $what, name => $name, path => $path,
                  validate => $doc{validate} });
            exit 1;
        }
    }

    if ($test) {
        $cleanup->();
        out({ %doc, changed => JSON::PP::false, test => JSON::PP::true, would_change => JSON::PP::true });
        exit 0;
    }

    if (defined $old_sha) {
        my $prev_tmp = "$dir/." . basename($path) . ".prev.$$";
        my $err = copy_keeping($path, $prev_tmp);
        if (defined $err) { unlink $prev_tmp; $cleanup->(); fail("cannot keep the old file as $path.prev: $err") }
        rename $prev_tmp, "$real.prev" or do { my $m = $!; unlink $prev_tmp; $cleanup->(); fail("cannot keep the old file as $path.prev: $m") };
    }
    rename $staged, $real or do { my $m = $!; $cleanup->(); fail("cannot replace $path: $m") };
    out({ %doc, changed => JSON::PP::true });
    exit 0;
}

sub main {
    my @a = @ARGV;
    usage() unless @a;
    my ($mode, $name);
    if ($a[0] eq '--list') { usage() unless @a == 1; $mode = 'list' }
    elsif ($a[0] eq '--test') { usage() unless @a == 2 && $a[1] !~ /^-/; ($mode, $name) = ('test', $a[1]) }
    elsif ($a[0] !~ /^-/) { usage() unless @a == 1; ($mode, $name) = ('write', $a[0]) }
    else { usage() }
    my ($map, $order) = load_map();
    do_list($map, $order) if $mode eq 'list';
    $name =~ /^[A-Za-z0-9_-]+$/ or fail('unknown config name (names are letters, digits, _ and -); known: ' . join(', ', sort keys %$map));
    do_write($map, $name, $mode eq 'test');
}

main();
