#!/bin/bash
# Test suite for the ReDoc viewer plugin. Run: bash test/run.sh
# The plugin is a single self-contained index.html. This checks the document
# structure, that it mounts the ReDoc container and loads the standalone bundle,
# and that it wires the OpenAPI spec URL (?spec= override falling back to the
# static spec).
set -u
DIR="$(cd "$(dirname "$0")/.." && pwd)"
HTML="$DIR/index.html"
PASS=0; FAIL=0
ok(){ if [ "$2" = "$3" ]; then echo "  PASS  $1"; PASS=$((PASS+1)); else echo "  FAIL  $1 (want $2, got $3)"; FAIL=$((FAIL+1)); fi; }
has(){ grep -qi "$1" "$HTML" && echo yes || echo no; }

echo "# Test report: redoc (ce-api-plugins)"
echo "Generated: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
echo

[ -s "$HTML" ] && e=yes || e=no
ok "index.html present and non-empty" yes "$e"
ok "has doctype declaration"          yes "$(has '<!doctype html>')"
ok "has <head> and <body>"            yes "$([ "$(has '<head>')" = yes ] && [ "$(has '<body>')" = yes ] && echo yes || echo no)"
ok "closes the html document"         yes "$(has '</html>')"
ok "sets a document title"            yes "$(has '<title>')"
ok "mounts the redoc container"       yes "$(has 'id=\"redoc\"')"
ok "loads the ReDoc standalone bundle" yes "$(has 'redoc.standalone.js')"
ok "initialises Redoc.init"           yes "$(has 'Redoc.init(')"
ok "supports ?spec= override"         yes "$(has URLSearchParams)"
ok "defaults to a spec URL"           yes "$(has '/openapi')"

echo
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && echo "VERDICT: PASS" || echo "VERDICT: FAIL"
[ "$FAIL" -eq 0 ]
