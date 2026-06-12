#!/bin/bash
# Test suite for the api-key-registry auth hook. Run: bash test/run.sh
set -u
DIR="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="$DIR/api-key-registry"
PASS=0; FAIL=0
ok(){ if [ "$2" = "$3" ]; then echo "  PASS  $1"; PASS=$((PASS+1)); else echo "  FAIL  $1 (want exit $2, got $3)"; FAIL=$((FAIL+1)); fi; }

echo "# Test report: api-key-registry (ce-auth-plugins)"
echo "Generated: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
echo

reg="$(mktemp)"; printf '%s\n' '# keys' 'k_ci:ci-runner:run' 'k_dash:dashboard:ping' > "$reg"

echo "" | "$HOOK"; ok "no token -> bad credentials" 2 $?
ENVEXEC_TOKEN=k_ci   ENVEXEC_ACTION=run       API_KEY_REGISTRY="$reg" "$HOOK"; ok "run-level key, run action -> authorised" 0 $?
ENVEXEC_TOKEN=k_dash ENVEXEC_ACTION=discovery API_KEY_REGISTRY="$reg" "$HOOK"; ok "ping-level key, discovery action -> authorised" 0 $?
ENVEXEC_TOKEN=k_dash ENVEXEC_ACTION=run       API_KEY_REGISTRY="$reg" "$HOOK"; ok "ping-level key, run action -> insufficient privilege" 3 $?
ENVEXEC_TOKEN=nope   ENVEXEC_ACTION=run       API_KEY_REGISTRY="$reg" "$HOOK"; ok "unknown key -> bad credentials" 2 $?
ENVEXEC_TOKEN=k_ci   ENVEXEC_ACTION=run       API_KEY_REGISTRY=/no/such/file "$HOOK"; ok "missing registry -> deny (fail closed)" 1 $?

rm -f "$reg"
echo
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && echo "VERDICT: PASS" || echo "VERDICT: FAIL"
[ "$FAIL" -eq 0 ]
