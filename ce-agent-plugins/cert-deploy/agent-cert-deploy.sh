#!/usr/bin/env bash
# agent-cert-deploy.sh
# ctrl-exec agent script - receives and deploys SSL certificate files
# to a target directory, in the file layout the consuming service expects.
# Called by deploy-cert.sh via ctrl-exec-cli run.
#
# Input (declare the script `input=fields` in scripts.conf):
#   The certificate, private key and CA chain arrive as ctrl-exec run input,
#   not as arguments, so the key is never in a process table. ctrl-exec puts
#   each field in a file in a private per-run directory, $CTRL_EXEC_INPUT:
#     $CTRL_EXEC_INPUT/cert   certificate (fullchain), PEM text
#     $CTRL_EXEC_INPUT/key    private key, PEM text
#     $CTRL_EXEC_INPUT/ca     CA certificate, PEM text
#   ctrl-exec removes the directory when the script ends.
#
# Arguments:
#   $1  target-dir   absolute path to write cert files into
#   $2  basename     filename stem (e.g. example.com) - writes <basename>.crt etc
#   $3  group        group to own the files (name or gid); '-' to skip chgrp
#   $4  layout       optional: named (default) or pem
#
# DEPRECATED, to be removed in the next release: when no input arrived (an
# older deploy-cert.sh, or a script not declared input=fields) the old form
# is still accepted, with the material as base64 arguments. The key is then
# visible in the process table of this host and of the dispatcher.
#   $1 target-dir  $2 basename  $3 group
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

# Did input arrive? input=fields gives a directory of files, one per field. A
# script declared input=fields but called without input gets an empty one, so
# an empty directory counts as no input.
input_dir=""
if [[ "$mode" == deploy && -n "${CTRL_EXEC_INPUT:-}" && -d "$CTRL_EXEC_INPUT" \
      && -n "$(ls -A -- "$CTRL_EXEC_INPUT")" ]]; then
    input_dir="$CTRL_EXEC_INPUT"
fi

cert_b64="" key_b64="" ca_b64=""
if [[ "$mode" == test || -n "$input_dir" ]]; then
    layout="${4:-named}"
else
    # DEPRECATED (remove in the next release): the old argument form
    cert_b64="${4:-}"
    key_b64="${5:-}"
    ca_b64="${6:-}"
    layout="${7:-named}"
fi

if [[ -z "$target_dir" || -z "$basename" || -z "$group" ]]; then
    usage=1
elif [[ "$mode" == deploy && -z "$input_dir" && ( -z "$cert_b64" || -z "$key_b64" || -z "$ca_b64" ) ]]; then
    usage=1
    echo "Error: no input received (CTRL_EXEC_INPUT is unset or empty) and no base64 arguments given." >&2
    echo "       The script needs 'input=fields' in scripts.conf and a run sent with input fields cert, key and ca." >&2
elif [[ -n "$input_dir" && $# -gt 4 ]]; then
    usage=1
    echo "Error: input arrived, so the arguments are <target-dir> <basename> <group> [layout] only" >&2
fi
if [[ -n "${usage:-}" ]]; then
    echo "Usage: agent-cert-deploy <target-dir> <basename> <group> [named|pem]   (input fields cert, key, ca)" >&2
    echo "       agent-cert-deploy --test <target-dir> <basename> <group> [named|pem]" >&2
    echo "  pass '-' as group to skip group ownership change" >&2
    echo "  deprecated: agent-cert-deploy <target-dir> <basename> <group> <cert-b64> <key-b64> <ca-b64> [named|pem]" >&2
    exit 1
fi

# Input arrived: every field must be there, and the message names the field
if [[ -n "$input_dir" ]]; then
    for field in cert key ca; do
        if [[ ! -f "$input_dir/$field" ]]; then
            echo "Error: input field '$field' is missing (send fields cert, key and ca)" >&2
            exit 1
        fi
    done
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

# The three pieces of PEM text, each ending in a newline. From input fields
# (the sed adds the final newline only when it is missing); from the
# DEPRECATED base64 arguments otherwise.
if [[ -n "$input_dir" ]]; then
    src_cert() { sed -e '$a\' "$input_dir/cert"; }
    src_key()  { sed -e '$a\' "$input_dir/key"; }
    src_ca()   { sed -e '$a\' "$input_dir/ca"; }
else
    src_cert() { echo "$cert_b64" | base64 -d; }
    src_key()  { echo "$key_b64"  | base64 -d; }
    src_ca()   { echo "$ca_b64"   | base64 -d; }
fi

# Fullchain = leaf certificate followed by intermediate CA. Files are
# overwritten in place, so a service that bind-mounts a single file keeps
# seeing the new content.
case "$layout" in
    named)
        crt_file="$target_dir/${basename}.crt"
        ca_file="$target_dir/${basename}.ca"
        src_cert > "$crt_file"
        src_key  > "$target_dir/${basename}.key"
        src_ca   > "$ca_file"
        cat "$crt_file" "$ca_file" > "$target_dir/${basename}.fullchain.crt"
        ;;
    pem)
        { src_cert; src_ca; } > "$target_dir/fullchain.pem"
        src_key > "$target_dir/privkey.pem"
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
