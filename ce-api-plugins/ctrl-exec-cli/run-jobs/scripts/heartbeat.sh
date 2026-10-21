#!/usr/bin/env bash
# heartbeat.sh
# Writes ONE syslog line per run saying whether ctrl-exec is healthy, so an
# external log monitor can alert when the status=ok line stops appearing.
#
#   status=ok   agents=3/3 api=0.14.0 min_cert_days=287
#   status=warn agents=3/3 api=0.14.0 expiring=agent-01:12d
#   status=fail agents=2/3 api=0.14.0 down=agent-02
#   status=fail api=down error="..."
#
# Env: HEARTBEAT_TAG (default ctrl-exec-heartbeat), HEARTBEAT_CERT_DAYS
# (default 30). Exit 0 for ok, 1 otherwise. The line is also printed on stdout.

set -uo pipefail

TAG="${HEARTBEAT_TAG:-ctrl-exec-heartbeat}"
export HEARTBEAT_CERT_DAYS="${HEARTBEAT_CERT_DAYS:-30}"

line="$(perl -MJSON::PP -MTime::Piece -e '
    use strict; use warnings;
    my $window = $ENV{HEARTBEAT_CERT_DAYS};

    sub run { my $o = qx(@_ 2>&1); return ($? == 0, $o); }
    sub clean {
        my $m = shift // "unknown"; $m =~ s/\s+/ /g; $m =~ s/"/\x27/g;
        $m =~ s/^ | $//g; return substr($m, 0, 200);
    }
    sub api_fail { print "status=fail api=down error=\"", clean(shift), "\"\n"; exit 0 }
    sub json { my $d = eval { decode_json($_[0]) }; return $d }

    my ($ok, $out) = run("ctrl-exec-cli", "--json", "health");
    my $h = $ok ? json($out) : undef;
    api_fail($ok ? "health: unreadable reply" : $out) unless $h && $h->{ok};
    my $api = $h->{version} // "unknown";

    ($ok, $out) = run("ctrl-exec-cli", "--json", "discovery");
    my $d = $ok ? json($out) : undef;
    api_fail("discovery: " . ($ok ? "unreadable reply" : $out)) unless $d && $d->{ok};
    my @names = sort keys %{ $d->{hosts} // {} };

    if (!@names) { print "status=warn agents=0/0 api=$api\n"; exit 0 }

    ($ok, $out) = run("ctrl-exec-cli", "--json", "ping", @names);
    my $p = $ok ? json($out) : undef;
    api_fail("ping: " . ($ok ? "unreadable reply" : $out)) unless $p && $p->{ok};
    my %res = map { $_->{host} => $_ } @{ $p->{results} // [] };

    my (@down, @expiring, $min, $up);
    $up = 0;
    for my $n (@names) {
        my $r = $res{$n};
        if (!$r || ($r->{status} // "") ne "ok") { push @down, $n; next }
        $up++;
        my $e = $r->{expiry} // "";
        $e =~ s/\s+/ /g; $e =~ s/ GMT$//; $e =~ s/^ //;
        my $t = eval { Time::Piece->strptime($e, "%b %d %H:%M:%S %Y") };
        if (!$t) { push @expiring, "$n:unknown"; next }
        my $days = int(($t->epoch - time) / 86400);
        $min = $days if !defined $min || $days < $min;
        push @expiring, "$n:${days}d" if $days < $window;
    }

    my $line = sprintf "agents=%d/%d api=%s", $up, scalar(@names), $api;
    $line .= " down=" . join(",", @down) if @down;
    $line .= " expiring=" . join(",", @expiring) if @expiring;
    my $status = @down ? "fail" : @expiring ? "warn" : "ok";
    $line .= " min_cert_days=$min" if $status eq "ok";
    print "status=$status $line\n";
')"

case "$line" in
    "status=ok "*)   prio=user.info;    rc=0 ;;
    "status=warn "*) prio=user.warning; rc=1 ;;
    *)               prio=user.err;     rc=1; line="${line:-status=fail api=down error=\"heartbeat produced no output\"}" ;;
esac

logger -p "$prio" -t "$TAG" -- "$line" || echo "heartbeat: logger failed" >&2
echo "$line"
exit "$rc"
