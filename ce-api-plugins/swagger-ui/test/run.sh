#!/bin/bash
# Test suite for the Swagger UI viewer plugin. Run: bash test/run.sh
# The plugin is a single self-contained index.html. This checks the document
# structure, that it mounts the Swagger UI container and loads the bundle+CSS,
# and that it wires the OpenAPI spec URL (?spec= override falling back to live).
set -u
DIR="$(cd "$(dirname "$0")/.." && pwd)"
HTML="$DIR/index.html"
PASS=0; FAIL=0
ok(){ if [ "$2" = "$3" ]; then echo "  PASS  $1"; PASS=$((PASS+1)); else echo "  FAIL  $1 (want $2, got $3)"; FAIL=$((FAIL+1)); fi; }
has(){ grep -qi "$1" "$HTML" && echo yes || echo no; }

echo "# Test report: swagger-ui (ce-api-plugins)"
echo "Generated: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
echo

[ -s "$HTML" ] && e=yes || e=no
ok "index.html present and non-empty" yes "$e"
ok "has doctype declaration"          yes "$(has '<!doctype html>')"
ok "has <head> and <body>"            yes "$([ "$(has '<head>')" = yes ] && [ "$(has '<body>')" = yes ] && echo yes || echo no)"
ok "closes the html document"         yes "$(has '</html>')"
ok "sets a document title"            yes "$(has '<title>')"
ok "mounts the swagger-ui container"  yes "$(has 'id=\"swagger-ui\"')"
ok "loads the Swagger UI bundle"      yes "$(has 'swagger-ui-bundle.js')"
ok "loads the Swagger UI stylesheet"  yes "$(has 'swagger-ui.css')"
ok "initialises SwaggerUIBundle"      yes "$(has 'SwaggerUIBundle(')"
ok "supports ?spec= override"         yes "$(has URLSearchParams)"
ok "defaults to the live spec"        yes "$(has '/openapi-live.json')"
ok "enables try-it-out"               yes "$(has 'tryItOutEnabled')"

echo
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && echo "VERDICT: PASS" || echo "VERDICT: FAIL"
[ "$FAIL" -eq 0 ]
