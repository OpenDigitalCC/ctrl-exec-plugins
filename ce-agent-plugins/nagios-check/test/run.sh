#!/bin/bash
# Test suite for the nagios-check plugin. Run: bash test/run.sh
#
# Covers the agent script and the run-jobs job:
#   - state mapping, overall state and exit code
#   - perfdata parsing: quoted labels, '' escape, units, empty fields, ranges,
#     U, perfdata continued in the long output
#   - timeout (the plugin's process group is killed), missing, non-executable,
#     exit 7, signal death, a plugin or name that tries to leave plugin_dir
#   - config parsing, argument splitting, no shell interpretation
#   - --list availability and exit code, plugin_dir with several directories
#   - the run budget: capping, "not run", the warning field, default timeout
#   - the unreadable-config message
#   - plugins/check_mem against a fake meminfo (CHECK_MEM_MEMINFO)
#   - nagios-checks.sh: end to end against a STUB ctrl-exec-cli (which runs the
#     real wrapper over fake plugins) and a STUB logger
# Plugins are small shell scripts in a temp plugin_dir. The real monitoring
# plugins run too when /usr/lib/nagios/plugins exists; otherwise that section
# is skipped. Needs perl and bash only, no network, no root; timeouts are 1 s
# and the load on the host is nil (no check runs longer than the budget test).
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
[ "$n" -le 320 ] && pass "wrapper stays small ($n lines)" || fail "wrapper stays small" "$n lines"

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
if [ "$(id -u)" -ne 0 ]; then
    echo "ok = ok_p" > "$T/locked.conf"
    chmod 000 "$T/locked.conf"
    NAGIOS_CHECKS_CONF="$T/locked.conf" nc ok
    expect_eq "unreadable config: exit 3" 3 "$RC"
    expect_has "unreadable config: names the user that could not read it" "$OUT" "as user $(id -un):"
else
    skip "unreadable config: running as root, the file cannot be made unreadable"
fi
for body in "garbage" "ok = " "timeout = abc" "timeout = 0" "budget = 0" "budget = 1.5" "bad name = ok_p" "dup = ok_p
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
jis "--list: names in config order, settings are not checks" '[map { $_->{name} } @{$d->{checks}}]' '["disk_root","load"]'
jis "--list: only host and checks" '[sort keys %$d]' '["checks","host"]'
jis "--list: plugin name and availability, no arguments" '$d->{checks}[0]' '{"available":true,"name":"disk_root","plugin":"ok_p"}'
nc disk_root load
expect_eq "spaces around = and no spaces both work: exit 0" 0 "$RC"
jis "both checks ran" 'scalar @{$d->{checks}}' 2
echo "ok = ok_p -x" > "$T/defaults.conf"
NAGIOS_CHECKS_CONF="$T/defaults.conf" nc ok
expect_has "default plugin_dir: both Debian directories, in order, named in the summary" "$OUT" "ok_p: plugin not found in /usr/lib/nagios/plugins:/usr/local/lib/nagios/plugins"
NAGIOS_CHECKS_CONF="$T/defaults.conf" nc --list
jis "--list names the plugin and the directories searched" '$d->{checks}[0]{reason}' '"plugin not found in /usr/lib/nagios/plugins:/usr/local/lib/nagios/plugins"'
expect_eq "default config path is /etc/nagios-checks/checks.conf" "1" "$(grep -c '/etc/nagios-checks/checks.conf"' "$NC")"

# ---------------------------------------------------------------------------
heading "Config folder: default path, fallback to the old path"

# NAGIOS_CHECKS_ROOT prefixes the default paths (tests only); no NAGIOS_CHECKS_CONF
FR="$T/froot"
mkdir -p "$FR/etc/nagios-checks"
nr() {
    OUT="$(env -u NAGIOS_CHECKS_CONF NAGIOS_CHECKS_ROOT="$FR" perl "$NC" "$@" 2> "$T/err" < /dev/null)"
    RC=$?
    ERR="$(cat "$T/err")"
}
printf '%s\n' "plugin_dir = $P" "timeout = 1" "newone = ok_p" > "$FR/etc/nagios-checks/checks.conf"
printf '%s\n' "plugin_dir = $P" "timeout = 1" "oldone = ok_p" > "$FR/etc/nagios-checks.conf"
nr --list
jis "new path exists: it is used" '[map { $_->{name} } @{$d->{checks}}]' '["newone"]'
expect_eq "new path exists: nothing on stderr" "" "$ERR"
rm "$FR/etc/nagios-checks/checks.conf"
nr --list
expect_eq "only the old path exists: exit 0" 0 "$RC"
jis "only the old path exists: it is used" '[map { $_->{name} } @{$d->{checks}}]' '["oldone"]'
is_json && pass "only the old path exists: stdout is one JSON document" || fail "only the old path exists: stdout is one JSON document"
expect_has "only the old path exists: one stderr line says so" "$ERR" "nagios-check: using $FR/etc/nagios-checks.conf; move it to $FR/etc/nagios-checks/checks.conf"
expect_eq "only the old path exists: exactly one line" 1 "$(wc -l <<< "$ERR")"
nr oldone
expect_eq "only the old path exists: a run works" 0 "$RC"
jis "only the old path exists: a run's state" '$d->{state}' '"OK"'
rm "$FR/etc/nagios-checks.conf"
nr --list
expect_eq "neither exists: exit 3" 3 "$RC"
expect_has "neither exists: the error names the new path" "$OUT" "$FR/etc/nagios-checks/checks.conf"
expect_eq "neither exists: no fallback line" "" "$ERR"
printf '%s\n' "plugin_dir = $P" "oldone = ok_p" > "$FR/etc/nagios-checks.conf"
OUT="$(NAGIOS_CHECKS_ROOT="$FR" NAGIOS_CHECKS_CONF="$T/absent.conf" perl "$NC" --list 2> "$T/err" < /dev/null)"; RC=$?
expect_eq "NAGIOS_CHECKS_CONF set: no fallback to the old path" 3 "$RC"
expect_eq "NAGIOS_CHECKS_CONF set: no fallback line" "" "$(cat "$T/err")"

# ---------------------------------------------------------------------------
heading "--check-config"

conf "ok = ok_p" "gone = no_such_plugin -w 1" "timeout = 7" "budget = 40"
cp "$CONF" "$T/candidate.conf"
printf '%s\n' "plugin_dir = $P" "other = ok_p -x" "timeout = 3" > "$T/other.conf"
NAGIOS_CHECKS_CONF="$T/absent.conf" nc --check-config "$T/candidate.conf"
expect_eq "--check-config: exit 0 although a plugin is missing" 0 "$RC"
is_json && pass "--check-config: stdout is one JSON document" || fail "--check-config: stdout is one JSON document" "$OUT"
jis "--check-config: the file's checks, one available, one not" '[map { [$_->{name}, $_->{available}] } @{$d->{checks}}]' '[["ok",true],["gone",false]]'
expect_has "--check-config: the missing plugin has a reason" "$(jv '$d->{checks}[1]{reason}')" "plugin not found"
jis "--check-config: settings" '$d->{settings}' "{\"budget\":40,\"plugin_dir\":\"$P\",\"timeout\":7}"
jis "--check-config: names the file and the host" '[$d->{config}, length($d->{host}) > 0 ? 1 : 0]' "[\"$T/candidate.conf\",1]"
expect_eq "--check-config: the configured config is not needed (absent.conf)" "" "$ERR"
nc --check-config "$T/other.conf"
jis "--check-config: reads the file given, not the configured one" '[map { $_->{name} } @{$d->{checks}}]' '["other"]'
jis "--check-config: default settings when the file has none" '$d->{settings}{budget}' 50
echo "# nothing" > "$T/empty.conf"
nc --check-config "$T/empty.conf"
expect_eq "--check-config: a config with no checks parses (exit 0)" 0 "$RC"
jis "--check-config: ...with an empty list" '$d->{checks}' '[]'
# nothing is run
rm -f "$T/ran"
plugin ran_p 'touch "'"$T"'/ran"; echo OK; exit 0'
printf '%s\n' "plugin_dir = $P" "r = ran_p" > "$T/ran.conf"
nc --check-config "$T/ran.conf"
[ ! -e "$T/ran" ] && pass "--check-config: no plugin is run" || fail "--check-config: no plugin is run"

SECRET="topsecretword"
for body in "garbage $SECRET" "ok = " "timeout = abc" "budget = 0" "bad name = ok_p" "dup = ok_p
dup = ok_p" "q = ok_p 'unterminated $SECRET" "x = ok_p
y $SECRET"; do
    printf '%s\n' "$body" > "$T/bad.conf"
    nc --check-config "$T/bad.conf"
    expect_eq "--check-config bad '${body//$'\n'/ / }': exit 3" 3 "$RC"
    is_json && jis "--check-config bad: error names the file and a line" '$d->{error} =~ /bad\.conf line \d/ ? 1 : 0' 1 || fail "--check-config bad: JSON"
    expect_lacks "--check-config bad: the line is not echoed" "$OUT" "$SECRET"
    jis "--check-config bad: state and no checks" '[$d->{state}, exists $d->{checks} ? 1 : 0]' '["UNKNOWN",0]'
done
nc --check-config "$T/nonexistent.conf"
expect_eq "--check-config: missing file exit 3" 3 "$RC"
expect_has "--check-config: missing file named" "$OUT" "nonexistent.conf"
nc --check-config
expect_eq "--check-config without a file: exit 3" 3 "$RC"
nc --check-config "$T/ok.conf" extra
expect_eq "--check-config with two files: exit 3" 3 "$RC"
nc --check-config "$T/empty.conf" ok
expect_eq "--check-config with a check name too: exit 3" 3 "$RC"
perl -MJSON::PP -e 'open my $f, "<", $ARGV[0] or exit 1; local $/; my $d = decode_json(<$f>);
    exit(exists $d->{arguments}{properties}{check_config} && grep { ($_->{flag} // "") eq "--check-config" } @{$d->{argv}} ? 0 : 1)' "$SCHEMA" \
    && pass "sidecar describes --check-config" || fail "sidecar describes --check-config"

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
heading "Run budget, default timeout and the warning"

# Default timeout is 10 s: six checks add up to 60 s, five to 50 s (= budget 50).
{ echo "plugin_dir = $P"; for n in 1 2 3 4 5 6; do echo "c$n = ok_p"; done; } > "$CONF"
nc c1 c2 c3 c4 c5 c6
jis "default timeout 10: six checks add up to 60s, over the default budget of 50s" '$d->{warning}' \
    '"check timeouts add up to 60s, over the 50s budget; split the checks over several calls or lower timeout"'
expect_has "the warning is also on stderr" "$ERR" "check timeouts add up to 60s"
is_json && pass "with a warning, stdout is still one JSON document" || fail "with a warning, stdout is still one JSON document" "$OUT"
jis "with a warning the checks still ran" '[$d->{state}, scalar @{$d->{checks}}]' '["OK",6]'
nc c1 c2 c3 c4 c5
expect_lacks "five checks (50s) fit the default budget: no warning field" "$OUT" '"warning"'
expect_eq "...and nothing on stderr" "" "$ERR"

# budget 1 s, timeout 5 s: the slow check is capped at the budget, the rest are not run
conf "slow = slow_p" "ok = ok_p" "ok2 = ok_p" "timeout = 5" "budget = 1"
nc slow ok ok2
is_json && pass "budget spent: stdout is one JSON document" || fail "budget spent: stdout is one JSON document" "$OUT"
jis "effective timeout is capped by the budget left" '$d->{checks}[0]{summary}' '"timed out after 1s (run budget)"'
jis "a check that cannot start is UNKNOWN 'not run' with duration 0" \
    '[map { ($_->{state}, $_->{summary}, $_->{duration_ms}) } @{$d->{checks}}[1,2]]' \
    '["UNKNOWN","not run: run budget of 1s spent",0,"UNKNOWN","not run: run budget of 1s spent",0]'
jis "the reply still comes back: three checks, overall UNKNOWN" '[scalar @{$d->{checks}}, $d->{state}]' '[3,"UNKNOWN"]'
jis "timeouts (15s) over the budget: warning names both" '$d->{warning}' \
    '"check timeouts add up to 15s, over the 1s budget; split the checks over several calls or lower timeout"'
conf "ok = ok_p" "budget = 2"
nc ok
expect_lacks "a fast check within budget is untouched" "$OUT" "not run"
conf "ok = ok_p" "budget = 0"
nc ok
expect_has "budget must be a whole number >= 1" "$OUT" "budget must be a whole number"

# ---------------------------------------------------------------------------
heading "--list availability and plugin_dir with several directories"

conf "ok = ok_p -w 5" "missing = nothing_here_p" "notexec = notexec_p" "symlink = escape_p"
nc --list
expect_eq "--list with unavailable plugins: exit 3" 3 "$RC"
jis "--list: available and unavailable, plugin name only" '[map { $_->{name} . ":" . $_->{plugin} . ":" . ($_->{available} ? 1 : 0) } @{$d->{checks}}]' \
    '["ok:ok_p:1","missing:nothing_here_p:0","notexec:notexec_p:0","symlink:escape_p:0"]'
jis "--list: reason for a missing plugin" '$d->{checks}[1]{reason}' "\"plugin not found in $P\""
expect_has "--list: reason for a non-executable plugin" "$(jv '$d->{checks}[2]{reason}')" "plugin not executable"
expect_has "--list: reason for a link that leaves plugin_dir" "$(jv '$d->{checks}[3]{reason}')" "outside plugin_dir"
jis "--list: an available check has no reason and shows no arguments" '[exists $d->{checks}[0]{reason} ? 1 : 0, exists $d->{checks}[0]{args} ? 1 : 0]' '[0,0]'
nc missing
expect_has "run: the summary names the plugin" "$(jv '$d->{checks}[0]{summary}')" "nothing_here_p: plugin not found in $P"
conf "ok = ok_p" "dup = dup_p"
plugin dup_p 'echo "OK - first dir"'
nc --list
expect_eq "--list when all are available: exit 0" 0 "$RC"

P2="$T/plugins2"
mkdir -p "$P2"
printf '#!/bin/bash\n%s\n' 'echo "OK - second dir"' > "$P2/dup_p"
printf '#!/bin/bash\n%s\n' 'echo "OK - only in second"' > "$P2/second_p"
chmod 755 "$P2/dup_p" "$P2/second_p"
ln -s "$P/ok_p" "$P2/link_p"
printf '%s\n' "plugin_dir = $P:$P2" "timeout = 1" "dup = dup_p" "second = second_p" "link = link_p" "none = none_p" > "$CONF"
nc dup second link none
jis "several dirs: the first match wins" '$d->{checks}[0]{summary}' '"OK - first dir"'
jis "several dirs: a plugin only in a later dir is found" '$d->{checks}[1]{summary}' '"OK - only in second"'
expect_has "containment is checked against the dir the plugin was found in" "$(jv '$d->{checks}[2]{summary}')" "outside plugin_dir"
expect_has "not found: every dir is named" "$(jv '$d->{checks}[3]{summary}')" "none_p: plugin not found in $P:$P2"
printf '%s\n' "plugin_dir = $P2:$P" "timeout = 1" "dup = dup_p" > "$CONF"
nc dup
jis "several dirs: order decides (reversed)" '$d->{checks}[0]{summary}' '"OK - second dir"'

# ---------------------------------------------------------------------------
heading "check_mem"

CM="$DIR/plugins/check_mem"
MI="$T/meminfo"
# mem KB_TOTAL KB_AVAILABLE ARGS...: runs check_mem on a fake meminfo
mem() {
    printf 'MemTotal:       %s kB\nMemFree:        1000 kB\nMemAvailable:   %s kB\n' "$1" "$2" > "$MI"
    shift 2
    OUT="$(CHECK_MEM_MEMINFO="$MI" bash "$CM" "$@" 2>&1)"
    RC=$?
}
[ -x "$CM" ] && pass "check_mem is executable" || fail "check_mem is executable"
mem 16000000 10000000
expect_eq "62% available: exit 0" 0 "$RC"
expect_has "OK output with sizes" "$OUT" "MEM OK - 62% available (9.5 GiB of 15.3 GiB) |"
expect_has "perfdata in MB with warn/crit/min/max" "$OUT" "available=9765MB;1562;781;0;15625 available_pct=62%;10;5;0;100"
mem 16000000 1200000
expect_eq "7% available, defaults: WARNING exit 1" 1 "$RC"
expect_has "WARNING output" "$OUT" "MEM WARNING - 7% available"
mem 16000000 400000
expect_eq "2% available, defaults: CRITICAL exit 2" 2 "$RC"
expect_has "CRITICAL output" "$OUT" "MEM CRITICAL - 2% available"
mem 16000000 3200000 -w 25 -c 10
expect_eq "20% with -w 25 -c 10: WARNING" 1 "$RC"
mem 16000000 1600000 -w 25 -c 10
expect_eq "10% with -w 25 -c 10: WARNING (CRITICAL is below the limit)" 1 "$RC"
mem 16000000 1500000 -w 25 -c 10
expect_eq "9% with -w 25 -c 10: CRITICAL" 2 "$RC"
mem 16000000 10000000 -w abc
expect_eq "bad -w: UNKNOWN exit 3" 3 "$RC"
expect_has "bad -w: says UNKNOWN" "$OUT" "MEM UNKNOWN"
mem 16000000 10000000 -w 5 -c 10
expect_eq "-w below -c: UNKNOWN" 3 "$RC"
mem 16000000 10000000 -x
expect_eq "unknown option: UNKNOWN" 3 "$RC"
mem 16000000 10000000 extra
expect_eq "stray argument: UNKNOWN" 3 "$RC"
printf 'MemTotal: 16000000 kB\nMemFree: 1000 kB\n' > "$MI"
OUT="$(CHECK_MEM_MEMINFO="$MI" bash "$CM" 2>&1)"
RC=$?
expect_eq "no MemAvailable: exit 3" 3 "$RC"
expect_has "no MemAvailable: UNKNOWN names it" "$OUT" "MEM UNKNOWN - no MemAvailable"
OUT="$(CHECK_MEM_MEMINFO="$T/nonexistent" bash "$CM" 2>&1)"
RC=$?
expect_eq "no meminfo file: exit 3" 3 "$RC"
OUT="$(bash "$CM" 2>&1)"
RC=$?
[ "$RC" -le 2 ] && pass "real /proc/meminfo: exit $RC" || fail "real /proc/meminfo" "exit $RC: $OUT"
printf '%s\n' "plugin_dir = $DIR/plugins" "timeout = 5" "mem = check_mem -w 1 -c 1" > "$CONF"
printf "MemTotal: 16000000 kB\nMemAvailable: 10000000 kB\n" > "$MI"
CHECK_MEM_MEMINFO="$MI" nc mem
jis "through the wrapper: perfdata parsed" '[$d->{checks}[0]{perfdata}[1]{label}, $d->{checks}[0]{perfdata}[1]{uom}]' '["available_pct","%"]'

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
    echo "x" > "$F/agent-04.fail"
    NAGIOS_JOB_CONF="$JOBCONF_EXAMPLE" job
    expect_has "example config: agent-03 asked for its check" "$CALLS" "run agent-03 --script nagios-check -- http_example"
    expect_has "example config: agent-01 asked for three checks" "$CALLS" "run agent-01 --script nagios-check -- disk_root load swap"
    expect_has "example config: one agent, local and network checks in separate calls" "$CALLS" "run agent-04 --script nagios-check -- disk load mem"
    expect_has "example config: ...the second call" "$CALLS" "run agent-04 --script nagios-check -- web_health ping_gateway"
    grep -q '^schedule *= *\*/5 \* \* \* \*$' "$JOBCONF_EXAMPLE" && pass "example config has a schedule" || fail "example config has a schedule"
else
    fail "nagios-checks.conf.example exists"
fi
[ -x "$JOB" ] && pass "nagios-checks.sh is executable" || fail "nagios-checks.sh is executable"

# ---------------------------------------------------------------------------
heading "install.sh (temp root, fake systemctl and runuser, no root needed)"

INST="$DIR/install.sh"
IB="$T/ibin"
R="$T/iroot"
mkdir -p "$IB"
printf '#!/bin/bash\necho "$*" >> "$STUB_SYSTEMCTL_LOG"\nexit 0\n' > "$IB/systemctl"
printf '#!/bin/bash\nshift 3\nNAGIOS_CHECKS_CONF="$NC_ROOT/etc/nagios-checks/checks.conf" exec "$@"\n' > "$IB/runuser"
chmod 755 "$IB/systemctl" "$IB/runuser"
export STUB_SYSTEMCTL_LOG="$T/systemctl.log"

# newroot [noplugins] [noscripts] [noexec]: a fresh agent host under $R
newroot() {
    rm -rf "$R"
    mkdir -p "$R/etc/ctrl-exec-agent" "$R/usr/lib/nagios/plugins"
    : > "$STUB_SYSTEMCTL_LOG"
    printf '#!/bin/sh\n' > "$R/usr/lib/nagios/plugins/check_disk"
    printf '# agent scripts\n' > "$R/etc/ctrl-exec-agent/scripts.conf"
    printf 'executor_socket = /run/x.sock\n\n[profile default]\nrun_as = nobody\n' > "$R/etc/ctrl-exec-agent/agent.conf"
    for o in "$@"; do
        case "$o" in
            noplugins) rm -f "$R/usr/lib/nagios/plugins/check_disk" ;;
            noscripts) rm -f "$R/etc/ctrl-exec-agent/scripts.conf" ;;
            noprofile) printf 'executor_socket = /run/x.sock\n' > "$R/etc/ctrl-exec-agent/agent.conf" ;;
        esac
    done
}
# inst ARGS...: runs the installer against $R; OUT holds its output, RC its exit
inst() {
    OUT="$(NC_ROOT="$R" NC_ALLOW_NONROOT=1 PATH="$IB:$PATH" bash "$INST" "$@" 2>&1 < /dev/null)"
    RC=$?
}

newroot
inst
expect_eq "fresh install: exit 0" 0 "$RC"
expect_has "fresh install: reports 5 changes (script, check_mem, folder, config, scripts.conf)" "$OUT" "done: 5 changed"
[ -x "$R/opt/ctrl-exec-scripts/nagios-check.pl" ] && pass "fresh install: script installed 755" || fail "fresh install: script installed 755"
cmp -s "$NC" "$R/opt/ctrl-exec-scripts/nagios-check.pl" && pass "fresh install: script is a copy of ours" || fail "fresh install: script is a copy of ours"
[ -x "$R/usr/local/lib/nagios/plugins/check_mem" ] && pass "fresh install: check_mem installed" || fail "fresh install: check_mem installed"
expect_eq "fresh install: config is 644" 644 "$(stat -c %a "$R/etc/nagios-checks/checks.conf")"
expect_eq "fresh install: config folder is 755" 755 "$(stat -c %a "$R/etc/nagios-checks")"
expect_has "fresh install: the folder is reported" "$OUT" "changed created $R/etc/nagios-checks"
[ ! -e "$R/etc/nagios-checks.conf" ] && pass "fresh install: nothing at the old path" || fail "fresh install: nothing at the old path"
expect_has "fresh install: scripts.conf entry added" "$(cat "$R/etc/ctrl-exec-agent/scripts.conf")" "nagios-check = $R/opt/ctrl-exec-scripts/nagios-check.pl"
expect_has "fresh install: agent reloaded" "$(cat "$STUB_SYSTEMCTL_LOG")" "reload ctrl-exec-agent"
expect_has "fresh install: verify line printed" "$OUT" "verify as"

: > "$STUB_SYSTEMCTL_LOG"
inst
expect_has "second run: nothing changed" "$OUT" "done: 0 changed"
expect_lacks "second run: no changed line" "$OUT" "changed /"
expect_eq "second run: no reload" "" "$(cat "$STUB_SYSTEMCTL_LOG")"
expect_eq "second run: scripts.conf has one entry" 1 "$(grep -c '^nagios-check' "$R/etc/ctrl-exec-agent/scripts.conf")"

echo "# my own checks" > "$R/etc/nagios-checks/checks.conf"
chmod 600 "$R/etc/nagios-checks/checks.conf"
echo "tampered" >> "$R/opt/ctrl-exec-scripts/nagios-check.pl"
inst
expect_eq "existing config: kept" "# my own checks" "$(cat "$R/etc/nagios-checks/checks.conf")"
cmp -s "$DIR/nagios-checks.conf.example" "$R/etc/nagios-checks/checks.conf.new" && pass "existing config: shipped one in .new" || fail "existing config: shipped one in .new"
expect_has "existing config: warned" "$OUT" "kept your"
expect_has "existing config: mode fixed and said so" "$OUT" "mode set to 644"
expect_eq "existing config: mode is 644" 644 "$(stat -c %a "$R/etc/nagios-checks/checks.conf")"
cmp -s "$NC" "$R/opt/ctrl-exec-scripts/nagios-check.pl" && pass "different script replaced" || fail "different script replaced"

# the config of an earlier install, at the old path, is moved
newroot
printf '%s\n' "# my old checks" "disk = check_disk" > "$R/etc/nagios-checks.conf"
chmod 640 "$R/etc/nagios-checks.conf"
inst
expect_eq "old path only: exit 0" 0 "$RC"
expect_has "old path only: reported as changed" "$OUT" "changed moved $R/etc/nagios-checks.conf to $R/etc/nagios-checks/checks.conf"
[ ! -e "$R/etc/nagios-checks.conf" ] && pass "old path only: the old file is gone" || fail "old path only: the old file is gone"
expect_eq "old path only: contents kept" $'# my old checks\ndisk = check_disk' "$(cat "$R/etc/nagios-checks/checks.conf")"
expect_eq "old path only: the unprivileged user can read it (mode fixed)" 644 "$(stat -c %a "$R/etc/nagios-checks/checks.conf")"
expect_has "old path only: the shipped config is offered as .new" "$OUT" "kept your $R/etc/nagios-checks/checks.conf"
expect_lacks "old path only: not replaced by the example" "$(cat "$R/etc/nagios-checks/checks.conf")" "monitoring-plugins"
inst
expect_has "old path only, second run: nothing more to move" "$OUT" "done: 0 changed"
expect_lacks "old path only, second run: no move" "$OUT" "changed moved"

newroot
cp "$DIR/nagios-checks.conf.example" "$R/etc/nagios-checks.conf"
inst
expect_has "old path equals the example: moved" "$OUT" "moved $R/etc/nagios-checks.conf"
expect_has "old path equals the example: then matches it" "$OUT" "checks.conf matches the shipped example"
expect_eq "old path equals the example: no .new" "" "$(compgen -G "$R/etc/nagios-checks/*.new")"

newroot
echo "# old" > "$R/etc/nagios-checks.conf"
mkdir -p "$R/etc/nagios-checks"
echo "# new one" > "$R/etc/nagios-checks/checks.conf"
chmod 644 "$R/etc/nagios-checks/checks.conf"
inst
expect_eq "both exist: the new one is not overwritten" "# new one" "$(cat "$R/etc/nagios-checks/checks.conf")"
expect_eq "both exist: the old one is left" "# old" "$(cat "$R/etc/nagios-checks.conf")"
expect_has "both exist: warned that the old one is not read" "$OUT" "is not read"
expect_lacks "both exist: nothing is moved" "$OUT" "changed moved"

newroot
mkdir -p "$R/etc/nagios-checks"
chmod 750 "$R/etc/nagios-checks"
inst
expect_eq "existing folder: mode left alone" 750 "$(stat -c %a "$R/etc/nagios-checks")"
expect_has "existing folder: not created again" "$OUT" "done: 4 changed"
expect_has "existing folder that others cannot enter: warned" "$OUT" "must be able to enter it"
chmod 755 "$R/etc/nagios-checks"

newroot
echo "# old" > "$R/etc/nagios-checks.conf"
inst --dry-run
expect_has "dry-run, old path only: says it would move" "$OUT" "changed moved $R/etc/nagios-checks.conf to $R/etc/nagios-checks/checks.conf (the old path is no longer read) (dry-run"
[ -f "$R/etc/nagios-checks.conf" ] && [ ! -e "$R/etc/nagios-checks" ] && pass "dry-run, old path only: nothing moved or made" || fail "dry-run, old path only: nothing moved or made"

newroot
echo "nagios-check = /srv/elsewhere/nagios-check" >> "$R/etc/ctrl-exec-agent/scripts.conf"
inst
expect_has "scripts.conf other path: warned with the path" "$OUT" "nagios-check = /srv/elsewhere/nagios-check"
expect_eq "scripts.conf other path: left alone" 2 "$(wc -l < "$R/etc/ctrl-exec-agent/scripts.conf")"
expect_eq "scripts.conf other path: no reload" "" "$(cat "$STUB_SYSTEMCTL_LOG")"

newroot noscripts
inst
expect_eq "no scripts.conf: exit 1" 1 "$RC"
expect_has "no scripts.conf: FAIL line" "$OUT" "FAIL"
expect_has "no scripts.conf: says why" "$OUT" "ctrl-exec agent not installed?"

newroot noplugins
inst
expect_eq "no plugins: still exit 0" 0 "$RC"
expect_has "no plugins: warns" "$OUT" "install monitoring-plugins-basic"

newroot noprofile
inst
expect_has "no default profile: warns" "$OUT" "no [profile default]"
expect_has "no default profile: gives the snippet" "$OUT" "run_as = nobody"
expect_eq "no default profile: agent.conf untouched" "executor_socket = /run/x.sock" "$(cat "$R/etc/ctrl-exec-agent/agent.conf")"

newroot
inst --dry-run
expect_eq "dry-run: exit 0" 0 "$RC"
expect_has "dry-run: says what would change" "$OUT" "changed installed $R/opt/ctrl-exec-scripts/nagios-check.pl (dry-run"
expect_eq "dry-run: nothing written" "" "$(find "$R/opt" "$R/usr/local" "$R/etc/nagios-checks" "$R/etc/nagios-checks.conf" 2> /dev/null)"
expect_eq "dry-run: scripts.conf untouched" "# agent scripts" "$(cat "$R/etc/ctrl-exec-agent/scripts.conf")"
expect_eq "dry-run: no reload" "" "$(cat "$STUB_SYSTEMCTL_LOG")"

newroot
inst --script-dir /srv/scripts
expect_has "--script-dir: used" "$(cat "$R/etc/ctrl-exec-agent/scripts.conf")" "nagios-check = $R/srv/scripts/nagios-check.pl"

OUT="$(bash "$INST" 2>&1 < /dev/null)"; RC=$?
if [ "$(id -u)" != 0 ]; then
    expect_eq "non-root without --dry-run: exit 1" 1 "$RC"
    expect_has "non-root without --dry-run: FAIL" "$OUT" "FAIL must run as root"
fi
shellcheck -x "$INST" > /dev/null 2>&1 && pass "install.sh is shellcheck clean" || { command -v shellcheck > /dev/null && fail "install.sh is shellcheck clean" || skip "shellcheck not installed"; }

# ---------------------------------------------------------------------------
echo
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
if [ "$FAIL" -eq 0 ]; then echo "VERDICT: PASS"; else echo "VERDICT: FAIL"; fi
[ "$FAIL" -eq 0 ]
