#!/bin/bash
# Test suite for the cert-deploy plugin. Run: bash test/run.sh
#
# Covers the three agent scripts and the run-jobs deploy job:
#   - the no-args contract of each agent script (non-zero exit with usage)
#   - agent-cert-deploy: both layouts, --test, groups, bad arguments
#   - agent-service-restart: --test and a real run against a STUB docker
#   - agent-cert-check: against local openssl s_server instances on 127.0.0.1
#   - deploy-cert.sh: end to end against a STUB ctrl-exec-cli
# Needs no network beyond 127.0.0.1, no real docker and no root. Sections
# that need openssl, jq or perl SKIP (counted, not failed) when it is absent.
# shellcheck disable=SC2015,SC2012,SC2016  # A && pass || fail is intended; ls output is test-controlled; stub scripts are quoted on purpose
set -u
DIR="$(cd "$(dirname "$0")/.." && pwd)"
ACD="$DIR/agent-cert-deploy.sh"
ASR="$DIR/agent-service-restart.sh"
ACC="$DIR/agent-cert-check.sh"
JOB="$DIR/run-jobs/deploy-cert.sh"
JOBCONF_EXAMPLE="$DIR/run-jobs/deploy-cert.conf.example"

PASS=0 FAIL=0 SKIP=0
T="$(mktemp -d "${TMPDIR:-/tmp}/cert-deploy-test.XXXXXX")" || exit 2
pids=()
cleanup() {
    local p
    for p in "${pids[@]:-}"; do
        [ -n "$p" ] && kill "$p" 2>/dev/null
    done
    wait 2>/dev/null
    [ -n "${KEEP_TMP:-}" ] && echo "kept: $T" >&2 || rm -rf "$T"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

pass() { echo "  PASS  $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL  $1${2:+ ($2)}"; FAIL=$((FAIL + 1)); }
skip() { echo "  SKIP  $1"; SKIP=$((SKIP + 1)); }
heading() { echo; echo "## $1"; echo; }

# expect_rc <name> <want> <got>
expect_rc() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "want exit $2, got $3"; fi; }
# expect_nonzero <name> <got>
expect_nonzero() { if [ "$2" != 0 ]; then pass "$1"; else fail "$1" "exit 0, wanted non-zero"; fi; }
# expect_has <name> <text> <needle>   (fixed string)
expect_has() { if grep -qF -- "$3" <<< "$2"; then pass "$1"; else fail "$1" "missing '$3'"; fi; }
# expect_lacks <name> <text> <needle>
expect_lacks() { if grep -qF -- "$3" <<< "$2"; then fail "$1" "unexpected '$3'"; else pass "$1"; fi; }
# expect_eq <name> <want> <got>
expect_eq() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "want '$2', got '$3'"; fi; }

# run <cmd...>: sets OUT (stdout+stderr) and RC
run() { OUT="$("$@" 2>&1 < /dev/null)"; RC=$?; }

have() { command -v "$1" > /dev/null 2>&1; }
is_root() { [ "$(id -u)" -eq 0 ]; }

free_port() {
    local p
    for _ in $(seq 1 200); do
        p=$((20000 + RANDOM % 30000))
        if ! (exec 3<> "/dev/tcp/127.0.0.1/$p") 2> /dev/null; then
            echo "$p"
            return 0
        fi
    done
    return 1
}

# wait_listen <port> <pid>: readiness poll, up to 10 s, never a fixed sleep
wait_listen() {
    for _ in $(seq 1 100); do
        kill -0 "$2" 2> /dev/null || return 1
        if (exec 3<> "/dev/tcp/127.0.0.1/$1") 2> /dev/null; then
            return 0
        fi
        sleep 0.1
    done
    return 1
}

echo "# Test report: cert-deploy (ce-agent-plugins)"
echo "Generated: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"

# ---------------------------------------------------------------------------
heading "Contract: no arguments"
for s in "$ACD" "$ASR" "$ACC"; do
    run "$s"
    expect_nonzero "$(basename "$s") with no arguments exits non-zero" "$RC"
    if [ -n "$OUT" ]; then
        pass "$(basename "$s") with no arguments prints usage"
    else
        fail "$(basename "$s") with no arguments prints usage" "no output"
    fi
done
for s in "$ACD" "$ASR" "$ACC"; do
    [ -x "$s" ] && pass "$(basename "$s") is executable" || fail "$(basename "$s") is executable"
    head -n 1 "$s" | grep -q '^#!' && pass "$(basename "$s") has a shebang" || fail "$(basename "$s") has a shebang"
    if have jq; then
        jq -e '.argv and .arguments and (.read_only != null or .idempotent != null)' "$s.schema.json" > /dev/null 2>&1 \
            && pass "$(basename "$s") schema sidecar is valid JSON with arguments and argv" \
            || fail "$(basename "$s") schema sidecar is valid JSON with arguments and argv"
    fi
done
if have jq; then
    expect_eq "agent-cert-check sidecar is read_only" true "$(jq -r '.read_only' "$ACC.schema.json")"
    expect_eq "agent-cert-deploy sidecar is not read_only" false "$(jq -r '.read_only' "$ACD.schema.json")"
    expect_eq "agent-service-restart sidecar is not read_only" false "$(jq -r '.read_only' "$ASR.schema.json")"
    expect_eq "agent-cert-deploy sidecar layout enum" "named,pem" \
        "$(jq -r '.arguments.properties.layout.enum | join(",")' "$ACD.schema.json")"
else
    skip "schema sidecar checks (jq not installed)"
fi

# ---------------------------------------------------------------------------
heading "agent-cert-deploy"
G="$(id -g)"
GN="$(id -gn)"
C="$(printf -- '-----BEGIN CERTIFICATE-----\nLEAF\n-----END CERTIFICATE-----\n' | base64 -w0)"
K="$(printf -- '-----BEGIN PRIVATE KEY-----\nKEY\n-----END PRIVATE KEY-----\n' | base64 -w0)"
A="$(printf -- '-----BEGIN CERTIFICATE-----\nCA\n-----END CERTIFICATE-----\n' | base64 -w0)"
D="$T/acd"
mkdir -p "$D"

run "$ACD" "$D/named" example.com "$G" "$C" "$K" "$A"
expect_rc "deploy, named layout (default)" 0 "$RC"
expect_eq "named layout writes the four files" \
    "example.com.ca example.com.crt example.com.fullchain.crt example.com.key" \
    "$(ls -A "$D/named" | tr '\n' ' ' | sed 's/ $//')"
expect_eq "named: file mode 640" 640 "$(stat -c %a "$D/named/example.com.key")"
expect_eq "named: folder mode 750" 750 "$(stat -c %a "$D/named")"
expect_eq "named: group set (numeric gid)" "$G" "$(stat -c %g "$D/named/example.com.key")"
expect_eq "named: fullchain is certificate then CA" \
    "$(printf 'LEAF\nCA' | tr '\n' ' ')" \
    "$(grep -v -- '-----' "$D/named/example.com.fullchain.crt" | tr '\n' ' ' | sed 's/ $//')"
if base64 -d <<< "$K" | cmp -s - "$D/named/example.com.key"; then
    pass "named: key written byte for byte"
else
    fail "named: key written byte for byte"
fi
expect_has "named: output names the layout" "$OUT" "layout named"

run "$ACD" "$D/named2" example.com - "$C" "$K" "$A" named
expect_rc "deploy, named given explicitly, group -" 0 "$RC"
if diff -r "$D/named" "$D/named2" > /dev/null; then
    pass "explicit named is identical to the default"
else
    fail "explicit named is identical to the default"
fi

run "$ACD" "$D/pem" example.com "$GN" "$C" "$K" "$A" pem
expect_rc "deploy, pem layout, group by name" 0 "$RC"
expect_eq "pem layout writes exactly two files" "fullchain.pem privkey.pem" \
    "$(ls -A "$D/pem" | tr '\n' ' ' | sed 's/ $//')"
expect_eq "pem: file mode 640" 640 "$(stat -c %a "$D/pem/privkey.pem")"
expect_eq "pem: fullchain is certificate then CA" "LEAF CA" \
    "$(grep -v -- '-----' "$D/pem/fullchain.pem" | tr '\n' ' ' | sed 's/ $//')"
if base64 -d <<< "$K" | cmp -s - "$D/pem/privkey.pem"; then
    pass "pem: privkey.pem is the key"
else
    fail "pem: privkey.pem is the key"
fi

printf 'old\n' > "$D/named/example.com.key"
run "$ACD" "$D/named" example.com - "$C" "$K" "$A"
expect_rc "deploy again over existing files (idempotent)" 0 "$RC"
expect_eq "existing key overwritten in place" "-----BEGIN PRIVATE KEY-----" "$(head -n 1 "$D/named/example.com.key")"

run "$ACD" "$D/bad" example.com - "$C" "$K" "$A" weird
expect_nonzero "bad layout rejected on deploy" "$RC"
expect_has "bad layout names the problem" "$OUT" "invalid layout"
[ ! -e "$D/bad" ] && pass "bad layout wrote nothing" || fail "bad layout wrote nothing"

run "$ACD" "$D/x" example.com -
expect_nonzero "deploy without the base64 arguments rejected" "$RC"
run "$ACD" relative/dir example.com - "$C" "$K" "$A"
expect_nonzero "relative target-dir rejected" "$RC"
run "$ACD" "$D/../x" example.com - "$C" "$K" "$A"
expect_nonzero "target-dir with '..' rejected" "$RC"
run "$ACD" "$D/x" "a/b" - "$C" "$K" "$A"
expect_nonzero "basename with '/' rejected" "$RC"
run "$ACD" "$D/x" example.com 'bad group;' "$C" "$K" "$A"
expect_nonzero "invalid group characters rejected" "$RC"

# --test mode
mkdir -p "$D/t-existing"
printf 'old\n' > "$D/t-existing/example.com.key"
chmod 640 "$D/t-existing/example.com.key"
run "$ACD" --test "$D/t-existing" example.com "$GN"
expect_rc "--test, existing folder, own group by name" 0 "$RC"
expect_has "--test reports success" "$OUT" "all checks passed"
expect_has "--test names the layout" "$OUT" "layout named"
run "$ACD" --test "$D/t-existing" example.com "$G"
expect_rc "--test, numeric gid of own group" 0 "$RC"
run "$ACD" --test "$D/t-existing" example.com 64999
# a user outside that group may still fail the chgrp check; the point is that
# the group is accepted without a host entry
expect_has "--test says no host entry is needed" "$OUT" "no host entry needed"
run "$ACD" --test "$D/t-existing" example.com nosuchgroup-cd
expect_nonzero "--test, group that does not exist" "$RC"
expect_has "--test names the missing group" "$OUT" "does not exist"
run "$ACD" --test "$D/t-new/sub" example.com -
expect_rc "--test, folder to be created" 0 "$RC"
expect_has "--test says the folder would be created" "$OUT" "would create it under"
[ ! -e "$D/t-new" ] && pass "--test did not create the folder" || fail "--test did not create the folder"
run "$ACD" --test "$D/pem" example.com "$G" pem
expect_rc "--test, pem layout over existing files" 0 "$RC"
expect_has "--test pem names the layout" "$OUT" "layout pem"
expect_has "--test pem checks an existing file" "$OUT" "can overwrite existing privkey.pem"
run "$ACD" --test "$D/t-existing" example.com - weird
expect_nonzero "--test, bad layout" "$RC"
expect_eq "--test left no probe file behind" "" "$(find "$D" -name '.agent-cert-deploy-test.*')"
expect_eq "--test left the existing key unchanged" "old" "$(cat "$D/t-existing/example.com.key")"
expect_eq "--test left the existing key's mode unchanged" 640 "$(stat -c %a "$D/t-existing/example.com.key")"
if is_root; then
    skip "--test unwritable folder, read-only key, group not a member (running as root)"
else
    mkdir -p "$D/locked"
    chmod 500 "$D/locked"
    run "$ACD" --test "$D/locked" example.com -
    expect_nonzero "--test, unwritable folder" "$RC"
    expect_has "--test explains the unwritable folder" "$OUT" "cannot create files"
    chmod 700 "$D/locked"
    mkdir -p "$D/ro"
    printf 'old\n' > "$D/ro/example.com.key"
    chmod 440 "$D/ro/example.com.key"
    run "$ACD" --test "$D/ro" example.com -
    expect_nonzero "--test, read-only existing key" "$RC"
    expect_has "--test names the read-only file" "$OUT" "cannot overwrite existing"
    run "$ACD" --test "$D/t-existing" example.com root
    expect_nonzero "--test, group the user is not a member of" "$RC"
fi

# ---------------------------------------------------------------------------
heading "agent-service-restart (stub docker)"
R="$T/asr"
mkdir -p "$R/bin" "$R/app"
F1="$R/app/compose.yml"
F2="$R/app/compose.extra.yml"
touch "$F1" "$F2"
cat > "$R/bin/docker" <<'STUB'
#!/bin/bash
# Stub docker. Services: web running, db stopped, cron defined with no container.
echo "$*" >> "${DLOG:-/dev/null}"
if [ "${STUBMODE:-}" = denied ]; then
    echo "permission denied while trying to connect to the docker API" >&2
    exit 1
fi
args="$*"
case "$args" in
    "version --format"*)                echo "27.0.0" ;;
    "compose --dry-run version")        echo "v2.29" ;;
    *"config --services")               printf 'web\ndb\ncron\n' ;;
    *"ps --all --services")             printf 'web\ndb\n' ;;
    *"ps --services --status running")  printf 'web\n' ;;
    "compose --dry-run -f "*)           echo "DRY-RUN MODE - Container app-web-1  Restarting" ;;
    "compose -f "*" restart"*)          : ;;
    *) echo "unexpected: $args" >&2; exit 9 ;;
esac
STUB
chmod 755 "$R/bin/docker"
dk() { PATH="$R/bin:$PATH" DLOG="$R/log" "$@"; }

: > "$R/log"
run dk "$ASR" --test "$F1" web db
expect_rc "--test, running and stopped services" 0 "$RC"
expect_has "--test reports a running service" "$OUT" "service 'web' is running"
expect_has "--test reports a stopped service" "$OUT" "service 'db' is stopped"
expect_has "--test ran the dry-run restart" "$OUT" "dry-run restart succeeded"
run dk "$ASR" --test "$F1" web cron
expect_nonzero "--test, service with no container fails" "$RC"
expect_has "--test explains the missing container" "$OUT" "'cron' has no container"
run dk "$ASR" --test "$F1" nginx
expect_nonzero "--test, service not defined fails" "$RC"
expect_has "--test names the undefined service" "$OUT" "'nginx' is not defined"
run dk "$ASR" --test "$F1"
expect_nonzero "--test, whole stack fails while a service has no container" "$RC"
: > "$R/log"
run dk "$ASR" --test "$F1:$F2" web
expect_rc "--test, two compose files" 0 "$RC"
expect_has "--test passes each file with its own -f, in order" "$(cat "$R/log")" "-f $F1 -f $F2"
run env STUBMODE=denied PATH="$R/bin:$PATH" "$ASR" --test "$F1" web
expect_nonzero "--test, no docker socket access fails" "$RC"
expect_has "--test explains the docker access problem" "$OUT" "cannot reach the docker daemon"

run dk "$ASR" --test /no/such/compose.yml
expect_nonzero "--test, compose file that does not exist" "$RC"
run dk "$ASR" --test "$F1:/no/such/extra.yml"
expect_nonzero "--test, second compose file that does not exist" "$RC"
run dk "$ASR" --test relative/compose.yml
expect_nonzero "relative compose path rejected" "$RC"
run dk "$ASR" --test "$R/app/../app/compose.yml"
expect_nonzero "compose path with '..' rejected" "$RC"
run dk "$ASR" "$F1" --evil
expect_nonzero "service name starting with '-' rejected" "$RC"

: > "$R/log"
run dk "$ASR" "$F1:$F2" web db
expect_rc "restart, two compose files, two services" 0 "$RC"
expect_has "restart runs docker compose restart with the files and services" \
    "$(cat "$R/log")" "compose -f $F1 -f $F2 restart web db"
: > "$R/log"
run dk "$ASR" "$F1"
expect_rc "restart, whole stack" 0 "$RC"
expect_has "whole-stack restart names no service" "$(cat "$R/log")" "compose -f $F1 restart"
expect_has "whole-stack restart says so" "$OUT" "restarting: all services"

# ---------------------------------------------------------------------------
heading "agent-cert-check (local openssl s_server)"
if ! have openssl; then
    skip "agent-cert-check section (openssl not installed)"
else
    X="$T/chk"
    mkdir -p "$X"
    (
        cd "$X" || exit 1
        q() { "$@" > /dev/null 2>&1; }
        q openssl req -x509 -newkey rsa:2048 -nodes -keyout root.key -out root.crt -days 365 \
            -subj /CN=TestRoot -addext basicConstraints=critical,CA:true \
            -addext keyUsage=critical,keyCertSign,cRLSign
        q openssl req -newkey rsa:2048 -nodes -keyout int.key -out int.csr -subj /CN=TestInt
        printf 'basicConstraints=critical,CA:true\nkeyUsage=critical,keyCertSign,cRLSign\n' > int.ext
        q openssl x509 -req -in int.csr -CA root.crt -CAkey root.key -CAcreateserial -out int.crt \
            -days 365 -extfile int.ext
        leaf() {   # leaf <name> <days> <san>
            q openssl req -newkey rsa:2048 -nodes -keyout "$1.key" -out "$1.csr" -subj "/CN=$3"
            printf 'subjectAltName=DNS:%s\n' "$3" > "$1.ext"
            q openssl x509 -req -in "$1.csr" -CA int.crt -CAkey int.key -CAcreateserial -out "$1.crt" \
                -days "$2" -extfile "$1.ext"
        }
        leaf good 90 '*.example.test'
        leaf soon 20 '*.example.test'
        leaf dying 3 '*.example.test'
    )
    if [ ! -s "$X/dying.crt" ]; then
        fail "build the test certificate chain" "openssl could not issue the test certificates"
    else
        serve() {   # serve <leaf> [chain-file]: starts s_server, sets SPORT or fails
            local port extra=()
            [ -n "${2:-}" ] && extra=(-cert_chain "$X/$2")
            port="$(free_port)" || return 1
            openssl s_server -accept "127.0.0.1:$port" -cert "$X/$1.crt" -key "$X/$1.key" "${extra[@]}" \
                -quiet < /dev/null > /dev/null 2>&1 &
            pids+=($!)
            wait_listen "$port" $! || return 1
            SPORT="$port"
        }
        serve good int.crt   && P_FULL="$SPORT"  || fail "start s_server (full chain)"
        serve good           && P_LEAF="$SPORT"  || fail "start s_server (leaf only)"
        serve soon int.crt   && P_SOON="$SPORT"  || fail "start s_server (20 days left)"
        serve dying int.crt  && P_DYING="$SPORT" || fail "start s_server (3 days left)"
        P_CLOSED="$(free_port)"
        FP="$(openssl x509 -noout -fingerprint -sha256 -in "$X/good.crt" | cut -d= -f2)"
        NAME=app.example.test
        CA="$X/root.crt"

        run "$ACC" -H 127.0.0.1 -p "${P_FULL:-0}" -n "$NAME" -C "$CA"
        expect_rc "healthy chain: exit 0 (OK)" 0 "$RC"
        expect_has "healthy chain: status line" "$OUT" "SSL OK"
        expect_has "healthy chain: verified, chain of 2" "$OUT" "chain 2, verified"
        expect_has "healthy chain: performance data" "$OUT" "| days="
        run "$ACC" -H 127.0.0.1 -p "${P_FULL:-0}" -n "$NAME" -C "$CA" -f "$FP"
        expect_rc "fingerprint match: exit 0" 0 "$RC"
        expect_has "fingerprint match: reported" "$OUT" "fingerprint matches"
        run "$ACC" -H 127.0.0.1 -p "${P_FULL:-0}" -n "$NAME" -C "$CA" -f "$(tr 'A-F' 'a-f' <<< "${FP//:/}")"
        expect_rc "fingerprint match: lower case, no colons" 0 "$RC"
        run "$ACC" -H 127.0.0.1 -p "${P_FULL:-0}" -n "$NAME" -C "$CA" -f AA:BB:CC
        expect_rc "fingerprint mismatch: exit 2 (CRITICAL)" 2 "$RC"
        expect_has "fingerprint mismatch: reported" "$OUT" "serving a different certificate"
        run "$ACC" -H 127.0.0.1 -p "${P_LEAF:-0}" -n "$NAME" -C "$CA"
        expect_rc "missing intermediate: exit 2" 2 "$RC"
        expect_has "missing intermediate: chain does not verify" "$OUT" "chain does not verify"
        run "$ACC" -H 127.0.0.1 -p "${P_FULL:-0}" -n "$NAME"
        expect_rc "chain to an unknown CA (no -C): exit 2" 2 "$RC"
        run "$ACC" -H 127.0.0.1 -p "${P_FULL:-0}" -n other.test -C "$CA"
        expect_rc "wrong name: exit 2" 2 "$RC"
        expect_has "wrong name: reported" "$OUT" "does not cover other.test"
        run "$ACC" -H 127.0.0.1 -p "${P_SOON:-0}" -n "$NAME" -C "$CA"
        expect_rc "20 days left: exit 1 (WARNING)" 1 "$RC"
        expect_has "20 days left: status line" "$OUT" "SSL WARNING"
        run "$ACC" -H 127.0.0.1 -p "${P_SOON:-0}" -n "$NAME" -C "$CA" -w 10
        expect_rc "20 days left, -w 10: exit 0" 0 "$RC"
        run "$ACC" -H 127.0.0.1 -p "${P_DYING:-0}" -n "$NAME" -C "$CA"
        expect_rc "3 days left: exit 2 (CRITICAL)" 2 "$RC"
        run "$ACC" -H 127.0.0.1 -p "$P_CLOSED" -n "$NAME" -C "$CA" -t 3
        expect_rc "closed port: exit 2" 2 "$RC"
        expect_has "closed port: reason" "$OUT" "Connection refused"
        run "$ACC" -p "${P_FULL:-0}"
        expect_rc "missing -n: exit 3 (UNKNOWN)" 3 "$RC"
        run "$ACC" -p abc -n x.test
        expect_rc "bad port: exit 3" 3 "$RC"
        run "$ACC" -p 443 -n 'bad name;'
        expect_rc "bad name: exit 3" 3 "$RC"
        run "$ACC" -p 443 -n x.test -w ten
        expect_rc "non-numeric -w: exit 3" 3 "$RC"
        run "$ACC" -p 443 -n x.test -C /no/such/ca.pem
        expect_rc "unreadable CA file: exit 3" 3 "$RC"
        run "$ACC" -p 443 -n x.test -Z
        expect_rc "unknown option: exit 3" 3 "$RC"
        run "$ACC" -h
        expect_rc "-h prints usage, exit 0" 0 "$RC"
    fi
fi

# ---------------------------------------------------------------------------
heading "deploy-cert.sh (stub ctrl-exec-cli)"
if ! have openssl || ! have jq || ! have perl; then
    skip "deploy-cert.sh section (needs openssl, jq and perl)"
else
    J="$T/job"
    mkdir -p "$J/bin"
    openssl req -x509 -newkey rsa:2048 -nodes -keyout "$J/k.pem" -out "$J/c.pem" -days 90 \
        -subj '/CN=*.example.test' > /dev/null 2>&1
    openssl x509 -noout -fingerprint -sha256 -in "$J/c.pem" | cut -d= -f2 | tr -d ':' > "$J/fp"

    cat > "$J/bin/ctrl-exec-cli" <<'STUB'
#!/bin/bash
# Stub: ctrl-exec-cli run <host> --script <name> --json -- <args...>
# Records "<host> <script> <args>" with base64 blobs shortened to <b64>.
host=$2 script=$4
shift 6
rec="$host $script"
for a in "$@"; do
    if [[ $a =~ ^[A-Za-z0-9+/=]{8,}$ && ! $a =~ ^[0-9A-F]{64}$ && $a != localhost && $a != /* ]]; then rec+=" <b64>"; else rec+=" $a"; fi
done
echo "$rec" >> "$CALLS"
case $script in
    ctrl-exec-hestia)
        out="### CERT ###"$'\n'"$(cat "$D/c.pem")"$'\n'"### KEY ###"$'\n'"KEYDATA-SECRET"$'\n'"### CA ###"$'\n'"CADATA"
        jq -n --arg o "$out" '{ok:true,results:[{exit:0,stdout:$o}]}' ;;
    agent-cert-deploy)
        if [[ "${FAIL_DEPLOY:-}" == "$host" ]]; then
            echo '{"ok":true,"results":[{"exit":1,"stderr":"chgrp: invalid group"}]}'
        else
            echo '{"ok":true,"results":[{"exit":0,"stdout":"deployed"}]}'
        fi ;;
    agent-cert-check)
        n=$(( $(cat "$D/tries" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$D/tries"
        fp=""; prev=""
        for a in "$@"; do [[ $prev == -f ]] && fp=$a; prev=$a; done
        if [[ $fp != "$(cat "$D/fp")" ]]; then
            jq -n '{ok:true,results:[{exit:2,stdout:"SSL CRITICAL - stub: wrong fingerprint passed"}]}'
        else case ${MODE:-ok} in
            ok)   jq -n '{ok:true,results:[{exit:0,stdout:"SSL OK - stub"}]}' ;;
            warn) jq -n '{ok:true,results:[{exit:1,stdout:"SSL WARNING - stub"}]}' ;;
            late) if (( n < 3 )); then
                      jq -n '{ok:true,results:[{exit:2,stdout:"SSL CRITICAL - Connection refused"}]}'
                  else jq -n '{ok:true,results:[{exit:0,stdout:"SSL OK - stub after restart"}]}'; fi ;;
            fail) jq -n '{ok:true,results:[{exit:2,stdout:"SSL CRITICAL - chain does not verify"}]}' ;;
        esac fi ;;
    *) echo '{"ok":true,"results":[{"exit":0,"stdout":"done"}]}' ;;
esac
STUB
    printf '#!/bin/bash\necho "$*" >> "$SYSLOG"\n' > "$J/bin/logger"
    chmod 755 "$J/bin/ctrl-exec-cli" "$J/bin/logger"

    # scenario <name> <conf> [filter] [ENV=value ...]
    # Sets RC, CALLS_TXT (the recorded calls, issue calls excluded), LOG_TXT (syslog)
    # and SDIR. VERIFY_WAIT is 0 so retries do not slow the run.
    scenario() {
        local name=$1 conf=$2 filter=${3:-}
        shift 3 2> /dev/null || shift $#
        SDIR="$J/$name"
        mkdir -p "$SDIR/out"
        cp "$JOB" "$SDIR/deploy-cert.sh"
        printf '%s\n' "$conf" > "$SDIR/deploy-cert.conf"
        cp "$J/c.pem" "$J/fp" "$SDIR/"
        RC=0
        env PATH="$J/bin:$PATH" CALLS="$SDIR/calls" SYSLOG="$SDIR/syslog" D="$SDIR" \
            CERT_OUTPUT_DIR="$SDIR/out" VERIFY_WAIT=0 "$@" \
            bash "$SDIR/deploy-cert.sh" ${filter:+"$filter"} > "$SDIR/stdout" 2>&1 || RC=$?
        CALLS_TXT="$(grep -v ctrl-exec-hestia "$SDIR/calls" 2> /dev/null)"
        LOG_TXT="$(cat "$SDIR/syslog" 2> /dev/null)"
    }
    count() { grep -c -- "$2" <<< "$1"; }   # count <text> <fixed pattern>

    TWO='agent = issuer-01.example.com
certificate = a.example.test wildcard
certificate = b.example.test wildcard
target = web   web-01.example.com /srv/web/certs 101
target = ldaps web-01.example.com /srv/idp/certs/directory 1000 pem
deploy = a.example.test web
deploy = b.example.test ldaps
restart = web   /srv/web/compose.yml nginx
restart = ldaps /srv/idp/compose.yml worker
verify = ldaps b.example.test 636'

    scenario two-targets "$TWO"
    expect_rc "two targets on one agent: exit 0" 0 "$RC"
    expect_has "two targets: named layout passed for the first" "$CALLS_TXT" \
        "web-01.example.com agent-cert-deploy /srv/web/certs a.example.test 101 <b64> <b64> <b64> named"
    expect_has "two targets: pem layout passed for the second" "$CALLS_TXT" \
        "web-01.example.com agent-cert-deploy /srv/idp/certs/directory b.example.test 1000 <b64> <b64> <b64> pem"
    expect_eq "two targets: both restarts ran" 2 "$(count "$CALLS_TXT" agent-service-restart)"
    expect_has "two targets: summary line" "$LOG_TXT" \
        "complete: issued 2 ok 0 failed | deployed 2 ok 0 failed | restarted 2 ok 0 failed | verified 1 ok 0 failed"
    expect_eq "private key not left on disk" "" "$(grep -rl KEYDATA-SECRET "$SDIR/out" 2> /dev/null)"

    scenario only-web "$TWO" a.example.test
    expect_rc "single certificate by name: exit 0" 0 "$RC"
    expect_has "restart only for the target that got a certificate" "$CALLS_TXT" "agent-service-restart /srv/web/compose.yml nginx"
    expect_lacks "no restart for the target that got none" "$CALLS_TXT" "/srv/idp/compose.yml"
    expect_eq "no verify call for the target that got none" 0 "$(count "$CALLS_TXT" agent-cert-check)"

    scenario unknown-target 'agent = issuer-01.example.com
certificate = a.example.test
target = web web-01.example.com /srv/web/certs 101
deploy = a.example.test nosuch
restart = web /srv/web/compose.yml nginx'
    expect_rc "deploy to an unknown target: exit 1" 1 "$RC"
    expect_has "unknown target is named in the log" "$LOG_TXT" "no target named 'nosuch'"
    expect_lacks "nothing restarted after a failed deploy" "$CALLS_TXT" agent-service-restart

    scenario bad-layout 'agent = issuer-01.example.com
certificate = a.example.test
target = web web-01.example.com /srv/web/certs 101 tarball
deploy = a.example.test web'
    expect_rc "bad layout in a target line: exit 1" 1 "$RC"
    expect_has "bad target line logged" "$LOG_TXT" "bad target line"
    [ ! -s "$SDIR/calls" ] && pass "bad target line stops before anything is issued" \
        || fail "bad target line stops before anything is issued"

    scenario duplicate-name 'agent = issuer-01.example.com
certificate = a.example.test
target = web web-01.example.com /srv/a 101
target = web web-02.example.com /srv/b 101
deploy = a.example.test web'
    expect_rc "duplicate target name: exit 1" 1 "$RC"
    expect_has "duplicate target name logged" "$LOG_TXT" "duplicate target name 'web'"

    scenario old-format-target 'agent = issuer-01.example.com
certificate = a.example.test
target = web-01.example.com /srv/web/certs 101
deploy = a.example.test web-01.example.com'
    expect_rc "target line without a name: exit 1" 1 "$RC"
    expect_has "target line without a name logged" "$LOG_TXT" "bad target line"

    scenario bad-deploy-line 'agent = issuer-01.example.com
certificate = a.example.test
target = web web-01.example.com /srv/web/certs 101
deploy = a.example.test web /srv/web/certs -
restart = web /srv/web/compose.yml nginx'
    expect_rc "deploy line with extra fields: exit 1" 1 "$RC"
    expect_has "bad deploy line logged" "$LOG_TXT" "bad deploy line"

    scenario deploy-fails "$TWO" "" FAIL_DEPLOY=web-01.example.com
    expect_rc "deploy fails on the agent: exit 1" 1 "$RC"
    expect_has "agent error is logged" "$LOG_TXT" "chgrp: invalid group"
    expect_lacks "no restart when every deploy failed" "$CALLS_TXT" agent-service-restart

    scenario restart-unknown-target 'agent = issuer-01.example.com
certificate = a.example.test
target = web web-01.example.com /srv/web/certs 101
deploy = a.example.test web
restart = web-01.example.com /srv/web/compose.yml nginx'
    expect_rc "restart for an unknown target: exit 1" 1 "$RC"
    expect_has "bad restart line logged" "$LOG_TXT" "bad restart line"

    scenario no-deploys 'agent = issuer-01.example.com
certificate = a.example.test
target = web web-01.example.com /srv/web/certs 101
restart = web /srv/web/compose.yml nginx'
    expect_rc "certificate with no deploy line: exit 0" 0 "$RC"
    expect_has "no-deploy case logged" "$LOG_TXT" "no deploy targets configured"
    expect_lacks "no restart without a deploy" "$CALLS_TXT" agent-service-restart

    scenario no-agent 'certificate = a.example.test'
    expect_rc "no agent in the configuration: exit 1" 1 "$RC"

    # verify: by name, wildcard coverage, address:port
    scenario verify-names 'agent = issuer-01.example.com
certificate = example.test wildcard
certificate = exact.test
target = idp idp-01.example.com /srv/idp/certs/directory 1000 pem
target = ex  idp-01.example.com /srv/ex 101
deploy = example.test idp
deploy = exact.test ex
restart = idp /srv/idp/compose.yml:/srv/idp/compose.outpost.yml worker ldap
verify = idp ldap.example.test 192.0.2.10:3636
verify = idp a.b.example.test 3636
verify = idp example.test 3636
verify = ex www.exact.test 443
verify = ex exact.test localhost:8443'
    expect_rc "verify by name: exit 0" 0 "$RC"
    expect_has "restart passes ':'-joined compose files as one argument" "$CALLS_TXT" \
        "agent-service-restart /srv/idp/compose.yml:/srv/idp/compose.outpost.yml worker ldap"
    expect_has "wildcard covers one label: address:port" "$CALLS_TXT" \
        "agent-cert-check -p 3636 -n ldap.example.test -H 192.0.2.10 -f $(cat "$J/fp")"
    expect_lacks "wildcard does not cover two labels" "$CALLS_TXT" "a.b.example.test"
    expect_has "wildcard domain itself is covered" "$CALLS_TXT" "agent-cert-check -p 3636 -n example.test -f"
    expect_lacks "exact certificate does not cover a sub-name" "$CALLS_TXT" "www.exact.test"
    expect_has "port on localhost via address:port" "$CALLS_TXT" "-p 8443 -n exact.test -H localhost"
    expect_eq "verify: three checks ran" 3 "$(count "$CALLS_TXT" agent-cert-check)"

    scenario verify-bad-address 'agent = issuer-01.example.com
certificate = example.test wildcard
target = idp idp-01.example.com /srv/a 1000 pem
deploy = example.test idp
verify = idp ldap.example.test 192.0.2.10:
verify = idp ldap.example.test [::1]:3636
verify = idp ldap.example.test notaport'
    expect_rc "bad verify addresses: exit 1" 1 "$RC"
    expect_eq "each bad verify line is logged" 3 "$(count "$LOG_TXT" 'bad verify line')"
    expect_eq "no check ran for a bad verify line" 0 "$(count "$CALLS_TXT" agent-cert-check)"

    scenario verify-unknown-target 'agent = issuer-01.example.com
certificate = a.example.test
target = web web-01.example.com /srv/web/certs 101
deploy = a.example.test web
verify = web-01.example.com a.example.test 443'
    expect_rc "verify for an unknown target: exit 1" 1 "$RC"

    scenario verify-other-target 'agent = issuer-01.example.com
certificate = a.example.test
target = web  web-01.example.com /srv/web/certs 101
target = ldap web-01.example.com /srv/ldap 1000 pem
deploy = a.example.test web
verify = ldap a.example.test 636'
    expect_rc "verify for a target that got no certificate: exit 0" 0 "$RC"
    expect_eq "…and no check ran" 0 "$(count "$CALLS_TXT" agent-cert-check)"

    VCONF='agent = issuer-01.example.com
certificate = app.example.test wildcard
certificate = other.example.test wildcard
target = web web-01.example.com /srv/certs 101
deploy = app.example.test web
restart = web /srv/app/compose.yml app
verify = web app.example.test 5222 xmpp
verify = web other.example.test 443'
    scenario verify-ok "$VCONF" "" MODE=ok
    expect_rc "verify OK: exit 0" 0 "$RC"
    expect_has "verify passes the issued fingerprint and STARTTLS protocol" "$CALLS_TXT" \
        "agent-cert-check -p 5222 -n app.example.test -f $(cat "$J/fp") -P xmpp"
    expect_eq "verify OK: one check (no retry)" 1 "$(count "$CALLS_TXT" agent-cert-check)"
    expect_has "verify OK: logged" "$LOG_TXT" "verified: app.example.test"
    scenario verify-warn "$VCONF" "" MODE=warn
    expect_rc "verify WARNING does not fail the run" 0 "$RC"
    expect_has "verify WARNING is logged" "$LOG_TXT" "verify warning"
    scenario verify-late "$VCONF" "" MODE=late
    expect_rc "verify retries while the service comes back: exit 0" 0 "$RC"
    expect_eq "verify retried until it answered" 3 "$(count "$CALLS_TXT" agent-cert-check)"
    scenario verify-fail "$VCONF" "" MODE=fail
    expect_rc "verify CRITICAL: exit 1" 1 "$RC"
    expect_eq "verify gives up after VERIFY_TRIES" 4 "$(count "$CALLS_TXT" agent-cert-check)"
    expect_has "verify failure logged" "$LOG_TXT" "verify failed: app.example.test"
    scenario no-verify "$(grep -v '^verify' <<< "$VCONF")" "" MODE=ok
    expect_rc "no verify lines: exit 0" 0 "$RC"
    expect_lacks "no verify lines: summary has no verified count" "$LOG_TXT" "verified"

    # The shipped example configuration is accepted by the job
    if [ -f "$JOBCONF_EXAMPLE" ]; then
        scenario example-conf "$(cat "$JOBCONF_EXAMPLE")"
        expect_rc "deploy-cert.conf.example runs cleanly" 0 "$RC"
        expect_has "example: named target deployed" "$CALLS_TXT" "/srv/web/certs example.com 101"
        expect_has "example: pem target deployed" "$CALLS_TXT" "/srv/idp/certs/directory example.org 1000"
        expect_has "example: two-file restart passed through" "$CALLS_TXT" \
            "/srv/idp/compose.yml:/srv/idp/compose.outpost.yml worker ldap"
    else
        fail "deploy-cert.conf.example exists"
    fi
fi

# ---------------------------------------------------------------------------
echo
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
if [ "$FAIL" -eq 0 ]; then echo "VERDICT: PASS"; else echo "VERDICT: FAIL"; fi
[ "$FAIL" -eq 0 ]
