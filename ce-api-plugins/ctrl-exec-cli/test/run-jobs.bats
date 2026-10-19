#!/usr/bin/env bats
# Tests for run-jobs/run-jobs.sh. Run: bats test/run-jobs.bats
#
# Each test gets its own scripts and state dirs and a stub logger on PATH
# that appends to $LOG, or fails as logger does when /dev/log is missing.

bats_require_minimum_version 1.5.0

RUN_JOBS="${RUN_JOBS:-$BATS_TEST_DIRNAME/../run-jobs/run-jobs.sh}"

setup() {
    W="$BATS_TEST_TMPDIR"
    mkdir -p "$W/bin" "$W/scripts" "$W/state"
    LOG="$W/syslog"
    cat > "$W/bin/logger" <<'STUB'
#!/bin/bash
if [[ -n "${STUB_LOGGER_FAIL:-}" ]]; then
    echo "logger: socket /dev/log: No such file or directory" >&2
    exit 1
fi
echo "$*" >> "$STUB_LOG"
STUB
    chmod 755 "$W/bin/logger"
    export PATH="$W/bin:$PATH"
    export STUB_LOG="$LOG"
    export JOBS_SCRIPTS_DIR="$W/scripts"
    export JOBS_STATE_DIR="$W/state"
    export TZ=UTC
}

# matches EXPR MINUTE HOUR DOM MONTH DOW - status 0 when the expression
# matches; DOW is 0-6, Sunday 0. Runs in a child bash so the script's
# set -euo pipefail stays out of bats.
matches() {
    bash -c 'source "$1"; cron_parse "$2"; cron_match "$3" "$4" "$5" "$6" "$7"' \
        _ "$RUN_JOBS" "$@"
}

# parse_error EXPR - prints CRON_ERROR; status 0 only if parsing failed
parse_error() {
    bash -c 'source "$1"; if cron_parse "$2"; then exit 1; fi; echo "$CRON_ERROR"' \
        _ "$RUN_JOBS" "$1"
}

# at "YYYY-MM-DD HH:MM" - epoch seconds, UTC
at() {
    date -u -d "$1" +%s
}

# add_job NAME CONF-LINE... : executable job that prints its name
add_job() {
    local name=$1
    shift
    printf '#!/bin/bash\necho "ran %s"\n' "$name" > "$W/scripts/$name.sh"
    chmod 755 "$W/scripts/$name.sh"
    printf '%s\n' "$@" > "$W/scripts/$name.conf"
}

@test "a tick that runs a job exits 0" {
    add_job every 'schedule = * * * * *'
    run bash "$RUN_JOBS"
    [ "$status" -eq 0 ]
    grep -q '^exit_code=0$' "$W/state/every.state"
    grep -q '^ran every$' "$W/state/every.out"
}

@test "a tick with nothing due exits 0 and says so" {
    add_job never 'schedule = 0 0 31 2 *'
    run bash "$RUN_JOBS"
    [ "$status" -eq 0 ]
    grep -q 'tick: nothing due' "$LOG"
    [ ! -e "$W/state/never.state" ]
}

@test "a failing job is recorded and the tick still exits 0" {
    add_job broken 'schedule = * * * * *'
    printf '#!/bin/bash\necho oops\nexit 3\n' > "$W/scripts/broken.sh"
    run bash "$RUN_JOBS"
    [ "$status" -eq 0 ]
    grep -q '^exit_code=3$' "$W/state/broken.state"
    grep -q 'finished: broken exit=3' "$LOG"
}

@test "jobs still run when there is no syslog socket" {
    add_job every 'schedule = * * * * *'
    STUB_LOGGER_FAIL=1 run bash "$RUN_JOBS"
    [ "$status" -eq 0 ]
    grep -q '^exit_code=0$' "$W/state/every.state"
    [[ "$output" == *"run-jobs: starting: every trigger=schedule"* ]]
}

# --- cron expressions ---------------------------------------------------

@test "a day-of-week range matches weekdays only" {
    matches '0 2 * * 1-5' 0 2 19 10 1
    run ! matches '0 2 * * 1-5' 0 2 24 10 6
}

@test "Sunday is both 0 and 7" {
    matches '0 2 * * 0' 0 2 18 10 0
    matches '0 2 * * 7' 0 2 18 10 0
    run ! matches '0 2 * * 7' 0 2 19 10 1
}

@test "a step counts from the start of the field's range" {
    matches '0 0 */2 * *' 0 0 1 10 4
    run ! matches '0 0 */2 * *' 0 0 2 10 5
    matches '*/15 * * * *' 45 3 1 1 4
    run ! matches '*/15 * * * *' 50 3 1 1 4
    matches '5/20 * * * *' 25 3 1 1 4
    matches '0 9-17/4 * * *' 0 13 1 1 4
    run ! matches '0 9-17/4 * * *' 0 11 1 1 4
}

@test "restricted day-of-month and day-of-week match either, as cron does" {
    matches '0 0 1 * 1' 0 0 1 10 4
    matches '0 0 1 * 1' 0 0 19 10 1
    run ! matches '0 0 1 * 1' 0 0 15 10 4
    run ! matches '0 0 1 * *' 0 0 2 10 1
}

@test "lists and leading zeros match" {
    matches '05 02 * * *' 5 2 1 1 4
    matches '0,30 8,20 * * *' 30 20 1 1 4
    run ! matches '0,30 8,20 * * *' 30 9 1 1 4
}

@test "an invalid expression is reported with the field at fault" {
    run parse_error '0 2 * * 1-5x'
    [ "$status" -eq 0 ]
    [ "$output" = "day-of-week: bad value '1-5x'" ]
    run parse_error '60 * * * *'
    [ "$output" = "minute: '60' is outside 0-59" ]
    run parse_error '* * * *'
    [ "$output" = "needs 5 fields, has 4" ]
    run parse_error '*/0 * * * *'
    [ "$output" = "minute: bad step in '*/0'" ]
}

# --- ticks ----------------------------------------------------------------

@test "a Sunday schedule written as 0 runs on Sunday" {
    add_job weekly 'schedule = 0 2 * * 0'
    RUN_JOBS_NOW=$(at '2026-10-18 02:00') run bash "$RUN_JOBS"
    [ "$status" -eq 0 ]
    grep -q '^trigger=schedule$' "$W/state/weekly.state"
}

@test "an invalid schedule is logged, not silently ignored" {
    add_job bad 'schedule = 0 2 * * mon'
    RUN_JOBS_NOW=$(at '2026-10-19 02:00') run bash "$RUN_JOBS"
    [ "$status" -eq 0 ]
    grep -q "problem: bad - schedule '0 2 \* \* mon': day-of-week: bad value 'mon'" "$LOG"
}

@test "a .conf whose last line has no newline is still read" {
    add_job tail
    printf 'schedule = 0 2 * * *' > "$W/scripts/tail.conf"
    RUN_JOBS_NOW=$(at '2026-10-19 02:00') run bash "$RUN_JOBS"
    grep -q '^trigger=schedule$' "$W/state/tail.state"
}

@test "a .conf with CRLF line endings is read" {
    add_job dos
    printf 'schedule = 0 2 * * *\r\n' > "$W/scripts/dos.conf"
    RUN_JOBS_NOW=$(at '2026-10-19 02:00') run bash "$RUN_JOBS"
    grep -q '^trigger=schedule$' "$W/state/dos.state"
}

@test "keys other than schedule and runat are left to the job" {
    add_job certs 'schedule = 0 2 * * *' 'agent = hestia-01' 'deploy = example.com web-01'
    RUN_JOBS_NOW=$(at '2026-10-19 02:00') run bash "$RUN_JOBS"
    grep -q '^exit_code=0$' "$W/state/certs.state"
    run ! grep -q problem "$LOG"
}
