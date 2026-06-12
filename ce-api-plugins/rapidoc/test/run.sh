#!/bin/bash
# Test suite for the RapiDoc viewer plugin. Run: bash test/run.sh
# The plugin is a single self-contained index.html. This checks the document
# structure, that it mounts the RapiDoc element and loads the library, and that
# it wires the OpenAPI spec URL (?spec= override falling back to the live spec).
set -u
DIR="$(cd "$(dirname "$0")/.." && pwd)"
HTML="$DIR/index.html"
PASS=0; FAIL=0
ok(){ if [ "$2" = "$3" ]; then echo "  PASS  $1"; PASS=$((PASS+1)); else echo "  FAIL  $1 (want $2, got $3)"; FAIL=$((FAIL+1)); fi; }
has(){ grep -qi "$1" "$HTML" && echo yes || echo no; }

echo "# Test report: rapidoc (ce-api-plugins)"
echo "Generated: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
echo

[ -s "$HTML" ] && e=yes || e=no
ok "index.html present and non-empty" yes "$e"
ok "has doctype declaration"          yes "$(has '<!doctype html>')"
ok "has <head> and <body>"            yes "$([ "$(has '<head>')" = yes ] && [ "$(has '<body>')" = yes ] && echo yes || echo no)"
ok "closes the html document"         yes "$(has '</html>')"
ok "sets a document title"            yes "$(has '<title>')"
ok "mounts the rapi-doc element"      yes "$(has '<rapi-doc')"
ok "loads the RapiDoc library"        yes "$(has 'rapidoc-min.js')"
ok "supports ?spec= override"         yes "$(has URLSearchParams)"
ok "defaults to the live spec"        yes "$(has '/openapi-live.json')"
# allow-try enabled so the docs are interactive against a running dispatcher
ok "enables try-it (allow-try)"       yes "$(has 'allow-try=\"true\"')"

echo
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && echo "VERDICT: PASS" || echo "VERDICT: FAIL"
[ "$FAIL" -eq 0 ]
