#!/bin/bash
# Test suite for the nagios-check plugin. Run: bash test/run.sh
#
# Covers the agent script and the run-jobs job:
#   - state mapping, overall state and exit code
#   - perfdata parsing: quoted labels, '' escape, units, empty fields, ranges,
#     U, perfdata continued in the long output
#   - timeout (the plugin's process group is killed), missing, non-executable,
#     exit 7, signal death, a plugin or name that tries to leave plugin_dir
#   - config parsing, argument splitting, no shell interpretation, --list
#   - nagios-checks.sh: end to end against a STUB ctrl-exec-cli (which runs the
#     real wrapper over fake plugins) and a STUB logger
# Plugins are small shell scripts in a temp plugin_dir. The real monitoring
# plugins run too when /usr/lib/nagios/plugins exists; otherwise that section
# is skipped. Needs perl and bash only, no network, no root; timeouts are 1 s.
# shellcheck disable=SC2015,SC2016  # A && pass || fail is intended; fake plugins are quoted on purpose
set -u
DIR="$(cd "$(dirname "$0")/.." && pwd)"
NC="$DIR/nagios-check.pl"
SCHEMA="$DIR/nagios-check.pl.schema.json"
JOB="$DIR/run-jobs/nagios-checks.sh"
JOBCONF_EXAMPLE="$DIR/run-jobs/nagios-checks.conf.example"

PASS=0 FAIL=0 SKIP=0
T="$(mktemp -d "${TMPDIR:-/tmp}/nagios-check-test.XXXXXX")" || exit 2
cleanup() { [ -n "${KEEP_TMP:-}" ] && echo "kept: $T" >&2 || rm -rf "$T"; }
trap cleanup EXIT
trap 'exit 130' INT TERM

pass() { echo "  PASS  $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL  $1${2:+ ($2)}"; FAIL=$((FAIL + 1)); }
skip() { echo "  SKIP  $1"; SKIP=$((SKIP + 1)); }
heading() { echo; echo "## $1"; echo; }
expect_eq() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "want '$2', got '$3'"; fi; }
expect_has() { if grep -qF -- "$3" <<< "$2"; then pass "$1"; else fail "$1" "missing '$3'"; fi; }
expect_lacks() { if grep -qF -- "$3" <<< "$2"; then fail "$1" "unexpected '$3'"; else pass "$1"; fi; }

P="$T/plugins"
CONF="$T/nagios-checks.conf"
mkdir -p "$P"
export NAGIOS_CHECKS_CONF="$CONF"
unset CTRL_EXEC_INPUT

# plugin NAME BODY: a fake plugin, a shell script
plugin() { printf '#!/bin/bash\n%s\n' "$2" > "$P/$1"; chmod 755 "$P/$1"; }

# conf LINE...: writes the config, with the fake plugin_dir and a 1 s timeout
conf() { { echo "plugin_dir = $P"; echo "timeout = 1"; printf '%s\n' "$@"; } > "$CONF"; }

# nc ARGS...: runs the wrapper; OUT is its stdout, ERR its stderr, RC its exit
nc() {
    OUT="$(perl "$NC" "$@" 2> "$T/err" < /dev/null)"
    RC=$?
    ERR="$(cat "$T/err")"
}

# jv EXPR: evaluates a perl expression on the decoded $OUT as $d
jv() { printf '%s' "$OUT" | perl -MJSON::PP -e '
    my $d = decode_json(do { local $/; <STDIN> });
    my $v = eval $ARGV[0]; die $@ if $@;
    print JSON::PP->new->canonical->allow_nonref->encode($v);' "$1"; }
# is_json: $OUT is exactly one JSON document
is_json() { printf '%s' "$OUT" | perl -MJSON::PP -e 'decode_json(do { local $/; <STDIN> }); exit 0' 2> /dev/null; }

# check_is NAME EXPR WANT: the JSON value of EXPR equals WANT
jis() { expect_eq "$1" "$3" "$(jv "$2" 2>&1)"; }

echo "# Test report: nagios-check (ce-agent-plugins)"
echo "Generated: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"

plugin ok_p 'echo "OK - all fine | a=1;;;0;10"; exit 0'
plugin warn_p 'echo "WARNING - getting full"; exit 1'
plugin crit_p 'echo "CRITICAL - gone"; exit 2'
plugin unk_p 'echo "UNKNOWN - cannot tell"; exit 3'
plugin exit7_p 'echo boom; exit 7'
plugin sig_p 'kill -9 $$'
plugin args_p 'echo "OK - args"; for a in "$@"; do echo "[${a//|/<pipe>}]"; done'
plugin stdin_p 'read -t 1 x; echo "OK - stdin=[${x:-}]"'
plugin noout_p 'exit 0'
plugin bytes_p 'printf "OK - caf\xe9 \xff\n"'
printf '#!/bin/bash\necho OK\n' > "$P/notexec_p"
chmod 644 "$P/notexec_p"
ln -s /bin/true "$P/escape_p"
plugin slow_p 'sleep 30 & echo $! > "'"$T"'/slow.pid"; wait'
plugin perf_p "echo \"DISK WARNING - free | '/ root'=14280MB;13824;15552;0;17280 'it''s'=5 load=0.5;;;; time=0.012s;1:2;@3:4;; rate=U pct=50% bytes=10B;~:5;10: bad=abc\"
echo 'long line one'
echo 'long line two | extra=1c'
echo \"more=2;; 'x y'=3KB\"
exit 1"

# ---------------------------------------------------------------------------
heading "Contract: no arguments and the sidecar"

nc
expect_eq "no arguments exits 3" 3 "$RC"
expect_has "no arguments prints usage on stderr" "$ERR" "usage: nagios-check"
is_json && pass "no arguments: stdout is one JSON document" || fail "no arguments: stdout is one JSON document" "$OUT"
jis "no arguments: state UNKNOWN with an error" '[$d->{state}, $d->{code}, length($d->{error}) > 0 ? 1 : 0]' '["UNKNOWN",3,1]'
[ -x "$NC" ] && pass "nagios-check.pl is executable" || fail "nagios-check.pl is executable"
expect_eq "nagios-check.pl has a perl shebang" '#!/usr/bin/perl' "$(head -1 "$NC")"
perl -MJSON::PP -e 'open my $f, "<", $ARGV[0] or exit 1; local $/; my $d = decode_json(<$f>);
    exit($d->{arguments} && $d->{argv} && $d->{read_only} ? 0 : 1)' "$SCHEMA" \
    && pass "schema sidecar is valid JSON with arguments, argv and read_only" \
    || fail "schema sidecar is valid JSON with arguments, argv and read_only"
perl -c "$NC" > /dev/null 2>&1 && pass "perl -c passes" || fail "perl -c passes"
n="$(wc -l < "$NC")"
[ "$n" -le 260 ] && pass "wrapper stays small ($n lines)" || fail "wrapper stays small" "$n lines"

# ---------------------------------------------------------------------------
heading "State mapping and the overall state"

conf "ok = ok_p" "warn = warn_p" "crit = crit_p" "unk = unk_p" "plain = ok_p -x" "noout = noout_p"
nc ok
expect_eq "OK: exit 0" 0 "$RC"
jis "OK: state, code, summary" '[$d->{state}, $d->{code}, $d->{checks}[0]{summary}]' '["OK",0,"OK - all fine"]'
jis "OK: host is set" '$d->{host} eq "" ? 0 : 1' 1
jis "OK: check fields" '[sort keys %{$d->{checks}[0]}]' '["code","duration_ms","long_output","name","perfdata","state","summary"]'
jis "OK: duration_ms is a number" '$d->{checks}[0]{duration_ms} =~ /^\d+$/ ? 1 : 0' 1
nc warn
expect_eq "WARNING: exit 1" 1 "$RC"
jis "WARNING: state and code" '[$d->{state}, $d->{checks}[0]{code}]' '["WARNING",1]'
nc crit
expect_eq "CRITICAL: exit 2" 2 "$RC"
jis "CRITICAL: state" '$d->{checks}[0]{state}' '"CRITICAL"'
nc unk
expect_eq "UNKNOWN: exit 3" 3 "$RC"
nc ok warn
expect_eq "OK+WARNING: overall WARNING, exit 1" 1 "$RC"
jis "OK+WARNING: per-check states kept" '[map { $_->{state} } @{$d->{checks}}]' '["OK","WARNING"]'
nc ok unk
expect_eq "OK+UNKNOWN: overall UNKNOWN, exit 3" 3 "$RC"
nc warn unk
expect_eq "WARNING+UNKNOWN: overall WARNING (CRITICAL > WARNING > UNKNOWN > OK), exit 1" 1 "$RC"
nc unk crit warn ok
expect_eq "all four: overall CRITICAL, exit 2" 2 "$RC"
jis "all four: order as asked" '[map { $_->{name} } @{$d->{checks}}]' '["unk","crit","warn","ok"]'
jis "all four: top-level state" '[$d->{state}, $d->{code}]' '["CRITICAL",2]'
nc ok ok
jis "a name given twice runs once" 'scalar @{$d->{checks}}' 1
nc --all
jis "--all runs every configured check in config order" '[map { $_->{name} } @{$d->{checks}}]' '["ok","warn","crit","unk","plain","noout"]'
expect_eq "--all: exit is the worst (CRITICAL)" 2 "$RC"
nc noout
jis "a plugin that prints nothing: OK with an empty summary" '[$d->{checks}[0]{state}, $d->{checks}[0]{summary}]' '["OK",""]'
conf "bytes = bytes_p"
nc bytes
is_json && pass "non-UTF-8 plugin output still gives valid JSON" || fail "non-UTF-8 plugin output still gives valid JSON" "$OUT"
conf "stdin = stdin_p"
OUT="$(echo secret | perl "$NC" stdin 2> /dev/null)"
jis "the plugin gets no stdin" '$d->{checks}[0]{summary}' '"OK - stdin=[]"'

# ---------------------------------------------------------------------------
heading "Perfdata"

conf "perf = perf_p"
nc perf
expect_eq "perf plugin: exit 1" 1 "$RC"
jis "summary stops at the first |" '$d->{checks}[0]{summary}' '"DISK WARNING - free"'
jis "ten items parsed, the malformed one skipped" 'scalar @{$d->{checks}[0]{perfdata}}' 10
jis "quoted label with a space, unit, all five fields" '$d->{checks}[0]{perfdata}[0]' \
    '{"crit":15552,"label":"/ root","max":17280,"min":0,"uom":"MB","value":14280,"warn":13824}'
jis "'' inside a quoted label is one quote" '$d->{checks}[0]{perfdata}[1]{label}' '"it'"'"'s"'
jis "no unit: empty uom, other fields null" '$d->{checks}[0]{perfdata}[1]' \
    '{"crit":null,"label":"it'"'"'s","max":null,"min":null,"uom":"","value":5,"warn":null}'
jis "fractional value, empty fields are null" '$d->{checks}[0]{perfdata}[2]' \
    '{"crit":null,"label":"load","max":null,"min":null,"uom":"","value":0.5,"warn":null}'
jis "ranges stay strings (10:20 style, @ prefix), unit s" '$d->{checks}[0]{perfdata}[3]' \
    '{"crit":"@3:4","label":"time","max":null,"min":null,"uom":"s","value":0.012,"warn":"1:2"}'
jis "value U is null" '[$d->{checks}[0]{perfdata}[4]{label}, $d->{checks}[0]{perfdata}[4]{value}]' '["rate",null]'
jis "percent unit" '$d->{checks}[0]{perfdata}[5]{uom}' '"%"'
jis "~:5 and 10: ranges kept as strings" '[$d->{checks}[0]{perfdata}[6]{warn}, $d->{checks}[0]{perfdata}[6]{crit}, $d->{checks}[0]{perfdata}[6]{uom}]' '["~:5","10:","B"]'
jis "long output is the lines between, up to the |" '$d->{checks}[0]{long_output}' '"long line one\nlong line two"'
jis "a | in the long output starts more perfdata" '$d->{checks}[0]{perfdata}[7]{label}' '"extra"'
jis "...and its unit c (counter)" '$d->{checks}[0]{perfdata}[7]{uom}' '"c"'
jis "lines after that are perfdata too" '[$d->{checks}[0]{perfdata}[8]{label}, $d->{checks}[0]{perfdata}[9]{label}, $d->{checks}[0]{perfdata}[9]{uom}]' '["more","x y","KB"]'
jis "trailing empty fields (more=2;;) are null" '[$d->{checks}[0]{perfdata}[8]{warn}, $d->{checks}[0]{perfdata}[8]{crit}]' '[null,null]'
conf "ok = ok_p"
nc ok
jis "simple perfdata after a plain summary" '$d->{checks}[0]{perfdata}[0]' \
    '{"crit":null,"label":"a","max":10,"min":0,"uom":"","value":1,"warn":null}'

# ---------------------------------------------------------------------------
heading "Failures are UNKNOWN with a reason, and never hide other checks"

conf "ok = ok_p" "slow = slow_p" "exit7 = exit7_p" "sig = sig_p" "missing = nothing_here_p" \
    "notexec = notexec_p" "symlink = escape_p" "abs = /bin/true" "rel = ../plugins/ok_p" "dotdot = .."
START="$(date +%s)"
nc slow ok
ELAPSED=$(($(date +%s) - START))
jis "timeout: UNKNOWN" '$d->{checks}[0]{state}' '"UNKNOWN"'
jis "timeout: the reason says so" '$d->{checks}[0]{summary}' '"timed out after 1s"'
[ "$ELAPSED" -le 4 ] && pass "timeout: returned promptly (${ELAPSED}s)" || fail "timeout: returned promptly" "${ELAPSED}s"
jis "timeout: the next check still ran" '$d->{checks}[1]{state}' '"OK"'
expect_eq "timeout: overall exit 3 (UNKNOWN beats OK)" 3 "$RC"
SPID="$(cat "$T/slow.pid" 2> /dev/null || echo 0)"
for _ in 1 2 3 4 5 6 7 8 9 10; do kill -0 "$SPID" 2> /dev/null || break; sleep 0.1; done
kill -0 "$SPID" 2> /dev/null && fail "timeout: the plugin's child is killed too" || pass "timeout: the plugin's child is killed too"
nc exit7
jis "exit 7: UNKNOWN, reason and output" '[$d->{checks}[0]{state}, $d->{checks}[0]{summary}]' '["UNKNOWN","exit code 7 is outside 0-3: boom"]'
nc sig
jis "killed by signal: UNKNOWN" '[$d->{checks}[0]{state}, $d->{checks}[0]{summary}]' '["UNKNOWN","killed by signal 9"]'
nc missing
expect_has "missing plugin: reason" "$(jv '$d->{checks}[0]{summary}')" "plugin not found"
jis "missing plugin: UNKNOWN" '$d->{checks}[0]{state}' '"UNKNOWN"'
nc notexec
expect_has "non-executable plugin: reason" "$(jv '$d->{checks}[0]{summary}')" "not executable"
nc symlink
expect_has "symlink out of plugin_dir refused" "$(jv '$d->{checks}[0]{summary}')" "outside plugin_dir"
nc abs
expect_has "plugin with a / (absolute) refused" "$(jv '$d->{checks}[0]{summary}')" "must not contain '/'"
nc rel
expect_has "plugin with a / (relative) refused" "$(jv '$d->{checks}[0]{summary}')" "must not contain '/'"
nc dotdot
expect_has "plugin named .. refused" "$(jv '$d->{checks}[0]{summary}')" "outside plugin_dir"
nc missing ok notexec
jis "one bad check does not hide the others" '[map { $_->{state} } @{$d->{checks}}]' '["UNKNOWN","OK","UNKNOWN"]'
conf "ok = ok_p"
sed -i 's|^plugin_dir = .*|plugin_dir = /nonexistent-dir|' "$CONF"
nc ok
expect_has "plugin_dir missing: the check is UNKNOWN, not a crash" "$(jv '$d->{checks}[0]{summary}')" "plugin not found"

# ---------------------------------------------------------------------------
heading "Wrapper errors (exit 3, one JSON document with an error)"

conf "ok = ok_p"
for bad in nosuch "a/b" ".." "../ok" "--bogus" "OK;id" "ok " ""; do
    nc "$bad"
    is_json && j=ok || j=bad
    jis "name '$bad': error, exit 3" '[$d->{state}, $d->{code}, length($d->{error}) > 0 ? 1 : 0]' '["UNKNOWN",3,1]'
    expect_eq "name '$bad': exit 3 and valid JSON" "3 ok" "$RC $j"
done
nc ok nosuch
expect_has "one unknown name stops the run before anything runs" "$OUT" "unknown check 'nosuch'"
expect_lacks "...and no check results" "$OUT" '"checks"'
nc --list ok
expect_eq "--list with names: exit 3" 3 "$RC"
nc --all ok
expect_eq "--all with names: exit 3" 3 "$RC"
NAGIOS_CHECKS_CONF="$T/absent.conf" nc ok
expect_eq "missing config: exit 3" 3 "$RC"
expect_has "missing config: names the file" "$OUT" "absent.conf"
for body in "garbage" "ok = " "timeout = abc" "timeout = 0" "bad name = ok_p" "dup = ok_p
dup = ok_p" "q = ok_p 'unterminated" 'q = ok_p "unterminated'; do
    printf '%s\n' "$body" > "$CONF"
    nc --list
    expect_eq "bad config '${body//$'\n'/ / }': exit 3" 3 "$RC"
    is_json && jis "bad config: error names the line" '$d->{error} =~ /line \d/ ? 1 : 0' 1 || fail "bad config: JSON"
done
: > "$CONF"
nc --all
expect_eq "empty config, --all: exit 3" 3 "$RC"

# ---------------------------------------------------------------------------
heading "--list and the config format"

conf "# a comment" "" "  disk_root   =   ok_p  " "load=ok_p" "plugin_dir = $P" "timeout = 5"
nc --list
expect_eq "--list: exit 0" 0 "$RC"
jis "--list: names in config order, settings are not checks" '$d->{checks}' '["disk_root","load"]'
jis "--list: only host and checks" '[sort keys %$d]' '["checks","host"]'
nc disk_root load
expect_eq "spaces around = and no spaces both work: exit 0" 0 "$RC"
jis "both checks ran" 'scalar @{$d->{checks}}' 2
perl -e 'print "plugin_dir = /usr/lib/nagios/plugins\n"' > "$T/defaults.conf"
echo "ok = ok_p" >> "$T/defaults.conf"
NAGIOS_CHECKS_CONF="$T/defaults.conf" nc ok
expect_has "default plugin_dir is /usr/lib/nagios/plugins" "$OUT" "/usr/lib/nagios/plugins/ok_p"

# ---------------------------------------------------------------------------
heading "Argument splitting and no shell"

conf "q = args_p one \"two words\" 'three \"x\" y' a\"b c\"d '' last"
nc q
EXPECT=$'[one]\n[two words]\n[three "x" y]\n[ab cd]\n[]\n[last]'
expect_eq "quotes group words, adjacent pieces join, '' is an empty argument" "$EXPECT" "$(jv '$d->{checks}[0]{long_output}' | perl -MJSON::PP -e 'print decode_json("[".<STDIN>."]")->[0]')"
SENT="$T/sentinel"
conf "inj = args_p '\$(touch $SENT)' ';' '|' '\`touch $SENT\`' '>$SENT' '&&' 'touch' '$SENT' '*' '~'"
nc inj
EXPECT=$'[$(touch '"$SENT"$')]\n[;]\n[<pipe>]\n[`touch '"$SENT"$'`]\n[>'"$SENT"$']\n[&&]\n[touch]\n['"$SENT"$']\n[*]\n[~]'
expect_eq "shell metacharacters reach the plugin literally" "$EXPECT" "$(jv '$d->{checks}[0]{long_output}' | perl -MJSON::PP -e 'print decode_json("[".<STDIN>."]")->[0]')"
[ -e "$SENT" ] && fail "nothing was executed by a shell" "sentinel exists" || pass "nothing was executed by a shell"
conf "bare = args_p \$(touch $SENT) ; \`touch $SENT\` > $SENT"
nc bare
[ -e "$SENT" ] && fail "unquoted metacharacters are not run either" "sentinel exists" || pass "unquoted metacharacters are not run either"
expect_has "...they are plain words" "$OUT" '[;]'

# ---------------------------------------------------------------------------
heading "Real monitoring plugins"

if [ -d /usr/lib/nagios/plugins ] && [ -x /usr/lib/nagios/plugins/check_load ]; then
    printf '%s\n' "load = check_load -w 1000,1000,1000 -c 2000,2000,2000" "disk = check_disk -w 1% -c 1% -p /" > "$CONF"
    nc load disk
    jis "check_load: OK with perfdata" '[$d->{checks}[0]{state}, scalar(@{$d->{checks}[0]{perfdata}}) > 0 ? 1 : 0]' '["OK",1]'
    jis "check_disk: ran" '$d->{checks}[1]{state} =~ /^(OK|WARNING|CRITICAL)$/ ? 1 : 0' 1
else
    skip "real plugins: /usr/lib/nagios/plugins/check_load not installed (monitoring-plugins)"
fi

# ---------------------------------------------------------------------------
heading "Job: nagios-checks.sh against a stub ctrl-exec-cli and logger"

B="$T/bin"
F="$T/fake"
mkdir -p "$B" "$F"
cat > "$B/logger" <<'STUB'
#!/bin/bash
echo "$*" >> "$STUB_LOG"
STUB
cat > "$B/ctrl-exec-cli" <<'STUB'
#!/bin/bash
# ctrl-exec-cli --json run HOST --script S -- NAMES...
echo "$*" >> "$STUB_CALLS"
host=$3
shift 6
if [ -f "$STUB_DIR/$host.fail" ]; then cat "$STUB_DIR/$host.fail" >&2; exit 1; fi
if [ -f "$STUB_DIR/$host.json" ]; then cat "$STUB_DIR/$host.json"; exit 0; fi
out="$(NAGIOS_CHECKS_CONF="$STUB_DIR/$host.conf" perl "$STUB_WRAPPER" "$@")"
rc=$?
perl -MJSON::PP -e 'print encode_json({ok=>JSON::PP::true, reqid=>"a1b2c3d4", results=>[{host=>$ARGV[0], exit=>$ARGV[1]+0, stdout=>$ARGV[2], stderr=>"", rtt=>"3ms"}]}), "\n"' "$host" "$rc" "$out"
STUB
chmod 755 "$B/logger" "$B/ctrl-exec-cli"
export STUB_LOG="$T/syslog" STUB_CALLS="$T/calls" STUB_DIR="$F" STUB_WRAPPER="$NC"
JC="$T/job.conf"
export NAGIOS_JOB_CONF="$JC"

# job: runs the job; OUT/RC as before, LOG the syslog lines, CALLS the cli calls
job() {
    : > "$STUB_LOG"
    : > "$STUB_CALLS"
    OUT="$(PATH="$B:$PATH" bash "$JOB" 2> "$T/err" < /dev/null)"
    RC=$?
    LOG="$(cat "$STUB_LOG")"
    CALLS="$(cat "$STUB_CALLS")"
}

printf '%s\n' "plugin_dir = $P" "timeout = 1" "disk_root = ok_p" "load = ok_p" "swap = ok_p" > "$F/agent-01.conf"
printf '%s\n' "plugin_dir = $P" "timeout = 1" "disk_root = ok_p" "load = ok_p" > "$F/agent-02.conf"
printf '%s\n' "check = agent-01 disk_root load swap" "check = agent-02 disk_root load" "schedule = */5 * * * *" > "$JC"
job
expect_eq "all OK: exit 0" 0 "$RC"
expect_eq "all OK: one summary line, user.info" "-p user.info -t ctrl-exec-nagios -- status=ok hosts=2 checks=5 ok=5 warning=0 critical=0 unknown=0" "$LOG"
expect_eq "all OK: the summary is also printed" "status=ok hosts=2 checks=5 ok=5 warning=0 critical=0 unknown=0" "$OUT"
expect_eq "the CLI is asked with names only, one call per host" \
    $'--json run agent-01 --script nagios-check -- disk_root load swap\n--json run agent-02 --script nagios-check -- disk_root load' "$CALLS"

printf '%s\n' "plugin_dir = $P" "timeout = 1" "disk_root = warn_p" "load = ok_p" "swap = crit_p" > "$F/agent-01.conf"
job
expect_eq "WARNING and CRITICAL: exit 1" 1 "$RC"
expect_has "WARNING line at user.warning" "$LOG" '-p user.warning -t ctrl-exec-nagios -- host=agent-01 check=disk_root state=WARNING summary="WARNING - getting full"'
expect_has "CRITICAL line at user.err" "$LOG" '-p user.err -t ctrl-exec-nagios -- host=agent-01 check=swap state=CRITICAL summary="CRITICAL - gone"'
expect_lacks "OK checks get no line" "$LOG" "check=load"
expect_has "summary: worst state, counts, user.err" "$LOG" "-p user.err -t ctrl-exec-nagios -- status=critical hosts=2 checks=5 ok=3 warning=1 critical=1 unknown=0"
expect_eq "three lines in all (two checks plus summary)" 3 "$(wc -l <<< "$LOG")"

printf '%s\n' "plugin_dir = $P" "timeout = 1" "disk_root = warn_p" "load = ok_p" "swap = ok_p" > "$F/agent-01.conf"
job
expect_has "WARNING only: summary at user.warning" "$LOG" "-p user.warning -t ctrl-exec-nagios -- status=warning hosts=2 checks=5 ok=4 warning=1"

echo "ctrl-exec-cli: agent agent-02 unreachable" > "$F/agent-02.fail"
job
expect_eq "unreachable agent: exit 1" 1 "$RC"
expect_has "unreachable agent: each of its checks is UNKNOWN with the reason" "$LOG" 'host=agent-02 check=load state=UNKNOWN summary="ctrl-exec-cli: agent agent-02 unreachable"'
expect_has "unreachable agent: counted" "$LOG" "unknown=2"
rm "$F/agent-02.fail"

echo '{"ok":true,"results":[{"host":"agent-02","exit":126,"stdout":"","stderr":"script not permitted","error":"script not permitted"}]}' > "$F/agent-02.json"
job
expect_has "agent refuses the script: UNKNOWN with the agent's words" "$LOG" 'check=disk_root state=UNKNOWN summary="script not permitted"'
echo '{"ok":false,"error":"unknown agent agent-02","code":404}' > "$F/agent-02.json"
job
expect_has "API error: UNKNOWN with the API's words" "$LOG" 'state=UNKNOWN summary="unknown agent agent-02"'
echo 'not json at all' > "$F/agent-02.json"
job
expect_has "unreadable reply: UNKNOWN" "$LOG" "no reply from ctrl-exec-cli"
rm "$F/agent-02.json"

printf '%s\n' "plugin_dir = $P" "timeout = 1" "disk_root = ok_p" > "$F/agent-02.conf"
job
expect_has "agent lacks a requested check: wrapper error shown as UNKNOWN" "$LOG" 'host=agent-02 check=load state=UNKNOWN summary="unknown check '"'load'"'"'
printf '%s\n' "plugin_dir = $P" "timeout = 1" "disk_root = ok_p" "load = ok_p" > "$F/agent-02.conf"

NAGIOS_TAG=mytag job
expect_has "NAGIOS_TAG sets the tag" "$LOG" "-t mytag --"
OUT="$(NAGIOS_SCRIPT=other-name PATH="$B:$PATH" bash "$JOB" 2> /dev/null < /dev/null)"
expect_has "NAGIOS_SCRIPT sets the agent script name" "$(cat "$STUB_CALLS")" "--script other-name --"

printf '%s\n' "schedule = */5 * * * *" > "$JC"
job
expect_eq "no check lines: exit 1" 1 "$RC"
expect_has "no check lines: status=unknown" "$LOG" "status=unknown hosts=0 checks=0"
printf '%s\n' "check = agent-01" > "$JC"
job
expect_eq "check line without names: exit 1" 1 "$RC"
expect_has "check line without names: logged" "$LOG" "bad check line"
NAGIOS_JOB_CONF="$T/none.conf" job
expect_eq "missing job config: exit 1" 1 "$RC"
expect_has "missing job config: logged" "$LOG" "cannot read"

if [ -f "$JOBCONF_EXAMPLE" ]; then
    echo "x" > "$F/agent-01.fail"
    echo "x" > "$F/agent-02.fail"
    echo "x" > "$F/agent-03.fail"
    NAGIOS_JOB_CONF="$JOBCONF_EXAMPLE" job
    expect_has "example config: agent-03 asked for its check" "$CALLS" "run agent-03 --script nagios-check -- http_example"
    expect_has "example config: agent-01 asked for three checks" "$CALLS" "run agent-01 --script nagios-check -- disk_root load swap"
    grep -q '^schedule *= *\*/5 \* \* \* \*$' "$JOBCONF_EXAMPLE" && pass "example config has a schedule" || fail "example config has a schedule"
else
    fail "nagios-checks.conf.example exists"
fi
[ -x "$JOB" ] && pass "nagios-checks.sh is executable" || fail "nagios-checks.sh is executable"

# ---------------------------------------------------------------------------
echo
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
if [ "$FAIL" -eq 0 ]; then echo "VERDICT: PASS"; else echo "VERDICT: FAIL"; fi
[ "$FAIL" -eq 0 ]
