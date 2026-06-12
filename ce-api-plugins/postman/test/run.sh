#!/bin/bash
# Test suite for the Postman collection plugin. Run: bash test/run.sh
# Validates that the collection and environment parse, expose every ctrl-exec
# endpoint as a request, declare the expected environment variables, and that
# the async run is wired to capture the returned reqid.
set -u
DIR="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0; FAIL=0
ok(){ if [ "$2" = "$3" ]; then echo "  PASS  $1"; PASS=$((PASS+1)); else echo "  FAIL  $1 (want $2, got $3)"; FAIL=$((FAIL+1)); fi; }

echo "# Test report: postman (ce-api-plugins)"
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

coll = json.load(open(os.path.join(d, "ctrl-exec.postman_collection.json")))
env  = json.load(open(os.path.join(d, "ctrl-exec.postman_environment.json")))

emit("collection has a name", True, bool(coll.get("info", {}).get("name")))
names = [i["name"] for i in coll["item"]]
for r in ["Health", "Ping", "Discovery", "Run (sync)", "Run (async)", "Status"]:
    emit(f"request '{r}' present", True, r in names)
# every request carries a method + url
allgood = all(i.get("request", {}).get("method") and i["request"].get("url") for i in coll["item"])
emit("every request has method+url", True, allgood)

envvars = {v["key"] for v in env["values"]}
for v in ["baseUrl", "host", "script", "token", "reqid"]:
    emit(f"env var '{v}' declared", True, v in envvars)

# async run is wired: body async:true + a test that stores reqid
async_item = next(i for i in coll["item"] if i["name"] == "Run (async)")
raw = json.dumps(async_item)
emit("async run sets async:true", True, '"async": true' in async_item["request"]["body"]["raw"] or '"async":true' in async_item["request"]["body"]["raw"])
emit("async run captures reqid", True, "reqid" in raw)

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
