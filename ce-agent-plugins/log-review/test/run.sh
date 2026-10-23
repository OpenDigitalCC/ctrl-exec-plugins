#!/bin/bash
# Test suite for the log-review plugin. Run: bash test/run.sh
#
# Covers the agent script and install.sh:
#   - config parsing and every refusal (names the line, never echoes values)
#   - the caller's bounds: lines, span, names, usage
#   - file sources: tail correctness (large files, block boundaries, no
#     trailing newline), match=, control characters, the line cap, symlink,
#     non-regular and missing files, an unreadable file, --since
#   - journal sources against a STUB journalctl on LOG_REVIEW_JOURNALCTL that
#     records its argv: the exact argv, -u or -t, -p, -n, --since, and that no
#     text of the caller ever reaches it; timeout; failure; unreadable journal
#   - --list, --check-config (folder restriction), --text, the schema sidecar
#   - install.sh in a temp root with fake systemctl and runuser
# Needs perl and bash only, no network, no root, no real journal. The timeout
# tests wait one or two seconds.
# shellcheck disable=SC2015,SC2016  # A && pass || fail is intended
set -u
DIR="$(cd "$(dirname "$0")/.." && pwd)"
LR="$DIR/log-review.pl"
SCHEMA="$DIR/log-review.pl.schema.json"

PASS=0 FAIL=0 SKIP=0
T="$(mktemp -d "${TMPDIR:-/tmp}/log-review-test.XXXXXX")" || exit 2
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

ETC="$T/etc"
CONF="$ETC/sources.conf"
mkdir -p "$ETC"
export LOG_REVIEW_CONF="$CONF"

# the stub journalctl: records its argv, prints $STUB_OUT, can fail or sleep
JB="$T/jbin"
mkdir -p "$JB"
cat > "$JB/journalctl" <<'EOF'
#!/bin/bash
{ printf 'ARGV'; for a in "$@"; do printf ' [%s]' "$a"; done; echo; } >> "$STUB_LOG"
[ -n "${STUB_PIDFILE:-}" ] && echo $$ > "$STUB_PIDFILE"
[ -n "${STUB_ERR:-}" ] && echo "$STUB_ERR" >&2
[ -n "${STUB_OUT:-}" ] && cat "$STUB_OUT"
[ -n "${STUB_SLEEP:-}" ] && exec sleep "$STUB_SLEEP"
exit "${STUB_EXIT:-0}"
EOF
chmod 755 "$JB/journalctl"
export LOG_REVIEW_JOURNALCTL="$JB/journalctl"
export STUB_LOG="$T/stub.log"
: > "$STUB_LOG"
unset STUB_OUT STUB_ERR STUB_EXIT STUB_SLEEP STUB_PIDFILE

# conf LINE...: writes the config
conf() { printf '%s\n' "$@" > "$CONF"; }

# lr ARGS...: runs the script; OUT is its stdout, ERR its stderr, RC its exit
lr() {
    OUT="$(perl "$LR" "$@" 2> "$T/err" < /dev/null)"
    RC=$?
    ERR="$(cat "$T/err")"
}

# jv EXPR: evaluates a perl expression on the decoded $OUT as $d
jv() { printf '%s' "$OUT" | perl -MJSON::PP -e '
    my $d = decode_json(do { local $/; <STDIN> });
    my $v = eval $ARGV[0]; die $@ if $@;
    print JSON::PP->new->canonical->allow_nonref->encode($v);' "$1"; }
is_json() { printf '%s' "$OUT" | perl -MJSON::PP -e 'decode_json(do { local $/; <STDIN> }); exit 0' 2> /dev/null; }
jis() { expect_eq "$1" "$3" "$(jv "$2" 2>&1)"; }
# stub calls so far
calls() { wc -l < "$STUB_LOG"; }
last_argv() { tail -n 1 "$STUB_LOG"; }
# newline-free list of the lines of the last JSON answer
jlines() { jv '$d->{lines}'; }

echo "# Test report: log-review (ce-agent-plugins)"
echo "Generated: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"

# ---------------------------------------------------------------------------
heading "Contract: usage, the script and the sidecar"

conf "f = file $T/none.log"
lr
expect_eq "no arguments exits 2" 2 "$RC"
expect_has "no arguments prints usage on stderr" "$ERR" "usage: log-review"
expect_eq "no arguments prints nothing on stdout" "" "$OUT"
[ -x "$LR" ] && pass "log-review.pl is executable" || fail "log-review.pl is executable"
expect_eq "log-review.pl has a perl shebang" '#!/usr/bin/perl' "$(head -1 "$LR")"
perl -c "$LR" > /dev/null 2>&1 && pass "perl -c passes" || fail "perl -c passes"
n="$(wc -l < "$LR")"
[ "$n" -le 520 ] && pass "script stays small ($n lines)" || fail "script stays small" "$n lines"
grep -nE '^\s*use [A-Z]' "$LR" | grep -vE 'use (strict|warnings|Cwd|Encode|Fcntl|JSON::PP|POSIX|Sys::Hostname|Time::HiRes|Time::Local)\b' > "$T/uses" || true
expect_eq "core modules only" "" "$(cat "$T/uses")"
grep -qE '(system|qx)\s*[(`]|`|\bopen\s*\([^)]*\|' "$LR" && fail "no shell: no system, qx, backticks or piped open" || pass "no shell: no system, qx, backticks or piped open"
perl -MJSON::PP -e 'open my $f, "<", $ARGV[0] or exit 1; local $/; my $d = decode_json(<$f>);
    exit($d->{arguments} && $d->{argv} && $d->{read_only} ? 0 : 1)' "$SCHEMA" \
    && pass "schema sidecar is valid JSON with arguments, argv and read_only" \
    || fail "schema sidecar is valid JSON with arguments, argv and read_only"
perl -MJSON::PP -e 'open my $f, "<", $ARGV[0] or exit 1; local $/; my $d = decode_json(<$f>);
    my $p = $d->{arguments}{properties};
    my $re = $p->{since}{pattern};
    exit(1) unless $p->{lines}{minimum} == 1 && $p->{lines}{maximum} == 1000 && $p->{lines}{type} eq "integer";
    exit(1) unless "90m" =~ /$re/ && "7d" =~ /$re/ && "7w" !~ /$re/ && "m" !~ /$re/;
    exit(1) unless $p->{list}{type} eq "boolean" && $p->{check_config}{type} eq "string" && $p->{text}{type} eq "boolean" && $p->{name}{type} eq "string";
    my %f = map { ($_->{arg} => $_->{flag}) } @{ $d->{argv} };
    exit(1) unless $f{list} eq "--list" && $f{check_config} eq "--check-config" && $f{text} eq "--text" && $f{lines} eq "--lines" && $f{since} eq "--since";
    exit 0' "$SCHEMA" \
    && pass "schema sidecar: lines 1..1000, since pattern, flags" \
    || fail "schema sidecar: lines 1..1000, since pattern, flags"

# ---------------------------------------------------------------------------
heading "Config: parsing and refusals (each names the line, none echoes a value)"

# badconf LABEL WANT LINE...: config with LINE(s) must exit 3 naming the problem
badconf() {
    local label="$1" want="$2"
    shift 2
    conf "$@"
    lr --list
    expect_eq "$label: exit 3" 3 "$RC"
    expect_has "$label: says why" "$OUT" "$want"
    expect_lacks "$label: does not echo the value" "$OUT" "SECRETVAL"
    is_json && pass "$label: stdout is one JSON document" || fail "$label: stdout is one JSON document" "$OUT"
}

badconf "no equals sign" "line 2: expected 'key = value'" "# first" "SECRETVAL garbage"
badconf "bad source name" "line 1: bad source name" "bad.name = file /var/log/SECRETVAL"
badconf "duplicate source" "line 3: source 'a' defined twice" "a = file /var/log/x" "# c" "a = file /var/log/SECRETVAL"
badconf "unknown kind" "kind must be journal or file" "a = tail /var/log/SECRETVAL"
badconf "journal bare word" "bare word" "a = journal SECRETVAL"
badconf "journal unit and id" "not both" "a = journal unit=x.service id=SECRETVAL"
badconf "journal neither" "name a unit= or an id=" "a = journal priority=err"
badconf "journal unknown option" "unknown option 'foo'" "a = journal id=x foo=SECRETVAL"
badconf "journal option twice" "'id' given twice" "a = journal id=x id=SECRETVAL"
badconf "journal bad priority" "priority must be 0-7 or" "a = journal id=x priority=SECRETVAL"
badconf "journal priority 8" "priority must be 0-7 or" "a = journal id=x priority=8"
badconf "journal unit with shell characters" "unit must look like" "a = journal unit=x;SECRETVAL"
badconf "journal id starting with a dash" "id must be a syslog identifier" "a = journal id=-SECRETVAL"
badconf "journal id with a slash" "id must be a syslog identifier" "a = journal id=a/SECRETVAL"
badconf "file relative path" "path must be absolute" "a = file var/log/SECRETVAL"
badconf "file dot-dot" "must be normalised" "a = file /var/../SECRETVAL"
badconf "file dot segment" "must be normalised" "a = file /var/./SECRETVAL"
badconf "file double slash" "must be normalised" "a = file /var//SECRETVAL"
badconf "file trailing slash" "must be normalised" "a = file /var/SECRETVAL/"
badconf "file root" "must be normalised" "a = file /"
badconf "file two paths" "one path only" "a = file /var/log/a /var/SECRETVAL"
badconf "file no path" "no path given" "a = file"
badconf "file path with control character" "outside printable ASCII" "$(printf 'a = file /var/log/SECRETVAL\001')"
badconf "bad regex" "match= is not a valid regex" "a = file /var/log/x match=(SECRETVAL"
badconf "regex with code block" "match= is not a valid regex" 'a = file /var/log/x match=(?{ system("SECRETVAL") })'
badconf "empty regex" "match= is empty" "a = file /var/log/x match="
badconf "max_lines above 1000" "line 1: max_lines must not be above 1000" "max_lines = 1001"
badconf "max_lines zero" "max_lines must be a whole number" "max_lines = 0"
badconf "max_lines text" "max_lines must be a whole number" "max_lines = SECRETVAL"
badconf "default_lines text" "default_lines must be a whole number" "default_lines = -1"
badconf "max_span above 7d" "line 1: max_span must not be above 7d" "max_span = 8d"
badconf "max_span above 7d in hours" "max_span must not be above 7d" "max_span = 169h"
badconf "max_span bad unit" "max_span must be a number and one of" "max_span = 7w"
badconf "max_span no number" "max_span must be a number and one of" "max_span = d"
badconf "timeout zero" "timeout must be 1 to 600" "timeout = 0"
badconf "timeout too big" "timeout must be 1 to 600" "timeout = 601"
badconf "default_lines above max_lines" "line 2: default_lines must not be above max_lines (50)" "max_lines = 50" "default_lines = 60"
badconf "default_lines above a later max_lines" "line 1: default_lines must not be above max_lines (50)" "default_lines = 60" "max_lines = 50"

conf "a = file /var/log/x" "b = journal id=y"
printf 'a = file /var/log/x\n\n   # indented comment\n  b   =   journal   id=y   \n' > "$CONF"
lr --list
expect_eq "comments, blanks and spacing: exit 0" 0 "$RC"
jis "comments, blanks and spacing: both sources" '[map { $_->{name} } @{ $d->{sources} }]' '["a","b"]'

LR_BAK="$LOG_REVIEW_CONF"
LOG_REVIEW_CONF="$T/etc/missing.conf" lr --list
expect_eq "missing config: exit 3" 3 "$RC"
expect_has "missing config: names the path and the user" "$OUT" "cannot read config $T/etc/missing.conf as user"
export LOG_REVIEW_CONF="$LR_BAK"

conf "max_lines = 1000" "max_span = 168h" "default_lines = 1000" "timeout = 600" "a = file /var/log/x"
lr --list
expect_eq "limits exactly at the caps are accepted" 0 "$RC"
jis "limits at the caps: settings" '$d->{settings}' '{"default_lines":1000,"max_lines":1000,"max_span_seconds":604800,"timeout":600}'
conf "max_lines = 50" "max_span = 2h" "a = file /var/log/x"
lr --list
jis "lowered caps: settings (default_lines follows max_lines)" '$d->{settings}' '{"default_lines":50,"max_lines":50,"max_span_seconds":7200,"timeout":15}'
conf "a = file /var/log/x"
lr --list
jis "defaults: 1000 lines, 100 default, 7d, 15 s" '$d->{settings}' '{"default_lines":100,"max_lines":1000,"max_span_seconds":604800,"timeout":15}'
conf "a=file /var/log/x"
lr --list
expect_eq "'key=value' without spaces is accepted" 0 "$RC"
conf "a-b_9 = file /var/log/x" "_u = journal unit=ssh@host.service" "dot = journal unit=getty@tty1.service priority=3"
lr --list
expect_eq "names with - and _, templated unit: exit 0" 0 "$RC"
conf "a = file /var/log/x match=a b  c = d"
lr --list
expect_eq "a regex with spaces and '=' is kept whole (the rest of the line)" 0 "$RC"

# ---------------------------------------------------------------------------
heading "The caller: names, bounds and usage"

seq 1 300 | sed 's/^/line /' > "$T/f.log"
conf "f = file $T/f.log" "j = journal id=sshd"
: > "$STUB_LOG"
lr nosuch
expect_eq "unknown name: exit 2" 2 "$RC"
jis "unknown name: error names the known sources" '$d->{error}' '"unknown source '"'"'nosuch'"'"'; known: f, j"'
for bad in 'a/b' '../etc/passwd' '/etc/passwd' 'a;ls' 'a b' '$HOME' '`id`' 'a*' ''; do
    lr "$bad"
    expect_eq "name '$bad': exit 2" 2 "$RC"
done
lr 'a;ls'
jis "bad name: says so, does not echo it" '$d->{error}' '"bad source name"'
for v in 0 1001 abc -5 1.5 '' ' 5' 5x 99999999; do
    lr f --lines "$v"
    expect_eq "--lines '$v': exit 2" 2 "$RC"
    is_json && pass "--lines '$v': error is JSON" || fail "--lines '$v': error is JSON"
done
lr f --lines 1001
jis "--lines 1001: error says the range" '$d->{error}' '"--lines must be 1 to 1000"'
for v in 8d 169h 604801s 10081m 7x 0m 1 d -1h '1h;ls' '1 h' 1.5h 99999999999d ''; do
    lr f --since "$v"
    expect_eq "--since '$v': exit 2" 2 "$RC"
done
lr f --lines 1000 --since 7d
expect_eq "--lines 1000 --since 7d are the caps and accepted" 1 "$RC"    # no timestamps in this file: refused for that, not the bounds
expect_has "...and the file is refused for its lines, not the bounds" "$OUT" "--since is not supported for this file"
lr f --since 168h
expect_has "--since 168h is accepted (7 days)" "$OUT" "not supported for this file"
conf "max_lines = 50" "max_span = 2h" "f = file $T/f.log"
lr f --lines 51
expect_eq "lowered cap: 51 refused" 2 "$RC"
jis "lowered cap: message gives the lowered limit" '$d->{error}' '"--lines must be 1 to 50"'
lr f --since 121m
expect_eq "lowered span: 121m refused" 2 "$RC"
lr f --lines 50
expect_eq "lowered cap: 50 accepted" 0 "$RC"
conf "f = file $T/f.log" "j = journal id=sshd"
lr f --lines
expect_eq "--lines without a value: usage, exit 2" 2 "$RC"
expect_has "--lines without a value: usage on stderr" "$ERR" "usage:"
for args in "--bogus" "-x" "f g" "f --list" "--list f" "--list --text" "--list --lines 5" "--check-config" "--check-config $CONF f" "--check-config $CONF --text" "--text" "--lines 5" "f --lines 5 --lines 6" "f --since 1h --since 2h" "f --text --text" "--check-config $CONF --list" "f --check-config $CONF" "f --all" "f --lines=5" "--help" "f -- g" "f --since"; do
    # shellcheck disable=SC2086
    lr $args
    expect_eq "usage: '$args' exits 2" 2 "$RC"
    expect_has "usage: '$args' prints usage on stderr" "$ERR" "usage: log-review"
    expect_eq "usage: '$args' prints nothing on stdout" "" "$OUT"
done
expect_eq "no journalctl was run by any caller error" 0 "$(calls)"

lr f
expect_eq "default lines: 100 of 300" 100 "$(jv '$d->{count}')"
jis "default lines: the last 100" '[$d->{lines}[0], $d->{lines}[-1]]' '["line 201","line 300"]'

# ---------------------------------------------------------------------------
heading "File sources: the tail"

conf "f = file $T/f.log"
lr f --lines 3
expect_eq "exit 0" 0 "$RC"
is_json && pass "stdout is one JSON document" || fail "stdout is one JSON document"
jis "document: lines, count, kind, name, truncated" '[$d->{lines}, $d->{count}, $d->{kind}, $d->{name}, $d->{truncated}]' '[["line 298","line 299","line 300"],3,"file","f",false]'
jis "document: target is the path" '$d->{target}' "\"$T/f.log\""
jis "document: host and duration_ms present, no since" '[length($d->{host}) > 0 ? 1 : 0, $d->{duration_ms} >= 0 ? 1 : 0, exists $d->{since} ? 1 : 0]' '[1,1,0]'
lr f --lines 1000
expect_eq "fewer lines than asked: all 300" 300 "$(jv '$d->{count}')"
jis "fewer lines than asked: not truncated" '$d->{truncated}' 'false'
jis "fewer lines than asked: from the first" '$d->{lines}[0]' '"line 1"'

printf 'a\nb\nc' > "$T/nonl.log"
conf "n = file $T/nonl.log"
lr n --lines 2
jis "no trailing newline: the last line counts" '$d->{lines}' '["b","c"]'
lr n --lines 3
jis "no trailing newline: whole file" '$d->{lines}' '["a","b","c"]'
printf 'a\nb\nc\n' > "$T/nl.log"
conf "n = file $T/nl.log"
lr n --lines 2
jis "trailing newline: the last two, no empty line" '$d->{lines}' '["b","c"]'
printf 'only' > "$T/one.log"
conf "n = file $T/one.log"
lr n --lines 5
jis "single line without newline" '$d->{lines}' '["only"]'
: > "$T/empty.log"
conf "n = file $T/empty.log"
lr n
jis "empty file: no lines, not truncated" '[$d->{lines}, $d->{count}, $d->{truncated}]' '[[],0,false]'
printf '\n\nx\n\n' > "$T/blank.log"
conf "n = file $T/blank.log"
lr n --lines 4
jis "blank lines are lines" '$d->{lines}' '["","","x",""]'
printf 'a\r\nb\r\n' > "$T/crlf.log"
conf "n = file $T/crlf.log"
lr n
jis "CRLF: the CR is stripped" '$d->{lines}' '["a","b"]'

# a large file, lines of uneven length so block boundaries fall mid-line
perl -e 'for my $i (1 .. 100000) { print "line $i ", "x" x ($i % 97), "\n" }' > "$T/big.log"
conf "big = file $T/big.log"
for n in 1 7 1000; do
    lr big --lines "$n" --text
    tail -n "$n" "$T/big.log" > "$T/want.txt"
    printf '%s\n' "$OUT" | cmp -s - "$T/want.txt" && pass "large file: --lines $n equals tail -n $n" || fail "large file: --lines $n equals tail -n $n"
done
lr big --lines 1000
jis "large file: first and last of 1000" '[$d->{lines}[0] =~ /^line 99001 /  ? 1 : 0, $d->{lines}[-1] =~ /^line 100000 / ? 1 : 0, $d->{count}]' '[1,1,1000]'
# fixed-width lines: a block boundary exactly on a line start
perl -e 'for my $i (1 .. 3000) { printf "%07d %s\n", $i, "y" x 119 }' > "$T/fixed.log"    # 128 bytes a line: a block holds 512
conf "fx = file $T/fixed.log"
for n in 511 512 513 1000; do
    lr fx --lines "$n" --text
    tail -n "$n" "$T/fixed.log" > "$T/want.txt"
    printf '%s\n' "$OUT" | cmp -s - "$T/want.txt" && pass "block boundary on a line start: --lines $n equals tail" || fail "block boundary on a line start: --lines $n equals tail"
done
printf 'x%.0s' $(seq 1 70000) > "$T/oneline.log"
conf "ol = file $T/oneline.log"
lr ol --lines 5
jis "one line longer than a block: cut at 2000 and marked" '[length($d->{lines}[0]), $d->{count}]' '[2011,1]'

# ---------------------------------------------------------------------------
heading "File sources: match= (agent-set filter)"

seq 1 5000 | sed 's/^/line /' > "$T/m.log"
conf "m = file $T/m.log match=7\$"
lr m --lines 3
jis "match: the last 3 matching lines" '$d->{lines}' '["line 4977","line 4987","line 4997"]'
lr m --lines 1
jis "match: the last matching line" '$d->{lines}' '["line 4997"]'
jis "match: whole file read, not truncated" '$d->{truncated}' 'false'
lr --list
jis "list: filter true" '$d->{sources}[0]{filter}' 'true'
seq 1 30000 | sed 's/^/line /' > "$T/m2.log"
conf "none = file $T/m2.log match=^line (1|2)\$" "few = file $T/m2.log match=^line 2999\\d\$"
lr none
jis "match beyond the read bound (last 20000 lines): nothing, truncated says so" '[$d->{count}, $d->{truncated}]' '[0,true]'
lr few --lines 20
jis "match: 10 found in the bound, truncated (older lines were not searched)" '[$d->{count}, $d->{truncated}]' '[10,true]'
jis "match: they are in order" '[$d->{lines}[0], $d->{lines}[-1]]' '["line 29990","line 29999"]'
conf "case = file $T/m.log match=(?i)LINE 4999\$"
lr case
jis "match: inline flags work" '$d->{lines}' '["line 4999"]'
conf "m = file $T/m.log match=7\$"
lr m --lines 2 --text
expect_eq "match with --text" $'line 4987\nline 4997' "$OUT"

# ---------------------------------------------------------------------------
heading "File sources: cleaning and the line cap"

printf 'plain\n\033[31mred\033[0m\nbell\a\000nul\ttab\n\xc2\x85c1\nbad\xffbyte\nnl\vvt\014ff\n' > "$T/ctl.log"
conf "c = file $T/ctl.log"
lr c
is_json && pass "control characters: stdout is one JSON document" || fail "control characters: stdout is one JSON document"
OUT2="$(jv '$d->{lines}')"
expect_eq "control characters: stripped" '["plain","[31mred[0m","bellnul\ttab","c1","bad�byte","nlvtff"]' "$(printf '%s' "$OUT2" | sed 's/\\u001b//g')"
perl -e 'print "a" x 2000, "\n", "b" x 2001, "\n", "c" x 5000, "\n", "d" x 1999, "\n"' > "$T/long.log"
conf "l = file $T/long.log"
lr l
jis "line cap: 2000 kept, 2001 and 5000 cut and marked, 1999 kept" '[map { length } @{ $d->{lines} }]' '[2000,2011,2011,1999]'
jis "line cap: the marker" '$d->{lines}[1] =~ / \[line cut\]$/ ? 1 : 0' '1'
lr l --text
expect_eq "line cap in --text" 2000 "$(head -1 <<< "$OUT" | tr -d '\n' | wc -c)"
printf 'caf\xc3\xa9 \xe2\x82\xac\n' > "$T/u.log"
conf "u = file $T/u.log"
lr u
jis "UTF-8 text survives" '$d->{lines}[0] eq "caf\x{e9} \x{20ac}" ? 1 : 0' '1'
lr u --text
expect_eq "UTF-8 text in --text" $'caf\xc3\xa9 \xe2\x82\xac' "$OUT"

# ---------------------------------------------------------------------------
heading "File sources: what may be read"

ln -s "$T/f.log" "$T/link.log"
mkdir "$T/adir"
mkfifo "$T/fifo.log"
chmod 755 "$T/f.log"
cp "$T/f.log" "$T/locked.log"
chmod 000 "$T/locked.log"
conf "sym = file $T/link.log" "dir = file $T/adir" "gone = file $T/nonexistent.log" "fifo = file $T/fifo.log" "locked = file $T/locked.log" "ok = file $T/f.log" "deepgone = file $T/nodir/x.log"
lr sym
expect_eq "symlink: exit 1" 1 "$RC"
expect_has "symlink: refused" "$OUT" "symlink refused"
lr dir
expect_eq "directory: exit 1" 1 "$RC"
expect_has "directory: not a regular file" "$OUT" "not a regular file"
lr gone
expect_eq "missing file: exit 1" 1 "$RC"
expect_has "missing file: says so" "$OUT" "file not found"
lr deepgone
expect_has "missing folder: says so" "$OUT" "file not found"
timeout 10 perl "$LR" fifo > "$T/out" 2> /dev/null < /dev/null
RC=$?
expect_eq "fifo: refused at once (exit 1, no hang)" 1 "$RC"
expect_has "fifo: not a regular file" "$(cat "$T/out")" "not a regular file"
if [ "$(id -u)" = 0 ]; then
    skip "unreadable file (running as root)"
else
    lr locked
    expect_eq "unreadable file: exit 1" 1 "$RC"
    expect_has "unreadable file: permission denied, names the user" "$OUT" "permission denied for user"
fi
is_json && pass "errors are JSON {host,error}" || fail "errors are JSON {host,error}"
jis "error document: only host and error" '[sort keys %$d]' '["error","host"]'
lr sym --text
expect_eq "error in --text: stdout empty" "" "$OUT"
expect_has "error in --text: on stderr" "$ERR" "log-review: $T/link.log: symlink refused"
expect_eq "error in --text: exit 1" 1 "$RC"
lr --list
expect_eq "list: exit 0 even with unreadable sources" 0 "$RC"
jis "list: readable flags" '[map { $_->{readable} } @{ $d->{sources} }]' '[false,false,false,false,false,true,false]'
[ "$(id -u)" = 0 ] || jis "list: reasons" '[map { $_->{reason} // "" } @{ $d->{sources} }]' "[\"symlink refused\",\"not a regular file\",\"file not found\",\"not a regular file\",\"permission denied for user $(id -un)\",\"\",\"file not found\"]"
jis "list: rows carry name, kind, target, filter" '$d->{sources}[5]' "{\"filter\":false,\"kind\":\"file\",\"name\":\"ok\",\"readable\":true,\"target\":\"$T/f.log\"}"
chmod 644 "$T/locked.log"

# ---------------------------------------------------------------------------
heading "File sources: --since"

perl -e '
use POSIX qw(strftime);
my $now = time;
my @a = ([3*86400, "three days ago"], [7200, "two hours ago"], [1800, "half an hour ago"], [10, "ten seconds ago"]);
for my $e (@a) { print strftime("%Y-%m-%dT%H:%M:%SZ", gmtime($now - $e->[0])), " host app: $e->[1]\n" }
print "    continuation of the last line\n";' > "$T/iso.log"
conf "iso = file $T/iso.log"
lr iso --since 1h
jis "iso: the last hour (two entries and the continuation)" '[map { s/^\S+ //r } @{ $d->{lines} }]' '["host app: half an hour ago","host app: ten seconds ago","    continuation of the last line"]'
jis "iso: since is echoed, not truncated" '[$d->{since}, $d->{truncated}]' '["1h",false]'
lr iso --since 1d
jis "iso: the last day" '$d->{count}' '4'
lr iso --since 4d
jis "iso: four days (all)" '$d->{count}' '5'
lr iso --since 1h --lines 1
jis "iso: --lines 1 keeps the newest, truncated" '[$d->{count}, $d->{truncated}, $d->{lines}[0]]' '[1,true,"    continuation of the last line"]'
lr iso --since 30s --text
expect_eq "iso: --text, last 30 s" 2 "$(wc -l <<< "$OUT")"
perl -e '
use POSIX qw(strftime);
my $now = time;
for my $e ([7200, "old"], [60, "recent"]) { print strftime("%b %e %H:%M:%S", localtime($now - $e->[0])), " host sshd[1]: $e->[1]\n" }' > "$T/sys.log"
conf "sys = file $T/sys.log"
lr sys --since 1h
jis "syslog format: the last hour" '[map { s/^.* sshd\[1\]: //r } @{ $d->{lines} }]' '["recent"]'
perl -e '
use POSIX qw(strftime);
use Time::Local;
my $now = time;
for my $e ([7200, "old"], [60, "recent"]) { my @t = gmtime($now - $e->[0]); print strftime("%Y-%m-%dT%H:%M:%S+01:00", gmtime($now - $e->[0] + 3600)), " $e->[1]\n" }' > "$T/off.log"
conf "off = file $T/off.log"
lr off --since 1h
jis "iso with an offset is read as that zone" '[map { s/^\S+ //r } @{ $d->{lines} }]' '["recent"]'
perl -e '
use POSIX qw(strftime);
for my $e ([7200, "old"], [60, "recent"]) { print strftime("%Y/%m/%d %H:%M:%S", localtime(time - $e->[0])), " [error] $e->[1]\n" }' > "$T/ng.log"
conf "ng = file $T/ng.log"
lr ng --since 1h
jis "nginx-style YYYY/MM/DD timestamps" '$d->{count}' '1'
conf "f = file $T/f.log"
lr f --since 1h
expect_eq "no timestamps: exit 1" 1 "$RC"
jis "no timestamps: error says it is not supported" '$d->{error} =~ /^--since is not supported for this file/ ? 1 : 0' '1'
conf "iso = file $T/iso.log match=ago"
lr iso --since 1h
jis "since with match=: filters inside the window" '$d->{count}' '2'
perl -e '
use POSIX qw(strftime);
my $now = time;
for my $i (1 .. 30000) { print strftime("%Y-%m-%dT%H:%M:%SZ", gmtime($now - 86400 * 3 + $i)), " host app: n$i\n" }' > "$T/bigiso.log"
conf "bi = file $T/bigiso.log"
lr bi --since 7d --lines 5
jis "window larger than the read bound: newest 5, truncated" '[$d->{count}, $d->{truncated}, $d->{lines}[-1] =~ /n30000$/ ? 1 : 0]' '[5,true,1]'

# ---------------------------------------------------------------------------
heading "Journal sources (stub journalctl)"

: > "$STUB_LOG"
perl -e 'for my $i (1 .. 30) { printf "2026-10-23T10:00:%02d+0000 host sshd[%d]: message %d\n", $i, 100 + $i, $i }' > "$T/jout.txt"
export STUB_OUT="$T/jout.txt"
conf "auth = journal id=sshd" "web = journal unit=nginx.service priority=warning" "krn = journal id=kernel priority=3" "flt = journal unit=a.service match=message \d*[12]\$"
lr auth
expect_eq "journal: exit 0" 0 "$RC"
expect_eq "journal: exact argv (default 100 lines, identifier)" "ARGV [--no-pager] [-o] [short-iso] [-q] [-n] [100] [-t] [sshd]" "$(last_argv)"
jis "journal: kind, target, lines passed through" '[$d->{kind}, $d->{target}, $d->{count}, $d->{truncated}]' '["journal","sshd",30,false]'
lr web --lines 7
expect_eq "journal: exact argv (unit, priority, -n 7)" "ARGV [--no-pager] [-o] [short-iso] [-q] [-n] [7] [-u] [nginx.service] [-p] [warning]" "$(last_argv)"
lr krn --lines 1000
expect_eq "journal: numeric priority, -n 1000" "ARGV [--no-pager] [-o] [short-iso] [-q] [-n] [1000] [-t] [kernel] [-p] [3]" "$(last_argv)"
lr auth --lines 5 --since 90m
expect_eq "journal: --since becomes seconds, one more line is asked for to know about truncation" "ARGV [--no-pager] [-o] [short-iso] [-q] [-n] [6] [-t] [sshd] [--since=-5400 seconds]" "$(last_argv)"
jis "journal: since echoed" '$d->{since}' '"90m"'
lr auth --since 7d
expect_eq "journal: 7d is 604800 s, default 100+1 lines" "ARGV [--no-pager] [-o] [short-iso] [-q] [-n] [101] [-t] [sshd] [--since=-604800 seconds]" "$(last_argv)"
lr auth --since 2h --lines 30
jis "journal: since, exactly N lines back: not truncated" '[$d->{count}, $d->{truncated}]' '[30,false]'
lr auth --since 2h --lines 10
jis "journal: since, N+1 lines back: only the newest N, truncated" '[$d->{count}, $d->{truncated}, $d->{lines}[0] =~ /message 21$/ ? 1 : 0, $d->{lines}[-1] =~ /message 30$/ ? 1 : 0]' '[10,true,1,1]'
lr auth --lines 10
jis "journal: no --since: just the lines journalctl gave, not truncated" '$d->{truncated}' 'false'
lr flt --lines 3
expect_eq "journal with match=: reads up to the bound (20000), not N" "ARGV [--no-pager] [-o] [short-iso] [-q] [-n] [20000] [-u] [a.service]" "$(last_argv)"
jis "journal with match=: the matches are 1, 2, 11, 12, 21, 22; the newest 3 are kept" '[map { s/^.*: //r } @{ $d->{lines} }]' '["message 12","message 21","message 22"]'
lr flt --lines 2
jis "journal with match=: newest 2" '[map { s/^.*: //r } @{ $d->{lines} }]' '["message 21","message 22"]'
lr flt --lines 3
jis "journal with match=: three newest ending in 1 or 2" '[map { s/^.*: //r } @{ $d->{lines} }]' '["message 12","message 21","message 22"]'
jis "journal with match=, no --since, N matches found: not truncated" '$d->{truncated}' 'false'
lr flt --lines 3 --since 1d
jis "journal with match= and --since, more matches than N: truncated" '$d->{truncated}' 'true'
lr flt --lines 100 --since 1d
jis "journal with match= and --since, all matches fit: not truncated" '[$d->{count}, $d->{truncated}]' '[6,false]'
conf "none = journal id=sshd match=never-matches-SECRET"
lr none
jis "journal with match=, nothing matches, bound not reached: empty, not truncated" '[$d->{count}, $d->{truncated}]' '[0,false]'
perl -e 'for my $i (1 .. 20000) { print "2026-10-23T10:00:00+0000 host sshd[1]: n$i\n" }' > "$T/j20k.txt"
STUB_OUT="$T/j20k.txt" lr none
jis "journal with match=, nothing matches, bound reached: truncated says the search stopped" '[$d->{count}, $d->{truncated}]' '[0,true]'
conf "auth = journal id=sshd"
STUB_OUT="$T/j20k.txt" lr auth --lines 5
jis "journal: a large answer keeps the newest 5" '[$d->{count}, $d->{lines}[-1] =~ /n20000$/ ? 1 : 0]' '[5,1]'

printf '2026-10-23T10:00:01+0000 host x: \033[31mred\033[0m\a\000end\n2026-10-23T10:00:02+0000 host x: %s\n' "$(perl -e 'print "z" x 3000')" > "$T/jctl.txt"
STUB_OUT="$T/jctl.txt" lr auth
OUT2="$(jv '$d->{lines}[0]' | sed 's/\\u001b//g')"
expect_eq "journal: ESC, BEL, NUL stripped" '"2026-10-23T10:00:01+0000 host x: [31mred[0mend"' "$OUT2"
jis "journal: long line cut and marked" 'length($d->{lines}[1])' '2011'

# no text of the caller reaches the command
: > "$STUB_LOG"
lr auth --lines '5; id' ; lr auth --since '1h; id' ; lr 'auth;id' ; lr '--unit=ssh' ; lr auth -u x ; lr auth --lines 5 extra ; lr 'auth' --since '-1h' ; lr auth --since 8d ; lr auth --lines 1001
expect_eq "no caller text reaches journalctl: nothing ran for bad input" 0 "$(calls)"
lr auth --lines 12 --since 15m
expect_eq "only validated numbers reach it" "ARGV [--no-pager] [-o] [short-iso] [-q] [-n] [13] [-t] [sshd] [--since=-900 seconds]" "$(last_argv)"
expect_eq "one run, one journalctl call" 1 "$(calls)"

# failure, timeout, unreadable
conf "auth = journal id=sshd" "slow = journal id=slow"
STUB_EXIT=1 STUB_ERR="Failed to open journal" lr auth
expect_eq "journalctl fails: exit 1" 1 "$RC"
expect_has "journalctl fails: says so with its message" "$OUT" "journalctl failed: Failed to open journal"
STUB_EXIT=1 lr auth
expect_has "journalctl fails silently: exit code shown" "$OUT" "journalctl failed: exit 1"
conf "timeout = 1" "slow = journal id=slow"
start=$SECONDS
STUB_SLEEP=30 STUB_PIDFILE="$T/stub.pid" lr slow
took=$((SECONDS - start))
expect_eq "timeout: exit 1" 1 "$RC"
expect_has "timeout: says so" "$OUT" "journalctl timed out after 1s"
[ "$took" -le 4 ] && pass "timeout: returned in $took s" || fail "timeout: returned in time" "$took s"
sleep 0.2
kill -0 "$(cat "$T/stub.pid")" 2> /dev/null && fail "timeout: the stub was killed" || pass "timeout: the stub was killed"
conf "auth = journal id=sshd"
: > "$T/nothing.txt"
STUB_OUT="$T/nothing.txt" STUB_ERR="No journal files were opened due to insufficient permissions." lr auth
expect_eq "empty answer and a permission warning: exit 1" 1 "$RC"
expect_has "empty answer and a permission warning: journal not readable" "$OUT" "journal not readable: no permission to read the journal"
STUB_OUT="$T/nothing.txt" lr auth
expect_eq "empty answer, journal readable: exit 0, no lines" 0 "$RC"
jis "empty answer, journal readable: no lines" '[$d->{count}, $d->{truncated}]' '[0,false]'
LOG_REVIEW_JOURNALCTL="$T/nowhere" lr auth
expect_eq "journalctl missing: exit 1" 1 "$RC"
jis "journalctl missing: message" '$d->{error}' '"journalctl not found"'

# --list with journal sources
: > "$STUB_LOG"
conf "a = journal id=sshd" "b = journal unit=nginx.service priority=err match=x" "f = file $T/f.log"
lr --list
jis "list: journal rows" '[map { [$_->{name}, $_->{kind}, $_->{target}, $_->{readable}, $_->{filter}, $_->{priority} // ""] } @{ $d->{sources} }[0,1]]' '[["a","journal","sshd",true,false,""],["b","journal","nginx.service",true,true,"err"]]'
expect_eq "list: the journal is probed once, with a fixed argv" "ARGV [--no-pager] [-o] [short-iso] [-n] [1]" "$(last_argv)"
expect_eq "list: one journalctl call for any number of journal sources" 1 "$(calls)"
STUB_ERR="No journal files were opened due to insufficient permissions." lr --list
jis "list: unreadable journal reported with the reason" '[$d->{sources}[0]{readable}, $d->{sources}[0]{reason} =~ /^no permission to read the journal \(user \S+ needs group systemd-journal or adm\)$/ ? 1 : 0]' '[false,1]'
STUB_EXIT=1 STUB_ERR="Failed to open" lr --list
jis "list: journalctl failure reported" '$d->{sources}[1]{reason}' '"journalctl failed: Failed to open"'
conf "timeout = 1" "a = journal id=sshd"
STUB_SLEEP=30 lr --list
jis "list: journalctl timeout reported" '$d->{sources}[0]{reason}' '"journalctl timed out after 1s"'
conf "f = file $T/f.log"
: > "$STUB_LOG"
lr --list
expect_eq "list: no journal source, no journalctl call" 0 "$(calls)"

# ---------------------------------------------------------------------------
heading "--text"

conf "f = file $T/f.log" "auth = journal id=sshd"
lr f --lines 3 --text
expect_eq "text: only the lines" $'line 298\nline 299\nline 300' "$OUT"
lr --text f --lines 2
expect_eq "text: flags in any order" $'line 299\nline 300' "$OUT"
lr auth --lines 2 --text
expect_eq "text: journal lines, the newest 2 of what the stub gave" 2 "$(wc -l <<< "$OUT")"
expect_has "text: journal line content" "$OUT" "sshd[130]: message 30"
printf 'a\nb\nc\n' > "$T/nl.log"
conf "n = file $T/nl.log"
lr n --lines 1 --since 1h --text
expect_eq "text: unsupported --since is an error on stderr" 1 "$RC"
conf "iso = file $T/iso.log"
lr iso --since 1h --lines 1 --text
expect_eq "text: truncated is said on stderr" "log-review: truncated: the window holds more lines than returned" "$ERR"
expect_eq "text: and stdout is only the line" 1 "$(wc -l <<< "$OUT")"
lr iso --since 4d --text
expect_eq "text: not truncated, stderr empty" "" "$ERR"

# ---------------------------------------------------------------------------
heading "--check-config"

: > "$STUB_LOG"
conf "f = file $T/f.log"
cat > "$ETC/sources.conf.new" <<EOF
max_lines = 200
fresh = file $T/f.log match=SECRETVAL
jr = journal unit=x.service priority=warning
EOF
lr --check-config "$ETC/sources.conf.new"
expect_eq "folder file, absolute: exit 0" 0 "$RC"
jis "folder file: sources with filter flags, no readable probe" '[map { [$_->{name}, $_->{kind}, $_->{target}, $_->{filter}, exists $_->{readable} ? 1 : 0] } @{ $d->{sources} }]' "[[\"fresh\",\"file\",\"$T/f.log\",true,0],[\"jr\",\"journal\",\"x.service\",false,0]]"
jis "folder file: config and settings" '[$d->{config}, $d->{settings}{max_lines}]' "[\"$ETC/sources.conf.new\",200]"
expect_lacks "folder file: the regex is not echoed" "$OUT" "SECRETVAL"
expect_eq "check-config runs nothing (no journalctl)" 0 "$(calls)"
(cd "$ETC" && OUT="$(perl "$LR" --check-config sources.conf.new 2>&1)"; echo "$OUT" | grep -q '"sources"') && pass "folder file, relative from inside the folder: accepted" || fail "folder file, relative from inside the folder: accepted"
(cd "$ETC" && rel="$(perl "$LR" --check-config ./sources.conf.new 2>&1)"; echo "$rel" | grep -q '"sources"') && pass "folder file, ./ relative: accepted" || fail "folder file, ./ relative: accepted"
printf 'good = file /var/log/x\nSECRETVAL no equals\n' > "$ETC/.sources.conf.new.123"
lr --check-config "$ETC/.sources.conf.new.123"
expect_eq "staged file that does not parse: exit 3" 3 "$RC"
expect_has "staged file that does not parse: names the line" "$OUT" ".sources.conf.new.123 line 2: expected 'key = value'"
expect_lacks "staged file that does not parse: no echo" "$OUT" "SECRETVAL"
printf 'a = file /x\nb = journal id=x foo=SECRETVAL\n' > "$ETC/bad.new"
lr --check-config "$ETC/bad.new"
expect_eq "bad source: exit 3" 3 "$RC"
expect_has "bad source: line 2" "$OUT" "line 2"
mkdir -p "$T/other"
printf 'secret = file /SECRETVAL\n' > "$T/other/sources.conf"
lr --check-config "$T/other/sources.conf"
expect_eq "file outside the folder: exit 3" 3 "$RC"
expect_has "file outside the folder: says what is read" "$OUT" "--check-config only reads files in $ETC"
expect_lacks "file outside the folder: unread" "$OUT" "SECRETVAL"
lr --check-config /etc/passwd
expect_eq "/etc/passwd: exit 3, unread" 3 "$RC"
expect_lacks "/etc/passwd: nothing echoed" "$OUT" "root:"
lr --check-config "$ETC/../other/sources.conf"
expect_eq "..-path to another folder: exit 3" 3 "$RC"
lr --check-config "$ETC/sub/../sources.conf.new"
expect_eq "path through a missing subfolder: exit 3" 3 "$RC"
ln -s "$T/other/sources.conf" "$ETC/link.new"
lr --check-config "$ETC/link.new"
expect_eq "symlink in the folder to elsewhere: exit 3" 3 "$RC"
expect_lacks "symlink in the folder to elsewhere: unread" "$OUT" "SECRETVAL"
ln -s "$ETC/sources.conf.new" "$ETC/link2.new"
lr --check-config "$ETC/link2.new"
expect_eq "symlink in the folder to a folder file: also refused" 3 "$RC"
ln -s "$ETC" "$T/etclink"
lr --check-config "$T/etclink/sources.conf.new"
expect_eq "the folder reached through a symlinked folder: same folder, accepted" 0 "$RC"
lr --check-config "$ETC/absent.new"
expect_eq "missing file in the folder: exit 3" 3 "$RC"
expect_has "missing file in the folder: cannot read" "$OUT" "cannot read config"
lr --check-config "$ETC"
expect_eq "the folder itself: exit 3" 3 "$RC"
cp "$DIR/sources.conf.example" "$ETC/example.new"
lr --check-config "$ETC/example.new"
expect_eq "the shipped example parses" 0 "$RC"
jis "the shipped example: four sources" '[map { $_->{name} } @{ $d->{sources} }]' '["auth","syslog","nginx-errors","kernel"]'

# ---------------------------------------------------------------------------
heading "Output hygiene"

conf "f = file $T/f.log"
lr f --lines 2
expect_eq "JSON answer is one line" 1 "$(wc -l <<< "$OUT")"
expect_eq "nothing on stderr for a normal run" "" "$ERR"
lr --list
expect_eq "nothing on stderr for --list" "" "$ERR"

# INSTALL-TESTS-HERE

# ---------------------------------------------------------------------------
echo
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
if [ "$FAIL" -eq 0 ]; then echo "VERDICT: PASS"; else echo "VERDICT: FAIL"; fi
[ "$FAIL" -eq 0 ]
