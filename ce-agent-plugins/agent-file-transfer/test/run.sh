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

echo
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && echo "VERDICT: PASS" || echo "VERDICT: FAIL"
[ "$FAIL" -eq 0 ]
