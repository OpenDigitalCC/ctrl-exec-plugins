#!/usr/bin/env bats
# Tests for run-jobs/run-jobs.sh. Run: bats test/run-jobs.bats
#
# Each test gets its own scripts and state dirs, a stand-in syslog socket,
# and a stub logger on PATH that appends its arguments to $LOG (or fails,
# with STUB_LOGGER_FAIL set).

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
    export RUN_JOBS_SYSLOG_SOCKET="$W/syslog.sock"
    touch "$RUN_JOBS_SYSLOG_SOCKET"
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

@test "logging goes to the named syslog socket" {
    add_job every 'schedule = * * * * *'
    run bash "$RUN_JOBS"
    grep -q -- "-u $W/syslog.sock -t run-jobs -p local0.info starting: every" "$LOG"
    [[ "$output" != *"run-jobs: starting"* ]]
}

@test "with no syslog socket, log lines go to stderr" {
    # util-linux logger exits 0 here even though the line is lost, which
    # the stub models by succeeding
    add_job every 'schedule = * * * * *'
    RUN_JOBS_SYSLOG_SOCKET="$W/no-such-socket" run bash "$RUN_JOBS"
    [ "$status" -eq 0 ]
    grep -q '^exit_code=0$' "$W/state/every.state"
    [[ "$output" == *"run-jobs: starting: every trigger=schedule"* ]]
    [ ! -e "$LOG" ]
}

@test "jobs still run when logger fails" {
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

# --- the tick window --------------------------------------------------------

# add_counting_job NAME CONF-LINE... : job that appends a line to $W/NAME.count
add_counting_job() {
    local name=$1
    shift
    printf '#!/bin/bash\necho x >> "%s"\n' "$W/$name.count" > "$W/scripts/$name.sh"
    chmod 755 "$W/scripts/$name.sh"
    printf '%s\n' "$@" > "$W/scripts/$name.conf"
}

# tick "YYYY-MM-DD HH:MM" - run one tick at that time (UTC)
tick() {
    RUN_JOBS_NOW=$(at "$1") bash "$RUN_JOBS"
}

# runs NAME - how many times the counting job has run
runs() {
    if [[ -e "$W/$1.count" ]]; then
        wc -l < "$W/$1.count"
    else
        echo 0
    fi
}

@test "a minute between 5-minute ticks runs at the next tick" {
    add_counting_job odd 'schedule = 7 * * * *'
    tick '2026-10-19 10:05'
    [ "$(runs odd)" -eq 0 ]
    tick '2026-10-19 10:10'
    [ "$(runs odd)" -eq 1 ]
}

@test "a job runs once, not again at a repeated or early tick" {
    add_counting_job daily 'schedule = 0 2 * * *'
    tick '2026-10-19 02:00'
    tick '2026-10-19 02:00'
    tick '2026-10-19 02:02'
    tick '2026-10-19 02:05'
    [ "$(runs daily)" -eq 1 ]
}

@test "a minute that passed during an overrunning tick is caught up" {
    add_counting_job mid 'schedule = 10 2 * * *'
    tick '2026-10-19 02:00'
    tick '2026-10-19 02:15'
    [ "$(runs mid)" -eq 1 ]
}

@test "after more than an hour without a tick, missed minutes are not run" {
    add_counting_job missed 'schedule = 30 2 * * *'
    tick '2026-10-19 01:00'
    tick '2026-10-19 03:00'
    [ "$(runs missed)" -eq 0 ]
}

@test "a schedule that matches several minutes of one tick runs once" {
    add_counting_job every 'schedule = * * * * *'
    tick '2026-10-19 02:00'
    tick '2026-10-19 02:05'
    [ "$(runs every)" -eq 2 ]
}

@test "runat runs at the first tick at or after it, never before" {
    add_counting_job once 'runat = 2026-10-19 22:03'
    tick '2026-10-19 21:55'
    tick '2026-10-19 22:00'
    [ "$(runs once)" -eq 0 ]
    tick '2026-10-19 22:05'
    [ "$(runs once)" -eq 1 ]
    grep -q '^trigger=runat=2026-10-19 22:03$' "$W/state/once.state"
    tick '2026-10-19 22:10'
    [ "$(runs once)" -eq 1 ]
}

@test "runat on a tick boundary runs at that tick" {
    add_counting_job exact 'runat = 2026-10-19 22:00'
    tick '2026-10-19 22:00'
    [ "$(runs exact)" -eq 1 ]
}

@test "a runat that is not a date is logged" {
    add_counting_job typo 'runat = 2026-13-45 22:00'
    tick '2026-10-19 22:00'
    grep -q "problem: typo - runat '2026-13-45 22:00' is not a date" "$LOG"
}

# --- --explain ---------------------------------------------------------------

# explain ARGS... - run --explain on the test scripts dir
explain() {
    bash "$RUN_JOBS" --explain --dir "$W/scripts" "$@"
}

@test "explain names the jobs a real tick at the same time runs, and runs none" {
    add_counting_job daily 'schedule = 0 2 * * *'
    add_counting_job odd 'schedule = 58 1 * * *'
    add_counting_job weekend 'schedule = 0 2 * * 6,0'
    add_counting_job once 'runat = 2026-10-19 01:57'
    add_counting_job later 'runat = 2026-10-19 02:01'

    run explain --at '2026-10-19 02:00'
    [ "$status" -eq 0 ]
    for job in daily odd weekend once later; do
        [ "$(runs "$job")" -eq 0 ]
    done
    [ ! -e "$W/state/.last-tick" ]
    # Job blocks start with the unindented name, after the blank line that
    # ends the header
    explained=$(echo "$output" \
        | awk '/^$/ { body = 1 } body && /^[^ ]/ { job = $0 } /^  this tick  RUNS/ { print job }' \
        | sort | tr '\n' ' ')

    tick '2026-10-19 02:00'
    ran=$(for job in daily odd weekend once later; do
        if [ "$(runs "$job")" -gt 0 ]; then echo "$job"; fi
    done | sort | tr '\n' ' ')

    [ "$explained" = "daily odd once " ]
    [ "$ran" = "$explained" ]
}

@test "explain shows the next ticks, and the minute an off-grid one is for" {
    add_job report 'schedule = 7 9 * * 1-5'
    run explain --at '2026-10-23 10:00'
    [ "$status" -eq 0 ]
    [[ "$output" == *"next       2026-10-26 09:10 (for 09:07)"* ]]
    [[ "$output" == *"           2026-10-27 09:10 (for 09:07)"* ]]
}

@test "explain shows where each runat stands" {
    add_job once 'runat = 2026-04-02 22:00' 'runat = 2026-10-19 21:59' 'runat = 2026-10-21 22:03'
    run explain --at '2026-10-19 22:00'
    [[ "$output" == *"runat      2026-04-02 22:00 - past, ignored"* ]]
    [[ "$output" == *"runat      2026-10-19 21:59 - in this tick"* ]]
    [[ "$output" == *"runat      2026-10-21 22:03 - runs at tick 2026-10-21 22:05"* ]]
    [[ "$output" == *"this tick  RUNS (trigger=runat=2026-10-19 21:59)"* ]]
}

@test "explain reports problems and exits 1" {
    add_job typo 'schedule = 0 2 * * mon'
    add_job never 'schedule = 0 0 30 2 *'
    add_job blank 'agent = hestia-01'
    add_job noexec 'schedule = 0 2 * * *'
    chmod 644 "$W/scripts/noexec.sh"
    add_job orphan
    rm "$W/scripts/orphan.conf"
    run explain --at '2026-10-19 02:00'
    [ "$status" -eq 1 ]
    [[ "$output" == *"PROBLEM    schedule '0 2 * * mon': day-of-week: bad value 'mon'"* ]]
    [[ "$output" == *"PROBLEM    schedule '0 0 30 2 *' never matches within a year"* ]]
    [[ "$output" == *"PROBLEM    no schedule= or runat=, so it never runs"* ]]
    [[ "$output" == *"due (trigger=schedule) but skipped"* ]]
    [[ "$output" == *"PROBLEM    noexec.sh is not executable (chmod 755); every tick skips it"* ]]
    [[ "$output" == *"PROBLEM    no orphan.conf, so orphan.sh never runs"* ]]
    [[ "$output" == *"5 job(s): 0 would run in this tick, 5 problem(s)"* ]]
}

@test "explain of a named job shows only that job" {
    add_job a 'schedule = 0 2 * * *'
    add_job b 'schedule = 0 3 * * *'
    run explain --at '2026-10-19 02:00' b.sh
    [ "$status" -eq 0 ]
    [[ "$output" == *$'\nb\n'* ]]
    [[ "$output" != *$'\na\n'* ]]
    run explain --at '2026-10-19 02:00' nosuch
    [ "$status" -eq 1 ]
    [[ "$output" == *"PROBLEM    no such job in $W/scripts"* ]]
}

@test "explain skips a local time lost to daylight saving, as ticks do" {
    add_job night 'schedule = 30 1 * * *'
    TZ=Europe/London run explain --at '2027-03-27 02:00'
    [[ "$output" == *"next       2027-03-29 01:30"* ]]
}

@test "explain and the runner reject bad arguments with status 2" {
    run explain --at 'not a time'
    [ "$status" -eq 2 ]
    run explain --bogus
    [ "$status" -eq 2 ]
    run bash "$RUN_JOBS" --bogus
    [ "$status" -eq 2 ]
    run bash "$RUN_JOBS" --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"--explain"* ]]
}
