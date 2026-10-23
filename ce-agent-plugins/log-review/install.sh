#!/bin/bash
# Install the log-review plugin on a ctrl-exec agent host.
#
#   install.sh [--script-dir DIR] [--dry-run]
#
# Run as root from a copy of this plugin folder. --script-dir is where the
# agent script goes (default /opt/ctrl-exec-scripts; cloudient uses
# /srv/scripts). --dry-run checks everything and changes nothing.
#
# Nothing a host already has is overwritten without being asked: an existing
# /etc/log-review/sources.conf is kept (the shipped example is written beside
# it as .new) and an existing scripts.conf entry is never changed. Only our
# own script is replaced when it differs. agent.conf is never edited: a missing
# [profile log-review] is reported with the snippet to add.
#
# Test-only environment (the test suite uses these; leave them unset):
#   LR_ROOT=DIR         prefix for /etc, /usr and the default script dir
#   LR_ALLOW_NONROOT=1  skip the root check and do not chown to root
set -uo pipefail
unset LOG_REVIEW_CONF

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="${LR_ROOT:-}"
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

CONF_DIR="$ROOT/etc/log-review"
CONF="$CONF_DIR/sources.conf"
AGENT_DIR="$ROOT/etc/ctrl-exec-agent"
OWNER=(-o root -g root)
[ -n "${LR_ALLOW_NONROOT:-}" ] && OWNER=()

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
if [ "$(id -u)" != 0 ] && [ -z "${LR_ALLOW_NONROOT:-}" ] && [ "$DRY" = 0 ]; then
    fail "must run as root (or use --dry-run)"
    exit 1
fi

# 1b. script_dirs: an agent.conf that limits where scripts may live refuses
#     ours anywhere else, so stop before changing anything
SCRIPT_DIR_HOST="${SCRIPT_DIR#"$ROOT"}"
SD="$(sed -n 's/^[[:space:]]*script_dirs[[:space:]]*=[[:space:]]*\([^#[:space:]]*\).*/\1/p' "$AGENT_DIR/agent.conf" 2> /dev/null | tail -n 1)"
if [ -n "$SD" ]; then
    inside=0
    IFS=: read -r -a sd_list <<< "$SD"
    for d in "${sd_list[@]}"; do
        d="${d%/}"
        case "$SCRIPT_DIR_HOST/" in "$d"/*) inside=1 ;; esac
    done
    if [ "$inside" = 1 ]; then
        ok "$SCRIPT_DIR_HOST is under script_dirs ($SD)"
    else
        fail "$SCRIPT_DIR_HOST is not under agent.conf script_dirs ($SD): the agent would refuse the script there; run again with --script-dir set to one of those folders"
        echo "done: $CHANGED changed, $WARNED warnings"
        exit 1
    fi
fi

# 2. our script
put "$HERE/log-review.pl" "$SCRIPT_DIR/log-review.pl"

# 3. config: never overwritten. The folder is made if missing (root 755).
EXAMPLE="$HERE/sources.conf.example"
if [ ! -d "$CONF_DIR" ]; then
    [ "$DRY" = 0 ] && install -d -m 755 "${OWNER[@]}" "$CONF_DIR"
    changed "created $CONF_DIR"
elif [ $(( 8#$(mode_of "$CONF_DIR") & 5 )) != 5 ]; then
    warn "$CONF_DIR is mode $(mode_of "$CONF_DIR"), the script runs unprivileged and must be able to enter it (left as it is)"
fi
if [ ! -e "$CONF" ]; then
    [ "$DRY" = 0 ] && install -m 644 "${OWNER[@]}" "$EXAMPLE" "$CONF"
    changed "installed $CONF from the example (adjust the sources)"
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

# 4. scripts.conf: append our entry only if there is none
SC="$AGENT_DIR/scripts.conf"
WANT="$SCRIPT_DIR/log-review.pl"
SC_CHANGED=0
if [ ! -f "$SC" ]; then
    fail "$SC not found: ctrl-exec agent not installed?"
else
    line="$(grep -E '^[[:space:]]*log-review[[:space:]]*=' "$SC" | head -n 1)"
    have="$(printf '%s\n' "$line" | sed -n 's/^[[:space:]]*log-review[[:space:]]*=[[:space:]]*\([^[:space:]]*\).*/\1/p')"
    if [ "$have" = "$WANT" ]; then
        ok "scripts.conf already has log-review = $WANT"
        case "$line" in
            *profile=log-review*) ;;
            *) warn "the scripts.conf entry has no profile=log-review: the script would run as the agent's default and may not read the logs" ;;
        esac
    elif [ -n "$have" ]; then
        warn "scripts.conf has log-review = $have, left as is (this install is at $WANT)"
    else
        if [ "$DRY" = 0 ]; then
            [ -n "$(tail -c 1 "$SC")" ] && echo >> "$SC"
            echo "log-review = $WANT profile=log-review" >> "$SC"
        fi
        changed "added log-review = $WANT profile=log-review to $SC"
        SC_CHANGED=1
    fi
fi

# 5. agent.conf: report only
AC="$AGENT_DIR/agent.conf"
RUN_USER=root
if [ -f "$AC" ] && grep -Eq '^\[profile log-review\]' "$AC"; then
    ok "[profile log-review] defined in $AC"
    ru="$(sed -n '/^\[profile log-review\]/,/^\[/{s/^[[:space:]]*run_as[[:space:]]*=[[:space:]]*\([^#[:space:]]*\).*/\1/p}' "$AC" | head -n 1)"
    [ -n "$ru" ] && RUN_USER="$ru"
else
    warn "$AC has no [profile log-review]; add: [profile log-review], run_as = <a user in groups adm and systemd-journal, e.g. ce-logs>, no_new_privileges = yes (and restart ctrl-exec-agent)"
fi

# 6. reload the agent when scripts.conf changed
if [ "$SC_CHANGED" = 1 ] && [ "$DRY" = 0 ]; then
    if command -v systemctl > /dev/null && systemctl is-active --quiet ctrl-exec-agent; then
        if systemctl reload ctrl-exec-agent; then ok "reloaded ctrl-exec-agent"; else warn "reload failed: run systemctl reload ctrl-exec-agent"; fi
    else
        warn "ctrl-exec-agent not active here: run systemctl reload ctrl-exec-agent when it is"
    fi
fi

# 7. verify as the user the script will run as
if [ ! -f "$SCRIPT_DIR/log-review.pl" ] || [ ! -f "$CONF" ]; then
    say skip "verify: script or config not installed yet"
else
    runner=()
    if [ "$RUN_USER" != root ] && { [ "$(id -u)" = 0 ] || [ -n "${LR_ALLOW_NONROOT:-}" ]; }; then
        if command -v runuser > /dev/null; then runner=(runuser -u "$RUN_USER" --)
        elif command -v setpriv > /dev/null; then runner=(setpriv --reuid "$RUN_USER" --regid "$RUN_USER" --clear-groups --)
        fi
    fi
    [ ${#runner[@]} = 0 ] && RUN_USER="$(id -un)"
    [ -n "$ROOT" ] && export LOG_REVIEW_CONF="$CONF"  # test-only: the config is under LR_ROOT
    out="$("${runner[@]}" perl "$SCRIPT_DIR/log-review.pl" --list 2>&1)"
    summary="$(printf '%s' "$out" | perl -MJSON::PP -e '
        my $d = eval { decode_json(do { local $/; <STDIN> }) } or do { print "unreadable: $@"; exit 1 };
        $d->{error} and do { print "error: $d->{error}"; exit 1 };
        my $bad = 0;
        print join(", ", map { $_->{readable} ? "$_->{name} ok" : do { $bad++; "$_->{name} NOT READABLE ($_->{reason})" } } @{ $d->{sources} });
        exit($bad ? 1 : 0)')"
    rc=$?
    if [ "$rc" = 0 ]; then ok "verify as $RUN_USER: $summary"; else warn "verify as $RUN_USER: $summary"; fi
fi

echo "done: $CHANGED changed, $WARNED warnings"
[ "$FAILED" = 0 ]
