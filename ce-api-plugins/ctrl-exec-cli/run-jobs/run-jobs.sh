#!/usr/bin/env bash
# run-jobs.sh - Job runner, called every 5 minutes by run-jobs-entrypoint.sh
#
# Usage:
#   run-jobs.sh                  run one tick: execute every job that is due
#   run-jobs.sh --explain [--at TIME] [--dir DIR] [JOB...]
#                                report what a tick would run and when each job
#                                runs next; executes nothing, writes nothing
#
# .conf keys:
#   schedule = <cron expression>   recurring schedule (5-field cron)
#   runat    = <ISO datetime>      one-off execution (YYYY-MM-DD HH:MM)
#
# Multiple runat= lines are supported. schedule= and runat= may coexist.
# A runat= that has passed will never trigger again - leave the file in place.
# Other keys are left for the job itself to read.
#
# Each tick covers every minute since the previous tick, so a job runs at the
# first tick at or after its scheduled minute, and at most once per tick.

set -euo pipefail

SCRIPTS_DIR="${JOBS_SCRIPTS_DIR:-/etc/run-jobs/scripts}"
STATE_DIR="${JOBS_STATE_DIR:-/var/lib/run-jobs/state}"
SYSLOG_TAG="run-jobs"
# RUN_JOBS_SYSLOG_SOCKET points the test suite at a stand-in socket
SYSLOG_SOCKET="${RUN_JOBS_SYSLOG_SOCKET:-/dev/log}"
TICK_SECONDS=300
CATCHUP_SECONDS=3600

# Syslog when the socket is there; otherwise stderr, which the entrypoint hands
# to the container log. The socket is named explicitly: without -u, util-linux
# logger falls back to UDP when /dev/log is missing, exits 0, and the line is
# lost. A logging failure must never stop a tick.
log() {
    if [[ -e $SYSLOG_SOCKET ]] \
        && logger -u "$SYSLOG_SOCKET" -t "$SYSLOG_TAG" -p local0.info "$1" 2>/dev/null; then
        return 0
    fi
    printf '%s: %s\n' "$SYSLOG_TAG" "$1" >&2 || true
}

# cron_field FIELD MIN MAX
# Expand one cron field to a sorted, space-delimited set (" 0 15 30 45 ") on
# stdout. Accepts *, N, N-M and a /STEP on any of them, comma-separated, as
# cron(5) does; N/STEP means N-MAX/STEP. On an invalid field prints the reason
# and returns 1.
cron_field() {
    local field=$1
    local min=$2
    local max=$3
    local item range step lo hi v
    local -a items
    local -a hit=()

    IFS=',' read -r -a items <<< "$field"
    for item in "${items[@]}"; do
        range=$item
        step=1
        if [[ $item == */* ]]; then
            range=${item%%/*}
            step=${item#*/}
            if [[ ! $step =~ ^[0-9]+$ ]] || (( 10#$step == 0 )); then
                echo "bad step in '$item'"
                return 1
            fi
            step=$(( 10#$step ))
        fi
        if [[ $range == "*" ]]; then
            lo=$min
            hi=$max
        elif [[ $range =~ ^([0-9]+)-([0-9]+)$ ]]; then
            lo=$(( 10#${BASH_REMATCH[1]} ))
            hi=$(( 10#${BASH_REMATCH[2]} ))
        elif [[ $range =~ ^[0-9]+$ ]]; then
            lo=$(( 10#$range ))
            hi=$lo
            if [[ $item == */* ]]; then
                hi=$max
            fi
        else
            echo "bad value '$item'"
            return 1
        fi
        if (( lo < min || hi > max || lo > hi )); then
            echo "'$item' is outside $min-$max"
            return 1
        fi
        for (( v = lo; v <= hi; v += step )); do
            hit[v]=1
        done
    done

    local out=" "
    for (( v = min; v <= max; v++ )); do
        if [[ -n ${hit[v]:-} ]]; then
            out+="$v "
        fi
    done
    echo "$out"
}

# cron_parse EXPRESSION
# Parse a five-field expression into CRON_MIN, CRON_HOUR, CRON_DOM, CRON_MON
# and CRON_DOW for cron_match. Returns 1 with CRON_ERROR set when invalid.
cron_parse() {
    local -a f
    local -a names=(minute hour day-of-month month day-of-week)
    local -a mins=(0 0 1 1 0)
    local -a maxs=(59 23 31 12 7)
    local -a sets=()
    local i s

    CRON_ERROR=""
    read -r -a f <<< "$1"
    if (( ${#f[@]} != 5 )); then
        CRON_ERROR="needs 5 fields, has ${#f[@]}"
        return 1
    fi
    for i in 0 1 2 3 4; do
        if ! s=$(cron_field "${f[i]}" "${mins[i]}" "${maxs[i]}"); then
            CRON_ERROR="${names[i]}: $s"
            return 1
        fi
        sets[i]=$s
    done

    CRON_MIN=${sets[0]}
    CRON_HOUR=${sets[1]}
    CRON_DOM=${sets[2]}
    CRON_MON=${sets[3]}
    CRON_DOW=${sets[4]}
    # Sunday is both 0 and 7
    if [[ $CRON_DOW == *" 7 "* ]]; then
        CRON_DOW+="0 "
    fi
    # cron(5): when both day fields are restricted, either one may match
    CRON_DAY_OR=0
    if [[ ${f[2]} != \** && ${f[4]} != \** ]]; then
        CRON_DAY_OR=1
    fi
}

# cron_day_match DOM MONTH DOW - the date part of cron_match
cron_day_match() {
    local dom_ok=0
    local dow_ok=0

    if [[ $CRON_MON != *" $2 "* ]]; then
        return 1
    fi
    if [[ $CRON_DOM == *" $1 "* ]]; then
        dom_ok=1
    fi
    if [[ $CRON_DOW == *" $3 "* ]]; then
        dow_ok=1
    fi
    if (( CRON_DAY_OR )); then
        (( dom_ok || dow_ok ))
    else
        (( dom_ok && dow_ok ))
    fi
}

# cron_match MINUTE HOUR DOM MONTH DOW - against the last cron_parse.
# DOW is 0-6 with 0 = Sunday, as date +%w gives it.
cron_match() {
    if [[ $CRON_MIN != *" $1 "* || $CRON_HOUR != *" $2 "* ]]; then
        return 1
    fi
    cron_day_match "$3" "$4" "$5"
}

# read_conf FILE
# Read schedule= into CONF_SCHEDULE and every runat= into CONF_RUNAT. Problems
# with those two keys are collected in CONF_PROBLEMS; other keys belong to the
# job and are skipped.
read_conf() {
    local line key value

    CONF_SCHEDULE=""
    CONF_RUNAT=()
    CONF_PROBLEMS=()
    # The || clause keeps a last line that has no trailing newline
    while IFS= read -r line || [[ -n $line ]]; do
        line=${line%$'\r'}
        if [[ ! $line =~ ^[[:space:]]*([A-Za-z_]+)[[:space:]]*=[[:space:]]*(.*[^[:space:]])[[:space:]]*$ ]]; then
            continue
        fi
        key=${BASH_REMATCH[1]}
        value=${BASH_REMATCH[2]}
        case $key in
            schedule)
                if [[ -n $CONF_SCHEDULE ]]; then
                    CONF_PROBLEMS+=("schedule is set more than once; the last one is used")
                fi
                CONF_SCHEDULE=$value
                ;;
            runat)
                CONF_RUNAT+=("$value")
                ;;
        esac
    done < "$1"
}

# tick_window NOW_MINUTE
# Set WIN_LO..WIN_HI (epoch seconds, whole minutes, inclusive) to the minutes
# this tick covers: everything since the previous tick recorded in
# STATE_DIR/.last-tick, so a minute between 5-minute boundaries, or one that
# passed while a long tick ran, is still covered. With no previous tick, or
# one older than CATCHUP_SECONDS, the window is the last TICK_SECONDS. A tick
# in the same minute as the previous one covers nothing.
tick_window() {
    local now_minute=$1
    local last=""

    if [[ -r $STATE_DIR/.last-tick ]]; then
        read -r last < "$STATE_DIR/.last-tick" || true
    fi
    WIN_HI=$now_minute
    if [[ ! $last =~ ^[0-9]+$ ]] || (( now_minute - last > CATCHUP_SECONDS )); then
        WIN_LO=$(( now_minute - TICK_SECONDS + 60 ))
    else
        WIN_LO=$(( last + 60 ))
    fi
}

# window_fields
# Fill WIN_M, WIN_H, WIN_DOM, WIN_MON and WIN_DOW with the date fields of each
# minute WIN_LO..WIN_HI, from a single date call.
window_fields() {
    local t m h dom mon dow

    WIN_M=()
    WIN_H=()
    WIN_DOM=()
    WIN_MON=()
    WIN_DOW=()
    if (( WIN_LO > WIN_HI )); then
        return 0
    fi
    while read -r m h dom mon dow; do
        WIN_M+=("$m")
        WIN_H+=("$h")
        WIN_DOM+=("$dom")
        WIN_MON+=("$mon")
        WIN_DOW+=("$dow")
    done < <(
        for (( t = WIN_LO; t <= WIN_HI; t += 60 )); do
            echo "@$t"
        done | date -f - '+%-M %-H %-d %-m %w'
    )
}

# job_due CONF
# Return 0 if the job is due in WIN_LO..WIN_HI, with JOB_TRIGGER set to
# "schedule" or "runat=<value>"; a schedule match wins over runat=. Problems
# in the .conf are collected in JOB_PROBLEMS whether or not the job is due.
# Needs window_fields to have run.
job_due() {
    local i runat runat_epoch

    JOB_TRIGGER=""
    read_conf "$1"
    JOB_PROBLEMS=("${CONF_PROBLEMS[@]}")

    if [[ -n $CONF_SCHEDULE ]]; then
        if ! cron_parse "$CONF_SCHEDULE"; then
            JOB_PROBLEMS+=("schedule '$CONF_SCHEDULE': $CRON_ERROR")
        else
            for i in "${!WIN_M[@]}"; do
                if cron_match "${WIN_M[i]}" "${WIN_H[i]}" "${WIN_DOM[i]}" "${WIN_MON[i]}" "${WIN_DOW[i]}"; then
                    JOB_TRIGGER="schedule"
                    break
                fi
            done
        fi
    fi

    for runat in "${CONF_RUNAT[@]}"; do
        if ! runat_epoch=$(date -d "$runat" +%s 2>/dev/null); then
            JOB_PROBLEMS+=("runat '$runat' is not a date")
            continue
        fi
        runat_epoch=$(( runat_epoch - runat_epoch % 60 ))
        if [[ -z $JOB_TRIGGER ]] && (( runat_epoch >= WIN_LO && runat_epoch <= WIN_HI )); then
            JOB_TRIGGER="runat=$runat"
        fi
    done

    [[ -n $JOB_TRIGGER ]]
}

# --- explain ------------------------------------------------------------------

usage() {
    cat <<'USAGE'
Usage:
  run-jobs.sh                  run one tick: execute every job that is due
  run-jobs.sh --explain [--at TIME] [--dir DIR] [JOB...]

--explain reports, for each job (or only the JOBs named), its schedule and
runat= entries, whether a tick at TIME would run it, and the next ticks that
will. Nothing is executed and nothing is written. Exit status is 0 when no
problems were found, 1 when some were, 2 on a usage error.

  --at TIME   the tick to explain, any date(1) time ("2026-10-20 02:00",
              "tomorrow 02:00"); default the next tick
  --dir DIR   scripts dir; default $JOBS_SCRIPTS_DIR or /etc/run-jobs/scripts
USAGE
}

# fmt_time EPOCH - local "YYYY-MM-DD HH:MM"
fmt_time() {
    date -d "@$1" '+%Y-%m-%d %H:%M'
}

# tick_for EPOCH - the tick that covers a minute: the first 5-minute boundary
# at or after it, as the entrypoint aligns ticks
tick_for() {
    echo $(( ($1 + TICK_SECONDS - 1) / TICK_SECONDS * TICK_SECONDS ))
}

# cron_next AFTER COUNT
# Print up to COUNT lines "TICK MINUTE" (epoch seconds): the next ticks after
# AFTER at which the last cron_parse runs, each with the scheduled minute it
# runs for. Searches a year ahead; a local time that does not exist (a
# daylight-saving gap) is skipped, as a tick never covers it.
cron_next() {
    local after=$1
    local count=$2
    local after_day after_h after_m noon d
    local day dom mon dow h m epoch tick
    local last_tick=0
    local found=0

    read -r after_day after_h after_m <<< "$(date -d "@$after" '+%F %-H %-M')"
    noon=$(date -d "$after_day 12:00" +%s)
    while read -r day dom mon dow; do
        if ! cron_day_match "$dom" "$mon" "$dow"; then
            continue
        fi
        for h in $CRON_HOUR; do
            for m in $CRON_MIN; do
                if [[ $day == "$after_day" ]] && (( h * 60 + m <= after_h * 60 + after_m )); then
                    continue
                fi
                if ! epoch=$(date -d "$day $h:$m" +%s 2>/dev/null); then
                    continue
                fi
                tick=$(tick_for "$epoch")
                if (( tick == last_tick )); then
                    continue
                fi
                echo "$tick $epoch"
                last_tick=$tick
                (( ++found ))
                if (( found >= count )); then
                    return 0
                fi
            done
        done
    done < <(
        for (( d = 0; d <= 366; d++ )); do
            echo "@$(( noon + d * 86400 ))"
        done | date -f - '+%F %-d %-m %w'
    )
}

# explain_job DIR NAME
# Print one job's block; add its problems to EXPLAIN_PROBLEMS and count it in
# EXPLAIN_RUNS when the tick would run it.
explain_job() {
    local dir=$1
    local name=$2
    local conf="$dir/$name.conf"
    local script="$dir/$name.sh"
    local skip=""
    local runat runat_epoch tick minute note problem
    local -a next=()

    echo "$name"
    if [[ ! -e $conf ]]; then
        if [[ ! -e $script ]]; then
            printf '  %-10s %s\n' PROBLEM "no such job in $dir"
        else
            printf '  %-10s %s\n' PROBLEM "no $name.conf, so $name.sh never runs"
        fi
        (( ++EXPLAIN_PROBLEMS ))
        echo
        return 0
    fi
    if [[ ! -e $script ]]; then
        skip="$name.sh is missing"
    elif [[ ! -x $script ]]; then
        skip="$name.sh is not executable (chmod 755)"
    fi

    local due=0
    if job_due "$conf"; then
        due=1
    fi

    printf '  %-10s %s\n' schedule "${CONF_SCHEDULE:-none}"
    for runat in "${CONF_RUNAT[@]}"; do
        if ! runat_epoch=$(date -d "$runat" +%s 2>/dev/null); then
            note="not a date"
        else
            runat_epoch=$(( runat_epoch - runat_epoch % 60 ))
            if (( runat_epoch < WIN_LO )); then
                note="past, ignored"
            elif (( runat_epoch <= WIN_HI )); then
                note="in this tick"
            else
                note="runs at tick $(fmt_time "$(tick_for "$runat_epoch")")"
            fi
        fi
        printf '  %-10s %s - %s\n' runat "$runat" "$note"
    done

    if (( due )) && [[ -z $skip ]]; then
        printf '  %-10s %s\n' 'this tick' "RUNS (trigger=$JOB_TRIGGER)"
        (( ++EXPLAIN_RUNS ))
    elif (( due )); then
        printf '  %-10s %s\n' 'this tick' "due (trigger=$JOB_TRIGGER) but skipped"
    else
        printf '  %-10s %s\n' 'this tick' '-'
    fi

    if [[ -n $CONF_SCHEDULE ]] && cron_parse "$CONF_SCHEDULE"; then
        while read -r tick minute; do
            note=$(fmt_time "$tick")
            if (( tick != minute )); then
                note+=" (for $(date -d "@$minute" '+%H:%M'))"
            fi
            next+=("$note")
        done < <(cron_next "$WIN_HI" 3)
        if (( ${#next[@]} == 0 )); then
            printf '  %-10s %s\n' next 'never (no match within a year)'
            JOB_PROBLEMS+=("schedule '$CONF_SCHEDULE' never matches within a year")
        else
            printf '  %-10s %s\n' next "${next[0]}"
            for note in "${next[@]:1}"; do
                printf '  %-10s %s\n' '' "$note"
            done
        fi
    fi

    if [[ -n $skip ]]; then
        JOB_PROBLEMS+=("$skip; every tick skips it")
    fi
    if [[ -z $CONF_SCHEDULE && ${#CONF_RUNAT[@]} -eq 0 ]]; then
        JOB_PROBLEMS+=("no schedule= or runat=, so it never runs")
    fi
    for problem in "${JOB_PROBLEMS[@]}"; do
        printf '  %-10s %s\n' PROBLEM "$problem"
        (( ++EXPLAIN_PROBLEMS ))
    done
    echo
}

# explain [--at TIME] [--dir DIR] [JOB...]
explain() {
    local at=""
    local dir=$SCRIPTS_DIR
    local -a names=()
    local now f name

    while (( $# )); do
        case $1 in
            --at)
                at=${2:-}
                shift 2 || { usage >&2; return 2; }
                ;;
            --dir)
                dir=${2:-}
                shift 2 || { usage >&2; return 2; }
                ;;
            -h|--help)
                usage
                return 0
                ;;
            -*)
                echo "run-jobs: unknown option '$1'" >&2
                usage >&2
                return 2
                ;;
            *)
                name=${1%.sh}
                names+=("${name%.conf}")
                shift
                ;;
        esac
    done

    if [[ ! -d $dir ]]; then
        echo "run-jobs: scripts dir not found: $dir" >&2
        return 2
    fi
    if [[ -n $at ]]; then
        if ! now=$(date -d "$at" +%s 2>/dev/null); then
            echo "run-jobs: --at '$at' is not a time date(1) understands" >&2
            return 2
        fi
    else
        now=$(tick_for "$(date +%s)")
    fi
    WIN_HI=$(( now - now % 60 ))
    WIN_LO=$(( WIN_HI - TICK_SECONDS + 60 ))
    window_fields

    if (( ${#names[@]} == 0 )); then
        for f in "$dir"/*.conf "$dir"/*.sh; do
            if [[ -e $f ]]; then
                name=${f##*/}
                names+=("${name%.*}")
            fi
        done
        if (( ${#names[@]} )); then
            mapfile -t names < <(printf '%s\n' "${names[@]}" | sort -u)
        fi
    fi

    echo "run-jobs explain - nothing is executed"
    echo "tick       $(fmt_time "$WIN_HI") $(date -d "@$WIN_HI" +%Z), covering $(date -d "@$WIN_LO" +%H:%M)-$(date -d "@$WIN_HI" +%H:%M)"
    if (( WIN_HI % TICK_SECONDS )); then
        echo "           (real ticks fall on 5-minute boundaries)"
    fi
    echo "scripts    $dir"
    echo

    EXPLAIN_PROBLEMS=0
    EXPLAIN_RUNS=0
    for name in "${names[@]}"; do
        explain_job "$dir" "$name"
    done

    echo "${#names[@]} job(s): $EXPLAIN_RUNS would run in this tick, $EXPLAIN_PROBLEMS problem(s)"
    if (( EXPLAIN_PROBLEMS )); then
        return 1
    fi
}

run_script() {
    local script="$1"
    local trigger="$2"   # 'schedule' or runat datetime
    local name
    name=$(basename "$script" .sh)
    local state_file="$STATE_DIR/${name}.state"
    local output_file="$STATE_DIR/${name}.out"

    log "starting: $name trigger=$trigger"

    local start_time
    start_time=$(date +%s)

    local exit_code=0
    bash "$script" > "$output_file" 2>&1 || exit_code=$?

    local end_time
    end_time=$(date +%s)
    local duration=$(( end_time - start_time ))

    cat > "$state_file" <<STATEOF
script=$name
trigger=$trigger
started=$(date -d "@$start_time" --iso-8601=seconds)
finished=$(date -d "@$end_time" --iso-8601=seconds)
duration=${duration}s
exit_code=$exit_code
STATEOF

    log "finished: $name exit=$exit_code duration=${duration}s"
}

main() {
    mkdir -p "$STATE_DIR"

    if [[ ! -d "$SCRIPTS_DIR" ]]; then
        log "scripts dir not found: $SCRIPTS_DIR"
        exit 1
    fi

    # RUN_JOBS_NOW (epoch seconds) fixes the clock for the test suite
    local now
    now=${RUN_JOBS_NOW:-$(date +%s)}
    tick_window $(( now - now % 60 ))
    window_fields
    # Recorded before any job runs: a tick killed part way through does not
    # repeat on restart the jobs it already started
    echo "$WIN_HI" > "$STATE_DIR/.last-tick"

    local ran=0
    local conf script name problem

    for conf in "$SCRIPTS_DIR"/*.conf; do
        [[ -e "$conf" ]] || continue

        script="${conf%.conf}.sh"
        name=$(basename "$script" .sh)
        if [[ ! -x "$script" ]]; then
            log "skipping: $name (not executable or missing)"
            continue
        fi

        if job_due "$conf"; then
            run_script "$script" "$JOB_TRIGGER"
            (( ran++ )) || true
        fi
        for problem in "${JOB_PROBLEMS[@]}"; do
            log "problem: $name - $problem"
        done
    done

    if (( ran == 0 )); then
        log "tick: nothing due"
    fi
}

# Sourcing the file (as the test suite does) defines the functions only
if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
    case ${1:-} in
        --explain)
            shift
            rc=0
            explain "$@" || rc=$?
            exit "$rc"
            ;;
        -h|--help)
            usage
            ;;
        "")
            main
            ;;
        *)
            echo "run-jobs: unknown argument '$1'" >&2
            usage >&2
            exit 2
            ;;
    esac
fi
