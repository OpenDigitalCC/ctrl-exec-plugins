#!/bin/bash
# Test suite for the htpasswd auth hook. Run: bash test/run.sh
set -u
DIR="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="$DIR/htpasswd"
PASS=0; FAIL=0
ok(){ if [ "$2" = "$3" ]; then echo "  PASS  $1"; PASS=$((PASS+1)); else echo "  FAIL  $1 (want exit $2, got $3)"; FAIL=$((FAIL+1)); fi; }

echo "# Test report: htpasswd (ce-auth-plugins)"
echo "Generated: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
echo

echo "" | "$HOOK"; ok "no credentials -> bad credentials" 2 $?

if command -v htpasswd >/dev/null 2>&1; then
  hf="$(mktemp)"; htpasswd -cbB "$hf" alice s3cr3t >/dev/null 2>&1
  ENVEXEC_USERNAME=alice ENVEXEC_TOKEN=s3cr3t HTPASSWD_FILE="$hf" "$HOOK"; ok "valid user + password -> authorised" 0 $?
  ENVEXEC_USERNAME=alice ENVEXEC_TOKEN=wrong  HTPASSWD_FILE="$hf" "$HOOK"; ok "wrong password -> bad credentials" 2 $?
  ENVEXEC_USERNAME=bob   ENVEXEC_TOKEN=x       HTPASSWD_FILE="$hf" "$HOOK"; ok "unknown user -> bad credentials" 2 $?
  rm -f "$hf"
else
  echo "  SKIP  htpasswd(1) not installed (apache2-utils) - hash-verification checks skipped"
fi

ENVEXEC_USERNAME=alice ENVEXEC_TOKEN=s3cr3t HTPASSWD_FILE=/no/such/file "$HOOK"; ok "missing file -> deny (fail closed)" 1 $?

echo
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && echo "VERDICT: PASS" || echo "VERDICT: FAIL"
[ "$FAIL" -eq 0 ]
