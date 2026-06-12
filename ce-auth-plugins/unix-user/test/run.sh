#!/bin/bash
# Test suite for the unix-user auth hook. Run: bash test/run.sh
set -u
DIR="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="$DIR/unix-user"
PASS=0; FAIL=0
ok(){ if [ "$2" = "$3" ]; then echo "  PASS  $1"; PASS=$((PASS+1)); else echo "  FAIL  $1 (want exit $2, got $3)"; FAIL=$((FAIL+1)); fi; }

echo "# Test report: unix-user (ce-auth-plugins)"
echo "Generated: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
echo

# Use 'root' (always present) and its real primary group for deterministic checks.
selfgrp="$(id -gn root 2>/dev/null || echo root)"

echo "" | "$HOOK"; ok "no username -> bad credentials" 2 $?
ENVEXEC_USERNAME=root "$HOOK"; ok "existing local user -> authorised" 0 $?
ENVEXEC_USERNAME=root UNIX_USER_GROUP="$selfgrp" "$HOOK"; ok "user in its primary group -> authorised" 0 $?
ENVEXEC_USERNAME=root UNIX_USER_GROUP=__no_such_group__ "$HOOK"; ok "user not in required group -> insufficient privilege" 3 $?
ENVEXEC_USERNAME=__no_such_user__ "$HOOK"; ok "unknown user -> bad credentials" 2 $?

echo
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && echo "VERDICT: PASS" || echo "VERDICT: FAIL"
[ "$FAIL" -eq 0 ]
