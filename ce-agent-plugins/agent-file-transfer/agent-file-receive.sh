#!/bin/bash
# agent-file-receive - Receive a file archive from a dispatcher or another agent
#
# Lightweight TLS receiver. Generates a throwaway self-signed cert, prints the
# cert fingerprint to stdout (returned to the caller via ctrl-exec), then
# listens for one inbound TLS connection and writes the received data to the
# output path. Verifies the archive on completion.
#
# On failure or timeout the output file is renamed to <file>.failed.<epoch>.
# The throwaway cert is deleted on exit regardless of outcome.
#
# Arguments:
#   --port <n>         TCP port to listen on (required)
#   --output <file>    Output path for received archive (required)
#   --timeout <n>      Seconds to wait for connection and transfer (default: 300)
#
# Stdout (consumed by coordinator):
#   fingerprint:<hex>   SHA-256 fingerprint of the throwaway cert
#   received:<bytes>    Size of received file on success
#
# Exit codes:
#   0   File received and verified
#   1   Transfer or verification error
#   2   Argument or dependency error
#
# Usage via ctrl-exec (coordinator dispatches this):
#   ced run <agent> agent-file-receive -- \
#     --port 9000 \
#     --output /tmp/received.tar.gz

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

require_cmd openssl openssl
require_cmd tar     tar
require_cmd ss      iproute2

HAS_PV=0
command -v pv >/dev/null 2>&1 && HAS_PV=1

# ---------------------------------------------------------------------------
# Arguments
# ---------------------------------------------------------------------------

usage() {
    cat >&2 <<EOF
Usage: agent-file-receive.sh --port <n> --output <file> [--timeout <seconds>]

  --port <n>        TCP port to listen on (required)
  --output <file>   Output file path (required)
  --timeout <n>     Seconds to wait for connection and transfer (default: 300)
EOF
    exit 2
}

PORT=''
OUTPUT=''
TIMEOUT=300

while [[ $# -gt 0 ]]; do
    case "$1" in
        --port)    PORT="${2:-}"; shift 2 ;;
        --output)  OUTPUT="${2:-}"; shift 2 ;;
        --timeout) TIMEOUT="${2:-}"; shift 2 ;;
        *) echo "Error: Unknown argument: $1" >&2; usage ;;
    esac
done

[[ -n "$PORT" ]]   || { echo "Error: --port is required" >&2; usage; }
[[ -n "$OUTPUT" ]] || { echo "Error: --output is required" >&2; usage; }
[[ "$PORT" =~ ^[0-9]+$ ]]    || { echo "Error: --port must be numeric" >&2; exit 2; }
[[ "$TIMEOUT" =~ ^[0-9]+$ ]] || { echo "Error: --timeout must be numeric" >&2; exit 2; }

# ---------------------------------------------------------------------------
# Preflight: check port is not already in use
# ---------------------------------------------------------------------------

if ss -tlnH "sport = :${PORT}" 2>/dev/null | grep -q .; then
    echo "Error: Port $PORT is already in use" >&2
    exit 2
fi

# ---------------------------------------------------------------------------
# Temp cert with guaranteed cleanup
# ---------------------------------------------------------------------------

TMPDIR_CERT=$(mktemp -d)
CERT="$TMPDIR_CERT/recv.crt"
KEY="$TMPDIR_CERT/recv.key"

TRANSFER_OK=0

cleanup() {
    rm -rf "$TMPDIR_CERT"
    if [[ $TRANSFER_OK -eq 0 && -f "$OUTPUT" ]]; then
        FAILED="${OUTPUT}.failed.$(date +%s)"
        mv "$OUTPUT" "$FAILED"
        echo "Transfer failed - partial output saved to: $FAILED" >&2
    fi
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Generate throwaway self-signed cert
# ---------------------------------------------------------------------------

openssl req -x509 -newkey rsa:2048 -keyout "$KEY" -out "$CERT" \
    -days 1 -nodes -subj "/CN=agent-file-receive" \
    2>/dev/null

FINGERPRINT=$(openssl x509 -fingerprint -sha256 -noout -in "$CERT" \
    | sed 's/.*Fingerprint=//' | tr -d ':' | tr '[:lower:]' '[:upper:]')

# Print fingerprint to stdout - returned to coordinator via ctrl-exec
echo "fingerprint:${FINGERPRINT}"

# ---------------------------------------------------------------------------
# Receive
# ---------------------------------------------------------------------------

OUTPUT_DIR="$(dirname "$OUTPUT")"
[[ -d "$OUTPUT_DIR" ]] || mkdir -p "$OUTPUT_DIR"

if [[ $HAS_PV -eq 1 ]]; then
    timeout "$TIMEOUT" openssl s_server \
        -cert "$CERT" -key "$KEY" \
        -port "$PORT" \
        -quiet \
        2>/dev/null \
        | pv -b > "$OUTPUT"
else
    timeout "$TIMEOUT" openssl s_server \
        -cert "$CERT" -key "$KEY" \
        -port "$PORT" \
        -quiet \
        2>/dev/null \
        > "$OUTPUT"
fi

# ---------------------------------------------------------------------------
# Verify
# ---------------------------------------------------------------------------

if ! tar -tzf "$OUTPUT" >/dev/null 2>&1; then
    echo "Error: Received file failed archive verification" >&2
    exit 1
fi

RECEIVED_SIZE=$(stat -c '%s' "$OUTPUT")
TRANSFER_OK=1
echo "received:${RECEIVED_SIZE}"
