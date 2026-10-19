#!/usr/bin/env bats
# Tests for run-jobs/run-jobs.sh. Run: bats test/run-jobs.bats
#
# Each test gets its own scripts and state dirs and a stub logger on PATH
# that appends to $LOG, or fails as logger does when /dev/log is missing.

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
