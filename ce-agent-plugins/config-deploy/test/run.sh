#!/bin/bash
# Test suite for the config-deploy plugin. Run: bash test/run.sh
#
# Covers the agent script, the run-jobs job and the installer:
#   - the map: every refusal (owner, mode, parse, name, duplicate, path,
#     '..', protected folders and symlinks into them, the map itself, options)
#   - a write: new file, unchanged (no write, no .prev), changed (.prev holds
#     the old file), owner and mode, no leftovers
#   - validate: pass, fail (old file untouched, nothing left behind), output
#     trimmed, no shell, timeout, missing command
#   - size limit, no input, unknown name, symlink and folder checks
#   - --test makes no change, --list, usage exit 2
#   - config-push.sh: end to end against a STUB ctrl-exec-cli (which runs the
#     real agent script) and a STUB logger
#   - install.sh against a temp root, with a fake systemctl
# Needs perl and bash only, no network. It runs as any user; the checks that
# need root (an owner that is not the caller's) are skipped when not root, and
# the 'map not owned by root' check is skipped when run as root.
# shellcheck disable=SC2015,SC2016  # A && pass || fail is intended; fake scripts are quoted on purpose
set -u
DIR="$(cd "$(dirname "$0")/.." && pwd)"
CD="$DIR/agent-config-deploy.pl"
SCHEMA="$DIR/agent-config-deploy.pl.schema.json"
JOB="$DIR/run-jobs/config-push.sh"
JOBCONF_EXAMPLE="$DIR/run-jobs/config-push.conf.example"
MAPEX="$DIR/config-deploy.conf.example"
NAGIOS="$DIR/../nagios-check/nagios-check.pl"

PASS=0 FAIL=0 SKIP=0
T="$(mktemp -d "${TMPDIR:-/tmp}/config-deploy-test.XXXXXX")" || exit 2
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

ME="$(id -un)"
MYGROUP="$(id -gn)"
AM_ROOT=0; [ "$(id -u)" = 0 ] && AM_ROOT=1
D="$T/d"             # the target folder
IN="$T/in"           # CTRL_EXEC_INPUT
MAP="$T/config-deploy.conf"
mkdir -p "$D" "$IN"
export CONFIG_DEPLOY_MAP="$MAP" CONFIG_DEPLOY_ALLOW_NONROOT=1 CTRL_EXEC_INPUT="$IN" CONFIG_DEPLOY_PROTECTED="$T/prot"
unset CONFIG_DEPLOY_VALIDATE_TIMEOUT
mkdir -p "$T/prot/sub"

# mapw LINE...: writes the map (mode 600) from the lines given
mapw() { printf '%s\n' "$@" > "$MAP"; chmod 600 "$MAP"; }
# setin TEXT: the input field content (printf format, no trailing newline added)
# shellcheck disable=SC2059  # the text is a printf format on purpose
setin() { printf "$1" > "$IN/content"; }
# cd ARGS...: runs the script; OUT is its stdout, ERR its stderr, RC its exit
cd_run() {
    OUT="$(perl "$CD" "$@" 2> "$T/err" < /dev/null)"
    RC=$?
    ERR="$(cat "$T/err")"
}
jv() { printf '%s' "$OUT" | perl -MJSON::PP -e '
    my $d = decode_json(do { local $/; <STDIN> });
    my $v = eval $ARGV[0]; die $@ if $@;
    print JSON::PP->new->canonical->allow_nonref->encode($v);' "$1"; }
is_json() { printf '%s' "$OUT" | perl -MJSON::PP -e 'decode_json(do { local $/; <STDIN> }); exit 0' 2> /dev/null; }
jis() { expect_eq "$1" "$3" "$(jv "$2" 2>&1)"; }
sha() { sha256sum "$1" | cut -d' ' -f1; }
# refused LABEL EXPECTED-TEXT: the last call exited 1 with an error holding the text
refused() {
    expect_eq "$1: exit 1" 1 "$RC"
    is_json && pass "$1: stdout is one JSON document" || fail "$1: stdout is one JSON document" "$OUT"
    expect_has "$1: error says why" "$(jv '$d->{error}' 2>&1)" "$2"
}
leftovers() { find "$D" -name '.*' -type f | wc -l; }

echo "# Test report: config-deploy (ce-agent-plugins)"
echo "Generated: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"

# ---------------------------------------------------------------------------
heading "Contract: usage, the script and the sidecar"

mapw "a = $D/a.conf"
cd_run
expect_eq "no arguments exits 2" 2 "$RC"
expect_has "no arguments prints usage on stderr" "$ERR" "usage: agent-config-deploy"
expect_eq "no arguments: nothing on stdout" "" "$OUT"
cd_run --bogus
expect_eq "unknown flag exits 2" 2 "$RC"
expect_has "unknown flag prints usage on stderr" "$ERR" "usage:"
cd_run --test
expect_eq "--test without a name exits 2" 2 "$RC"
cd_run --list a
expect_eq "--list with a name exits 2" 2 "$RC"
cd_run a b
expect_eq "two names exit 2" 2 "$RC"
[ -x "$CD" ] && pass "agent-config-deploy.pl is executable" || fail "agent-config-deploy.pl is executable"
expect_eq "agent-config-deploy.pl has a perl shebang" '#!/usr/bin/perl' "$(head -1 "$CD")"
perl -c "$CD" > /dev/null 2>&1 && pass "perl -c passes" || fail "perl -c passes"
perl -MJSON::PP -e 'open my $f, "<", $ARGV[0] or exit 1; local $/; my $d = decode_json(<$f>);
    exit($d->{arguments} && $d->{argv} && $d->{destructive} && !$d->{read_only}
         && $d->{input}{mode} eq "fields" && $d->{input}{fields}{content} && $d->{input}{required}[0] eq "content" ? 0 : 1)' "$SCHEMA" \
    && pass "sidecar: valid JSON, destructive, input field content" \
    || fail "sidecar: valid JSON, destructive, input field content"

# ---------------------------------------------------------------------------
heading "The map: what is refused"

cd_run --list
expect_eq "a good map is accepted" 0 "$RC"
mapw "# comment" "" "   " "a = $D/a.conf" "  b   =   $D/b.conf   mode=0600  owner=$ME:$MYGROUP  " "c = $D/c.conf validate=/bin/true {}"
cd_run --list
expect_eq "comments, blank lines and spaces are fine" 0 "$RC"
jis "entries kept in map order" '[map { $_->{name} } @{ $d->{files} }]' '["a","b","c"]'

rm -f "$MAP"
cd_run --list
refused "missing map" "cannot read config map"
cd_run a
refused "missing map: a write too" "cannot read config map"

mapw "a = $D/a.conf"
chmod 660 "$MAP"
cd_run --list
refused "group-writable map" "group- or world-writable"
chmod 606 "$MAP"
cd_run a
refused "world-writable map: a write too" "group- or world-writable"
chmod 600 "$MAP"
if [ "$AM_ROOT" = 0 ]; then
    OUT="$(CONFIG_DEPLOY_ALLOW_NONROOT='' perl "$CD" --list 2> /dev/null < /dev/null)"; RC=$?
    refused "map not owned by root" "not owned by root"
else
    skip "map not owned by root (running as root)"
fi

mapw "a = $D/a.conf" "this is not an entry SECRETWORD"
cd_run --list
refused "unparsable line" "line 2"
expect_lacks "unparsable line: the line is not echoed" "$OUT" "SECRETWORD"
mapw "a = $D/a.conf SECRETWORD"
cd_run --list
refused "text after the path" "line 1"
expect_lacks "text after the path: not echoed" "$OUT" "SECRETWORD"
mapw "a = $D/a.conf frob=SECRETWORD"
cd_run --list
refused "unknown option" "unknown option 'frob'"
expect_lacks "unknown option: the value is not echoed" "$OUT" "SECRETWORD"
mapw "a = $D/a.conf mode=0644 mode=0600"
cd_run --list
refused "option twice" "mode given twice"
mapw "a ="
cd_run --list
refused "no path" "line 1"
mapw "bad name = $D/x"
cd_run --list
refused "name with a space" "line 1"
mapw "bad.name = $D/x"
cd_run --list
refused "name with a dot" "bad name 'bad.name'"
mapw "a = $D/a.conf" "b = $D/b.conf" "a = $D/c.conf"
cd_run --list
refused "duplicate name" "line 3"
expect_has "duplicate name: names it" "$OUT" "'a' defined twice"
mapw "a = a.conf"
cd_run --list
refused "relative path" "not absolute"
mapw "a = $D/../x"
cd_run --list
refused "path with .." "no '..'"
mapw "a = $D/sub/../x"
cd_run --list
refused "path with .. in the middle" "no '..'"
mapw "a = $D//x"
cd_run --list
refused "path with //" "normalised"
mapw "a = $D/./x"
cd_run --list
refused "path with ." "normalised"
mapw "a = $D/x/"
cd_run --list
refused "path with a trailing /" "normalised"
mapw "a = /etc/ctrl-exec-agent/scripts.conf"
cd_run --list
refused "path in /etc/ctrl-exec-agent" "/etc/ctrl-exec-agent"
mapw "a = /etc/ctrl-exec-agent"
cd_run --list
refused "path is /etc/ctrl-exec-agent" "/etc/ctrl-exec-agent"
mapw "a = /etc/ctrl-exec-dispatcher/x/y.conf"
cd_run --list
refused "path in /etc/ctrl-exec-dispatcher" "/etc/ctrl-exec-dispatcher"
mapw "a = $T/prot/x.conf"
cd_run --list
refused "path in a protected folder (CONFIG_DEPLOY_PROTECTED)" "never writes"
ln -s "$T/prot/sub" "$T/lnk"
mapw "a = $T/lnk/x.conf"
cd_run --list
refused "path through a symlink into a protected folder" "never writes"
cd_run a
refused "...a write too" "never writes"
mapw "a = $MAP"
cd_run --list
refused "path is the map file itself" "the map file itself"
ln -s "$MAP" "$T/maplink"
mapw "a = $T/maplink"
cd_run --list
refused "path is a symlink to the map file" "the map file itself"
mapw "a = $D/a owner=nosuchuser-xyz:root"
cd_run --list
refused "unknown user" "no such user 'nosuchuser-xyz'"
mapw "a = $D/a owner=root:nosuchgroup-xyz"
cd_run --list
refused "unknown group" "no such group"
mapw "a = $D/a owner=root"
cd_run --list
refused "owner without a group" "owner must be"
mapw "a = $D/a mode=rw"
cd_run --list
refused "mode not octal" "mode must be octal"
mapw "a = $D/a mode=0888"
cd_run --list
refused "mode with 8" "mode must be octal"
mapw "a = $D/a mode=4755"
cd_run --list
refused "setuid mode" "setuid"
mapw "a = $D/a validate="
cd_run --list
refused "empty validate" "names no command"
mapw "a = $D/a validate=check.sh {}"
cd_run --list
refused "validate not absolute" "not an absolute path"
mapw "a = $D/a validate=/bin/../bin/true {}"
cd_run --list
refused "validate with .." "contains '..'"
mapw "a = $D/a validate=/bin/true"
cd_run --list
refused "validate without {}" "no {}"
mapw "a = $D/a" "b = $D/b" "c oops"
cd_run a
refused "a refused map refuses every call, not only the bad line" "line 3"
chmod 600 "$MAP"

# ---------------------------------------------------------------------------
heading "Write: new file, unchanged, changed"

rm -rf "$D"; mkdir -p "$D"
mapw "a = $D/a.conf mode=0640"
setin 'first line\nsecond "quoted" \\ line\n'
cd_run a
expect_eq "new file: exit 0" 0 "$RC"
is_json && pass "new file: stdout is one JSON document" || fail "new file: stdout is one JSON document" "$OUT"
jis "new file: changed true, no previous" '[$d->{changed}, $d->{previous_sha256}, $d->{name}, $d->{path}]' "[true,null,\"a\",\"$D/a.conf\"]"
jis "new file: sha256 of the content" '$d->{sha256}' "\"$(sha "$IN/content")\""
jis "new file: host is set" 'length($d->{host}) > 0 ? 1 : 0' 1
jis "new file: validate did not run" '[$d->{validate}{ran}, $d->{validate}{exit}, $d->{validate}{output}]' '[false,null,""]'
cmp -s "$IN/content" "$D/a.conf" && pass "new file: content is exact" || fail "new file: content is exact"
expect_eq "new file: mode 0640 applied" 640 "$(stat -c %a "$D/a.conf")"
[ ! -e "$D/a.conf.prev" ] && pass "new file: no .prev" || fail "new file: no .prev"
expect_eq "new file: nothing left but the file" "a.conf" "$(ls -A "$D")"
FIRST_SHA="$(sha "$D/a.conf")"

STAT1="$(stat -c '%i %Y' "$D/a.conf")"
sleep 1
cd_run a
expect_eq "unchanged: exit 0" 0 "$RC"
jis "unchanged: changed false, previous equals sha" '[$d->{changed}, $d->{previous_sha256} eq $d->{sha256} ? 1 : 0]' '[false,1]'
expect_eq "unchanged: file not rewritten (inode and mtime)" "$STAT1" "$(stat -c '%i %Y' "$D/a.conf")"
[ ! -e "$D/a.conf.prev" ] && pass "unchanged: no .prev" || fail "unchanged: no .prev"
expect_eq "unchanged: nothing left behind" "a.conf" "$(ls -A "$D")"

setin 'a changed file\n'
chmod 600 "$D/a.conf"
cd_run a
expect_eq "changed: exit 0" 0 "$RC"
jis "changed: changed true, previous is the old sha" '[$d->{changed}, $d->{previous_sha256}]' "[true,\"$FIRST_SHA\"]"
jis "changed: new sha256" '$d->{sha256}' "\"$(sha "$IN/content")\""
expect_eq "changed: the new content is installed" "a changed file" "$(cat "$D/a.conf")"
expect_eq "changed: .prev holds the old content" "$FIRST_SHA" "$(sha "$D/a.conf.prev")"
expect_eq "changed: .prev has the old file's mode (600)" 600 "$(stat -c %a "$D/a.conf.prev")"
expect_eq "changed: the new file has the mapped mode, not the old one" 640 "$(stat -c %a "$D/a.conf")"
expect_eq "changed: nothing else left behind" $'a.conf\na.conf.prev' "$(ls -A "$D")"

setin 'third\n'
cd_run a
expect_eq ".prev is replaced by the file just superseded" "a changed file" "$(cat "$D/a.conf.prev")"

setin ''
cd_run a
expect_eq "empty content: written" "true" "$(jv '$d->{changed}')"
expect_eq "empty content: the file is empty" 0 "$(stat -c %s "$D/a.conf")"

# a .prev that is a symlink is replaced, never followed
echo victim > "$T/victim"
rm -f "$D/a.conf.prev"; ln -s "$T/victim" "$D/a.conf.prev"
setin 'again\n'
cd_run a
expect_eq ".prev symlink: write works" 0 "$RC"
expect_eq ".prev symlink: the link target is untouched" "victim" "$(cat "$T/victim")"

# ---------------------------------------------------------------------------
heading "Owner and mode"

rm -rf "$D"; mkdir -p "$D"
mapw "a = $D/a.conf" "m = $D/m.conf mode=600" "o = $D/o.conf owner=$ME:$MYGROUP mode=0664"
setin 'x\n'
cd_run a
expect_eq "default mode is 0644" 644 "$(stat -c %a "$D/a.conf")"
cd_run m
expect_eq "mode=600 applied" 600 "$(stat -c %a "$D/m.conf")"
cd_run o
expect_eq "mode=0664 applied" 664 "$(stat -c %a "$D/o.conf")"
expect_eq "owner of the caller applied, no warning" "" "$ERR"
expect_eq "owner applied" "$ME:$MYGROUP" "$(stat -c %U:%G "$D/o.conf")"
if [ "$AM_ROOT" = 0 ]; then
    rm -f "$D/a.conf"
    cd_run a
    expect_eq "not root, default owner root:root: warned on stderr" "agent-config-deploy: not root: owner root:root not applied" "$ERR"
    is_json && pass "warning stays off stdout (one JSON document)" || fail "warning stays off stdout" "$OUT"
else
    mapw "a = $D/a.conf owner=nobody:nogroup mode=0640"
    cd_run a
    expect_eq "root: owner nobody:nogroup applied" "nobody:nogroup" "$(stat -c %U:%G "$D/a.conf")"
fi

# ---------------------------------------------------------------------------
heading "validate"

rm -rf "$D"; mkdir -p "$D"
cat > "$T/v-ok.sh" <<'EOF'
#!/bin/bash
# prints the staged file's mode, name and content
echo "mode=$(stat -c %a "$1") base=$(basename "$1") dir=$(dirname "$1")"
cat "$1"
exit 0
EOF
cat > "$T/v-fail.sh" <<'EOF'
#!/bin/bash
echo "line 3: bad thing"
echo "to stderr too" >&2
exit 3
EOF
cat > "$T/v-grep.sh" <<'EOF'
#!/bin/bash
# accepts a file that contains the word good; also gets a second argument
[ "$1" = "--file" ] || [ "$1" = "--check" ] || exit 9
grep -q good "$2"
EOF
chmod 755 "$T/v-ok.sh" "$T/v-fail.sh" "$T/v-grep.sh"

mapw "a = $D/a.conf mode=0600 validate=$T/v-ok.sh {}"
setin 'good\n'
cd_run a
expect_eq "validate ok: exit 0" 0 "$RC"
jis "validate ok: ran, exit 0" '[$d->{validate}{ran}, $d->{validate}{exit}, $d->{changed}]' '[true,0,true]'
expect_has "validate ok: output captured" "$(jv '$d->{validate}{output}')" "mode=600 base=.a.conf.new."
expect_has "validate ok: the staged file is beside the target" "$(jv '$d->{validate}{output}')" "dir=$D"
expect_has "validate ok: it saw the new content" "$(jv '$d->{validate}{output}')" "good"
expect_eq "validate ok: installed" "good" "$(cat "$D/a.conf")"
expect_eq "validate ok: no staged file left" "a.conf" "$(ls -A "$D")"

mapw "a = $D/a.conf validate=$T/v-grep.sh --check {}"
setin 'good again\n'
cd_run a
expect_eq "validate with a leading argument and {} last: accepted" "true" "$(jv '$d->{changed}')"

mapw "a = $D/a.conf validate=$T/v-fail.sh {}"
rm -f "$D/a.conf.prev"
OLD="$(sha "$D/a.conf")"
setin 'bad content\n'
cd_run a
expect_eq "validate fail: exit 1" 1 "$RC"
is_json && pass "validate fail: stdout is one JSON document" || fail "validate fail: stdout is one JSON document" "$OUT"
expect_has "validate fail: error has the exit code" "$(jv '$d->{error}')" "validate failed (exit 3)"
expect_has "validate fail: error has stdout of validate" "$(jv '$d->{error}')" "line 3: bad thing"
expect_has "validate fail: error has stderr of validate" "$(jv '$d->{error}')" "to stderr too"
jis "validate fail: validate object" '[$d->{validate}{ran}, $d->{validate}{exit}]' '[true,3]'
expect_eq "validate fail: the old file is untouched" "$OLD" "$(sha "$D/a.conf")"
expect_eq "validate fail: no staged file, no .prev" "a.conf" "$(ls -A "$D")"

# a new file that fails validation is not created
mapw "n = $D/n.conf validate=$T/v-fail.sh {}"
cd_run n
expect_eq "validate fail on a new file: exit 1" 1 "$RC"
[ ! -e "$D/n.conf" ] && pass "validate fail on a new file: nothing created" || fail "validate fail on a new file: nothing created"
expect_eq "validate fail on a new file: no leftovers" "a.conf" "$(ls -A "$D")"

# {} inside a word is replaced too
mapw "a = $D/a.conf validate=$T/v-grep.sh --file {}"
setin 'good\n'
cd_run a
expect_eq "validate: {} as its own word" 0 "$RC"

# no shell: ; and $ reach the command as plain text
mapw "a = $D/a.conf validate=/bin/echo ; touch $T/pwned \$HOME {}"
setin 'noshell\n'
cd_run a
expect_eq "validate: no shell, the command ran as one argument list" 0 "$RC"
[ ! -e "$T/pwned" ] && pass "validate: nothing after ; was run" || fail "validate: nothing after ; was run"
expect_has "validate: \$HOME arrived unexpanded" "$(jv '$d->{validate}{output}')" '$HOME'

# a command that is missing or not executable
mapw "a = $D/a.conf validate=$T/nonexistent {}"
setin 'x2\n'
cd_run a
expect_eq "validate command missing: exit 1" 1 "$RC"
expect_has "validate command missing: says so" "$(jv '$d->{error}')" "not found or not executable"
printf '#!/bin/bash\nexit 0\n' > "$T/v-noexec.sh"; chmod 644 "$T/v-noexec.sh"
mapw "a = $D/a.conf validate=$T/v-noexec.sh {}"
cd_run a
expect_eq "validate command not executable: exit 1" 1 "$RC"

# output is trimmed to 2000 characters
printf '#!/bin/bash\nhead -c 6000 /dev/zero | tr "\\0" "x"; exit 1\n' > "$T/v-long.sh"; chmod 755 "$T/v-long.sh"
mapw "a = $D/a.conf validate=$T/v-long.sh {}"
cd_run a
expect_eq "validate output: at most 2000 characters" 1 "$(jv 'length($d->{validate}{output}) <= 2000 ? 1 : 0')"
expect_eq "validate output: not empty" 1 "$(jv 'length($d->{validate}{output}) > 1000 ? 1 : 0')"
printf '#!/bin/bash\nprintf "\\n\\n  spaced out  \\n\\n"; exit 1\n' > "$T/v-ws.sh"; chmod 755 "$T/v-ws.sh"
mapw "a = $D/a.conf validate=$T/v-ws.sh {}"
cd_run a
expect_eq "validate output: trimmed" '"validate failed (exit 1): spaced out"' "$(jv '$d->{error}')"

# timeout (the test knob shortens the 30 s)
printf '#!/bin/bash\nsleep 30 & echo $! > "%s/slow.pid"; wait\n' "$T" > "$T/v-slow.sh"; chmod 755 "$T/v-slow.sh"
mapw "a = $D/a.conf validate=$T/v-slow.sh {}"
rm -f "$D/a.conf.prev"
OLD="$(sha "$D/a.conf")"
setin 'slow\n'
t0=$SECONDS
CONFIG_DEPLOY_VALIDATE_TIMEOUT=1 cd_run a
expect_eq "validate timeout: exit 1" 1 "$RC"
expect_has "validate timeout: says so" "$(jv '$d->{error}')" "timed out after 1s"
[ $((SECONDS - t0)) -le 5 ] && pass "validate timeout: returned promptly" || fail "validate timeout: returned promptly" "$((SECONDS - t0)) s"
expect_eq "validate timeout: old file untouched" "$OLD" "$(sha "$D/a.conf")"
expect_eq "validate timeout: nothing left behind" "a.conf" "$(ls -A "$D")"
sleep 0.2
if [ -f "$T/slow.pid" ] && kill -0 "$(cat "$T/slow.pid")" 2> /dev/null; then fail "validate timeout: its children are killed"; kill "$(cat "$T/slow.pid")" 2> /dev/null; else pass "validate timeout: its children are killed"; fi
grep -q 'my \$VTIME *= \$ENV{CONFIG_DEPLOY_VALIDATE_TIMEOUT} // 30' "$CD" && pass "default validate timeout is 30 s" || fail "default validate timeout is 30 s"

# validate runs only when there is something to write
printf '#!/bin/bash\ntouch "%s/validate-ran"\nexit 0\n' "$T" > "$T/v-mark.sh"; chmod 755 "$T/v-mark.sh"
mapw "a = $D/a.conf validate=$T/v-mark.sh {}"
rm -f "$T/validate-ran"
setin 'mark\n'
cd_run a
[ -e "$T/validate-ran" ] && pass "changed content: validate runs" || fail "changed content: validate runs"
rm -f "$T/validate-ran"
cd_run a
[ ! -e "$T/validate-ran" ] && pass "unchanged content: validate does not run" || fail "unchanged content: validate does not run"

# ---------------------------------------------------------------------------
heading "Size limit, input, names, targets"

rm -rf "$D"; mkdir -p "$D"
mapw "a = $D/a.conf" "b = $D/b.conf"
head -c 1048576 /dev/zero | tr '\0' 'y' > "$IN/content"
cd_run a
expect_eq "exactly 1 MiB: accepted" 0 "$RC"
expect_eq "exactly 1 MiB: written whole" 1048576 "$(stat -c %s "$D/a.conf")"
OLD="$(sha "$D/a.conf")"
head -c 1048577 /dev/zero | tr '\0' 'z' > "$IN/content"
cd_run a
refused "over 1 MiB" "over the 1048576 byte limit"
expect_eq "over 1 MiB: the file is untouched" "$OLD" "$(sha "$D/a.conf")"
cd_run b
[ ! -e "$D/b.conf" ] && pass "over 1 MiB: nothing created" || fail "over 1 MiB: nothing created"
expect_eq "over 1 MiB: nothing left behind" "a.conf" "$(ls -A "$D")"

rm -f "$IN/content"
cd_run a
refused "no input file" "no input received (field 'content')"
OUT="$(env -u CTRL_EXEC_INPUT perl "$CD" a 2> /dev/null < /dev/null)"; RC=$?
refused "no CTRL_EXEC_INPUT at all" "no input received (field 'content')"
echo "x" > "$IN/other"
cd_run a
refused "input with another field only" "no input received (field 'content')"
rm -f "$IN/other"

setin 'x\n'
mapw "alpha = $D/a.conf" "beta = $D/b.conf"
cd_run gamma
refused "unknown name" "unknown config name 'gamma'; known: alpha, beta"
expect_lacks "unknown name: no paths in the answer" "$OUT" "$D"
cd_run 'a;b'
refused "name with odd characters" "unknown config name"
cd_run ../a
refused "name with a path" "unknown config name"
cd_run --test gamma
refused "unknown name with --test" "unknown config name 'gamma'"

# the folder must exist and is never created
mapw "a = $T/nofolder/a.conf"
cd_run a
refused "folder missing" "does not exist"
[ ! -e "$T/nofolder" ] && pass "folder missing: not created" || fail "folder missing: not created"
mapw "a = $T/victim/a.conf"
cd_run a
refused "folder is a file" "does not exist"

# symlink target
mapw "a = $D/link.conf"
echo "keep me" > "$T/other.conf"
ln -s "$T/other.conf" "$D/link.conf"
cd_run a
refused "symlink target" "symlink"
expect_eq "symlink target: the linked file is untouched" "keep me" "$(cat "$T/other.conf")"
cd_run --test a
refused "symlink target with --test" "symlink"
rm "$D/link.conf"; ln -s "$T/nowhere" "$D/link.conf"
cd_run a
refused "dangling symlink target" "symlink"
[ ! -e "$T/nowhere" ] && pass "dangling symlink: nothing created behind it" || fail "dangling symlink: nothing created behind it"
rm "$D/link.conf"
mkdir "$D/dir.conf"
mapw "a = $D/dir.conf"
cd_run a
refused "target is a folder" "not a regular file"

# the map itself, and a folder with a link into the protected one, at write time
ln -s "$T/prot/sub" "$D/lnkdir"
mapw "a = $D/lnkdir/x.conf"
cd_run a
refused "folder that is a symlink into a protected folder (checked at write time)" "never writes"
[ ! -e "$T/prot/sub/x.conf" ] && pass "...and nothing was written there" || fail "...and nothing was written there"

# ---------------------------------------------------------------------------
heading "--test"

rm -rf "$D"; mkdir -p "$D"
mapw "a = $D/a.conf validate=$T/v-ok.sh {}"
setin 'proposed\n'
cd_run --test a
expect_eq "--test new file: exit 0" 0 "$RC"
jis "--test new file: would_change true, changed false" '[$d->{would_change}, $d->{changed}, $d->{validate}{ran}]' '[true,false,true]'
expect_eq "--test new file: nothing created, nothing left" "" "$(ls -A "$D")"
echo "current" > "$D/a.conf"
cd_run --test a
expect_eq "--test existing: file untouched" "current" "$(cat "$D/a.conf")"
expect_eq "--test existing: no .prev, no staged file" "a.conf" "$(ls -A "$D")"
jis "--test existing: previous sha is the installed file's" '$d->{previous_sha256}' "\"$(sha "$D/a.conf")\""
printf 'current\n' > "$IN/content"
cd_run --test a
jis "--test same content: would_change false, validate not run" '[$d->{would_change}, $d->{validate}{ran}]' '[false,false]'
mapw "a = $D/a.conf validate=$T/v-fail.sh {}"
setin 'will fail\n'
cd_run --test a
expect_eq "--test with failing validate: exit 1" 1 "$RC"
expect_has "--test with failing validate: error" "$(jv '$d->{error}')" "validate failed (exit 3)"
expect_eq "--test with failing validate: nothing left" "a.conf" "$(ls -A "$D")"
rm -f "$IN/content"
cd_run --test a
refused "--test without input" "no input received"

# ---------------------------------------------------------------------------
heading "--list"

rm -rf "$D"; mkdir -p "$D"
mapw "one = $D/one.conf mode=0600" "two = $D/two.conf validate=/bin/true {}" "three = $D/three.conf" "four = $D/link.conf"
printf 'hello\n' > "$D/one.conf"; chmod 600 "$D/one.conf"
echo x > "$D/target"; ln -s "$D/target" "$D/link.conf"
cd_run --list
expect_eq "--list: exit 0" 0 "$RC"
is_json && pass "--list: stdout is one JSON document" || fail "--list: stdout is one JSON document" "$OUT"
jis "--list: names in order" '[map { $_->{name} } @{ $d->{files} }]' '["one","two","three","four"]'
jis "--list: an installed file" '[@{ $d->{files}[0] }{qw(path exists size mode validate)}]' "[\"$D/one.conf\",true,6,\"0600\",false]"
expect_eq "--list: sha256 of the installed file" "$(sha "$D/one.conf")" "$(jv '$d->{files}[0]{sha256}' | tr -d '"')"
expect_eq "--list: owner of the installed file" "\"$ME:$MYGROUP\"" "$(jv '$d->{files}[0]{owner}')"
jis "--list: an absent file" '[@{ $d->{files}[1] }{qw(exists sha256 size owner mode validate)}]' '[false,null,null,null,null,true]'
jis "--list: a symlink is flagged and not read" '[@{ $d->{files}[3] }{qw(exists symlink sha256)}]' '[true,true,null]'
expect_lacks "--list: contents are not shown" "$OUT" "hello"
expect_eq "--list needs no input" 0 "$(env -u CTRL_EXEC_INPUT perl "$CD" --list > /dev/null 2>&1 < /dev/null; echo $?)"

# ---------------------------------------------------------------------------
heading "The shipped map example, and the nagios-check validate"

if [ -f "$MAPEX" ]; then
    cp "$MAPEX" "$MAP"; chmod 600 "$MAP"
    cd_run --list
    expect_eq "config-deploy.conf.example is a valid map" 0 "$RC"
    expect_eq "example: one entry, nagios-checks" '["nagios-checks"]' "$(jv '[map { $_->{name} } @{ $d->{files} }]')"
    expect_eq "example: path /etc/nagios-checks/checks.conf" '"/etc/nagios-checks/checks.conf"' "$(jv '$d->{files}[0]{path}')"
    expect_eq "example: has a validate command" "true" "$(jv '$d->{files}[0]{validate}')"
    expect_lacks "example: generic (no real host names)" "$(cat "$MAPEX")" "cloudient"
else
    fail "config-deploy.conf.example exists"
fi

# ---------------------------------------------------------------------------
# config-push.sh
heading "config-push.sh (STUB ctrl-exec-cli over the real agent script, STUB logger)"

B="$T/jbin"        # stubs
F="$T/jfiles"      # per-agent maps, folders, canned replies
JC="$T/jobs/config-push.conf"
mkdir -p "$B" "$F" "$T/jobs/sources"
export STUB_LOG="$T/logger.log" STUB_CALLS="$T/calls.log" STUB_FILES="$F" STUB_AGENT_SCRIPT="$CD"
printf '#!/bin/bash\necho "$*" >> "$STUB_LOG"\n' > "$B/logger"
cat > "$B/ctrl-exec-cli" <<'EOF'
#!/bin/bash
# stub: ctrl-exec-cli run <agent> --script S --json [--input-fields -] -- args...
# Logs the call, then runs the real agent script with this agent's map and the
# fields from stdin as files in a CTRL_EXEC_INPUT folder (as input=fields does).
echo "$*" >> "$STUB_CALLS"
[ "$1" = run ] || exit 64
agent="$2"; shift 2
fields=0
while [ $# -gt 0 ] && [ "$1" != "--" ]; do
    [ "$1" = "--input-fields" ] && fields=1
    shift
done
shift
if [ -f "$STUB_FILES/$agent.fail" ]; then cat "$STUB_FILES/$agent.fail" >&2; exit 1; fi
if [ -f "$STUB_FILES/$agent.json" ]; then cat "$STUB_FILES/$agent.json"; exit 0; fi
inp="$(mktemp -d "$STUB_FILES/in.XXXXXX")"
if [ "$fields" = 1 ]; then
    cat > "$inp/.stdin"
    cp "$inp/.stdin" "$STUB_FILES/$agent.stdin"
    perl -MJSON::PP -e 'open my $f, "<", "$ARGV[0]/.stdin" or exit 1; local $/; my $d = decode_json(<$f>);
        for my $k (keys %$d) { open my $o, ">:utf8", "$ARGV[0]/$k" or exit 1; print $o $d->{$k} }' "$inp"
    rm -f "$inp/.stdin"
else
    rmdir "$inp"; inp=""
fi
export CONFIG_DEPLOY_MAP="$STUB_FILES/$agent.map" CONFIG_DEPLOY_ALLOW_NONROOT=1
[ -n "$inp" ] && export CTRL_EXEC_INPUT="$inp" || unset CTRL_EXEC_INPUT
out="$(perl "$STUB_AGENT_SCRIPT" "$@" 2> "$STUB_FILES/stub.err" < /dev/null)"
rc=$?
[ -n "$inp" ] && rm -rf "$inp"
perl -MJSON::PP -e 'my ($h, $rc, $out, $err) = @ARGV; local $/; open my $f, "<", $err; my $e = <$f> // "";
    print encode_json({ ok => JSON::PP::true, results => [{ host => $h, exit => $rc + 0, stdout => $out, stderr => $e }] })' "$agent" "$rc" "$out" "$STUB_FILES/stub.err"
EOF
chmod 755 "$B/logger" "$B/ctrl-exec-cli"
for a in agent-01 agent-02 agent-03; do
    mkdir -p "$F/$a"
    printf 'nagios-checks = %s/%s/checks.conf mode=0644\n' "$F" "$a" > "$F/$a.map"
    chmod 600 "$F/$a.map"
done
printf '# checks\ndisk = check_disk -w 15%% -c 5%%\nnote = check_x "caf\xc3\xa9 \\\\ back"\n' > "$T/jobs/sources/nagios-checks.conf"
cat > "$JC" <<'EOF'
# the push lines
push = agent-01 nagios-checks sources/nagios-checks.conf
push = agent-02 nagios-checks sources/nagios-checks.conf
EOF
cat >> "$JC" <<'EOF'
schedule = */5 * * * *
EOF

# job ARGS...: runs the job; OUT its stdout, RC its exit, LOG the logger lines, CALLS the CLI calls
job() {
    : > "$STUB_LOG"; : > "$STUB_CALLS"
    OUT="$(CONFIG_PUSH_CONF="${CONFIG_PUSH_CONF:-$JC}" PATH="$B:$PATH" bash "$JOB" "$@" 2> "$T/jerr" < /dev/null)"
    RC=$?
    LOG="$(cat "$STUB_LOG")"
    CALLS="$(cat "$STUB_CALLS")"
}

job
expect_eq "push: exit 0" 0 "$RC"
expect_eq "push: the CLI is called per line, name on the command line, contents not" \
    $'run agent-01 --script agent-config-deploy --json --input-fields - -- nagios-checks\nrun agent-02 --script agent-config-deploy --json --input-fields - -- nagios-checks' "$CALLS"
SHA12="$(sha "$T/jobs/sources/nagios-checks.conf" | cut -c1-12)"
expect_has "push: syslog line per agent, user.info" "$LOG" "-p user.info -t ctrl-exec-config -- agent=agent-01 name=nagios-checks result=changed sha256=$SHA12"
expect_has "push: second agent" "$LOG" "agent=agent-02 name=nagios-checks result=changed sha256=$SHA12"
expect_has "push: summary line" "$LOG" "-p user.info -t ctrl-exec-config -- status=ok mode=push lines=2 changed=2 unchanged=0 same=0 differs=0 missing=0 failed=0"
expect_eq "push: the summary is also printed" "agent=agent-01 name=nagios-checks result=changed sha256=$SHA12
agent=agent-02 name=nagios-checks result=changed sha256=$SHA12
status=ok mode=push lines=2 changed=2 unchanged=0 same=0 differs=0 missing=0 failed=0" "$OUT"
cmp -s "$T/jobs/sources/nagios-checks.conf" "$F/agent-01/checks.conf" && pass "push: file arrives byte for byte (quotes, backslash, UTF-8)" || fail "push: file arrives byte for byte"
cmp -s "$T/jobs/sources/nagios-checks.conf" "$F/agent-02/checks.conf" && pass "push: ...on the second agent" || fail "push: ...on the second agent"
expect_eq "push: the CLI's stdin was one JSON object with content" '["content"]' "$(perl -MJSON::PP -e 'open my $f, "<", $ARGV[0]; local $/; print encode_json([sort keys %{ decode_json(<$f>) }])' "$F/agent-01.stdin")"
expect_lacks "push: contents are in no argument" "$CALLS" "check_disk"

job
expect_eq "second push: exit 0" 0 "$RC"
expect_has "second push: unchanged" "$LOG" "agent=agent-01 name=nagios-checks result=unchanged"
expect_has "second push: summary counts" "$LOG" "changed=0 unchanged=2"
[ ! -e "$F/agent-01/checks.conf.prev" ] && pass "second push: no .prev written" || fail "second push: no .prev written"

echo "# a new line" >> "$T/jobs/sources/nagios-checks.conf"
job
expect_has "edited source: changed again" "$LOG" "agent=agent-01 name=nagios-checks result=changed"
[ -f "$F/agent-01/checks.conf.prev" ] && pass "edited source: the agent kept .prev" || fail "edited source: the agent kept .prev"

# --check
job --check
expect_eq "--check same: exit 0" 0 "$RC"
expect_eq "--check: only --list is called, no input sent" $'run agent-01 --script agent-config-deploy --json -- --list\nrun agent-02 --script agent-config-deploy --json -- --list' "$CALLS"
expect_has "--check same: result=same" "$LOG" "-p user.info -t ctrl-exec-config -- agent=agent-01 name=nagios-checks result=same sha256=$(sha "$T/jobs/sources/nagios-checks.conf" | cut -c1-12)"
expect_has "--check same: summary" "$LOG" "status=ok mode=check lines=2 changed=0 unchanged=0 same=2 differs=0 missing=0 failed=0"
echo "drift" > "$F/agent-02/checks.conf"
rm -f "$F/agent-01/checks.conf"
SNAP="$(sha "$F/agent-02/checks.conf")"
job --check
expect_eq "--check differs/missing: exit 1" 1 "$RC"
expect_has "--check: missing file" "$LOG" "-p user.warning -t ctrl-exec-config -- agent=agent-01 name=nagios-checks result=missing"
expect_has "--check: differing file" "$LOG" "-p user.warning -t ctrl-exec-config -- agent=agent-02 name=nagios-checks result=differs"
expect_has "--check: summary status=differs at user.warning" "$LOG" "-p user.warning -t ctrl-exec-config -- status=differs mode=check lines=2 changed=0 unchanged=0 same=0 differs=1 missing=1 failed=0"
expect_eq "--check changes nothing on the agents" "$SNAP" "$(sha "$F/agent-02/checks.conf")"
[ ! -e "$F/agent-01/checks.conf" ] && pass "--check does not create the missing file" || fail "--check does not create the missing file"

# agent filter
job agent-02
expect_eq "agent filter: only that agent is called" "run agent-02 --script agent-config-deploy --json --input-fields - -- nagios-checks" "$CALLS"
expect_has "agent filter: summary counts one line" "$LOG" "lines=1"
job --check agent-01 agent-02
expect_eq "--check with agents: both called" 2 "$(wc -l <<< "$CALLS")"
job agent-09
expect_eq "agent filter matching nothing: exit 1" 1 "$RC"
expect_has "agent filter matching nothing: logged" "$LOG" "no push lines"
job --bogus
expect_eq "unknown option: exit 2" 2 "$RC"

# failures
echo "ctrl-exec-cli: agent agent-02 unreachable" > "$F/agent-02.fail"
job
expect_eq "unreachable agent: exit 1" 1 "$RC"
expect_has "unreachable agent: failed with the reason, user.err" "$LOG" '-p user.err -t ctrl-exec-config -- agent=agent-02 name=nagios-checks result=failed error="ctrl-exec-cli: agent agent-02 unreachable"'
expect_has "unreachable agent: the other agent is still done" "$LOG" "agent=agent-01 name=nagios-checks result=changed"
expect_has "unreachable agent: summary status=failed at user.err" "$LOG" "-p user.err -t ctrl-exec-config -- status=failed mode=push lines=2"
job --check
expect_has "unreachable agent: --check failed too" "$LOG" "agent=agent-02 name=nagios-checks result=failed"
rm "$F/agent-02.fail"

echo '{"ok":true,"results":[{"host":"agent-02","exit":126,"stdout":"","stderr":"script not permitted","error":"script not permitted"}]}' > "$F/agent-02.json"
job
expect_has "agent refuses the script: failed with the agent's words" "$LOG" 'agent=agent-02 name=nagios-checks result=failed error="script not permitted"'
echo '{"ok":false,"error":"unknown agent agent-02","code":404}' > "$F/agent-02.json"
job
expect_has "API error: failed with the API's words" "$LOG" 'error="unknown agent agent-02"'
echo 'not json' > "$F/agent-02.json"
job
expect_has "unreadable reply: failed" "$LOG" "no reply from ctrl-exec-cli"
rm "$F/agent-02.json"

# the agent's own refusal (validate) comes through
printf 'nagios-checks = %s/agent-02/checks.conf validate=%s {}\n' "$F" "$T/v-fail.sh" > "$F/agent-02.map"
echo "different" >> "$T/jobs/sources/nagios-checks.conf"
job
expect_eq "agent's validate fails: exit 1" 1 "$RC"
expect_has "agent's validate fails: its words in the log" "$LOG" 'agent=agent-02 name=nagios-checks result=failed error="validate failed (exit 3): line 3: bad thing to stderr too"'
printf 'nagios-checks = %s/agent-02/checks.conf\n' "$F" > "$F/agent-02.map"
printf 'other = %s/agent-02/o.conf\n' "$F" > "$F/agent-02.map"
job
expect_has "name unknown on the agent: failed with the agent's words" "$LOG" "unknown config name 'nagios-checks'; known: other"
printf 'nagios-checks = %s/agent-02/checks.conf\n' "$F" > "$F/agent-02.map"
job --check
printf 'other = %s/agent-02/o.conf\n' "$F" > "$F/agent-02.map"
job --check agent-02
expect_has "--check, name unknown on the agent: failed" "$LOG" "agent=agent-02 name=nagios-checks result=failed error=\"unknown name on the agent\""
printf 'nagios-checks = %s/agent-02/checks.conf\n' "$F" > "$F/agent-02.map"

# sources
printf '%s\n' "push = agent-01 nagios-checks sources/missing.conf" > "$T/jobs/c2.conf"
CONFIG_PUSH_CONF="$T/jobs/c2.conf" job
expect_eq "missing source: exit 1" 1 "$RC"
expect_has "missing source: failed, named" "$LOG" "result=failed error=\"cannot read source $T/jobs/sources/missing.conf\""
expect_eq "missing source: the agent is not called" "" "$CALLS"
printf '\xff\xfe binary' > "$T/jobs/sources/bin.conf"
printf '%s\n' "push = agent-01 nagios-checks sources/bin.conf" > "$T/jobs/c2.conf"
CONFIG_PUSH_CONF="$T/jobs/c2.conf" job
expect_has "source not UTF-8: failed" "$LOG" "is not UTF-8 text"
expect_eq "source not UTF-8: the agent is not called" "" "$CALLS"
head -c 1048577 /dev/zero | tr '\0' 'q' > "$T/jobs/sources/big.conf"
printf '%s\n' "push = agent-01 nagios-checks $T/jobs/sources/big.conf" > "$T/jobs/c2.conf"
CONFIG_PUSH_CONF="$T/jobs/c2.conf" job
expect_has "source over 1 MiB: failed before any call" "$LOG" "is over 1 MiB"
expect_eq "source over 1 MiB: the agent is not called" "" "$CALLS"
printf '%s\n' "push = agent-01 nagios-checks $T/jobs/sources/nagios-checks.conf" > "$T/jobs/c2.conf"
CONFIG_PUSH_CONF="$T/jobs/c2.conf" job
expect_eq "absolute source path: works" 0 "$RC"
mkdir -p "$T/elsewhere"
OUT="$(cd "$T/elsewhere" && CONFIG_PUSH_CONF="$JC" PATH="$B:$PATH" bash "$JOB" 2> /dev/null < /dev/null)"; RC=$?
expect_eq "relative source resolves from the conf's folder, not the cwd" 0 "$RC"

# conf
CONFIG_PUSH_TAG=mytag job
expect_has "CONFIG_PUSH_TAG sets the tag" "$LOG" "-t mytag --"
OUT="$(CONFIG_PUSH_SCRIPT=other-name CONFIG_PUSH_CONF="$JC" PATH="$B:$PATH" bash "$JOB" 2> /dev/null < /dev/null)"
expect_has "CONFIG_PUSH_SCRIPT sets the agent script name" "$(cat "$STUB_CALLS")" "--script other-name --"
printf '%s\n' "schedule = */5 * * * *" > "$T/jobs/c2.conf"
CONFIG_PUSH_CONF="$T/jobs/c2.conf" job
expect_eq "no push lines: exit 1" 1 "$RC"
expect_has "no push lines: logged" "$LOG" "no push lines"
printf '%s\n' "push = agent-01 nagios-checks" > "$T/jobs/c2.conf"
CONFIG_PUSH_CONF="$T/jobs/c2.conf" job
expect_eq "push line without a source: exit 1" 1 "$RC"
expect_has "push line without a source: logged" "$LOG" "bad push line"
CONFIG_PUSH_CONF="$T/none.conf" job
expect_eq "missing job config: exit 1" 1 "$RC"
expect_has "missing job config: logged" "$LOG" "cannot read"
cp "$JC" "$T/jobs/default/config-push.conf" 2> /dev/null || { mkdir -p "$T/jobs/default"; cp "$JC" "$T/jobs/default/config-push.conf"; cp "$JOB" "$T/jobs/default/config-push.sh"; cp -r "$T/jobs/sources" "$T/jobs/default/sources"; }
OUT="$(env -u CONFIG_PUSH_CONF PATH="$B:$PATH" bash "$T/jobs/default/config-push.sh" 2> /dev/null < /dev/null)"; RC=$?
expect_eq "default config path is beside the script" 0 "$RC"

if [ -f "$JOBCONF_EXAMPLE" ]; then
    CONFIG_PUSH_CONF="$JOBCONF_EXAMPLE" job
    expect_has "example config: three agents, names only" "$LOG" "agent=agent-03 name=nagios-checks result=failed"
    expect_eq "example config: no call is made while the source is missing" "" "$CALLS"
    grep -q '^schedule' "$JOBCONF_EXAMPLE" && fail "example config has no schedule line" || pass "example config has no schedule line"
else
    fail "config-push.conf.example exists"
fi
[ -x "$JOB" ] && pass "config-push.sh is executable" || fail "config-push.sh is executable"
shellcheck -x "$JOB" > /dev/null 2>&1 && pass "config-push.sh is shellcheck clean" || { command -v shellcheck > /dev/null && fail "config-push.sh is shellcheck clean" || skip "shellcheck not installed"; }

# ---------------------------------------------------------------------------
heading "nagios-check --check-config as the validate command"

if [ -x "$NAGIOS" ] && perl "$NAGIOS" --check-config /dev/null > /dev/null 2>&1; then
    rm -rf "$D"; mkdir -p "$D"
    mapw "nagios-checks = $D/checks.conf validate=$NAGIOS --check-config {}"
    setin 'plugin_dir = /nonexistent\nload = check_load -w 1\n'
    cd_run nagios-checks
    expect_eq "good nagios config: deployed" "true" "$(jv '$d->{changed}')"
    expect_eq "good nagios config: validate exit 0" "0" "$(jv '$d->{validate}{exit}')"
    OLDN="$(sha "$D/checks.conf")"
    setin 'this is not a check\n'
    cd_run nagios-checks
    expect_eq "bad nagios config: refused" 1 "$RC"
    expect_has "bad nagios config: the parser's line number" "$(jv '$d->{error}')" "line 1"
    expect_eq "bad nagios config: old file kept" "$OLDN" "$(sha "$D/checks.conf")"
else
    skip "nagios-check --check-config not available"
fi

# ---------------------------------------------------------------------------
heading "install.sh (temp root, fake systemctl, no root needed)"

INST="$DIR/install.sh"
IB="$T/ibin"
R="$T/iroot"
mkdir -p "$IB"
printf '#!/bin/bash\necho "$*" >> "$STUB_SYSTEMCTL_LOG"\nexit 0\n' > "$IB/systemctl"
chmod 755 "$IB/systemctl"
export STUB_SYSTEMCTL_LOG="$T/systemctl.log"

# newroot [noscripts] [noprofile]: a fresh agent host under $R
newroot() {
    rm -rf "$R"
    mkdir -p "$R/etc/ctrl-exec-agent"
    : > "$STUB_SYSTEMCTL_LOG"
    printf '# agent scripts\n' > "$R/etc/ctrl-exec-agent/scripts.conf"
    printf 'executor_socket = /run/x.sock\n\n[profile config-deploy]\nrun_as = root\nwritable = /etc/nagios-checks\n' > "$R/etc/ctrl-exec-agent/agent.conf"
    for o in "$@"; do
        case "$o" in
            noscripts) rm -f "$R/etc/ctrl-exec-agent/scripts.conf" ;;
            noprofile) printf 'executor_socket = /run/x.sock\n' > "$R/etc/ctrl-exec-agent/agent.conf" ;;
        esac
    done
}
inst() {
    OUT="$(CD_ROOT="$R" CD_ALLOW_NONROOT=1 PATH="$IB:$PATH" bash "$INST" "$@" 2>&1 < /dev/null)"
    RC=$?
}

newroot
inst
expect_eq "fresh install: exit 0" 0 "$RC"
expect_has "fresh install: reports 3 changes" "$OUT" "done: 3 changed, 0 warnings"
[ -x "$R/opt/ctrl-exec-scripts/agent-config-deploy.pl" ] && pass "fresh install: script installed 755" || fail "fresh install: script installed 755"
cmp -s "$CD" "$R/opt/ctrl-exec-scripts/agent-config-deploy.pl" && pass "fresh install: script is a copy of ours" || fail "fresh install: script is a copy of ours"
expect_eq "fresh install: the map is mode 600" 600 "$(stat -c %a "$R/etc/ctrl-exec-agent/config-deploy.conf")"
expect_has "fresh install: the map holds the nagios-checks entry" "$(cat "$R/etc/ctrl-exec-agent/config-deploy.conf")" "nagios-checks = /etc/nagios-checks/checks.conf"
expect_has "fresh install: scripts.conf entry added" "$(cat "$R/etc/ctrl-exec-agent/scripts.conf")" "agent-config-deploy = /opt/ctrl-exec-scripts/agent-config-deploy.pl profile=config-deploy input=fields"
expect_has "fresh install: agent reloaded" "$(cat "$STUB_SYSTEMCTL_LOG")" "reload ctrl-exec-agent"
expect_has "fresh install: ends with --list output" "$OUT" "ok verify: nagios-checks -> /etc/nagios-checks/checks.conf (absent)"
expect_has "fresh install: profile present" "$OUT" "ok [profile config-deploy] defined"
expect_eq "fresh install: agent.conf untouched" 5 "$(wc -l < "$R/etc/ctrl-exec-agent/agent.conf")"

: > "$STUB_SYSTEMCTL_LOG"
inst
expect_has "second run: nothing changed" "$OUT" "done: 0 changed, 0 warnings"
expect_lacks "second run: no changed line" "$OUT" "changed /"
expect_eq "second run: no reload" "" "$(cat "$STUB_SYSTEMCTL_LOG")"
expect_eq "second run: scripts.conf has one entry" 1 "$(grep -c '^agent-config-deploy' "$R/etc/ctrl-exec-agent/scripts.conf")"

echo "mine = /etc/mine.conf" > "$R/etc/ctrl-exec-agent/config-deploy.conf"
echo "tampered" >> "$R/opt/ctrl-exec-scripts/agent-config-deploy.pl"
inst
expect_eq "existing map: kept" "mine = /etc/mine.conf" "$(cat "$R/etc/ctrl-exec-agent/config-deploy.conf")"
expect_has "existing map: the shipped one is in .new" "$(cat "$R/etc/ctrl-exec-agent/config-deploy.conf.new")" "nagios-checks = /etc/nagios-checks/checks.conf"
expect_eq "existing map: .new is mode 600" 600 "$(stat -c %a "$R/etc/ctrl-exec-agent/config-deploy.conf.new")"
expect_has "existing map: warned" "$OUT" "kept your"
cmp -s "$CD" "$R/opt/ctrl-exec-scripts/agent-config-deploy.pl" && pass "different script replaced" || fail "different script replaced"
inst
expect_has "existing map, second run: .new not rewritten, still warned" "$OUT" "done: 0 changed, 1 warnings"

newroot
echo "agent-config-deploy = /srv/elsewhere/agent-config-deploy.pl" >> "$R/etc/ctrl-exec-agent/scripts.conf"
inst
expect_has "scripts.conf other path: warned with the path" "$OUT" "agent-config-deploy = /srv/elsewhere/agent-config-deploy.pl"
expect_eq "scripts.conf other path: left alone" 2 "$(wc -l < "$R/etc/ctrl-exec-agent/scripts.conf")"
expect_eq "scripts.conf other path: no reload" "" "$(cat "$STUB_SYSTEMCTL_LOG")"

newroot noscripts
inst
expect_eq "no scripts.conf: exit 1" 1 "$RC"
expect_has "no scripts.conf: FAIL line" "$OUT" "FAIL"
expect_has "no scripts.conf: says why" "$OUT" "ctrl-exec agent not installed?"

newroot noprofile
inst
expect_has "no profile: warns" "$OUT" "no [profile config-deploy]"
expect_has "no profile: gives the snippet" "$OUT" "writable = /etc/nagios-checks"
expect_eq "no profile: agent.conf untouched" "executor_socket = /run/x.sock" "$(cat "$R/etc/ctrl-exec-agent/agent.conf")"

newroot
inst --dry-run
expect_eq "dry-run: exit 0" 0 "$RC"
expect_has "dry-run: says what would change" "$OUT" "changed installed $R/opt/ctrl-exec-scripts/agent-config-deploy.pl (dry-run"
expect_eq "dry-run: nothing written" "" "$(find "$R/opt" "$R/etc/ctrl-exec-agent/config-deploy.conf" 2> /dev/null)"
expect_eq "dry-run: scripts.conf untouched" "# agent scripts" "$(cat "$R/etc/ctrl-exec-agent/scripts.conf")"
expect_eq "dry-run: no reload" "" "$(cat "$STUB_SYSTEMCTL_LOG")"

newroot
inst --script-dir /srv/scripts
expect_has "--script-dir: used in scripts.conf" "$(cat "$R/etc/ctrl-exec-agent/scripts.conf")" "agent-config-deploy = /srv/scripts/agent-config-deploy.pl profile="
expect_has "--script-dir: the map's validate follows it" "$(cat "$R/etc/ctrl-exec-agent/config-deploy.conf")" "validate=/srv/scripts/nagios-check.pl --check-config {}"
[ -x "$R/srv/scripts/agent-config-deploy.pl" ] && pass "--script-dir: script installed there" || fail "--script-dir: script installed there"

OUT="$(bash "$INST" 2>&1 < /dev/null)"; RC=$?
if [ "$AM_ROOT" = 0 ]; then
    expect_eq "non-root without --dry-run: exit 1" 1 "$RC"
    expect_has "non-root without --dry-run: FAIL" "$OUT" "FAIL must run as root"
fi
OUT="$(bash "$INST" --bogus 2>&1 < /dev/null)"; RC=$?
expect_eq "install.sh: unknown option exits 2" 2 "$RC"
shellcheck -x "$INST" > /dev/null 2>&1 && pass "install.sh is shellcheck clean" || { command -v shellcheck > /dev/null && fail "install.sh is shellcheck clean" || skip "shellcheck not installed"; }

# ---------------------------------------------------------------------------
echo
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
if [ "$FAIL" -eq 0 ]; then echo "VERDICT: PASS"; else echo "VERDICT: FAIL"; fi
[ "$FAIL" -eq 0 ]
