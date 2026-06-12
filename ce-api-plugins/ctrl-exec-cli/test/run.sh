#!/bin/bash
# Test suite for ctrl-exec-cli. Run: bash test/run.sh
# Runs the Perl unit tests under test/ with prove.
set -u
DIR="$(cd "$(dirname "$0")/.." && pwd)"

echo "# Test report: ctrl-exec-cli (ce-api-plugins)"
echo "Generated: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
echo

out="$(cd "$DIR" && prove test/ 2>&1)"; rc=$?
echo "$out"
echo
[ "$rc" -eq 0 ] && echo "VERDICT: PASS" || echo "VERDICT: FAIL"
exit "$rc"
