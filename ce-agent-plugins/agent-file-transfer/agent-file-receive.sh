#!/bin/bash
# agent-file-receive - Receive a file archive from a dispatcher or another agent
#
# Lightweight TLS receiver. Generates a throwaway self-signed cert, starts a
# detached listener for one inbound TLS transfer, prints the cert fingerprint
# and a transfer id to stdout (returned to the caller via ctrl-exec) and exits
# 0 at once. The listener carries on in its own session with every standard
# stream detached, so the ctrl-exec run is not held open while it waits for the
# sender. The caller learns the outcome with the --status call.
#
# The listener keeps its own --timeout. It writes the data to the output path,
# verifies the archive on completion, records the result in a status file
# beside the output, and deletes its throwaway cert itself. On failure or
# timeout the output file is renamed to <file>.failed.<epoch>.
#
# Receive (default mode):
#   --port <n>         TCP port to listen on (required)
#   --output <file>    Output path for received archive (required)
#   --timeout <n>      Seconds to wait for connection and transfer (default: 300)
#
# Status:
#   --status <id>      Report the transfer <id> started earlier (as printed by
#                      the receive call). --output must be the same path as for
#                      the receive call: the status file lives in its directory.
#
# Stdout of a receive call (consumed by coordinator):
#   fingerprint:<hex>   SHA-256 fingerprint of the throwaway cert
#   id:<hex>            Transfer id to pass to --status
#
# Stdout of a --status call:
#   pending                 Listener running, transfer not finished
#   received:<bytes>        Archive received and verified (size on disk)
#   sha256:<hex>            SHA-256 of the received file (follows received:)
#   failed:<reason>         Transfer or verification error (exit 1)
#   timedout:<reason>       No complete transfer within --timeout (exit 1)
#
# Exit codes:
#   0   Receive: listener started. Status: pending or received.
#   1   Receive: could not start the listener. Status: failed, timed out,
#       or unknown transfer.
#   2   Argument or dependency error
#
# The output directory must be writable by the run_as user: it holds the
# output, the status file and any .failed file. Under a profile with a
# `writable` list, that directory must be on the list.
#
# Usage via ctrl-exec (coordinator dispatches this):
#   ced run <agent> agent-file-receive -- \
#     --port 9000 --output /var/backups/in.tar.gz
#   ced run <agent> agent-file-receive -- \
#     --status <id> --output /var/backups/in.tar.gz

set -euo pipefail

# Discard stdin - context not needed
exec 0</dev/null

# ---------------------------------------------------------------------------
# Dependencies
# ---------------------------------------------------------------------------

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || {
        echo "Error: '$1' not found - install $2" >&2
        exit 2
    }
}

require_cmd openssl   openssl
require_cmd tar       tar
require_cmd ss        iproute2
require_cmd setsid    util-linux
require_cmd sha256sum coreutils

# ---------------------------------------------------------------------------
# Arguments
# ---------------------------------------------------------------------------

usage() {
    cat >&2 <<EOF
Usage: agent-file-receive.sh --port <n> --output <file> [--timeout <seconds>]
       agent-file-receive.sh --status <id> --output <file>

  --port <n>        TCP port to listen on (required to receive)
  --output <file>   Output file path (required)
  --timeout <n>     Seconds to wait for connection and transfer (default: 300)
  --status <id>     Report the transfer <id> started by an earlier receive call
EOF
    exit 2
}

PORT=''
OUTPUT=''
TIMEOUT=300
STATUS_ID=''

while [[ $# -gt 0 ]]; do
    case "$1" in
        --port)    PORT="${2:-}"; shift 2 ;;
        --output)  OUTPUT="${2:-}"; shift 2 ;;
        --timeout) TIMEOUT="${2:-}"; shift 2 ;;
        --status)  STATUS_ID="${2:-}"; shift 2 ;;
        *) echo "Error: Unknown argument: $1" >&2; usage ;;
    esac
done

[[ -n "$OUTPUT" ]] || { echo "Error: --output is required" >&2; usage; }
[[ "$TIMEOUT" =~ ^[0-9]+$ ]] || { echo "Error: --timeout must be numeric" >&2; exit 2; }

OUTPUT_DIR="$(dirname "$OUTPUT")"

status_path() { echo "${OUTPUT_DIR}/.agent-file-receive.$1.status"; }

# Write the status file atomically: state=<state> plus any extra key=value
# lines. Returns non-zero when the directory cannot be written.
write_status() {
    local file="$1"; shift
    local tmp="${file}.tmp.$$"
    { echo "state=$1"; shift; for kv in "$@"; do echo "$kv"; done; } > "$tmp" \
        && mv -f "$tmp" "$file"
}

# ---------------------------------------------------------------------------
# --status: read the status file and report
# ---------------------------------------------------------------------------

if [[ -n "$STATUS_ID" ]]; then
    [[ "$STATUS_ID" =~ ^[0-9a-f]{8,64}$ ]] \
        || { echo "Error: --status id must be a hex transfer id" >&2; exit 2; }
    SFILE="$(status_path "$STATUS_ID")"
    [[ -f "$SFILE" ]] || {
        echo "Error: unknown transfer $STATUS_ID (no status file in $OUTPUT_DIR)" >&2
        exit 1
    }
    s_state=''; s_bytes=''; s_sha=''; s_reason=''
    while IFS='=' read -r k v; do
        case "$k" in
            state)  s_state="$v" ;;
            bytes)  s_bytes="$v" ;;
            sha256) s_sha="$v" ;;
            reason) s_reason="$v" ;;
        esac
    done < "$SFILE"
    case "$s_state" in
        pending)  echo "pending" ;;
        received) echo "received:${s_bytes}"; echo "sha256:${s_sha}" ;;
        failed)   echo "failed:${s_reason}"; exit 1 ;;
        timedout) echo "timedout:${s_reason}"; exit 1 ;;
        *) echo "Error: unreadable status file for $STATUS_ID" >&2; exit 1 ;;
    esac
    exit 0
fi

# ---------------------------------------------------------------------------
# Receive: argument checks
# ---------------------------------------------------------------------------

[[ -n "$PORT" ]] || { echo "Error: --port is required" >&2; usage; }
[[ "$PORT" =~ ^[0-9]+$ ]] || { echo "Error: --port must be numeric" >&2; exit 2; }

# ---------------------------------------------------------------------------
# Listener (second stage, started detached by the receive call below)
# ---------------------------------------------------------------------------

run_listener() {
    local certdir="$AGENT_FILE_RECEIVE_LISTENER_DIR"
    local id="$AGENT_FILE_RECEIVE_ID"
    local sfile; sfile="$(status_path "$id")"
    local srv='' finished=0

    # finish <state> [key=value ...]: stop the server, remove the cert, set
    # aside or remove a failed output, and only then publish the final status,
    # so a caller that sees the status can rely on the clean-up being done.
    finish() {
        local state="$1"; shift
        finished=1
        if [[ -n "$srv" ]]; then
            kill "$srv" 2>/dev/null || true
            wait "$srv" 2>/dev/null || true
            srv=''
        fi
        rm -rf "$certdir"
        if [[ "$state" != received ]]; then
            if [[ -s "$OUTPUT" ]]; then
                mv "$OUTPUT" "${OUTPUT}.failed.$(date +%s)" 2>/dev/null || true
            else
                rm -f "$OUTPUT"
            fi
        fi
        write_status "$sfile" "$state" "$@" || true
    }
    # Never leave a transfer pending once the listener is gone.
    trap '[[ $finished -eq 1 ]] || finish failed "reason=listener exited unexpectedly"' EXIT
    trap 'exit 1' TERM HUP INT

    # The server reads stdin; at EOF it drops the connection without reading
    # the data. Hold a FIFO open read-write so stdin never reaches EOF.
    mkfifo "$certdir/in"
    exec 3<>"$certdir/in"

    openssl s_server -cert "$certdir/recv.crt" -key "$certdir/recv.key" \
        -port "$PORT" -quiet <&3 2>/dev/null >"$OUTPUT" &
    srv=$!

    # Any connection on the port that is not finished (a sender that has
    # closed its side leaves ours in CLOSE_WAIT while data is still unread).
    conn_open() {
        ss -tnH "sport = :${PORT}" 2>/dev/null | awk '$1 != "TIME-WAIT"' | grep -q .
    }

    # Wait for a transfer: data on disk and no connection still open on the
    # port. A connection that delivers nothing (a fingerprint probe) is not a
    # transfer, and the server keeps serving after it.
    local deadline=$((SECONDS + TIMEOUT)) size last=-1
    while :; do
        if ! kill -0 "$srv" 2>/dev/null; then
            finish failed "reason=listener could not serve on port ${PORT}"
            return 1
        fi
        size=$(stat -c '%s' "$OUTPUT" 2>/dev/null || echo 0)
        if [[ "$size" -gt 0 && "$size" -eq "$last" ]] && ! conn_open; then
            break
        fi
        last="$size"
        if (( SECONDS >= deadline )); then
            finish timedout "reason=no complete transfer within ${TIMEOUT}s"
            return 1
        fi
        sleep 0.2
    done

    kill "$srv" 2>/dev/null || true
    wait "$srv" 2>/dev/null || true
    srv=''

    if ! tar -tzf "$OUTPUT" >/dev/null 2>&1; then
        finish failed "reason=received file failed archive verification"
        return 1
    fi

    local bytes sha
    bytes=$(stat -c '%s' "$OUTPUT")
    sha=$(sha256sum "$OUTPUT" | cut -d' ' -f1)
    finish received "bytes=${bytes}" "sha256=${sha}"
}

if [[ -n "${AGENT_FILE_RECEIVE_LISTENER_DIR:-}" ]]; then
    [[ -f "${AGENT_FILE_RECEIVE_LISTENER_DIR}/recv.crt" && -n "${AGENT_FILE_RECEIVE_ID:-}" ]] \
        || exit 2
    run_listener
    exit $?
fi

# ---------------------------------------------------------------------------
# Preflight: check port is not already in use
# ---------------------------------------------------------------------------

if ss -tlnH "sport = :${PORT}" 2>/dev/null | grep -q .; then
    echo "Error: Port $PORT is already in use" >&2
    exit 2
fi

[[ -d "$OUTPUT_DIR" ]] || mkdir -p "$OUTPUT_DIR"

# Drop status files left by transfers more than a day old.
find "$OUTPUT_DIR" -maxdepth 1 -name '.agent-file-receive.*.status' \
    -mtime +1 -delete 2>/dev/null || true

# ---------------------------------------------------------------------------
# Throwaway cert and status file. Until the listener is running, this call
# owns the cert directory and removes it on any failure; afterwards the
# listener owns it.
# ---------------------------------------------------------------------------

TMPDIR_CERT=$(mktemp -d)
CERT="$TMPDIR_CERT/recv.crt"
KEY="$TMPDIR_CERT/recv.key"
HANDED_OVER=0
trap '[[ $HANDED_OVER -eq 1 ]] || rm -rf "$TMPDIR_CERT"' EXIT

openssl req -x509 -newkey rsa:2048 -keyout "$KEY" -out "$CERT" \
    -days 1 -nodes -subj "/CN=agent-file-receive" \
    2>/dev/null

FINGERPRINT=$(openssl x509 -fingerprint -sha256 -noout -in "$CERT" \
    | sed 's/.*Fingerprint=//' | tr -d ':' | tr '[:lower:]' '[:upper:]')

ID=$(openssl rand -hex 8)
SFILE="$(status_path "$ID")"

write_status "$SFILE" pending 2>/dev/null || {
    echo "Error: cannot write the status file in $OUTPUT_DIR - the output directory must be writable (profile 'writable' list)" >&2
    exit 1
}

# ---------------------------------------------------------------------------
# Detach the listener: own session, every standard stream off the run
# ---------------------------------------------------------------------------

AGENT_FILE_RECEIVE_LISTENER_DIR="$TMPDIR_CERT" AGENT_FILE_RECEIVE_ID="$ID" \
    setsid "$BASH" "$0" --port "$PORT" --output "$OUTPUT" --timeout "$TIMEOUT" \
    </dev/null >/dev/null 2>&1 &
disown
HANDED_OVER=1

# Return only once the listener is accepting (or has failed), so the sender
# never meets a closed port after reading the fingerprint.
for _ in $(seq 1 100); do
    if ss -tlnH "sport = :${PORT}" 2>/dev/null | grep -q .; then
        echo "fingerprint:${FINGERPRINT}"
        echo "id:${ID}"
        exit 0
    fi
    grep -q '^state=pending' "$SFILE" 2>/dev/null || break
    sleep 0.05
done

reason=$(sed -n 's/^reason=//p' "$SFILE" 2>/dev/null || true)
echo "Error: listener did not start on port $PORT${reason:+ ($reason)}" >&2
exit 1
