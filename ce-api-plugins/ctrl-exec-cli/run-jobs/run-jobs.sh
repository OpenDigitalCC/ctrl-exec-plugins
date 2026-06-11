#!/usr/bin/env bash
# run-jobs.sh - Job runner, called every 5 minutes by run-jobs-entrypoint.sh
#
# .conf keys:
#   schedule = <cron expression>   recurring schedule (5-field cron)
#   runat    = <ISO datetime>      one-off execution (YYYY-MM-DD HH:MM)
#
# Multiple runat= lines are supported. schedule= and runat= may coexist.
# A runat= that has passed will never trigger again - leave the file in place.

set -euo pipefail

SCRIPTS_DIR="${JOBS_SCRIPTS_DIR:-/etc/run-jobs/scripts}"
STATE_DIR="${JOBS_STATE_DIR:-/var/lib/run-jobs/state}"
SYSLOG_TAG="run-jobs"

log() {
    logger -t "$SYSLOG_TAG" -p local0.info "$1"
}

# Parse a cron expression and return 0 if it matches the given timestamp
cron_matches() {
    local expression="$1"
    local timestamp="$2"

    local minute hour dom month dow
    read -r minute hour dom month dow <<< "$expression"

    local t_minute t_hour t_dom t_month t_dow
    t_minute=$(date -d "@$timestamp" +%-M)
    t_hour=$(date -d "@$timestamp"   +%-H)
    t_dom=$(date -d "@$timestamp"    +%-d)
    t_month=$(date -d "@$timestamp"  +%-m)
    t_dow=$(date -d "@$timestamp"    +%u)  # 1=Mon ... 7=Sun

    field_matches() {
        local field="$1"
        local value="$2"
        if [[ "$field" == "*" ]]; then
            return 0
        fi
        # Handle */n step syntax
        if [[ "$field" == */* ]]; then
            local step="${field#*/}"
            if (( value % step == 0 )); then
                return 0
            fi
            return 1
        fi
        # Handle comma-separated list
        local IFS=','
        for part in $field; do
            if [[ "$part" == "$value" ]]; then
                return 0
            fi
        done
        return 1
    }

    field_matches "$minute" "$t_minute" || return 1
    field_matches "$hour"   "$t_hour"   || return 1
    field_matches "$dom"    "$t_dom"    || return 1
    field_matches "$month"  "$t_month"  || return 1
    field_matches "$dow"    "$t_dow"    || return 1
    return 0
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

    # Round current time down to the nearest minute for cron matching
    local now
    now=$(date +%s)
    local now_minute=$(( now - (now % 60) ))

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

        # Read all keys - collect schedule and all runat values
        local schedule=""
        local -a runat_list=()

        while IFS='=' read -r key value; do
            key="${key// /}"
            value="${value# }"
            case "$key" in
                schedule) schedule="$value" ;;
                runat)    runat_list+=("$value") ;;
            esac
        done < "$conf"

        # Check schedule
        if [[ -n "$schedule" ]]; then
            if cron_matches "$schedule" "$now_minute"; then
                run_script "$script" "schedule"
                (( ran++ )) || true
                continue   # already ran this tick - skip runat checks
            fi
        fi

        # Check each runat
        for runat in "${runat_list[@]}"; do
            if runat_matches "$runat" "$now_minute"; then
                run_script "$script" "runat=$runat"
                (( ran++ )) || true
                break   # one execution per tick regardless of multiple runat matches
            fi
        done

    done

    [[ $ran -eq 0 ]] && log "tick: nothing due"
}

main
