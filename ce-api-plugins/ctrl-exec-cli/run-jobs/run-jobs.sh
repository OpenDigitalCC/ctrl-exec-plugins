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

set -euo pipefail

SCRIPTS_DIR="${JOBS_SCRIPTS_DIR:-/etc/run-jobs/scripts}"
STATE_DIR="${JOBS_STATE_DIR:-/var/lib/run-jobs/state}"
SYSLOG_TAG="run-jobs"

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

# Return 0 if a runat= datetime falls within the current 5-minute window
runat_matches() {
    local runat="$1"
    local now_minute="$2"

    local runat_epoch
    runat_epoch=$(date -d "$runat" +%s 2>/dev/null) || return 1

    # Matches if runat falls within [now_minute, now_minute+300)
    if (( runat_epoch >= now_minute && runat_epoch < now_minute + 300 )); then
        return 0
    fi
    return 1
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

    # Round current time down to the nearest minute for cron matching.
    # RUN_JOBS_NOW (epoch seconds) fixes the clock for the test suite.
    local now
    now=${RUN_JOBS_NOW:-$(date +%s)}
    local now_minute=$(( now - (now % 60) ))
    local -a now_fields
    read -r -a now_fields <<< "$(date -d "@$now_minute" '+%-M %-H %-d %-m %w')"

    local ran=0

    for conf in "$SCRIPTS_DIR"/*.conf; do
        [[ -e "$conf" ]] || continue

        local script="${conf%.conf}.sh"
        if [[ ! -x "$script" ]]; then
            log "skipping: $(basename "$script" .sh) (not executable or missing)"
            continue
        fi

        local name
        name=$(basename "$script" .sh)

        read_conf "$conf"
        local problem
        for problem in "${CONF_PROBLEMS[@]}"; do
            log "problem: $name - $problem"
        done

        # Check schedule
        if [[ -n "$CONF_SCHEDULE" ]]; then
            if ! cron_parse "$CONF_SCHEDULE"; then
                log "problem: $name - schedule '$CONF_SCHEDULE': $CRON_ERROR"
            elif cron_match "${now_fields[@]}"; then
                run_script "$script" "schedule"
                (( ran++ )) || true
                continue   # already ran this tick - skip runat checks
            fi
        fi

        # Check each runat
        local runat
        for runat in "${CONF_RUNAT[@]}"; do
            if runat_matches "$runat" "$now_minute"; then
                run_script "$script" "runat=$runat"
                (( ran++ )) || true
                break   # one execution per tick regardless of multiple runat matches
            fi
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
