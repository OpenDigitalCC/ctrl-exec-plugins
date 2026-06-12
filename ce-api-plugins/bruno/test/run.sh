#!/bin/bash
# Test suite for the Bruno collection plugin. Run: bash test/run.sh
# Bruno stores one .bru file per request plus a JSON manifest. This checks the
# manifest parses, every ctrl-exec endpoint has its .bru file, the Local
# environment declares the expected variables, and the async run is wired to
# set async:true and capture the returned reqid.
set -u
DIR="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0; FAIL=0
ok(){ if [ "$2" = "$3" ]; then echo "  PASS  $1"; PASS=$((PASS+1)); else echo "  FAIL  $1 (want $2, got $3)"; FAIL=$((FAIL+1)); fi; }
has(){ grep -q "$1" "$2" 2>/dev/null && echo yes || echo no; }

echo "# Test report: bruno (ce-api-plugins)"
echo "Generated: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
echo

# Manifest parses as JSON.
if command -v python3 >/dev/null 2>&1; then
  python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$DIR/bruno.json" 2>/dev/null
  ok "bruno.json manifest parses" 0 $?
else
  echo "  SKIP  python3 unavailable - manifest JSON parse skipped"
fi

# One .bru per endpoint.
for r in "Health" "Ping" "Discovery" "Run (sync)" "Run (async)" "Status"; do
  [ -f "$DIR/$r.bru" ] && r2=yes || r2=no
  ok "request file '$r.bru' present" yes "$r2"
done

# Local environment declares the variables.
ENVF="$DIR/environments/Local.bru"
[ -f "$ENVF" ] && e=yes || e=no
ok "environments/Local.bru present" yes "$e"
for v in baseUrl host script token reqid; do
  ok "env var '$v' declared" yes "$(has "$v:" "$ENVF")"
done

# Async run wiring.
ASYNC="$DIR/Run (async).bru"
ok "async run sets async:true" yes "$(has '\"async\": true' "$ASYNC")"
ok "async run captures reqid" yes "$(has 'setEnvVar(\"reqid\"' "$ASYNC")"

echo
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && echo "VERDICT: PASS" || echo "VERDICT: FAIL"
[ "$FAIL" -eq 0 ]
