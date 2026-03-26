#!/usr/bin/env bash
# run-jobs.sh - Simple job runner, called by cron every 5 minutes

set -euo pipefail

SCRIPTS_DIR="${JOBS_SCRIPTS_DIR:-/etc/run-jobs/scripts}"
STATE_DIR="${JOBS_STATE_DIR:-/var/lib/run-jobs/state}"
SYSLOG_TAG="run-jobs"

log() {
    logger -t "$SYSLOG_TAG" "$1"
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

run_script() {
    local script="$1"
    local name
    name=$(basename "$script" .sh)
    local state_file="$STATE_DIR/${name}.state"
    local output_file="$STATE_DIR/${name}.out"

    log "starting: $name"

    local start_time
    start_time=$(date +%s)

    local exit_code=0
    bash "$script" > "$output_file" 2>&1 || exit_code=$?

    local end_time
    end_time=$(date +%s)
    local duration=$(( end_time - start_time ))

    # Write state file
    cat > "$state_file" <<EOF
script=$name
started=$(date -d "@$start_time" --iso-8601=seconds)
finished=$(date -d "@$end_time" --iso-8601=seconds)
duration=${duration}s
exit_code=$exit_code
EOF

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
            log "skipping: $script (not executable or missing)"
            continue
        fi

        local schedule=""
        while IFS='=' read -r key value; do
            [[ "$key" == "schedule" ]] && schedule="$value"
        done < "$conf"

        if [[ -z "$schedule" ]]; then
            log "skipping: $(basename "$script") (no schedule in $conf)"
            continue
        fi

        if cron_matches "$schedule" "$now_minute"; then
            run_script "$script"
            (( ran++ )) || true
        fi
    done

    [[ $ran -eq 0 ]] && log "tick: nothing due"
}

main
