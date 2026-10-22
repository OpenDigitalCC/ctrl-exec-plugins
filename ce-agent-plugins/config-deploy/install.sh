#!/bin/bash
# Install the config-deploy plugin on a ctrl-exec agent host.
#
#   install.sh [--script-dir DIR] [--dry-run]
#
# Run as root from a copy of this plugin folder. --script-dir is where the
# agent script goes (default /opt/ctrl-exec-scripts; cloudient uses
# /srv/scripts). --dry-run checks everything and changes nothing.
#
# Nothing a host already has is moved or overwritten without being asked:
# an existing /etc/ctrl-exec-agent/config-deploy.conf is kept (the shipped
# one is written beside it as .new), an existing scripts.conf entry is never
# changed, and agent.conf is never edited. Only our own script is replaced
# when it differs.
#
# Test-only environment (the test suite uses these; leave them unset):
#   CD_ROOT=DIR         prefix for /etc and the default script dir
#   CD_ALLOW_NONROOT=1  skip the root check and do not chown to root
set -uo pipefail
unset CONFIG_DEPLOY_MAP CONFIG_DEPLOY_ALLOW_NONROOT

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="${CD_ROOT:-}"
SCRIPT_DIR_HOST="/opt/ctrl-exec-scripts"
DRY=0
while [ $# -gt 0 ]; do
    case "$1" in
        --script-dir)
            [ -n "${2:-}" ] || { echo "install.sh: --script-dir needs a directory" >&2; exit 2; }
            SCRIPT_DIR_HOST="$2"; shift ;;
        --dry-run) DRY=1 ;;
        *) echo "usage: install.sh [--script-dir DIR] [--dry-run]" >&2; exit 2 ;;
    esac
    shift
done

SCRIPT_DIR="$ROOT$SCRIPT_DIR_HOST"
AGENT_DIR="$ROOT/etc/ctrl-exec-agent"
MAP="$AGENT_DIR/config-deploy.conf"
OWNER=(-o root -g root)
[ -n "${CD_ALLOW_NONROOT:-}" ] && OWNER=()

CHANGED=0 WARNED=0 FAILED=0
say() { printf '%s %s\n' "$1" "$2"; }
ok() { say ok "$1"; }
changed() { CHANGED=$((CHANGED + 1)); if [ "$DRY" = 1 ]; then say changed "$1 (dry-run: not done)"; else say changed "$1"; fi; }
warn() { WARNED=$((WARNED + 1)); say warn "$1"; }
fail() { FAILED=$((FAILED + 1)); say FAIL "$1"; }
mode_of() { stat -c %a "$1"; }

TMPD="$(mktemp -d "${TMPDIR:-/tmp}/config-deploy-install.XXXXXX")" || exit 1
trap 'rm -rf "$TMPD"' EXIT

# put SRC DEST: install a file of ours as root:root 755 and report it
put() {
    local src="$1" dest="$2"
    if [ -f "$dest" ] && cmp -s "$src" "$dest" && [ "$(mode_of "$dest")" = 755 ]; then
        ok "$dest is current"
        return
    fi
    local what="installed $dest"
    [ -e "$dest" ] && what="replaced $dest"
    if [ "$DRY" = 0 ]; then
        # create the folder only if missing: an existing one keeps its owner and mode
        [ -d "$(dirname "$dest")" ] || install -d -m 755 "${OWNER[@]}" "$(dirname "$dest")"
        install -m 755 "${OWNER[@]}" "$src" "$dest"
    fi
    changed "$what"
}

# 1. root
if [ "$(id -u)" != 0 ] && [ -z "${CD_ALLOW_NONROOT:-}" ] && [ "$DRY" = 0 ]; then
    fail "must run as root (or use --dry-run)"
    exit 1
fi

# 2. our script
put "$HERE/agent-config-deploy.pl" "$SCRIPT_DIR/agent-config-deploy.pl"

# 3. the map: never overwritten. The example's validate line names nagios-check.pl
#    in the default script dir; render it for the dir this install uses.
EXAMPLE="$TMPD/config-deploy.conf.example"
sed "s#/opt/ctrl-exec-scripts/#$SCRIPT_DIR_HOST/#g" "$HERE/config-deploy.conf.example" > "$EXAMPLE"
if [ ! -d "$AGENT_DIR" ]; then
    fail "$AGENT_DIR not found: ctrl-exec agent not installed?"
elif [ ! -e "$MAP" ]; then
    [ "$DRY" = 0 ] && install -m 600 "${OWNER[@]}" "$EXAMPLE" "$MAP"
    changed "installed $MAP from the example (it names nagios-checks only: add the files this host may receive)"
elif cmp -s "$EXAMPLE" "$MAP"; then
    ok "$MAP matches the shipped example"
else
    if [ -f "$MAP.new" ] && cmp -s "$EXAMPLE" "$MAP.new"; then
        :
    else
        [ "$DRY" = 0 ] && install -m 600 "${OWNER[@]}" "$EXAMPLE" "$MAP.new"
        changed "wrote $MAP.new"
    fi
    warn "kept your $MAP; the shipped one is in $MAP.new"
fi

# 4. scripts.conf: append our entry only if there is none
SC="$AGENT_DIR/scripts.conf"
WANT="$SCRIPT_DIR_HOST/agent-config-deploy.pl"
ENTRY="agent-config-deploy = $WANT profile=config-deploy input=fields"
SC_CHANGED=0
if [ ! -f "$SC" ]; then
    fail "$SC not found: ctrl-exec agent not installed?"
else
    have="$(sed -n 's/^[[:space:]]*agent-config-deploy[[:space:]]*=[[:space:]]*\([^[:space:]]*\).*/\1/p' "$SC" | head -n 1)"
    if [ "$have" = "$WANT" ]; then
        ok "scripts.conf already has agent-config-deploy = $WANT"
    elif [ -n "$have" ]; then
        warn "scripts.conf has agent-config-deploy = $have, left as is (this install is at $WANT)"
    else
        if [ "$DRY" = 0 ]; then
            [ -n "$(tail -c 1 "$SC")" ] && echo >> "$SC"
            echo "$ENTRY" >> "$SC"
        fi
        changed "added $ENTRY to $SC"
        SC_CHANGED=1
    fi
fi

# 5. agent.conf: report only
AC="$AGENT_DIR/agent.conf"
if [ -f "$AC" ] && grep -Eq '^\[profile config-deploy\]' "$AC"; then
    ok "[profile config-deploy] defined in $AC"
else
    warn "$AC has no [profile config-deploy]; add it (writable = the folders of the map's files), then restart ctrl-exec-agent: [profile config-deploy] run_as = root, writable = /etc/nagios-checks"
fi

# 6. reload the agent when scripts.conf changed
if [ "$SC_CHANGED" = 1 ] && [ "$DRY" = 0 ]; then
    if command -v systemctl > /dev/null && systemctl is-active --quiet ctrl-exec-agent; then
        if systemctl reload ctrl-exec-agent; then ok "reloaded ctrl-exec-agent"; else warn "reload failed: run systemctl reload ctrl-exec-agent"; fi
    else
        warn "ctrl-exec-agent not active here: run systemctl reload ctrl-exec-agent when it is"
    fi
fi

# 7. verify: --list reads the map the way a run does
if [ ! -f "$SCRIPT_DIR/agent-config-deploy.pl" ] || [ ! -f "$MAP" ]; then
    say skip "verify: script or map not installed yet"
else
    [ -n "$ROOT" ] && export CONFIG_DEPLOY_MAP="$MAP"  # test-only: the map is under CD_ROOT
    [ -n "${CD_ALLOW_NONROOT:-}" ] && export CONFIG_DEPLOY_ALLOW_NONROOT=1
    out="$(perl "$SCRIPT_DIR/agent-config-deploy.pl" --list 2>&1)"
    summary="$(printf '%s' "$out" | perl -MJSON::PP -e '
        my $d = eval { decode_json(do { local $/; <STDIN> }) } or do { print "unreadable: $@"; exit 1 };
        $d->{error} and do { print "error: $d->{error}"; exit 1 };
        print join(", ", map { "$_->{name} -> $_->{path} (" . ($_->{exists} ? "present" : "absent") . ")" } @{ $d->{files} });
        exit 0')"
    rc=$?
    if [ "$rc" = 0 ]; then ok "verify: $summary"; else warn "verify: $summary"; fi
fi

echo "done: $CHANGED changed, $WARNED warnings"
[ "$FAILED" = 0 ]
