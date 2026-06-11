---
title: ctrl-exec-plugins - unix-user
subtitle: Authorise ctrl-exec by local Unix identity
brand: odcc
---

# unix-user

## Purpose

`unix-user` is a ctrl-exec auth hook that authorises a request when the caller's
username exists as a **local Unix account** on the host, and optionally belongs
to a required group. There is **no password check** - it answers "is this a real
local user (in the right group)?", not "did they prove who they are?".

**What it gives you:** the simplest possible authorisation for trusted internal
networks, with zero dependencies and zero configuration to maintain. Where
identity is already established upstream - an SSH `ForceCommand`, PAM
pre-authentication, a trusted reverse proxy, or a private management VLAN - this
hook ties ctrl-exec authorisation to the host's existing user and group model:
add a user to a group to grant access, remove them to revoke it, using the tools
you already use. No token files, no external service, no secrets to rotate.

**When *not* to use it:** anywhere the username is attacker-controllable or not
already authenticated. Because there is no credential check, on an untrusted
network anyone who can set the request username would pass. Use a credential or
token hook (`htpasswd`, `api-key-registry`, `jwt`, `ldap`, `pam`, ...) there.

## Dependencies

- `bash` and `coreutils` (`id`). No external services, no network.

## Installation

Deploy the hook on the host that runs the auth check (the ctrl-exec / API host,
the agent host, or both) and reference it:

```bash
install -m 0755 unix-user /etc/ctrl-exec/hooks/unix-user

# In ctrl-exec.conf (or agent.conf):
auth_hook = /etc/ctrl-exec/hooks/unix-user
```

## Configuration

| Variable | Default | Purpose |
| --- | --- | --- |
| `UNIX_USER_GROUP` | (unset) | If set, the user must be a member of this group; otherwise any existing local user is authorised. |

Identity comes from the request username (`ENVEXEC_USERNAME`). Pass it on the
CLI with `--username`, set `CTRL_EXEC_USERNAME`, or have your upstream
(ForceCommand/proxy) supply it.

## Exit codes

- `0` - authorised: the username is a local user (and, if `UNIX_USER_GROUP` is
  set, a member of that group).
- `1` - denied (fail closed): an unexpected error.
- `2` - bad credentials: no username presented, or no such local user.
- `3` - insufficient privilege: the user exists but is not in the required group.

## Examples

Authorise any local user:

```bash
auth_hook = /etc/ctrl-exec/hooks/unix-user
```

Restrict to members of an `ops` group:

```bash
# environment for the ctrl-exec / agent service
UNIX_USER_GROUP=ops
```

- A request from `alice` (a local user in `ops`) → exit `0`.
- A request from `alice` when she is not in `ops` → exit `3`.
- A request from `nosuchuser` → exit `2`.

Manage access with the standard tools:

```bash
sudo usermod -aG ops alice    # grant
sudo gpasswd -d alice ops     # revoke
```

## Limitations

- **No authentication.** Identity is trusted, not verified. Only safe where the
  username is already authenticated upstream and cannot be forged.
- **Local accounts only.** Users must resolve via NSS on this host (`/etc/passwd`,
  or LDAP/SSSD if configured). It does not query a directory itself - for that
  use the `ldap` or `pam` hooks.
- **Single optional group.** One group gate; for richer policy (per-script or
  per-host rules) combine with the allowlist and/or a `rest-query` hook.
