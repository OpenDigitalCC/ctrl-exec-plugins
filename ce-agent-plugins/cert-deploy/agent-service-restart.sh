#!/usr/bin/env bash
# agent-service-restart.sh
# ctrl-exec agent script - restarts docker compose services so that
# newly deployed certificates are picked up.
# Called by deploy-cert.sh via ctrl-exec-cli run after a successful deploy.
#
# Arguments:
#   $1   compose-file   absolute path to the compose file; several files
#                        are separated by ':', as in COMPOSE_FILE, and passed
#                        in order (e.g. /srv/app/compose.yml:/srv/app/extra.yml)
#   $2.. service         optional service names to restart; if none given,
#                        the whole stack is restarted
#
# Runs: docker compose -f <file> [-f <file> ...] restart [service ...]
#
# Test mode: agent-service-restart --test <compose-file> [service ...]
#   Restarts nothing. Checks the same arguments, that the docker daemon is
#   reachable, that the compose file parses and names the services, that
#   each service has a container to restart, and runs the restart with
#   docker compose --dry-run. Run it through ctrl-exec, so it runs as the
#   profile's user. Exits 0 when every check passes, 1 otherwise.
#
# Privilege: requires a profile whose run_as user is a member of the
# 'docker' group (Docker socket access). No sudo is used - the executor
# applies the profile. See [profile svc-restart] in agent.conf.
#
# Scope, by design: any compose stack on this host can be restarted. The
# script does not limit which compose file it is given. Control sits with
# ctrl-exec - who may run this script is decided by the dispatcher's auth
# hook and the agent's allowlist, and the agent's optional auth_hook sees the
# arguments if a host needs to narrow it. A dispatcher allowed to run this
# script is already trusted with far more than restarting a container.

set -euo pipefail

mode=restart
if [[ "${1:-}" == "--test" ]]; then
    mode="test"
    shift
fi

compose_file="${1:-}"
shift || true
services=("$@")

if [[ -z "$compose_file" ]]; then
    echo "Usage: agent-service-restart [--test] <compose-file> [service ...]" >&2
    exit 1
fi

# One or more compose files, ':'-separated, each passed with its own -f
IFS=: read -r -a compose_files <<< "$compose_file"
compose_args=()
for f in "${compose_files[@]}"; do
    if [[ "$f" != /* ]]; then
        echo "Error: compose-file must be an absolute path: '$f'" >&2
        exit 1
    fi
    if [[ "$f" == *..* ]]; then
        echo "Error: compose-file must not contain '..': '$f'" >&2
        exit 1
    fi
    if [[ ! -f "$f" ]]; then
        echo "Error: compose-file not found: '$f'" >&2
        exit 1
    fi
    compose_args+=(-f "$f")
done

# Service names only - anything starting with '-' would be read as an option
for s in "${services[@]}"; do
    if [[ ! "$s" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]]; then
        echo "Error: invalid service name '$s'" >&2
        exit 1
    fi
done

# Test mode: report what a restart would do, change nothing
run_test() {
    local fails=0 server s out
    local -a defined=() existing=() running=() targets=()
    ok()   { echo "ok    $*"; }
    fail() { echo "FAIL  $*"; fails=$(( fails + 1 )); }

    echo "test mode - nothing is restarted"
    echo "user:  $(id -un) (groups: $(id -Gn))"
    echo "file:  $compose_file"

    if ! command -v docker > /dev/null 2>&1; then
        fail "docker not found in PATH"
        return 1
    fi
    if server=$(docker version --format '{{.Server.Version}}' 2>&1); then
        ok "docker daemon reachable (server $server)"
    else
        fail "cannot reach the docker daemon - is $(id -un) in the docker group? ($server)"
        return 1
    fi

    if ! out=$(docker compose "${compose_args[@]}" config --services 2>&1); then
        fail "compose file does not parse: $out"
        return 1
    fi
    mapfile -t defined <<< "$out"
    ok "compose file parses (services: ${defined[*]})"

    mapfile -t existing < <(docker compose "${compose_args[@]}" ps --all --services 2>/dev/null)
    mapfile -t running  < <(docker compose "${compose_args[@]}" ps --services --status running 2>/dev/null)

    if (( ${#services[@]} )); then
        targets=("${services[@]}")
    else
        targets=("${defined[@]}")
    fi
    for s in "${targets[@]}"; do
        if [[ " ${defined[*]} " != *" $s "* ]]; then
            fail "service '$s' is not defined in the compose file"
        elif [[ " ${running[*]} " == *" $s "* ]]; then
            ok "service '$s' is running"
        elif [[ " ${existing[*]} " == *" $s "* ]]; then
            ok "service '$s' is stopped - a restart would start it"
        else
            fail "service '$s' has no container - a restart would do nothing"
        fi
    done

    # docker compose --dry-run runs the restart without touching containers
    if docker compose --dry-run version > /dev/null 2>&1; then
        if out=$(docker compose --dry-run "${compose_args[@]}" restart "${services[@]}" 2>&1); then
            ok "dry-run restart succeeded"
            if [[ -n "$out" ]]; then
                printf '      %s\n' "${out//$'\n'/$'\n'      }"
            fi
        else
            fail "dry-run restart failed: $out"
        fi
    else
        echo "skip  dry-run restart (needs docker compose v2.17 or later)"
    fi

    echo
    if (( fails )); then
        echo "$fails check(s) failed"
        return 1
    fi
    echo "all checks passed - a restart would work"
}

if [[ "$mode" == test ]]; then
    rc=0
    run_test || rc=$?
    exit "$rc"
fi

if [[ ${#services[@]} -gt 0 ]]; then
    echo "restarting: ${services[*]} in $compose_file"
    docker compose "${compose_args[@]}" restart "${services[@]}"
    echo "restarted: ${services[*]} at $(date --iso-8601=seconds)"
else
    echo "restarting: all services in $compose_file"
    docker compose "${compose_args[@]}" restart
    echo "restarted: all services at $(date --iso-8601=seconds)"
fi
