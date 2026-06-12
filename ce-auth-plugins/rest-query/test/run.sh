#!/bin/bash
# Test suite for the rest-query auth hook. Run: bash test/run.sh
# Covers the deterministic fail-closed paths, plus the HTTP-status -> exit-code
# mapping against a local mock endpoint (skipped if python3 is unavailable).
set -u
DIR="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="$DIR/rest-query"
PASS=0; FAIL=0
ok(){ if [ "$2" = "$3" ]; then echo "  PASS  $1"; PASS=$((PASS+1)); else echo "  FAIL  $1 (want exit $2, got $3)"; FAIL=$((FAIL+1)); fi; }

echo "# Test report: rest-query (ce-auth-plugins)"
echo "Generated: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
echo

echo "" | "$HOOK"; ok "no endpoint configured -> deny (fail closed)" 1 $?
echo '{"action":"ping"}' | REST_QUERY_URL= "$HOOK"; ok "empty endpoint URL -> deny (fail closed)" 1 $?

if command -v python3 >/dev/null 2>&1 && command -v curl >/dev/null 2>&1; then
  port=$(( (RANDOM % 2000) + 8000 ))
  # Mock that returns the HTTP status named in the request path (/200, /401, ...).
  python3 - "$port" >/dev/null 2>&1 <<'PY' &
import sys, http.server
class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        p = self.path.strip('/')
        code = int(p) if p.isdigit() else 200
        self.rfile.read(int(self.headers.get('content-length', 0)))
        self.send_response(code); self.end_headers()
    def log_message(self, *a): pass
http.server.HTTPServer(('127.0.0.1', int(sys.argv[1])), H).serve_forever()
PY
  mock=$!
  for _ in $(seq 1 50); do curl -s -o /dev/null -X POST -d '{}' "http://127.0.0.1:$port/200" 2>/dev/null && break; done
  echo '{}' | REST_QUERY_URL="http://127.0.0.1:$port/200" "$HOOK"; ok "endpoint 200 -> authorised" 0 $?
  echo '{}' | REST_QUERY_URL="http://127.0.0.1:$port/401" "$HOOK"; ok "endpoint 401 -> bad credentials" 2 $?
  echo '{}' | REST_QUERY_URL="http://127.0.0.1:$port/403" "$HOOK"; ok "endpoint 403 -> insufficient privilege" 3 $?
  echo '{}' | REST_QUERY_URL="http://127.0.0.1:$port/500" "$HOOK"; ok "endpoint 500 -> deny" 1 $?
  echo '{}' | REST_QUERY_URL="http://127.0.0.1:1/x" REST_QUERY_TIMEOUT=2 "$HOOK"; ok "unreachable endpoint -> deny" 1 $?
  kill "$mock" 2>/dev/null; wait "$mock" 2>/dev/null
else
  echo "  SKIP  python3/curl unavailable - HTTP status-mapping checks skipped"
fi

echo
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && echo "VERDICT: PASS" || echo "VERDICT: FAIL"
[ "$FAIL" -eq 0 ]
