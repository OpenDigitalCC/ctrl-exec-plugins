#!/usr/bin/env bash
# deploy-cert.sh
# Issues SSL certificates via a Hestia ctrl-exec agent, deploys the resulting
# cert, key, and CA to destination agents, then restarts the services that
# use them.
#
# Usage: deploy-cert.sh [cert-name]
#   cert-name  optional - process only this certificate from the config
#
# conf keys:
#   schedule    = <cron expression>
#   agent       = <hestia agent hostname>
#   certificate = <domain> [wildcard]
#   target      = <name> <dest-agent> <target-dir> <group|-> [named|pem]
#   deploy      = <domain> <target-name>
#   restart     = <target-name> <compose-file> [service ...]
#   verify      = <target-name> <name> <[address:]port> [starttls-protocol]
#
# target= names one destination: an agent, a folder on it, the group for the
# files and the file layout agent-cert-deploy writes - named (default:
# <domain>.crt/.key/.ca/.fullchain.crt) or pem (fullchain.pem + privkey.pem,
# for services that expect those names in a folder of their own). An agent
# can have several targets. deploy= may repeat, one line per domain and target.
# restart= runs once per run, on the target's agent, when that target
# received at least one successful deploy in the run, after all deploys.
# verify= is optional: after the restarts, when that target received a
# certificate covering <name> in this run (the domain itself, or one label
# under it for a wildcard), agent-cert-check on the target's agent connects to
# <port> (on localhost, or <address>:<port>), asks for <name> and confirms it
# serves
# the certificate just issued (same fingerprint, name covered, chain
# verifies, not near expiry). It retries while the service comes back up.
#
# Exits 1 if any issue, deploy, restart or verify failed, so the run-jobs
# state records it; details are in syslog. A verify WARNING (expiry within
# the check's warning days) is logged but does not fail the run.
#
# Environment overrides:
#   CE_AGENT_SCRIPT    agent script on Hestia (default: ctrl-exec-hestia)
#   CE_DEPLOY_SCRIPT   agent script on destination hosts (default: agent-cert-deploy)
#   CE_RESTART_SCRIPT  agent script for restarts (default: agent-service-restart)
#   CE_CHECK_SCRIPT    agent script for verify (default: agent-cert-check)
#   VERIFY_TRIES       verify attempts before giving up (default: 4)
#   VERIFY_WAIT        seconds between verify attempts (default: 20); kept wide
#                      so retries stay under the agent's connection rate limit
#                      (10 per 60 s per caller by default, then a 5-minute block)
#   CERT_OUTPUT_DIR    local JSON output dir (default: /tmp/ssl-renewal)

set -euo pipefail

# Issue responses carry the private key
umask 077

SYSLOG_TAG="run-jobs.deploy-cert"
CERT_OUTPUT_DIR="${CERT_OUTPUT_DIR:-/tmp/ssl-renewal}"
CE_AGENT_SCRIPT="${CE_AGENT_SCRIPT:-ctrl-exec-hestia}"
CE_DEPLOY_SCRIPT="${CE_DEPLOY_SCRIPT:-agent-cert-deploy}"
CE_RESTART_SCRIPT="${CE_RESTART_SCRIPT:-agent-service-restart}"
CE_CHECK_SCRIPT="${CE_CHECK_SCRIPT:-agent-cert-check}"
VERIFY_TRIES="${VERIFY_TRIES:-4}"
VERIFY_WAIT="${VERIFY_WAIT:-20}"
CONF_FILE="$(dirname "$0")/deploy-cert.conf"

FILTER="${1:-}"

log_info()  { logger -t "$SYSLOG_TAG" -p local0.info "$1"; }
log_error() { logger -t "$SYSLOG_TAG" -p local0.err  "$1"; }

# Check ctrl-exec-cli is available
if ! command -v ctrl-exec-cli > /dev/null 2>&1; then
    log_error "ctrl-exec-cli not found in PATH"
    exit 1
fi

# Read config
agent=""
declare -a certificates=()
declare -a targets=()
declare -a deploys=()
declare -a restarts=()
declare -a verifies=()

while IFS='=' read -r key value; do
    key="${key// /}"
    value="${value# }"
    [[ "$key" =~ ^# ]] && continue
    [[ -z "$key" ]] && continue
    case "$key" in
        agent)       agent="$value" ;;
        certificate) certificates+=("$value") ;;
        target)      targets+=("$value") ;;
        deploy)      deploys+=("$value") ;;
        restart)     restarts+=("$value") ;;
        verify)      verifies+=("$value") ;;
    esac
done < "$CONF_FILE"

if [[ -z "$agent" ]]; then
    log_error "no agent defined in $CONF_FILE"
    exit 1
fi

if [[ ${#certificates[@]} -eq 0 ]]; then
    log_error "no certificates defined in $CONF_FILE"
    exit 1
fi

# Named destinations, checked before anything is issued
declare -A target_agent_for=()
declare -A target_dir_for=()
declare -A target_group_for=()
declare -A target_layout_for=()
for line in "${targets[@]}"; do
    read -r t_name t_agent t_dir t_group t_layout t_extra <<< "$line"
    t_layout="${t_layout:-named}"
    if [[ -z "${t_group:-}" || -n "${t_extra:-}" ]] \
        || [[ "$t_layout" != named && "$t_layout" != pem ]]; then
        log_error "bad target line '$line' in $CONF_FILE (want: <name> <dest-agent> <target-dir> <group|-> [named|pem])"
        exit 1
    fi
    if [[ -n "${target_agent_for[$t_name]:-}" ]]; then
        log_error "duplicate target name '$t_name' in $CONF_FILE"
        exit 1
    fi
    target_agent_for["$t_name"]="$t_agent"
    target_dir_for["$t_name"]="$t_dir"
    target_group_for["$t_name"]="$t_group"
    target_layout_for["$t_name"]="$t_layout"
done

mkdir -p "$CERT_OUTPUT_DIR"

# Extract a named section from Hestia stdout
# Usage: extract_section <stdout> <SECTION>
extract_section() {
    local content="$1"
    local section="$2"
    echo "$content" | awk "/^### ${section} ###$/{found=1; next} /^### /{found=0} found"
}

# Run a script on one agent, writing the JSON response to a file.
# Usage: run_on <agent> <script> <output-file> [arg ...]
# Returns 0 when the call worked and the script exited 0; otherwise sets
# RUN_ERROR and returns 1.
run_on() {
    local host="$1"
    local script="$2"
    local out="$3"
    shift 3
    local rc=0 result_exit

    RUN_ERROR=""
    ctrl-exec-cli run "$host" --script "$script" --json -- "$@" > "$out" 2>&1 || rc=$?
    if [[ $rc -ne 0 ]]; then
        RUN_ERROR=$(jq -r '.error // .results[0].error // "unknown error"' "$out" 2>/dev/null \
            || head -c 200 "$out")
        return 1
    fi
    result_exit=$(jq -r '.results[0].exit // -1' "$out" 2>/dev/null || echo "-1")
    if [[ "$result_exit" != "0" ]]; then
        RUN_ERROR=$(jq -r '.results[0].stderr // .results[0].error // "unknown error"' "$out" \
            2>/dev/null || echo "unknown error")
        return 1
    fi
}

issue_success=0
issue_failure=0
deploy_success=0
deploy_failure=0
restart_success=0
restart_failure=0
verify_success=0
verify_failure=0
declare -A deployed_to=()
declare -A deployed_domains=()   # target -> space-separated domains it received
declare -A wildcard_of=()
for entry in "${certificates[@]}"; do
    read -r c_domain c_flag <<< "$entry"
    [[ "${c_flag:-}" == wildcard ]] && wildcard_of["$c_domain"]=1
done
declare -A fingerprint_of=()

# SHA-256 fingerprint of the first certificate in a PEM text, upper-case hex.
# Perl core modules only: the run-jobs image has no openssl.
cert_fingerprint() {
    printf '%s\n' "$1" | perl -MMIME::Base64 -MDigest::SHA=sha256_hex -0777 -ne \
        'print uc sha256_hex(decode_base64($1)) if /-----BEGIN CERTIFICATE-----(.*?)-----END CERTIFICATE-----/s'
}

for entry in "${certificates[@]}"; do
    read -r domain wildcard_flag <<< "$entry"
    wildcard="${wildcard_flag:-}"

    # Filter to single cert if argument provided
    if [[ -n "$FILTER" && "$domain" != "$FILTER" ]]; then
        continue
    fi

    output_file="$CERT_OUTPUT_DIR/${domain}.json"
    args=("issue-cert" "$domain")
    [[ "$wildcard" == "wildcard" ]] && args+=("--wildcard")

    log_info "issuing: $domain via $agent (wildcard=${wildcard:-no})"

    if ! run_on "$agent" "$CE_AGENT_SCRIPT" "$output_file" "${args[@]}"; then
        log_error "issue failed: $domain - $RUN_ERROR"
        (( issue_failure++ )) || true
        continue
    fi

    log_info "issued: $domain"
    (( issue_success++ )) || true

    # Parse cert sections from stdout, then drop the response: it holds the key
    stdout=$(jq -r '.results[0].stdout' "$output_file")
    rm -f "$output_file"
    cert=$(extract_section "$stdout" "CERT")
    key=$(extract_section  "$stdout" "KEY")
    ca=$(extract_section   "$stdout" "CA")

    if [[ -z "$cert" || -z "$key" || -z "$ca" ]]; then
        log_error "deploy skipped: $domain - could not parse cert sections from response"
        (( deploy_failure++ )) || true
        continue
    fi

    # Base64-encode for transport
    cert_b64=$(echo "$cert" | base64 -w 0)
    key_b64=$(echo  "$key"  | base64 -w 0)
    ca_b64=$(echo   "$ca"   | base64 -w 0)
    fingerprint_of["$domain"]=$(cert_fingerprint "$cert")

    # Deploy to each destination configured for this domain
    dest_count=0
    for line in "${deploys[@]}"; do
        read -r d_domain t_name extra <<< "$line"
        [[ "$d_domain" == "$domain" ]] || continue
        (( dest_count++ )) || true

        if [[ -z "${t_name:-}" || -n "${extra:-}" ]]; then
            log_error "deploy failed: $domain - bad deploy line '$line' (want: <domain> <target-name>)"
            (( deploy_failure++ )) || true
            continue
        fi
        dest_agent="${target_agent_for[$t_name]:-}"
        if [[ -z "$dest_agent" ]]; then
            log_error "deploy failed: $domain - no target named '$t_name'"
            (( deploy_failure++ )) || true
            continue
        fi
        target_dir="${target_dir_for[$t_name]}"
        group="${target_group_for[$t_name]}"
        layout="${target_layout_for[$t_name]}"

        log_info "deploying: $domain to $t_name ($dest_agent:$target_dir, layout $layout)"
        if ! run_on "$dest_agent" "$CE_DEPLOY_SCRIPT" \
            "$CERT_OUTPUT_DIR/${domain}.${t_name}.deploy.json" \
            "$target_dir" "$domain" "$group" "$cert_b64" "$key_b64" "$ca_b64" "$layout"; then
            log_error "deploy failed: $domain to $t_name ($dest_agent) - $RUN_ERROR"
            (( deploy_failure++ )) || true
            continue
        fi

        log_info "deployed: $domain to $t_name ($dest_agent:$target_dir)"
        (( deploy_success++ )) || true
        deployed_to["$t_name"]=1
        deployed_domains["$t_name"]+="$domain "
    done

    if (( dest_count == 0 )); then
        log_info "deploy skipped: $domain - no deploy targets configured"
    fi
done

# Restart services for each target that received a certificate in this run
for line in "${restarts[@]}"; do
    read -r -a restart_args <<< "$line"
    r_target="${restart_args[0]}"
    dest_agent="${target_agent_for[$r_target]:-}"
    if [[ ${#restart_args[@]} -lt 2 || -z "$dest_agent" ]]; then
        log_error "restart failed: bad restart line '$line' (want: <target-name> <compose-file> [service ...], with a target of that name)"
        (( restart_failure++ )) || true
        continue
    fi
    if [[ -z "${deployed_to[$r_target]:-}" ]]; then
        continue
    fi

    log_info "restarting: ${restart_args[*]:1} on $dest_agent (target $r_target)"
    if ! run_on "$dest_agent" "$CE_RESTART_SCRIPT" \
        "$CERT_OUTPUT_DIR/${r_target}.restart.json" "${restart_args[@]:1}"; then
        log_error "restart failed: $dest_agent (target $r_target) - $RUN_ERROR"
        (( restart_failure++ )) || true
        continue
    fi
    log_info "restarted: ${restart_args[*]:1} on $dest_agent"
    (( restart_success++ )) || true
done

# Optional: confirm each service serves the certificate just deployed
for line in "${verifies[@]}"; do
    read -r v_target v_domain v_addr v_proto v_extra <<< "$line"
    v_agent="${target_agent_for[$v_target]:-}"
    v_host=""
    v_port="${v_addr:-}"
    if [[ "$v_port" =~ ^([A-Za-z0-9.-]+):([0-9]+)$ ]]; then
        v_host="${BASH_REMATCH[1]}"
        v_port="${BASH_REMATCH[2]}"
    fi
    if [[ -z "$v_port" || -n "${v_extra:-}" || ! "$v_port" =~ ^[0-9]+$ || -z "$v_agent" ]]; then
        log_error "verify failed: bad verify line '$line' (want: <target-name> <name> <[address:]port> [starttls], with a target of that name)"
        (( verify_failure++ )) || true
        continue
    fi

    # Which certificate deployed to this target in this run covers the name?
    v_cert=""
    for d in ${deployed_domains[$v_target]:-}; do
        if [[ "$v_domain" == "$d" ]]; then
            v_cert="$d"
        elif [[ -n "${wildcard_of[$d]:-}" && "$v_domain" == *."$d" \
                && "${v_domain%."$d"}" != *.* ]]; then
            v_cert="$d"
        fi
        [[ -n "$v_cert" ]] && break
    done
    [[ -n "$v_cert" ]] || continue

    check_args=(-p "$v_port" -n "$v_domain")
    [[ -n "$v_host" ]] && check_args+=(-H "$v_host")
    if [[ -n "${fingerprint_of[$v_cert]:-}" ]]; then
        check_args+=(-f "${fingerprint_of[$v_cert]}")
    else
        log_error "verify: no fingerprint for $v_cert (issued certificate unreadable); checking without it"
    fi
    [[ -n "${v_proto:-}" ]] && check_args+=(-P "$v_proto")
    out_file="$CERT_OUTPUT_DIR/${v_target}.${v_domain}.${v_port}.verify.json"

    v_exit=-1
    v_line=""
    for (( try = 1; try <= VERIFY_TRIES; try++ )); do
        rc=0
        ctrl-exec-cli run "$v_agent" --script "$CE_CHECK_SCRIPT" --json -- \
            "${check_args[@]}" > "$out_file" 2>&1 || rc=$?
        v_exit=$(jq -r '.results[0].exit // -1' "$out_file" 2>/dev/null || echo -1)
        v_line=$(jq -r '.results[0].stdout // .results[0].error // .error // ""' "$out_file" \
            2>/dev/null | head -n 1 || true)
        [[ -n "$v_line" ]] || v_line=$(head -c 200 "$out_file")
        # OK or WARNING is an answer; CRITICAL/UNKNOWN or a failed call may be
        # the service still starting, so try again
        [[ "$v_exit" == 0 || "$v_exit" == 1 ]] && break
        (( try < VERIFY_TRIES )) && sleep "$VERIFY_WAIT"
    done

    case "$v_exit" in
        0)  log_info  "verified: $v_domain on $v_agent:$v_port - $v_line"
            (( verify_success++ )) || true ;;
        1)  log_info  "verify warning: $v_domain on $v_agent:$v_port - $v_line"
            (( verify_success++ )) || true ;;
        *)  log_error "verify failed: $v_domain on $v_agent:$v_port after $VERIFY_TRIES tries - $v_line"
            (( verify_failure++ )) || true ;;
    esac
done

summary="complete: issued $issue_success ok $issue_failure failed | deployed $deploy_success ok $deploy_failure failed | restarted $restart_success ok $restart_failure failed"
if (( ${#verifies[@]} )); then
    summary+=" | verified $verify_success ok $verify_failure failed"
fi
log_info "$summary"

if (( issue_failure + deploy_failure + restart_failure + verify_failure > 0 )); then
    exit 1
fi
exit 0
