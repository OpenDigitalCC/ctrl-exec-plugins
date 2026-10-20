#!/bin/bash
# Test suite for agent-file-transfer. Run: bash test/run.sh
# Exercises the agent-file-receive.sh argument-validation contract (all the
# deterministic exit-2 paths that fire before any listener is opened), the
# schema<->argv flag consistency, and a no-args usage smoke for the two
# coordinator CLIs. No network listener is opened.
set -u
DIR="$(cd "$(dirname "$0")/.." && pwd)"
RECV="$DIR/agent-file-receive.sh"
SCHEMA="$DIR/agent-file-receive.sh.schema.json"
PASS=0; FAIL=0
ok(){ if [ "$2" = "$3" ]; then echo "  PASS  $1"; PASS=$((PASS+1)); else echo "  FAIL  $1 (want $2, got $3)"; FAIL=$((FAIL+1)); fi; }

echo "# Test report: agent-file-transfer (ce-agent-plugins)"
echo "Generated: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
echo

# --- agent-file-receive.sh: argument-validation contract (exit 2) ----------
"$RECV" </dev/null >/dev/null 2>&1;                              ok "no args -> exit 2 (--port required)"        2 $?
"$RECV" --port 9000 </dev/null >/dev/null 2>&1;                  ok "missing --output -> exit 2"                 2 $?
"$RECV" --port abc --output /tmp/x </dev/null >/dev/null 2>&1;   ok "non-numeric --port -> exit 2"               2 $?
"$RECV" --port 9000 --output /tmp/x --timeout abc </dev/null >/dev/null 2>&1; ok "non-numeric --timeout -> exit 2" 2 $?
"$RECV" --bogus </dev/null >/dev/null 2>&1;                      ok "unknown argument -> exit 2 (usage)"         2 $?

# --- schema <-> argv flag consistency --------------------------------------
if command -v python3 >/dev/null 2>&1; then
  drift="$(python3 - "$SCHEMA" "$RECV" <<'PY'
import json, re, sys
schema = json.load(open(sys.argv[1]))
props = set(schema["arguments"]["properties"])
flags = {a["arg"]: a.get("flag") for a in schema["argv"]}
src = open(sys.argv[2]).read()
case_flags = set(re.findall(r'^\s*(--[a-z]+)\)', src, re.M))
problems = []
for arg, flag in flags.items():
    if arg not in props:            problems.append(f"{arg}:not-in-properties")
    if flag and flag not in case_flags: problems.append(f"{flag}:not-parsed")
print(",".join(sorted(problems)))
PY
)"
  ok "every schema argv flag is declared and parsed" "" "$drift"
  dest="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("destructive"))' "$SCHEMA")"
  ok "schema marks the receiver destructive" "True" "$dest"
else
  echo "  SKIP  python3 unavailable - schema consistency checks skipped"
fi

# --- coordinator CLIs: no-args usage smoke ---------------------------------
for c in ce-file-transfer ce-push-blob; do
  "$DIR/$c" </dev/null >/dev/null 2>&1; ok "$c no args -> nonzero (usage)" nonzero "$([ $? -ne 0 ] && echo nonzero || echo zero)"
done

# --- status polls carry the token (auth-checking stub API) -----------------
# test/stub-api.py answers GET /status with 404 unless Authorization: Bearer
# <token> matches, as the real API does when the auth hook refuses the token.
if command -v python3 >/dev/null 2>&1 && command -v curl >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
  W="$(mktemp -d)"; trap 'kill "${STUB:-}" 2>/dev/null; rm -rf "$W"' EXIT
  python3 "$DIR/test/stub-api.py" sekrit "$W/port" "$W/log" & STUB=$!
  for _ in $(seq 1 100); do [ -s "$W/port" ] && break; sleep 0.1; done
  API="http://127.0.0.1:$(cat "$W/port" 2>/dev/null)"
  : > "$W/log"
  out="$(CTRL_EXEC_API_URL=$API CTRL_EXEC_TOKEN=sekrit timeout 15 "$DIR/ce-push-blob" \
      --host h --file "$DIR/test/run.sh" --output /x --port 1 2>&1)"
  case "$out" in *"Agent receiver ready. Fingerprint: AA:BB:CC"*) r=ready;; *) r=stalled;; esac
  ok "ce-push-blob fingerprint poll sends the Bearer token" ready "$r"
  : > "$W/log"
  out="$(CTRL_EXEC_API_URL=$API CTRL_EXEC_TOKEN=sekrit timeout 15 "$DIR/ce-file-transfer" \
      --from a --to b --path /p --output /o --port 1 2>&1)"
  case "$out" in *"Transfer complete"*"Recvd:   5 bytes"*) r=complete;; *) r=stalled;; esac
  ok "ce-file-transfer polls send the Bearer token (completes)" complete "$r"
  bare="$(grep -c 'auth=\[\]' "$W/log" || true)"
  ok "ce-file-transfer sends no tokenless status poll" 0 "$bare"
  kill "$STUB" 2>/dev/null; wait "$STUB" 2>/dev/null
else
  echo "  SKIP  python3/curl/jq unavailable - status-token checks skipped"
fi

echo
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && echo "VERDICT: PASS" || echo "VERDICT: FAIL"
[ "$FAIL" -eq 0 ]
