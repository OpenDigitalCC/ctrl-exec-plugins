#!/usr/bin/env bash
# agent-cert-deploy.sh
# ctrl-exec agent script - receives and deploys SSL certificate files
# to a target directory, in the file layout the consuming service expects.
# Called by deploy-cert.sh via ctrl-exec-cli run.
#
# Arguments:
#   $1  target-dir   absolute path to write cert files into
#   $2  basename     filename stem (e.g. example.com) - writes <basename>.crt etc
#   $3  group        group to own the files (name or gid); '-' to skip chgrp
#   $4  cert-b64     base64-encoded certificate (fullchain)
#   $5  key-b64      base64-encoded private key
#   $6  ca-b64       base64-encoded CA certificate
#   $7  layout       optional: named (default) or pem
#
# Layout named (default) writes, all mode 640:
#   <target-dir>/<basename>.crt            certificate
#   <target-dir>/<basename>.key            private key
#   <target-dir>/<basename>.ca             CA chain
#   <target-dir>/<basename>.fullchain.crt  certificate then CA
# Layout pem writes only these two, mode 640, for services that expect
# them by these names in a folder of their own (certbot style, e.g.
# Authentik's certs/<keypair-name>/); basename is not used in file names:
#   <target-dir>/fullchain.pem             certificate then CA
#   <target-dir>/privkey.pem               private key
#
# When a group is given, files are chowned to root:<group> mode 640 so a
# service running under that group (e.g. a containerised daemon that drops
# to an unprivileged user) can read the key. Requires CAP_CHOWN in the
# profile if changing group to one the run_as user does not own.
#
# Idempotent - safe to run multiple times, overwrites existing files.
#
# Where it may write is set by the agent profile (writable = ...), not here.
#
# Test mode: agent-cert-deploy --test <target-dir> <basename> <group|-> [layout]
#   Deploys nothing and changes nothing. Checks the same arguments, then that
#   this user can create files in the target dir (or create the dir), set the
#   group on them, set the modes, and overwrite any existing certificate
#   files. Uses a probe file that is removed again. Run it through ctrl-exec,
#   so it runs as the profile's user. Exits 0 when every check passes, 1
#   otherwise.

set -euo pipefail

# New files are created without world access, so the key is never readable
# by other users between being written and the chmod below
umask 027

mode=deploy
if [[ "${1:-}" == "--test" ]]; then
    mode="test"
    shift
fi

target_dir="${1:-}"
basename="${2:-}"
group="${3:-}"
cert_b64="${4:-}"
key_b64="${5:-}"
ca_b64="${6:-}"
if [[ "$mode" == test ]]; then
    layout="${4:-named}"
else
    layout="${7:-named}"
fi

if [[ -z "$target_dir" || -z "$basename" || -z "$group" ]] \
   || [[ "$mode" == deploy && ( -z "$cert_b64" || -z "$key_b64" || -z "$ca_b64" ) ]]; then
    echo "Usage: agent-cert-deploy <target-dir> <basename> <group> <cert-b64> <key-b64> <ca-b64> [named|pem]" >&2
    echo "       agent-cert-deploy --test <target-dir> <basename> <group> [named|pem]" >&2
    echo "  pass '-' as group to skip group ownership change" >&2
    exit 1
fi

if [[ "$target_dir" != /* ]]; then
    echo "Error: target-dir must be an absolute path: '$target_dir'" >&2
    exit 1
fi
if [[ "$target_dir" == *..* ]]; then
    echo "Error: target-dir must not contain '..': '$target_dir'" >&2
    exit 1
fi
if [[ "$basename" =~ [/\\] || "$basename" == *..* ]]; then
    echo "Error: invalid basename '$basename'" >&2
    exit 1
fi
if [[ "$group" != "-" && ! "$group" =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]*$ ]]; then
    echo "Error: invalid group '$group'" >&2
    exit 1
fi

# File names for the layout, in write order
case "$layout" in
    named) names=("$basename.crt" "$basename.key" "$basename.ca" "$basename.fullchain.crt") ;;
    pem)   names=(fullchain.pem privkey.pem) ;;
    *)     echo "Error: invalid layout '$layout' (named or pem)" >&2
           exit 1 ;;
esac

# Test mode: report whether a deploy would work, change nothing
run_test() {
    local fails=0 dir probe dir_mode f name tool
    ok()   { echo "ok    $*"; }
    fail() { echo "FAIL  $*"; fails=$(( fails + 1 )); }

    echo "test mode - nothing is deployed"
    echo "user:    $(id -un) (groups: $(id -Gn))"
    echo "target:  $target_dir/{$(IFS=,; echo "${names[*]}")} (layout $layout)"

    for tool in base64 cat chgrp chmod mkdir; do
        command -v "$tool" > /dev/null 2>&1 || fail "$tool not found in PATH"
    done

    if [[ "$group" != "-" ]]; then
        # A numeric gid need not exist on the host: a container's service
        # group often has a gid the host does not name
        if [[ "$group" =~ ^[0-9]+$ ]]; then
            ok "group is numeric gid $group (no host entry needed)"
        elif getent group "$group" > /dev/null; then
            ok "group '$group' exists"
        else
            fail "group '$group' does not exist on this host"
        fi
    fi

    # Probe in the target dir, or in the nearest folder that exists if the
    # deploy would have to create it
    dir="$target_dir"
    if [[ -d "$dir" ]]; then
        ok "target dir exists"
    else
        while [[ ! -d "$dir" ]]; do
            dir=$(dirname "$dir")
        done
        echo "info  target dir does not exist - a deploy would create it under $dir"
    fi

    probe="$dir/.agent-cert-deploy-test.$$"
    if ( : > "$probe" ) 2> /dev/null; then
        ok "can create files in $dir"
        if [[ "$group" != "-" ]]; then
            if chgrp "$group" "$probe" 2> /dev/null; then
                ok "can set group '$group' on new files"
            else
                fail "cannot set group '$group' - $(id -un) must be a member, or the profile needs CAP_CHOWN"
            fi
        fi
        if chmod 640 "$probe" 2> /dev/null; then
            ok "can set mode 640 on new files"
        else
            fail "cannot set mode 640 on new files"
        fi
        rm -f "$probe"
    else
        fail "cannot create files in $dir - check the profile's writable paths"
    fi

    # The deploy sets the dir's mode (and group). Re-applying its current mode
    # proves the right without changing anything.
    if [[ "$dir" == "$target_dir" ]]; then
        dir_mode=$(stat -c %a "$target_dir")
        if chmod "$dir_mode" "$target_dir" 2> /dev/null; then
            ok "can set the target dir's mode"
        else
            fail "cannot set the target dir's mode - $(id -un) must own $target_dir"
        fi
    fi

    # Existing files are overwritten in place, then given the group and mode
    for name in "${names[@]}"; do
        f="$target_dir/$name"
        [[ -e "$f" ]] || continue
        if [[ ! -w "$f" ]]; then
            fail "cannot overwrite existing $f"
        elif ! chmod "$(stat -c %a "$f")" "$f" 2> /dev/null; then
            fail "cannot set the mode of existing $f - $(id -un) must own it"
        else
            ok "can overwrite existing $name"
        fi
    done

    echo
    if (( fails )); then
        echo "$fails check(s) failed"
        return 1
    fi
    echo "all checks passed - a deploy would work"
}

if [[ "$mode" == test ]]; then
    rc=0
    run_test || rc=$?
    exit "$rc"
fi

mkdir -p "$target_dir"

# Fullchain = leaf certificate followed by intermediate CA. Files are
# overwritten in place, so a service that bind-mounts a single file keeps
# seeing the new content.
case "$layout" in
    named)
        crt_file="$target_dir/${basename}.crt"
        ca_file="$target_dir/${basename}.ca"
        echo "$cert_b64" | base64 -d > "$crt_file"
        echo "$key_b64"  | base64 -d > "$target_dir/${basename}.key"
        echo "$ca_b64"   | base64 -d > "$ca_file"
        cat "$crt_file" "$ca_file" > "$target_dir/${basename}.fullchain.crt"
        ;;
    pem)
        { echo "$cert_b64" | base64 -d; echo "$ca_b64" | base64 -d; } > "$target_dir/fullchain.pem"
        echo "$key_b64" | base64 -d > "$target_dir/privkey.pem"
        ;;
esac

files=()
for name in "${names[@]}"; do
    files+=("$target_dir/$name")
done

# Set group ownership so a service group can read the files and traverse the
# directory (skip if '-'). The directory needs group execute, the files need
# group read.
if [[ "$group" != "-" ]]; then
    chgrp "$group" "$target_dir" "${files[@]}"
fi

chmod 750 "$target_dir"
chmod 640 "${files[@]}"

echo "deployed $basename to $target_dir (layout $layout) at $(date --iso-8601=seconds)"
for name in "${names[@]}"; do
    printf '  %-26s %s bytes\n' "$name" "$(wc -c < "$target_dir/$name")"
done
if [[ "$group" != "-" ]]; then
    echo "  group: $group"
fi
