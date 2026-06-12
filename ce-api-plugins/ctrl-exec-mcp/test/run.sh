#!/bin/bash
# Test suite for ctrl-exec-mcp. Run: bash test/run.sh
# Runs the plugin's Perl unit suite under t/ with prove.
set -u
DIR="$(cd "$(dirname "$0")/.." && pwd)"

echo "# Test report: ctrl-exec-mcp (ce-api-plugins)"
echo "Generated: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
echo

out="$(cd "$DIR" && prove -Ilib t/ 2>&1)"; rc=$?
echo "$out"
echo
[ "$rc" -eq 0 ] && echo "VERDICT: PASS" || echo "VERDICT: FAIL"
exit "$rc"
