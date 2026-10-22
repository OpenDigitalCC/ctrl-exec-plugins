#!/usr/bin/env bash
# nagios-checks.sh
# run-jobs job: asks agents to run named Nagios checks (the nagios-check agent
# script) and logs the result: one syslog line per check that is not OK, and
# one summary line per run.
#
# The job decides WHAT is checked (the names below) and WHEN (schedule=); each
# agent decides HOW (its own checks.conf). Only names are sent.
#
# Config (nagios-checks.conf next to this script), one key per line:
#   schedule = <cron expression>
#   check    = <agent> <check-name> [<check-name> ...]     (may repeat)
#
# Syslog lines (tag ctrl-exec-nagios):
#   host=agent-01 check=disk_root state=CRITICAL summary="DISK CRITICAL - ..."
#   status=critical hosts=2 checks=5 ok=3 warning=1 critical=1 unknown=0
# A host that cannot be reached, or a check that returns nothing, counts as
# UNKNOWN. Priorities: OK info, WARNING warning, CRITICAL and UNKNOWN err.
# Exit 0 when every check is OK, 1 otherwise. The summary is also printed.
#
# Env: NAGIOS_TAG (default ctrl-exec-nagios), NAGIOS_SCRIPT (agent script
# name, default nagios-check), NAGIOS_JOB_CONF (config path).

set -uo pipefail

TAG="${NAGIOS_TAG:-ctrl-exec-nagios}"
SCRIPT="${NAGIOS_SCRIPT:-nagios-check}"
CONF="${NAGIOS_JOB_CONF:-$(dirname "$0")/nagios-checks.conf}"
ERR="/tmp/nagios-checks-$$.err"
trap 'rm -f "$ERR"' EXIT

log() { logger -p "$1" -t "$TAG" -- "$2" || echo "nagios-checks: logger failed" >&2; }

prio() {
    case "$1" in
        OK)      echo user.info ;;
        WARNING) echo user.warning ;;
        *)       echo user.err ;;
    esac
}

# host_lines HOST CHECK...: reads ctrl-exec-cli's JSON on stdin, prints one
# "STATE<TAB>log line" per requested check. The agent's reply is the
# nagios-check JSON in the result's stdout.
host_lines() {
    perl -MJSON::PP -e '
        use strict; use warnings;
        my ($host, @want) = @ARGV;
        sub clean {
            my $m = shift // ""; $m =~ s/\s+/ /g; $m =~ s/"/\x27/g;
            $m =~ s/^ | $//g; return substr($m, 0, 200);
        }
        sub line {
            my ($state, $check, $sum) = @_;
            $state = "UNKNOWN" unless $state && $state =~ /^(OK|WARNING|CRITICAL|UNKNOWN)$/;
            printf "%s\thost=%s check=%s state=%s summary=\"%s\"\n",
                $state, $host, $check, $state, clean($sum);
        }
        sub all_unknown { my $why = shift; line("UNKNOWN", $_, $why) for @want; exit 0 }

        my $d = eval { decode_json(do { local $/; <STDIN> }) };
        if (!$d || ref $d ne "HASH" || !$d->{ok}) {
            my $e = ref $d eq "HASH" ? $d->{error} : undef;
            if (!$e && open my $f, "<", $ENV{NC_ERR}) { $e = <$f> }
            all_unknown($e || "no reply from ctrl-exec-cli");
        }
        my $r = ($d->{results} // [])->[0] or all_unknown("no result for host");
        my $w = eval { decode_json($r->{stdout} // "") };
        if (!$w || ref $w ne "HASH" || !$w->{checks}) {
            all_unknown((ref $w eq "HASH" && $w->{error}) || $r->{error} || $r->{stderr}
                        || "exit " . ($r->{exit} // "?") . ": no readable reply");
        }
        my %got = map { $_->{name} => $_ } @{ $w->{checks} };
        for my $c (@want) {
            my $g = $got{$c};
            $g ? line($g->{state}, $c, $g->{summary}) : line("UNKNOWN", $c, "no result returned");
        }
    ' "$@"
}

if [[ ! -r $CONF ]]; then
    log user.err "cannot read $CONF"
    exit 1
fi

declare -A count=([OK]=0 [WARNING]=0 [CRITICAL]=0 [UNKNOWN]=0)
hosts=0
while IFS='=' read -r key value; do
    key="${key// /}"
    value="${value# }"
    [[ $key == check ]] || continue
    read -r -a words <<< "$value"
    host="${words[0]:-}"
    if [[ -z $host || ${#words[@]} -lt 2 ]]; then
        log user.err "bad check line (want: check = <agent> <name> ...): $value"
        count[UNKNOWN]=$((count[UNKNOWN] + 1))
        continue
    fi
    names=("${words[@]:1}")
    hosts=$((hosts + 1))
    reply="$(ctrl-exec-cli --json run "$host" --script "$SCRIPT" -- "${names[@]}" 2> "$ERR" < /dev/null)"
    while IFS=$'\t' read -r state line; do
        count[$state]=$((count[$state] + 1))
        [[ $state == OK ]] || log "$(prio "$state")" "$line"
    done < <(NC_ERR="$ERR" host_lines "$host" "${names[@]}" <<< "$reply")
done < "$CONF"

total=$((count[OK] + count[WARNING] + count[CRITICAL] + count[UNKNOWN]))
if [[ $total -eq 0 ]]; then
    status=unknown
    worst=UNKNOWN
elif [[ ${count[CRITICAL]} -gt 0 ]]; then
    status=critical
    worst=CRITICAL
elif [[ ${count[WARNING]} -gt 0 ]]; then
    status=warning
    worst=WARNING
elif [[ ${count[UNKNOWN]} -gt 0 ]]; then
    status=unknown
    worst=UNKNOWN
else
    status=ok
    worst=OK
fi
summary="status=$status hosts=$hosts checks=$total ok=${count[OK]} warning=${count[WARNING]} critical=${count[CRITICAL]} unknown=${count[UNKNOWN]}"
log "$(prio "$worst")" "$summary"
echo "$summary"
[[ $status == ok ]]
