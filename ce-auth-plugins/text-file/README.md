---
title: ctrl-exec-plugins - text-file
subtitle: Validate ctrl-exec credentials against a plaintext token file
brand: odcc
---

# text-file

## Purpose

`text-file` is the simplest possible ctrl-exec auth hook: it authorises a
request when the caller's `username:token` appears, verbatim, in a plaintext
file. One line per credential, re-read on every request.

**What it gives you:** working token auth in environments with **no auth
infrastructure at all** - an appliance, an embedded box, a minimal container, a
quick lab. Zero dependencies beyond `bash`, no hashing tools, no service. Issue a
credential by adding a line; revoke it by deleting the line. It is deliberately
minimal, and the README is equally explicit about its limits.

## Dependencies

- `bash`. Nothing else.

## Installation

Deploy the hook, create the token file (mode `0600`), and reference both:

```bash
install -m 0755 text-file /etc/ctrl-exec/hooks/text-file

umask 077
cat > /etc/ctrl-exec/tokens <<'EOF'
# username:token
alice:s3cr3t
ci-runner:k_9f3a...
EOF
chmod 0600 /etc/ctrl-exec/tokens

# In ctrl-exec.conf (or agent.conf):
auth_hook = /etc/ctrl-exec/hooks/text-file
```

The caller supplies the token as the request **token** and the username as
usual.

## Configuration

| Variable | Default | Purpose |
| --- | --- | --- |
| `TEXT_FILE_AUTH` | `/etc/ctrl-exec/tokens` | Path to the token file. |

File format: one `username:token` per line; `#` comments and blank lines are
ignored. The match is exact.

## Exit codes

- `0` - authorised: an exact `username:token` line exists.
- `1` - denied (fail closed): the file is missing/unreadable, or an unexpected
  error.
- `2` - bad credentials: no username or token presented, or no matching line.

## Examples

```
# /etc/ctrl-exec/tokens
alice:s3cr3t
ci-runner:k_9f3a2b
```

- Request as `alice` with token `s3cr3t` → exit `0`.
- Request as `alice` with any other token → exit `2`.
- Rotate by editing the file (no restart needed):

```bash
sed -i 's/^ci-runner:.*/ci-runner:k_NEW/' /etc/ctrl-exec/tokens
```

## Limitations

- **Plaintext tokens.** Anyone who can read the file has every credential. Keep
  it `0600`, owned by the service user, and out of version control. This is the
  trade-off for zero dependencies - do not use it where stronger storage is
  warranted (use `htpasswd`, `api-key-registry`, `jwt`, or a directory hook).
- **No scope, no expiry.** A token grants whatever the allowlist permits, until
  its line is removed. There is no per-script scope and no TTL.
- **Manual management.** No tooling beyond a text editor; for many hosts, manage
  the file with your configuration system.
