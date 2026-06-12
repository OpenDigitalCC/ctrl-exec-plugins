#!/bin/bash
# Test suite for the text-file auth hook. Run: bash test/run.sh
# Exercises the exit-code contract (0 ok / 1 fail-closed / 2 bad creds).
set -u
DIR="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="$DIR/text-file"
PASS=0; FAIL=0
ok(){ if [ "$2" = "$3" ]; then echo "  PASS  $1"; PASS=$((PASS+1)); else echo "  FAIL  $1 (want exit $2, got $3)"; FAIL=$((FAIL+1)); fi; }

echo "# Test report: text-file (ce-auth-plugins)"
echo "Generated: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
echo

reg="$(mktemp)"; printf '%s\n' '# comment' 'alice:s3cr3t' 'bob:hunter2' > "$reg"

echo "" | "$HOOK"; ok "empty stdin, no credentials -> bad credentials" 2 $?
ENVEXEC_USERNAME=alice ENVEXEC_TOKEN=s3cr3t TEXT_FILE_AUTH="$reg" "$HOOK"; ok "valid username:token -> authorised" 0 $?
ENVEXEC_USERNAME=alice ENVEXEC_TOKEN=wrong  TEXT_FILE_AUTH="$reg" "$HOOK"; ok "wrong token -> bad credentials" 2 $?
ENVEXEC_USERNAME=carol ENVEXEC_TOKEN=x      TEXT_FILE_AUTH="$reg" "$HOOK"; ok "unknown user -> bad credentials" 2 $?
ENVEXEC_USERNAME=alice ENVEXEC_TOKEN=""     TEXT_FILE_AUTH="$reg" "$HOOK"; ok "empty token -> bad credentials" 2 $?
ENVEXEC_USERNAME=alice ENVEXEC_TOKEN=s3cr3t TEXT_FILE_AUTH=/no/such/file "$HOOK"; ok "missing file -> deny (fail closed)" 1 $?

rm -f "$reg"
echo
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && echo "VERDICT: PASS" || echo "VERDICT: FAIL"
[ "$FAIL" -eq 0 ]
