#!/usr/bin/env bash
# agent-cert-check.sh
# ctrl-exec agent script - checks the TLS certificate a service is serving,
# in the style of a Nagios check_ssl plugin: one status line with perfdata,
# exit 0 OK / 1 WARNING / 2 CRITICAL / 3 UNKNOWN.
# Called by deploy-cert.sh after a deploy (verify = lines), or by hand.
#
# Usage:
#   agent-cert-check -p <port> -n <name> [-H <host>] [-P <starttls-proto>]
#                    [-w <days>] [-c <days>] [-f <sha256-fingerprint>]
#                    [-C <ca-file>] [-t <timeout>]
#
#   -p  port to connect to
#   -n  name the certificate must cover; also sent as SNI
#   -H  host to connect to (default localhost)
#   -P  STARTTLS protocol, as openssl s_client -starttls takes it
#       (xmpp, smtp, imap, pop3, ftp, ...); omit for direct TLS
#   -w  WARNING when fewer days than this remain (default 30)
#   -c  CRITICAL when fewer days than this remain (default 7)
#   -f  CRITICAL unless the served certificate has this SHA-256 fingerprint
#       (hex, colons optional); proves the service serves a given certificate
#   -C  CA file to verify against instead of the system store
#   -t  connection timeout in seconds (default 10)
#
# Checks: the connection, the name, expiry, that the chain verifies, and the
# fingerprint when given. Reads no files on the host and needs no privilege.

set -uo pipefail

host=localhost port="" name="" proto="" warn=30 crit=7 want_fp="" cafile="" tmo=10

usage() {
    echo "Usage: agent-cert-check -p <port> -n <name> [-H <host>] [-P <starttls>]"
    echo "       [-w <days>] [-c <days>] [-f <sha256>] [-C <ca-file>] [-t <secs>]"
}

unknown() {
    echo "SSL UNKNOWN - $1"
    exit 3
}

while getopts ':H:p:n:P:w:c:f:C:t:h' opt; do
    case $opt in
        H) host=$OPTARG ;;
        p) port=$OPTARG ;;
        n) name=$OPTARG ;;
        P) proto=$OPTARG ;;
        w) warn=$OPTARG ;;
        c) crit=$OPTARG ;;
        f) want_fp=$OPTARG ;;
        C) cafile=$OPTARG ;;
        t) tmo=$OPTARG ;;
        h) usage; exit 0 ;;
        :) unknown "option -$OPTARG needs a value" ;;
        *) unknown "unknown option -$OPTARG" ;;
    esac
done

[[ -n $port && -n $name ]] || unknown "-p <port> and -n <name> are required"
[[ $port =~ ^[0-9]+$ ]] || unknown "invalid port '$port'"
[[ $warn =~ ^[0-9]+$ && $crit =~ ^[0-9]+$ && $tmo =~ ^[0-9]+$ ]] \
    || unknown "-w, -c and -t take whole numbers"
[[ $name =~ ^[A-Za-z0-9*][A-Za-z0-9.*-]*$ ]] || unknown "invalid name '$name'"
[[ $host =~ ^[A-Za-z0-9][A-Za-z0-9.:-]*$ ]] || unknown "invalid host '$host'"
[[ -z $proto || $proto =~ ^[a-z0-9-]+$ ]] || unknown "invalid STARTTLS protocol '$proto'"
command -v openssl > /dev/null 2>&1 || unknown "openssl not found"

args=(s_client -connect "$host:$port" -servername "$name" -showcerts)
if [[ -n $proto ]]; then
    args+=(-starttls "$proto")
    [[ $proto == xmpp* ]] && args+=(-xmpphost "$name")
fi
if [[ -n $cafile ]]; then
    [[ -r $cafile ]] || unknown "cannot read CA file '$cafile'"
    args+=(-CAfile "$cafile")
fi

out=$(timeout "$tmo" openssl "${args[@]}" < /dev/null 2>&1)
rc=$?
leaf=$(printf '%s\n' "$out" | awk '/-----BEGIN CERTIFICATE-----/{n++} n==1{print} /-----END CERTIFICATE-----/ && n==1{exit}')
if [[ -z $leaf ]]; then
    if (( rc == 124 )); then
        reason="timed out after ${tmo}s"
    else
        reason=$(printf '%s\n' "$out" | grep -o -m1 -E 'Connection refused|Connection timed out|No route to host|Name or service not known|Network is unreachable|wrong version number|handshake failure|unsupported protocol|Did not get' || true)
    fi
    echo "SSL CRITICAL - no certificate from $host:$port${proto:+ ($proto)}${reason:+: $reason}"
    exit 2
fi

status=0
problems=()
raise() {   # raise <level> <message>
    (( $1 > status )) && status=$1
    problems+=("$2")
}

# Name
if ! printf '%s\n' "$leaf" | openssl x509 -noout -checkhost "$name" 2>/dev/null \
        | grep -q 'does match'; then
    raise 2 "does not cover $name"
fi

# Expiry
end=$(printf '%s\n' "$leaf" | openssl x509 -noout -enddate 2>/dev/null | cut -d= -f2)
if end_s=$(date -d "$end" +%s 2>/dev/null); then
    days=$(( (end_s - $(date +%s)) / 86400 ))
    expires=$(date -u -d "@$end_s" +%Y-%m-%d)
    if (( end_s <= $(date +%s) )); then
        raise 2 "expired $expires"
    elif (( days < crit )); then
        raise 2 "expires in $days days"
    elif (( days < warn )); then
        raise 1 "expires in $days days"
    fi
else
    days=-1
    expires=unknown
    raise 3 "cannot read the expiry date"
fi

# Chain
chain=$(printf '%s\n' "$out" | grep -c -- '-----BEGIN CERTIFICATE-----')
vcode=$(printf '%s\n' "$out" | sed -n 's/^ *Verify return code: \([0-9]*\) (\(.*\))$/\1 \2/p' | tail -n 1)
if [[ -z $vcode ]]; then
    raise 3 "no verification result"
elif [[ ${vcode%% *} != 0 ]]; then
    raise 2 "chain does not verify: ${vcode#* } (chain of $chain)"
fi

# Fingerprint
fp=$(printf '%s\n' "$leaf" | openssl x509 -noout -fingerprint -sha256 2>/dev/null | cut -d= -f2 | tr -d ':')
if [[ -n $want_fp ]]; then
    want=$(printf '%s' "$want_fp" | tr -d ':' | tr '[:lower:]' '[:upper:]')
    if [[ $fp != "$want" ]]; then
        raise 2 "serving a different certificate (sha256 ${fp:0:16}..., expected ${want:0:16}...)"
    fi
fi

subject=$(printf '%s\n' "$leaf" | openssl x509 -noout -subject -nameopt RFC2253 2>/dev/null | sed 's/^subject=//')
label=(OK WARNING CRITICAL UNKNOWN)
summary="$name on $host:$port${proto:+ ($proto)}: $subject, expires $expires ($days days), chain $chain"
if (( ${#problems[@]} )); then
    joined=$(IFS=';'; echo "${problems[*]}")
    msg="${joined//;/; } - $summary"
else
    msg="$summary, verified${want_fp:+, fingerprint matches}"
fi
echo "SSL ${label[$status]} - $msg | days=$days;$warn;$crit chain=$chain"
exit "$status"
