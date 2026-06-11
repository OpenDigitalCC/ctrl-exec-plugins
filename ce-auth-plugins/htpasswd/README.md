---
title: ctrl-exec-plugins - htpasswd
subtitle: Validate ctrl-exec credentials against an Apache htpasswd file
brand: odcc
---

# htpasswd

## Purpose

`htpasswd` is a ctrl-exec auth hook that authenticates a caller against an
**Apache htpasswd file** - the same `username:hash` file format used by web
servers for basic auth. The request username is the htpasswd user and the
request token is treated as the password; verification uses `htpasswd -v`, so
any hash it understands works (bcrypt, apr1/MD5, SHA, crypt).

**What it gives you:** password authentication with a format and tooling almost
every operator already knows. Issue and rotate credentials with the standard
`htpasswd` command, store them in one file, and reuse the same credential store
you may already have for a web UI. No database, no external service.

## Dependencies

- `bash` and `apache2-utils` (provides `htpasswd`).

## Installation

Deploy the hook on the host that runs the auth check, create the password file,
and reference both:

```bash
install -m 0755 htpasswd /etc/ctrl-exec/hooks/htpasswd

# bcrypt entries (-B), file mode 0600
htpasswd -cbB /etc/ctrl-exec/htpasswd alice 's3cr3t'
htpasswd -bB  /etc/ctrl-exec/htpasswd bob   'hunter2'
chmod 0600 /etc/ctrl-exec/htpasswd

# In ctrl-exec.conf (or agent.conf):
auth_hook = /etc/ctrl-exec/hooks/htpasswd
```

The caller supplies the password as the request **token** (`--token` on the CLI,
`CTRL_EXEC_TOKEN`, or the `token` field) and the username as usual.

## Configuration

| Variable | Default | Purpose |
| --- | --- | --- |
| `HTPASSWD_FILE` | `/etc/ctrl-exec/htpasswd` | Path to the htpasswd file. |

## Exit codes

- `0` - authorised: username and token (password) verify against the file.
- `1` - denied (fail closed): the file is missing/unreadable, or an unexpected
  error.
- `2` - bad credentials: no username or token presented, unknown user, or wrong
  password.

## Examples

```bash
htpasswd -bB /etc/ctrl-exec/htpasswd alice 's3cr3t'   # create/rotate
```

- Request as `alice` with token `s3cr3t` → exit `0`.
- Request as `alice` with the wrong token → exit `2`.
- Request as an unknown user → exit `2`.

## Limitations

- **Not for high-security deployments.** htpasswd is a basic credential store;
  the file holds password hashes that are only as strong as the chosen algorithm
  (use bcrypt, `-B`). Keep it `0600`.
- **Passwords, not scoped tokens.** There is one credential per user with no
  per-script or per-host scope - combine with the allowlist (the authoritative
  surface control), or use `api-key-registry` for levelled keys / `rest-query`
  for richer policy.
- **No lockout or rate limiting.** Pair with the agent's connection rate limiting
  and a fronting proxy if exposed.
