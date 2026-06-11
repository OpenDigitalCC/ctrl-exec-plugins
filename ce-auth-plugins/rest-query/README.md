---
title: ctrl-exec-plugins - rest-query
subtitle: Delegate the ctrl-exec auth decision to any HTTP service
brand: odcc
---

# rest-query

## Purpose

`rest-query` is a ctrl-exec auth hook that does not make the authorisation
decision itself - it **forwards** the full request context to an HTTP endpoint
you control and turns that service's response into the hook's verdict. It is a
generic adapter: instead of writing a new hook for every identity system, you
point `rest-query` at one URL and implement the decision wherever it is easiest
(an existing app, an API gateway, a serverless function, a microservice).

**What it gives you:** integration with *any* external auth or policy system in
minutes, with no new ctrl-exec-specific code. The endpoint receives everything
about the request - action, script, target hosts, username, token, source IP -
and returns a simple status. One small, audited hook covers LDAP front-ends,
OPA/policy engines, bespoke entitlement services, feature flags, change-freeze
windows, or anything else reachable over HTTP. It fails closed, so an
unreachable or misbehaving endpoint denies rather than allows.

## Dependencies

- `bash` and `curl`. No other dependencies.
- A reachable HTTP endpoint that implements the contract below.

## Installation

Deploy the hook to the host running the auth check - the ctrl-exec (API /
dispatcher) host, the agent host, or both - and reference it from the relevant
config:

```bash
install -m 0755 rest-query /etc/ctrl-exec/hooks/rest-query

# In ctrl-exec.conf (or agent.conf for an agent-side hook):
auth_hook = /etc/ctrl-exec/hooks/rest-query
```

The hook must be executable and is invoked once per request.

## Configuration

Configuration is by environment variable (set them in the service environment of
whatever launches ctrl-exec, e.g. the systemd unit):

| Variable | Default | Purpose |
| --- | --- | --- |
| `REST_QUERY_URL` | (none) | The decision endpoint. **Required** - if unset, the hook denies. |
| `REST_QUERY_TIMEOUT` | `5` | Per-request timeout in seconds. |

**Endpoint contract.** The hook `POST`s the request-context JSON as the body,
with `Content-Type: application/json`, the action as an `X-CtrlExec-Action`
header, and (when present) the caller's token as `Authorization: Bearer ...`.
The endpoint inspects the request and returns a status:

| HTTP status from the endpoint | Hook exit code | Meaning |
| --- | --- | --- |
| `200` | `0` | Authorised |
| `401` | `2` | Bad credentials |
| `403` | `3` | Insufficient privilege |
| anything else, or unreachable | `1` | Denied (fail closed) |

The context body looks like:

```json
{ "action": "run", "script": "pg-backup", "hosts": ["db-01"],
  "username": "alice", "token": "…", "source_ip": "10.0.0.5",
  "args": ["--database", "myapp"], "timestamp": "2026-06-11T…Z" }
```

## Exit codes

- `0` - authorised (endpoint returned 200).
- `1` - denied: endpoint returned an unexpected status, was unreachable, timed
  out, or `REST_QUERY_URL` is unset. The fail-closed default.
- `2` - bad credentials (endpoint returned 401).
- `3` - insufficient privilege (endpoint returned 403).

## Examples

A minimal decision endpoint (Flask) authorising only `ping`, and `run` for a
known token:

```python
from flask import Flask, request
app = Flask(__name__)

@app.post("/authz")
def authz():
    ctx = request.get_json(force=True, silent=True) or {}
    if ctx.get("action") in ("ping", "discovery"):
        return "", 200
    if ctx.get("action") == "run" and ctx.get("token") == "s3cr3t":
        return "", 200
    if not ctx.get("token"):
        return "", 401          # bad credentials
    return "", 403              # known but not permitted
```

Point the hook at it:

```bash
REST_QUERY_URL=http://127.0.0.1:8000/authz \
  ctrl-exec-api          # or the agent / dispatcher that uses the hook
```

## Limitations

- **Adds a network round-trip per request.** Keep the endpoint fast and local;
  tune `REST_QUERY_TIMEOUT`. A slow endpoint slows every operation.
- **Fail-closed only.** By design, any error denies. There is no fail-open mode;
  if you need availability over strictness, that belongs in your endpoint, not
  here.
- **Transport security is yours.** The context (including the token) is sent to
  `REST_QUERY_URL`. Use HTTPS or a localhost/loopback endpoint; do not point it
  at an untrusted network.
- **No response body parsing.** Only the HTTP status drives the decision - the
  endpoint cannot return a reason string to the caller. Richer policy output, if
  needed, should be logged by the endpoint itself.
