#!/usr/bin/env bash
# run-jobs.sh - Job runner, called every 5 minutes by run-jobs-entrypoint.sh
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
TICK_SECONDS=300
CATCHUP_SECONDS=3600

# Syslog when a socket is there; otherwise stderr, which the entrypoint hands
# to the container log. A logging failure must never stop a tick.
log() {
    logger -t "$SYSLOG_TAG" -p local0.info "$1" 2>/dev/null \
        || printf '%s: %s\n' "$SYSLOG_TAG" "$1" >&2 \
        || true
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

# cron_match MINUTE HOUR DOM MONTH DOW - against the last cron_parse.
# DOW is 0-6 with 0 = Sunday, as date +%w gives it.
cron_match() {
    local dom_ok=0
    local dow_ok=0

    if [[ $CRON_MIN != *" $1 "* || $CRON_HOUR != *" $2 "* || $CRON_MON != *" $4 "* ]]; then
        return 1
    fi
    if [[ $CRON_DOM == *" $3 "* ]]; then
        dom_ok=1
    fi
    if [[ $CRON_DOW == *" $5 "* ]]; then
        dow_ok=1
    fi
    if (( CRON_DAY_OR )); then
        (( dom_ok || dow_ok ))
    else
        (( dom_ok && dow_ok ))
    fi
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
    main "$@"
fi
