#!/bin/bash
# Install the nagios-check plugin on a ctrl-exec agent host.
#
#   install.sh [--script-dir DIR] [--dry-run]
#
# Run as root from a copy of this plugin folder. --script-dir is where the
# agent script goes (default /opt/ctrl-exec-scripts; cloudient uses
# /srv/scripts). --dry-run checks everything and changes nothing.
#
# Nothing a host already has is moved or overwritten without being asked:
# an existing /etc/nagios-checks.conf is kept (the shipped one is written
# beside it as .new) and an existing scripts.conf entry is never changed.
# Only our own two scripts are replaced when they differ.
#
# Test-only environment (the test suite uses these; leave them unset):
#   NC_ROOT=DIR         prefix for /etc, /usr and the default script dir
#   NC_ALLOW_NONROOT=1  skip the root check and do not chown to root
set -uo pipefail
unset NAGIOS_CHECKS_CONF

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="${NC_ROOT:-}"
SCRIPT_DIR="$ROOT/opt/ctrl-exec-scripts"
DRY=0
while [ $# -gt 0 ]; do
    case "$1" in
        --script-dir)
            [ -n "${2:-}" ] || { echo "install.sh: --script-dir needs a directory" >&2; exit 2; }
            SCRIPT_DIR="$ROOT$2"; shift ;;
        --dry-run) DRY=1 ;;
        *) echo "usage: install.sh [--script-dir DIR] [--dry-run]" >&2; exit 2 ;;
    esac
    shift
done

PLUGINS_SYS="$ROOT/usr/lib/nagios/plugins"
PLUGINS_LOCAL="$ROOT/usr/local/lib/nagios/plugins"
CONF="$ROOT/etc/nagios-checks.conf"
AGENT_DIR="$ROOT/etc/ctrl-exec-agent"
OWNER=(-o root -g root)
[ -n "${NC_ALLOW_NONROOT:-}" ] && OWNER=()

CHANGED=0 WARNED=0 FAILED=0
say() { printf '%s %s\n' "$1" "$2"; }
ok() { say ok "$1"; }
changed() { CHANGED=$((CHANGED + 1)); if [ "$DRY" = 1 ]; then say changed "$1 (dry-run: not done)"; else say changed "$1"; fi; }
warn() { WARNED=$((WARNED + 1)); say warn "$1"; }
fail() { FAILED=$((FAILED + 1)); say FAIL "$1"; }
mode_of() { stat -c %a "$1"; }

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
if [ "$(id -u)" != 0 ] && [ -z "${NC_ALLOW_NONROOT:-}" ] && [ "$DRY" = 0 ]; then
    fail "must run as root (or use --dry-run)"
    exit 1
fi

# 2. the Nagios plugins
if compgen -G "$PLUGINS_SYS/check_*" > /dev/null; then
    ok "Nagios plugins present in $PLUGINS_SYS"
else
    warn "no check_* in $PLUGINS_SYS: install monitoring-plugins-basic"
fi

# 3, 4. our scripts
put "$HERE/nagios-check.pl" "$SCRIPT_DIR/nagios-check.pl"
put "$HERE/plugins/check_mem" "$PLUGINS_LOCAL/check_mem"

# 5. config: never overwritten
EXAMPLE="$HERE/nagios-checks.conf.example"
if [ ! -e "$CONF" ]; then
    [ "$DRY" = 0 ] && install -m 644 "${OWNER[@]}" "$EXAMPLE" "$CONF"
    changed "installed $CONF from the example (adjust the thresholds)"
elif cmp -s "$EXAMPLE" "$CONF"; then
    ok "$CONF matches the shipped example"
else
    if [ -f "$CONF.new" ] && cmp -s "$EXAMPLE" "$CONF.new"; then
        :
    else
        [ "$DRY" = 0 ] && install -m 644 "${OWNER[@]}" "$EXAMPLE" "$CONF.new"
        changed "wrote $CONF.new"
    fi
    warn "kept your $CONF; the shipped one is in $CONF.new"
fi
if [ -e "$CONF" ] && [ $(( 8#$(mode_of "$CONF") & 4 )) = 0 ]; then
    warn "$CONF is mode $(mode_of "$CONF"), the script runs unprivileged: mode set to 644 (nothing else touched)"
    [ "$DRY" = 0 ] && chmod 644 "$CONF"
fi

# 6. scripts.conf: append our entry only if there is none
SC="$AGENT_DIR/scripts.conf"
WANT="$SCRIPT_DIR/nagios-check.pl"
SC_CHANGED=0
if [ ! -f "$SC" ]; then
    fail "$SC not found: ctrl-exec agent not installed?"
else
    have="$(sed -n 's/^[[:space:]]*nagios-check[[:space:]]*=[[:space:]]*\([^[:space:]]*\).*/\1/p' "$SC" | head -n 1)"
    if [ "$have" = "$WANT" ]; then
        ok "scripts.conf already has nagios-check = $WANT"
    elif [ -n "$have" ]; then
        warn "scripts.conf has nagios-check = $have, left as is (this install is at $WANT)"
    else
        if [ "$DRY" = 0 ]; then
            [ -n "$(tail -c 1 "$SC")" ] && echo >> "$SC"
            echo "nagios-check = $WANT" >> "$SC"
        fi
        changed "added nagios-check = $WANT to $SC"
        SC_CHANGED=1
    fi
fi

# 7. agent.conf: report only
AC="$AGENT_DIR/agent.conf"
RUN_USER=root
if [ -f "$AC" ] && grep -Eq '^[[:space:]]*executor_socket[[:space:]]*=[[:space:]]*[^[:space:]#]' "$AC"; then
    if grep -Eq '^\[profile default\]' "$AC"; then
        ok "executor enabled and [profile default] defined: the check runs under it"
        RUN_USER=nobody
    else
        warn "executor enabled but $AC has no [profile default]; add: [profile default] run_as = nobody, no_new_privileges = yes"
    fi
else
    ok "executor not enabled: the check runs as the agent's own user"
fi

# 8. reload the agent when scripts.conf changed
if [ "$SC_CHANGED" = 1 ] && [ "$DRY" = 0 ]; then
    if command -v systemctl > /dev/null && systemctl is-active --quiet ctrl-exec-agent; then
        if systemctl reload ctrl-exec-agent; then ok "reloaded ctrl-exec-agent"; else warn "reload failed: run systemctl reload ctrl-exec-agent"; fi
    else
        warn "ctrl-exec-agent not active here: run systemctl reload ctrl-exec-agent when it is"
    fi
fi

# 9. verify as the user the check will run as
if [ ! -f "$WANT" ] || [ ! -f "$CONF" ]; then
    say skip "verify: script or config not installed yet"
else
    runner=()
    if [ "$RUN_USER" != root ] && { [ "$(id -u)" = 0 ] || [ -n "${NC_ALLOW_NONROOT:-}" ]; }; then
        if command -v runuser > /dev/null; then runner=(runuser -u "$RUN_USER" --)
        elif command -v setpriv > /dev/null; then runner=(setpriv --reuid "$RUN_USER" --regid "$RUN_USER" --clear-groups --)
        fi
    fi
    [ ${#runner[@]} = 0 ] && RUN_USER="$(id -un)"
    [ -n "$ROOT" ] && export NAGIOS_CHECKS_CONF="$CONF"  # test-only: the config is under NC_ROOT
    out="$("${runner[@]}" perl "$WANT" --list 2>&1)"
    summary="$(printf '%s' "$out" | perl -MJSON::PP -e '
        my $d = eval { decode_json(do { local $/; <STDIN> }) } or do { print "unreadable: $@"; exit 1 };
        $d->{error} and do { print "error: $d->{error}"; exit 1 };
        my $bad = 0;
        print join(", ", map { $_->{available} ? "$_->{name} ok" : do { $bad++; "$_->{name} MISSING ($_->{reason})" } } @{ $d->{checks} });
        exit($bad ? 1 : 0)')"
    rc=$?
    if [ "$rc" = 0 ]; then ok "verify as $RUN_USER: $summary"; else warn "verify as $RUN_USER: $summary"; fi
fi

echo "done: $CHANGED changed, $WARNED warnings"
[ "$FAILED" = 0 ]
