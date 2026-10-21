#!/usr/bin/env bats
# Tests for run-jobs/scripts/heartbeat.sh. Run: bats test/heartbeat.bats
#
# A stub ctrl-exec-cli on PATH answers health, discovery and ping from
# canned JSON files in $W; a stub logger records one line per call:
# "<arguments>" in $STUB_LOG.

HEARTBEAT="${HEARTBEAT:-$BATS_TEST_DIRNAME/../run-jobs/scripts/heartbeat.sh}"

setup() {
    W="$BATS_TEST_TMPDIR"
    mkdir -p "$W/bin"
    export STUB_LOG="$W/syslog" STUB_DIR="$W"
    cat > "$W/bin/logger" <<'STUB'
#!/bin/bash
echo "$*" >> "$STUB_LOG"
STUB
    cat > "$W/bin/ctrl-exec-cli" <<'STUB'
#!/bin/bash
# usage: ctrl-exec-cli --json <cmd> [hosts...]; a file NAME.fail makes
# that command fail with its contents on stderr.
cmd=$2
if [[ -f "$STUB_DIR/$cmd.fail" ]]; then cat "$STUB_DIR/$cmd.fail" >&2; exit 1; fi
cat "$STUB_DIR/$cmd.json"
STUB
    chmod 755 "$W/bin/logger" "$W/bin/ctrl-exec-cli"
    export PATH="$W/bin:$PATH"
    unset HEARTBEAT_TAG HEARTBEAT_CERT_DAYS
    echo '{"ok":true,"version":"0.14.0"}' > "$W/health.json"
}

# expiry DAYS - an openssl notAfter string DAYS (plus a margin) from now
expiry() {
    date -u -d "now + $1 days + 1 hour" '+%b %e %H:%M:%S %Y GMT'
}

# fleet NAME:STATUS:DAYS ... - writes discovery.json and ping.json
fleet() {
    local d='' p='' sep='' spec n s e
    for spec in "$@"; do
        IFS=: read -r n s e <<< "$spec"
        d+="$sep\"$n\":{\"status\":\"ok\",\"version\":\"0.14.0\"}"
        if [[ $s == ok ]]; then
            p+="$sep{\"host\":\"$n\",\"status\":\"ok\",\"rtt\":\"3ms\",\"expiry\":\"$(expiry "$e")\",\"version\":\"0.14.0\"}"
        else
            p+="$sep{\"host\":\"$n\",\"status\":\"error\",\"error\":\"connection refused\"}"
        fi
        sep=,
    done
    echo "{\"ok\":true,\"hosts\":{$d}}" > "$W/discovery.json"
    echo "{\"ok\":true,\"results\":[$p]}" > "$W/ping.json"
}

@test "all agents up and certificates fresh: ok at user.info, exit 0" {
    fleet agent-01:ok:287 agent-02:ok:300 agent-03:ok:290
    run bash "$HEARTBEAT"
    [ "$status" -eq 0 ]
    [ "$output" = "status=ok agents=3/3 api=0.14.0 min_cert_days=287" ]
    [ "$(cat "$STUB_LOG")" = "-p user.info -t ctrl-exec-heartbeat -- status=ok agents=3/3 api=0.14.0 min_cert_days=287" ]
}

@test "one agent down: fail at user.err naming it, exit 1" {
    fleet agent-01:ok:287 agent-02:down:0 agent-03:ok:290
    run bash "$HEARTBEAT"
    [ "$status" -eq 1 ]
    [ "$output" = "status=fail agents=2/3 api=0.14.0 down=agent-02" ]
    [ "$(cat "$STUB_LOG")" = "-p user.err -t ctrl-exec-heartbeat -- status=fail agents=2/3 api=0.14.0 down=agent-02" ]
}

@test "certificate inside the window: warn at user.warning, exit 1" {
    fleet agent-01:ok:12 agent-02:ok:300
    run bash "$HEARTBEAT"
    [ "$status" -eq 1 ]
    [ "$output" = "status=warn agents=2/2 api=0.14.0 expiring=agent-01:12d" ]
    [[ "$(cat "$STUB_LOG")" == "-p user.warning -t ctrl-exec-heartbeat -- status=warn "* ]]
}

@test "HEARTBEAT_CERT_DAYS moves the window" {
    fleet agent-01:ok:12
    HEARTBEAT_CERT_DAYS=10 run bash "$HEARTBEAT"
    [ "$status" -eq 0 ]
    [ "$output" = "status=ok agents=1/1 api=0.14.0 min_cert_days=12" ]
    HEARTBEAT_CERT_DAYS=14 run bash "$HEARTBEAT"
    [ "$status" -eq 1 ]
}

@test "fail beats warn when an agent is down and another certificate is close" {
    fleet agent-01:ok:12 agent-02:down:0
    run bash "$HEARTBEAT"
    [ "$status" -eq 1 ]
    [ "$output" = "status=fail agents=1/2 api=0.14.0 down=agent-02 expiring=agent-01:12d" ]
    [[ "$(cat "$STUB_LOG")" == "-p user.err "* ]]
}

@test "API down: fail at user.err with the error" {
    echo "ctrl-exec-cli: cannot connect to http://localhost:7445" > "$W/health.fail"
    run bash "$HEARTBEAT"
    [ "$status" -eq 1 ]
    [ "$output" = 'status=fail api=down error="ctrl-exec-cli: cannot connect to http://localhost:7445"' ]
    [[ "$(cat "$STUB_LOG")" == "-p user.err -t ctrl-exec-heartbeat -- status=fail api=down "* ]]
}

@test "discovery failing is reported as an API failure" {
    echo "boom" > "$W/discovery.fail"
    run bash "$HEARTBEAT"
    [ "$status" -eq 1 ]
    [ "$output" = 'status=fail api=down error="discovery: boom"' ]
}

@test "zero registered agents: warn, never ok" {
    echo '{"ok":true,"hosts":{}}' > "$W/discovery.json"
    run bash "$HEARTBEAT"
    [ "$status" -eq 1 ]
    [ "$output" = "status=warn agents=0/0 api=0.14.0" ]
    [[ "$(cat "$STUB_LOG")" == "-p user.warning "* ]]
}

@test "exactly one logger call per run, in every state" {
    fleet agent-01:ok:287
    bash "$HEARTBEAT" || true
    fleet agent-01:down:0
    bash "$HEARTBEAT" || true
    echo x > "$W/health.fail"
    bash "$HEARTBEAT" || true
    [ "$(wc -l < "$STUB_LOG")" -eq 3 ]
}

@test "HEARTBEAT_TAG overrides the tag" {
    fleet agent-01:ok:287
    HEARTBEAT_TAG=hb-test run bash "$HEARTBEAT"
    [[ "$(cat "$STUB_LOG")" == "-p user.info -t hb-test -- "* ]]
}
