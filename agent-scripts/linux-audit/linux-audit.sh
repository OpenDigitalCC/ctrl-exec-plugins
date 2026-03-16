#!/bin/bash
# linux-audit - Read-only system audit script for dispatcher agents
#
# Subcommands:
#   logins        Recent successful logins (last)
#   auth-failures Failed authentication attempts (journalctl/auth.log)
#   ports         Listening TCP/UDP ports (ss)
#   services      Running and failed systemd services
#   disk          Filesystem disk usage (df)
#   memory        Memory and swap usage (free)
#   open-files    Count of open file descriptors per process (lsof summary)
#   all           Run all subcommands in sequence
#
# Usage (on the agent host directly):
#   linux-audit.sh <subcommand>
#
# Usage (via dispatcher):
#   ced run <host> linux-audit -- <subcommand>

set -euo pipefail

# Discard stdin - this script does not use the dispatcher JSON context
exec 0</dev/null

# --- helpers -----------------------------------------------------------------

header() {
    echo ""
    echo "=== $1 ==="
}

require_cmd() {
    local cmd="$1"
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "Error: '$cmd' not found" >&2
        return 1
    fi
}

# --- subcommands -------------------------------------------------------------

cmd_logins() {
    require_cmd last
    header "Recent logins"
    last -n 20 --time-format iso | grep -v '^$' | grep -v '^wtmp'
}

cmd_auth_failures() {
    header "Failed authentication attempts (last 24h)"

    # Try journalctl first; fall back to auth.log
    if command -v journalctl >/dev/null 2>&1; then
        journalctl _SYSTEMD_UNIT=ssh.service --since "24 hours ago" --no-pager \
            --output=short-iso 2>/dev/null \
            | grep -iE "failed|invalid|error" \
            | tail -50 \
            || true
    elif [[ -r /var/log/auth.log ]]; then
        grep -iE "failed|invalid" /var/log/auth.log \
            | tail -50 \
            || true
    else
        echo "No accessible auth log source found"
    fi
}

cmd_ports() {
    require_cmd ss
    header "Listening ports"
    ss -tlunp
}

cmd_services() {
    require_cmd systemctl
    header "Failed services"
    systemctl list-units --state=failed --no-pager --no-legend || true

    header "Running services (non-kernel)"
    systemctl list-units --type=service --state=running --no-pager --no-legend \
        | grep -v '\.scope' \
        | head -40 \
        || true
}

cmd_disk() {
    header "Disk usage"
    df -h --output=source,fstype,size,used,avail,pcent,target \
        -x tmpfs -x devtmpfs -x squashfs
}

cmd_memory() {
    require_cmd free
    header "Memory and swap"
    free -h
}

cmd_open_files() {
    require_cmd lsof
    header "Open file descriptor count by process (top 20)"
    lsof -n -P 2>/dev/null \
        | awk 'NR>1 {print $1}' \
        | sort \
        | uniq -c \
        | sort -rn \
        | head -20 \
        || true
}

cmd_all() {
    cmd_logins
    cmd_auth_failures
    cmd_ports
    cmd_services
    cmd_disk
    cmd_memory
    cmd_open_files
}

# --- usage -------------------------------------------------------------------

usage() {
    cat >&2 <<EOF
Usage: linux-audit.sh <subcommand>

Subcommands:
  logins          Recent successful logins
  auth-failures   Failed authentication attempts (last 24h)
  ports           Listening TCP/UDP ports
  services        Running and failed systemd services
  disk            Filesystem disk usage
  memory          Memory and swap usage
  open-files      Open file descriptor count by process
  all             Run all subcommands in sequence

Via dispatcher:
  ced run <host> linux-audit -- logins
  ced run <host> linux-audit -- all
EOF
    exit 1
}

# --- main --------------------------------------------------------------------

main() {
    local subcommand="${1:-}"

    case "$subcommand" in
        logins)         cmd_logins ;;
        auth-failures)  cmd_auth_failures ;;
        ports)          cmd_ports ;;
        services)       cmd_services ;;
        disk)           cmd_disk ;;
        memory)         cmd_memory ;;
        open-files)     cmd_open_files ;;
        all)            cmd_all ;;
        *)              usage ;;
    esac
}

main "$@"
