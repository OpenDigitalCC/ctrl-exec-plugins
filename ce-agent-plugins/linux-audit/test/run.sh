#!/bin/bash
# Test suite for the linux-audit agent script. Run: bash test/run.sh
# Covers the no-args/unknown-subcommand contract (validate-plugin requires a
# nonzero exit on no args), schema<->dispatcher consistency, and a live run of
# each read-only subcommand whose underlying tool is present.
set -u
DIR="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$DIR/linux-audit.sh"
SCHEMA="$DIR/linux-audit.sh.schema.json"
PASS=0; FAIL=0
ok(){ if [ "$2" = "$3" ]; then echo "  PASS  $1"; PASS=$((PASS+1)); else echo "  FAIL  $1 (want $2, got $3)"; FAIL=$((FAIL+1)); fi; }

echo "# Test report: linux-audit (ce-agent-plugins)"
echo "Generated: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
echo

# --- contract: no args / unknown subcommand exit nonzero -------------------
"$SCRIPT" </dev/null >/dev/null 2>&1; [ $? -ne 0 ] && r=nonzero || r=zero
ok "no subcommand -> nonzero exit (usage)" nonzero "$r"
"$SCRIPT" __no_such_subcommand__ </dev/null >/dev/null 2>&1; [ $? -ne 0 ] && r=nonzero || r=zero
ok "unknown subcommand -> nonzero exit (usage)" nonzero "$r"

# --- schema <-> dispatcher consistency -------------------------------------
# Every enum value in the sidecar must have a matching case label, and vice versa.
if command -v python3 >/dev/null 2>&1; then
  drift="$(python3 - "$SCHEMA" "$SCRIPT" <<'PY'
import json, re, sys
schema = json.load(open(sys.argv[1]))
enum = set(schema["arguments"]["properties"]["subcommand"]["enum"])
src = open(sys.argv[2]).read()
# case labels look like:  logins)  cmd_logins ;;
labels = set(re.findall(r'^\s*([a-z][a-z-]+)\)\s+cmd_', src, re.M))
missing = enum - labels      # advertised but not dispatched
extra   = labels - enum      # dispatched but not advertised
print(",".join(sorted(missing)) + "|" + ",".join(sorted(extra)))
PY
)"
  ok "schema enum subcommands all dispatched" "|" "$drift"
else
  echo "  SKIP  python3 unavailable - schema/dispatcher consistency check skipped"
fi

# --- live read-only runs (skipped where the tool is absent) ----------------
try_sub() {
  local sub="$1" need="$2"
  if [ -n "$need" ] && ! command -v "$need" >/dev/null 2>&1; then
    echo "  SKIP  subcommand '$sub' ($need not installed)"; return
  fi
  "$SCRIPT" "$sub" </dev/null >/dev/null 2>&1
  ok "subcommand '$sub' -> exit 0" 0 $?
}
try_sub disk    df
try_sub memory  free
try_sub ports   ss

echo
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && echo "VERDICT: PASS" || echo "VERDICT: FAIL"
[ "$FAIL" -eq 0 ]
