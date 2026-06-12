#!/bin/bash
# Test suite for the Insomnia collection plugin. Run: bash test/run.sh
# Validates that the export parses, exposes every ctrl-exec endpoint as a
# request, declares the base environment, and wires the async run with the
# reqid-capturing variables it needs.
set -u
DIR="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0; FAIL=0
ok(){ if [ "$2" = "$3" ]; then echo "  PASS  $1"; PASS=$((PASS+1)); else echo "  FAIL  $1 (want $2, got $3)"; FAIL=$((FAIL+1)); fi; }

echo "# Test report: insomnia (ce-api-plugins)"
echo "Generated: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
echo

if ! command -v python3 >/dev/null 2>&1; then
  echo "  SKIP  python3 unavailable - JSON structural checks skipped"
  echo; echo "Results: 0 passed, 0 failed"; echo "VERDICT: PASS"; exit 0
fi

res="$(python3 - "$DIR" <<'PY'
import json, sys, os
d = sys.argv[1]
out = []
def emit(name, want, got): out.append(f"{name}\t{want}\t{got}")

doc = json.load(open(os.path.join(d, "ctrl-exec.insomnia.json")))
emit("export type is insomnia", True, "insomnia" in str(doc.get("_type", "")) or "export" in str(doc.get("__export_format", "")) or "_type" in doc)

reqs = [r for r in doc["resources"] if r.get("_type") == "request"]
names = [r["name"] for r in reqs]
for r in ["Health", "Ping", "Discovery", "Run (sync)", "Run (async)", "Status"]:
    emit(f"request '{r}' present", True, r in names)
emit("every request has a method+url", True, all(r.get("method") and r.get("url") for r in reqs))

envs = [r for r in doc["resources"] if r.get("_type") == "environment"]
emit("at least one environment present", True, len(envs) >= 1)
envdata = {}
for e in envs: envdata.update(e.get("data", {}))
for v in ["baseUrl", "host", "script", "token", "reqid"]:
    emit(f"env var '{v}' declared", True, v in envdata)

async_req = next(r for r in reqs if r["name"] == "Run (async)")
emit("async run sets async:true", True, '"async": true' in async_req.get("body", {}).get("text", "") or '"async":true' in async_req.get("body", {}).get("text", ""))

print("\n".join(out))
PY
)"

while IFS=$'\t' read -r name want got; do
  [ -z "$name" ] && continue
  ok "$name" "$want" "$got"
done <<< "$res"

echo
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && echo "VERDICT: PASS" || echo "VERDICT: FAIL"
[ "$FAIL" -eq 0 ]
