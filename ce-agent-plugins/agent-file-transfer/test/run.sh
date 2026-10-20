#!/bin/bash
# Test suite for agent-file-transfer. Run: bash test/run.sh
# Exercises the agent-file-receive.sh argument-validation contract, the
# schema<->argv flag consistency, a no-args usage smoke for the two
# coordinator CLIs, the detached receiver on loopback (returns at once, its
# listener is detached, --status reports pending / received / timedout), and
# end-to-end pushes through test/stub-api.py (a token-checking stand-in for
# the ctrl-exec API that runs the real receiver). Loopback ports only.
set -u
DIR="$(cd "$(dirname "$0")/.." && pwd)"
RECV="$DIR/agent-file-receive.sh"
SCHEMA="$DIR/agent-file-receive.sh.schema.json"
PASS=0; FAIL=0
ok(){ if [ "$2" = "$3" ]; then echo "  PASS  $1"; PASS=$((PASS+1)); else echo "  FAIL  $1 (want $2, got $3)"; FAIL=$((FAIL+1)); fi; }

echo "# Test report: agent-file-transfer (ce-agent-plugins)"
echo "Generated: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
echo

# --- agent-file-receive.sh: argument-validation contract (exit 2) ----------
"$RECV" </dev/null >/dev/null 2>&1;                              ok "no args -> exit 2 (--port required)"        2 $?
"$RECV" --port 9000 </dev/null >/dev/null 2>&1;                  ok "missing --output -> exit 2"                 2 $?
"$RECV" --port abc --output /tmp/x </dev/null >/dev/null 2>&1;   ok "non-numeric --port -> exit 2"               2 $?
"$RECV" --port 9000 --output /tmp/x --timeout abc </dev/null >/dev/null 2>&1; ok "non-numeric --timeout -> exit 2" 2 $?
"$RECV" --bogus </dev/null >/dev/null 2>&1;                      ok "unknown argument -> exit 2 (usage)"         2 $?
"$RECV" --status abcd1234 </dev/null >/dev/null 2>&1;            ok "--status without --output -> exit 2"        2 $?
"$RECV" --status NOT-HEX --output /tmp/x </dev/null >/dev/null 2>&1; ok "--status with a non-hex id -> exit 2"   2 $?
"$RECV" --status abcd1234 --output /nonexistent-dir/x </dev/null >/dev/null 2>&1; ok "--status unknown transfer -> exit 1" 1 $?

# --- schema <-> argv flag consistency --------------------------------------
if command -v python3 >/dev/null 2>&1; then
  drift="$(python3 - "$SCHEMA" "$RECV" <<'PY'
import json, re, sys
schema = json.load(open(sys.argv[1]))
props = set(schema["arguments"]["properties"])
flags = {a["arg"]: a.get("flag") for a in schema["argv"]}
src = open(sys.argv[2]).read()
case_flags = set(re.findall(r'^\s*(--[a-z]+)\)', src, re.M))
problems = []
for arg, flag in flags.items():
    if arg not in props:            problems.append(f"{arg}:not-in-properties")
    if flag and flag not in case_flags: problems.append(f"{flag}:not-parsed")
print(",".join(sorted(problems)))
PY
)"
  ok "every schema argv flag is declared and parsed" "" "$drift"
  dest="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("destructive"))' "$SCHEMA")"
  ok "schema marks the receiver destructive" "True" "$dest"
else
  echo "  SKIP  python3 unavailable - schema consistency checks skipped"
fi

# --- coordinator CLIs: no-args usage smoke ---------------------------------
for c in ce-file-transfer ce-push-blob; do
  "$DIR/$c" </dev/null >/dev/null 2>&1; ok "$c no args -> nonzero (usage)" nonzero "$([ $? -ne 0 ] && echo nonzero || echo zero)"
done


# --- helpers for the live tests ---------------------------------------------
have_all=1
for c in python3 curl jq openssl ss setsid tar sha256sum; do
  command -v "$c" >/dev/null 2>&1 || { have_all=0; echo "  SKIP  $c unavailable - live receiver and push tests skipped"; break; }
done

now_ms(){ echo $(( $(date +%s%N) / 1000000 )); }
freeport(){ python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1])'; }
# status_of <id> <output>: print the --status stdout
status_of(){ "$RECV" --status "$1" --output "$2" 2>/dev/null; }
# await_state <id> <output> <seconds>: poll until the status is not pending
await_state(){
  local end=$(( $(now_ms) + $3 * 1000 )) o
  while :; do
    o="$(status_of "$1" "$2")"
    [ "$o" != "pending" ] && { echo "$o"; return; }
    [ "$(now_ms)" -gt "$end" ] && { echo "$o"; return; }
    sleep 0.1
  done
}
field(){ sed -n "s/^$1://p" | head -1; }

if [ "$have_all" = 1 ]; then
  W="$(mktemp -d)"
  trap 'kill "${STUB:-}" 2>/dev/null; pkill -u "$(id -u)" -f "openssl s_server .*-port ($PORTS)" 2>/dev/null; rm -rf "$W"' EXIT
  PORTS=0
  mkdir "$W/payload"; echo "hello $$" > "$W/payload/f.txt"
  tar -czf "$W/a.tar.gz" -C "$W/payload" f.txt
  ASIZE="$(stat -c %s "$W/a.tar.gz")"; ASHA="$(sha256sum "$W/a.tar.gz" | cut -d' ' -f1)"

  # --- receiver: returns at once, listener detached -------------------------
  P="$(freeport)"; PORTS="$P"; O="$W/r1/in.tar.gz"
  t0="$(now_ms)"
  out="$(timeout 30 "$RECV" --port "$P" --output "$O" --timeout 60 </dev/null 2>"$W/r1.err")"; rc=$?
  t1="$(now_ms)"
  ok "receiver exits 0 once the listener is up" 0 "$rc"
  # the substitution above only returns when no process holds its stdout, so
  # a listener that kept the fds would have run it for the whole --timeout
  [ $(( t1 - t0 )) -lt 10000 ] && r=fast || r="slow ($(( t1 - t0 )) ms)"
  ok "receiver returns at once, not after --timeout" fast "$r"
  FP="$(echo "$out" | field fingerprint)"; ID="$(echo "$out" | field id)"
  case "$FP" in [0-9A-F]*) [ "${#FP}" = 64 ] && r=ok || r=bad;; *) r=bad;; esac
  ok "stdout carries a 64-hex fingerprint:" ok "$r"
  case "$ID" in *[!0-9a-f]*|"") r=bad;; *) r=ok;; esac
  ok "stdout carries a hex id:" ok "$r"
  SPID="$(pgrep -f "^openssl s_server .*-port $P " | head -1)"
  [ -n "$SPID" ] && r=running || r=gone
  ok "listener still running after the receiver exited" running "$r"
  bad=''
  for fd in 1 2; do
    l="$(readlink "/proc/$SPID/fd/$fd" 2>/dev/null)"
    case "$l" in pipe:*|socket:*) bad="$bad fd$fd=$l";; esac
  done
  ok "listener holds no pipe on stdout/stderr" "" "$bad"
  [ "$(ps -o sid= -p "$SPID" | tr -d ' ')" != "$(ps -o sid= -p $$ | tr -d ' ')" ] && r=own || r=same
  ok "listener runs in its own session" own "$r"
  CERTDIR="$(tr '\0' ' ' < "/proc/$SPID/cmdline" | sed -n 's/.*-cert \(.*\)\/recv\.crt.*/\1/p')"
  [ -f "$CERTDIR/recv.key" ] && r=present || r=missing
  ok "throwaway cert exists while listening" present "$r"
  ok "--status reports pending before the transfer" pending "$(status_of "$ID" "$O")"
  ok "a fingerprint probe does not end the transfer" pending \
     "$(timeout 10 openssl s_client -connect "127.0.0.1:$P" -no_ign_eof </dev/null >/dev/null 2>&1; await_state "$ID" "$O" 0)"
  openssl s_client -connect "127.0.0.1:$P" -quiet -no_ign_eof -nocommands < "$W/a.tar.gz" >/dev/null 2>&1
  st="$(await_state "$ID" "$O" 20)"
  ok "--status reports received:<bytes> after the transfer" "received:$ASIZE" "$(echo "$st" | head -1)"
  ok "--status reports the sha256" "$ASHA" "$(echo "$st" | field sha256)"
  cmp -s "$W/a.tar.gz" "$O" && r=same || r=differs
  ok "received file is identical to the sent file" same "$r"
  [ -d "$CERTDIR" ] && r=left || r=removed
  ok "listener removed its throwaway cert" removed "$r"
  kill -0 "$SPID" 2>/dev/null && r=running || r=exited
  ok "listener exits after the transfer" exited "$r"
  ls "$W"/r1/in.tar.gz.failed.* >/dev/null 2>&1 && r=present || r=none
  ok "no .failed file after a good transfer" none "$r"

  # --- receiver: timeout -----------------------------------------------------
  P="$(freeport)"; PORTS="$PORTS|$P"; O="$W/r2/in.tar.gz"
  out="$(timeout 30 "$RECV" --port "$P" --output "$O" --timeout 2 </dev/null 2>/dev/null)"
  ID="$(echo "$out" | field id)"
  st="$(await_state "$ID" "$O" 30)"
  case "$st" in timedout:*) r=timedout;; *) r="$st";; esac
  ok "--status reports timedout when no sender connects" timedout "$r"
  "$RECV" --status "$ID" --output "$O" >/dev/null 2>&1; ok "--status exits 1 for timedout" 1 $?
  ls "$W"/r2/in.tar.gz* >/dev/null 2>&1 && r=left || r=none
  ok "timed-out listener leaves no output or .failed file" none "$r"

  # --- receiver: a bad archive is reported failed ---------------------------
  P="$(freeport)"; PORTS="$PORTS|$P"; O="$W/r3/in.tar.gz"
  out="$(timeout 30 "$RECV" --port "$P" --output "$O" --timeout 60 </dev/null 2>/dev/null)"
  ID="$(echo "$out" | field id)"
  echo "not an archive" | openssl s_client -connect "127.0.0.1:$P" -quiet -no_ign_eof -nocommands >/dev/null 2>&1
  st="$(await_state "$ID" "$O" 20)"
  case "$st" in failed:*) r=failed;; *) r="$st";; esac
  ok "--status reports failed for a non-archive" failed "$r"
  ls "$W"/r3/in.tar.gz.failed.* >/dev/null 2>&1 && r=kept || r=missing
  ok "failed transfer keeps its data as .failed.<epoch>" kept "$r"

  # --- receiver: unwritable output directory fails clearly ------------------
  mkdir "$W/ro"; chmod 555 "$W/ro"
  if [ "$(id -u)" != 0 ]; then
    P="$(freeport)"
    "$RECV" --port "$P" --output "$W/ro/in.tar.gz" </dev/null >/dev/null 2>"$W/ro.err"; rc=$?
    ok "unwritable output directory -> exit 1" 1 "$rc"
    grep -q 'writable' "$W/ro.err" && r=named || r=silent
    ok "the error names the writable requirement" named "$r"
  fi

  # --- end to end through the stub API (token-checking) ---------------------
  start_stub(){ # mode
    : > "$W/log"; rm -f "$W/port"
    python3 "$DIR/test/stub-api.py" sekrit "$W/port" "$W/log" "$RECV" "$1" & STUB=$!
    for _ in $(seq 1 100); do [ -s "$W/port" ] && break; sleep 0.1; done
    API="http://127.0.0.1:$(cat "$W/port" 2>/dev/null)"
  }
  stop_stub(){ kill "$STUB" 2>/dev/null; wait "$STUB" 2>/dev/null; }

  for mode in sync async; do
    start_stub "$mode"
    P="$(freeport)"; PORTS="$PORTS|$P"; O="$W/e2e-$mode/pushed.tar.gz"
    out="$(CTRL_EXEC_API_URL=$API CTRL_EXEC_TOKEN=sekrit timeout 60 "$DIR/ce-push-blob" \
        --host 127.0.0.1 --file "$W/a.tar.gz" --output "$O" --port "$P" --timeout 60 2>&1)"; rc=$?
    ok "ce-push-blob completes against the stub API ($mode)" 0 "$rc"
    case "$out" in *"Recvd:   $ASIZE bytes"*) r=confirmed;; *) r="unconfirmed: $out";; esac
    ok "ce-push-blob confirms receipt through --status ($mode)" confirmed "$r"
    cmp -s "$W/a.tar.gz" "$O" && r=same || r=differs
    ok "pushed file arrives intact ($mode)" same "$r"
    grep -q '"--status"' "$W/log" && r=called || r=never
    ok "confirmation goes through the --status run call ($mode)" called "$r"
    bare="$(grep -c 'auth=\[\]' "$W/log" || true)"
    ok "ce-push-blob sends no tokenless status poll ($mode)" 0 "$bare"
    if [ "$mode" = async ]; then
      grep -q 'auth=\[Bearer sekrit\]' "$W/log" && r=bearer || r=none
      ok "async status polls carry the Bearer token" bearer "$r"
    fi

    : > "$W/log"
    P="$(freeport)"; PORTS="$PORTS|$P"; O="$W/e2e-$mode/xfer.tar.gz"
    out="$(CTRL_EXEC_API_URL=$API CTRL_EXEC_TOKEN=sekrit timeout 60 "$DIR/ce-file-transfer" \
        --from sender --to 127.0.0.1 --path /p --output "$O" --port "$P" --timeout 60 2>&1)"; rc=$?
    ok "ce-file-transfer completes against the stub API ($mode)" 0 "$rc"
    case "$out" in *"Transfer complete"*"Recvd:   $ASIZE bytes"*|*"Transfer complete"*"Recvd:   "[0-9]*" bytes"*) r=complete;; *) r="stalled: $out";; esac
    ok "ce-file-transfer confirms receipt through --status ($mode)" complete "$r"
    grep -q '"--status"' "$W/log" && r=called || r=never
    ok "ce-file-transfer confirms through the --status run call ($mode)" called "$r"
    bare="$(grep -c 'auth=\[\]' "$W/log" || true)"
    ok "ce-file-transfer sends no tokenless status poll ($mode)" 0 "$bare"
    stop_stub
  done

  # wrong token: refused at /run, no listener left behind
  start_stub sync
  P="$(freeport)"; PORTS="$PORTS|$P"
  CTRL_EXEC_API_URL=$API CTRL_EXEC_TOKEN=wrong timeout 30 "$DIR/ce-push-blob" \
      --host 127.0.0.1 --file "$W/a.tar.gz" --output "$W/bad/x.tar.gz" --port "$P" >/dev/null 2>&1
  ok "ce-push-blob with a wrong token fails" nonzero "$([ $? -ne 0 ] && echo nonzero || echo zero)"
  stop_stub
fi

echo
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && echo "VERDICT: PASS" || echo "VERDICT: FAIL"
[ "$FAIL" -eq 0 ]
