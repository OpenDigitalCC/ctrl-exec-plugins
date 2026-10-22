#!/usr/bin/env bash
# config-push.sh
# run-jobs job: sends config files to agents (the agent-config-deploy agent
# script) and logs the result: one syslog line per push, one summary per run.
#
# The job decides WHICH file goes to WHICH agent under WHICH name; each agent
# decides WHERE it is written, with what owner and mode, and whether it passes
# the agent's own check (its config-deploy.conf). Only the name and the
# contents are sent.
#
#   config-push.sh [--check] [<agent> ...]
#
#   (no option)  push every line of the config (only the agents given, if any)
#   --check      read-only: ask each agent what it has (--list), compare the
#                sha256 with the local source, push nothing
#
# Config (config-push.conf next to this script), one key per line:
#   push = <agent> <name> <source file>             (may repeat)
# A relative source file is taken from the folder of the config file. A
# schedule = line is not needed (run on demand) and is ignored by the job.
#
# Syslog lines (tag ctrl-exec-config):
#   agent=agent-01 name=nagios-checks result=changed sha256=0123abcd...
#   agent=agent-01 name=nagios-checks result=unchanged sha256=0123abcd...
#   agent=agent-02 name=nagios-checks result=failed error="validate failed (exit 3): ..."
#   (--check) result=same | differs | missing | failed
#   status=ok mode=push lines=3 changed=1 unchanged=2 same=0 differs=0 missing=0 failed=0
# Priorities: changed, unchanged and same info; differs and missing warning;
# failed err. The summary takes the worst. Everything logged is also printed.
# Exit 0 when every line succeeded (push) or is the same (--check), else 1.
#
# Env: CONFIG_PUSH_TAG (default ctrl-exec-config), CONFIG_PUSH_SCRIPT (agent
# script name, default agent-config-deploy), CONFIG_PUSH_CONF (config path).

set -uo pipefail

TAG="${CONFIG_PUSH_TAG:-ctrl-exec-config}"
SCRIPT="${CONFIG_PUSH_SCRIPT:-agent-config-deploy}"
CONF="${CONFIG_PUSH_CONF:-$(dirname "$0")/config-push.conf}"
ERR="/tmp/config-push-$$.err"
trap 'rm -f "$ERR"' EXIT

CHECK=0
AGENTS=()
for arg in "$@"; do
    case "$arg" in
        --check) CHECK=1 ;;
        -*) echo "usage: config-push.sh [--check] [<agent> ...]" >&2; exit 2 ;;
        *) AGENTS+=("$arg") ;;
    esac
done

log() { logger -p "$1" -t "$TAG" -- "$2" || echo "config-push: logger failed" >&2; }

# src_json FILE: {"content": "<file text>"} on stdout. Fails (message on
# stderr) when the file cannot be read, is over 1 MiB or is not UTF-8 text.
src_json() {
    perl -MJSON::PP -MEncode -e '
        use strict; use warnings;
        open my $f, "<", $ARGV[0] or die "cannot read $ARGV[0]: $!\n";
        binmode $f; local $/;
        my $b = <$f>; $b //= "";
        length $b <= 1048576 or die "$ARGV[0] is over 1 MiB\n";
        my $t = eval { Encode::decode("UTF-8", $b, Encode::FB_CROAK) } // die "$ARGV[0] is not UTF-8 text\n";
        print JSON::PP->new->utf8->canonical->encode({ content => $t });' "$1"
}

# src_sha FILE: sha256 of the file's bytes
src_sha() {
    perl -MDigest::SHA -e '
        open my $f, "<", $ARGV[0] or exit 1; binmode $f;
        print Digest::SHA->new(256)->addfile($f)->hexdigest;' "$1"
}

# reply_line MODE AGENT NAME LOCAL_SHA: reads ctrl-exec-cli's JSON on stdin,
# prints "KIND<TAB>log line". KIND is changed, unchanged, same, differs,
# missing or failed.
reply_line() {
    perl -MJSON::PP -e '
        use strict; use warnings;
        my ($mode, $agent, $name, $sha) = @ARGV;
        sub clean {
            my $m = shift // ""; $m =~ s/\s+/ /g; $m =~ s/"/\x27/g;
            $m =~ s/^ | $//g; return substr($m, 0, 300);
        }
        sub line {
            my ($kind, $extra) = @_;
            printf "%s\tagent=%s name=%s result=%s %s\n", $kind, $agent, $name, $kind, $extra;
            exit 0;
        }
        sub bad { line("failed", "error=\"" . clean(shift || "no reply from ctrl-exec-cli") . "\"") }

        my $d = eval { decode_json(do { local $/; <STDIN> }) };
        if (!$d || ref $d ne "HASH" || !$d->{ok}) {
            my $e = ref $d eq "HASH" ? $d->{error} : undef;
            if (!$e && open my $f, "<", $ENV{CP_ERR}) { $e = <$f> }
            bad($e);
        }
        my $r = ($d->{results} // [])->[0] or bad("no result for host");
        my $w = eval { decode_json($r->{stdout} // "") };
        if (!$w || ref $w ne "HASH" || $w->{error} || ($r->{exit} // 1) != 0) {
            bad((ref $w eq "HASH" && $w->{error}) || $r->{error} || $r->{stderr}
                || "exit " . ($r->{exit} // "?") . ": no readable reply");
        }
        if ($mode eq "push") {
            my $s = substr($w->{sha256} // "", 0, 12);
            line($w->{changed} ? "changed" : "unchanged", "sha256=$s");
        }
        my ($f) = grep { $_->{name} eq $name } @{ $w->{files} // [] };
        bad("unknown name on the agent") unless $f;
        line("missing", "") unless $f->{exists} && !$f->{symlink} && defined $f->{sha256};
        line($f->{sha256} eq $sha ? "same" : "differs", "sha256=" . substr($sha, 0, 12) . " agent_sha256=" . substr($f->{sha256}, 0, 12));
    ' "$@"
}

prio() {
    case "$1" in
        changed | unchanged | same) echo user.info ;;
        differs | missing)          echo user.warning ;;
        *)                          echo user.err ;;
    esac
}

if [[ ! -r $CONF ]]; then
    log user.err "cannot read $CONF"
    echo "cannot read $CONF" >&2
    exit 1
fi

declare -A count=([changed]=0 [unchanged]=0 [same]=0 [differs]=0 [missing]=0 [failed]=0)
lines=0
mode=push
[[ $CHECK == 1 ]] && mode=check
confdir="$(cd "$(dirname "$CONF")" && pwd)"

record() {    # KIND LINE
    count[$1]=$((count[$1] + 1))
    log "$(prio "$1")" "$2"
    echo "$2"
}

while IFS='=' read -r key value; do
    key="${key// /}"
    value="${value# }"
    [[ $key == push ]] || continue
    read -r -a words <<< "$value"
    agent="${words[0]:-}"
    name="${words[1]:-}"
    src="${words[2]:-}"
    if [[ -z $agent || -z $name || -z $src || ${#words[@]} -ne 3 ]]; then
        lines=$((lines + 1))
        record failed "bad push line (want: push = <agent> <name> <source file>): $value"
        continue
    fi
    if [[ ${#AGENTS[@]} -gt 0 ]]; then
        wanted=0
        for a in "${AGENTS[@]}"; do [[ $a == "$agent" ]] && wanted=1; done
        [[ $wanted == 1 ]] || continue
    fi
    lines=$((lines + 1))
    [[ $src == /* ]] || src="$confdir/$src"
    if ! sha="$(src_sha "$src")"; then
        record failed "agent=$agent name=$name result=failed error=\"cannot read source $src\""
        continue
    fi
    if [[ $CHECK == 1 ]]; then
        reply="$(ctrl-exec-cli run "$agent" --script "$SCRIPT" --json -- --list 2> "$ERR" < /dev/null)"
    else
        if ! fields="$(src_json "$src" 2> "$ERR")"; then
            record failed "agent=$agent name=$name result=failed error=\"$(tr '\n"' ' \047' < "$ERR")\""
            continue
        fi
        # the contents travel on stdin only: a plain variable, never exported
        reply="$(printf '%s' "$fields" | ctrl-exec-cli run "$agent" --script "$SCRIPT" --json --input-fields - -- "$name" 2> "$ERR")"
    fi
    IFS=$'\t' read -r kind line < <(CP_ERR="$ERR" reply_line "$mode" "$agent" "$name" "$sha" <<< "$reply")
    record "$kind" "$line"
done < "$CONF"

if [[ $lines -eq 0 ]]; then
    status=failed
    log user.err "no push lines to run in $CONF"
elif [[ ${count[failed]} -gt 0 ]]; then
    status=failed
elif [[ $((count[differs] + count[missing])) -gt 0 ]]; then
    status=differs
else
    status=ok
fi
summary="status=$status mode=$mode lines=$lines changed=${count[changed]} unchanged=${count[unchanged]} same=${count[same]} differs=${count[differs]} missing=${count[missing]} failed=${count[failed]}"
case "$status" in
    ok) log user.info "$summary" ;;
    differs) log user.warning "$summary" ;;
    *) log user.err "$summary" ;;
esac
echo "$summary"
[[ $status == ok ]]
