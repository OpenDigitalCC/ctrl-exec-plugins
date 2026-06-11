---
title: ctrl-exec-plugins - api-key-registry
subtitle: Validate opaque API keys against a local registry file
brand: odcc
---

# api-key-registry

## Purpose

`api-key-registry` is a ctrl-exec auth hook that authenticates a caller by an
**opaque API key** - the request's `token` - looked up in a simple local file
that maps each key to an identity and a privilege level. It is the
machine-to-machine counterpart to password hooks: keys are issued to scripts,
services, and agents rather than typed by people.

**What it gives you:** real token authentication with the simplest possible
operations. The registry is a plain text file; the hook re-reads it on **every
request**, so you can issue, revoke, or re-level a key by editing one line - no
restart, no reload, no external service. Two privilege tiers (`ping` < `run`)
let read-only callers be separated from those allowed to execute scripts. It has
zero dependencies beyond `bash`, works offline, and fails closed.

It pairs naturally with the **`ctrl-exec-mcp`** bridge's HTTP transport, which
forwards each client's `Authorization: Bearer` token as the ctrl-exec `token` -
this hook is the validator that makes a networked MCP endpoint actually
authenticated.

## Dependencies

- `bash`. No external tools, no network, no libraries.

## Installation

Deploy the hook on the host that runs the auth check (the ctrl-exec / API host,
the agent host, or both), create a registry file, and reference both:

```bash
install -m 0755 api-key-registry /etc/ctrl-exec/hooks/api-key-registry

umask 077
cat > /etc/ctrl-exec/api-keys.conf <<'EOF'
# key:username:level   (level = ping | run | admin)
k_3f9a…:ci-runner:run
k_pub1…:dashboard:ping
EOF
chmod 0600 /etc/ctrl-exec/api-keys.conf

# In ctrl-exec.conf (or agent.conf):
auth_hook = /etc/ctrl-exec/hooks/api-key-registry
```

## Configuration

| Variable | Default | Purpose |
| --- | --- | --- |
| `API_KEY_REGISTRY` | `/etc/ctrl-exec/api-keys.conf` | Path to the registry file. |

**Registry format** - one entry per line; `#` comments and blank lines ignored:

```
<key>:<username>:<level>
```

- `key` - the opaque token the caller presents (generate with e.g.
  `openssl rand -hex 24`). The first colon-separated field.
- `username` - for your own audit only; the decision does not use it.
- `level` - `ping`, `run`, or `admin` (the last colon-separated field).

**Action → required level:**

| Action | Requires |
| --- | --- |
| `ping`, `discovery` | `ping` |
| `run`, `api`, anything else | `run` |

A key's level must meet or exceed the action's requirement (`ping` < `run` <
`admin`).

## Exit codes

- `0` - authorised: key found and its level satisfies the action.
- `1` - denied: registry file missing or unreadable (fail closed).
- `2` - bad credentials: no token presented, or the token is not in the registry.
- `3` - insufficient privilege: key is valid but its level is below what the
  action requires.

## Examples

Registry:

```
# read-only dashboard
k_dash_a1b2c3:grafana:ping
# CI pipeline allowed to run scripts
k_ci_d4e5f6:ci-runner:run
```

- A `discovery` call with token `k_dash_a1b2c3` → exit `0` (ping ≤ ping).
- A `run` call with token `k_dash_a1b2c3` → exit `3` (dashboard key lacks `run`).
- A `run` call with token `k_ci_d4e5f6` → exit `0`.
- Any call with an unknown token → exit `2`.

Rotate a key with no downtime - just edit the file:

```bash
sed -i 's/^k_ci_d4e5f6:/k_ci_NEWKEY:/' /etc/ctrl-exec/api-keys.conf
```

## Limitations

- **Bearer tokens, not passwords.** Anyone holding a key has its privileges;
  keep the registry `0600` and distribute keys over secure channels. Treat keys
  like passwords - long and random.
- **Two coarse tiers.** `ping` vs `run` (with `admin` reserved). It does not do
  per-script or per-host authorisation; combine with the allowlist (which is the
  authoritative surface control) and, for finer policy, a hook like `rest-query`.
- **No expiry.** Keys are valid until removed from the file; there is no built-in
  TTL. Rotate by editing the registry.
- **Local file only.** No central key store or distribution; for many hosts,
  manage the file with your configuration tooling.
- **Client-supplied username is not checked.** Identity comes from the key, not
  the `username` field of the request; the registry username is for audit.
