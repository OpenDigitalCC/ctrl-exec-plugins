---
title: ctrl-exec-plugins - ce-api-plugins
subtitle: Interfaces and clients for the ctrl-exec HTTP API
brand: odcc
---

# ce-api-plugins

Tools and interfaces for operators and systems that interact with ctrl-exec
via its HTTP API or CLI. This includes browser-based API interfaces, client
libraries, collection files for HTTP tools, and CLI wrappers.


## How the API works

`ctrl-exec-api` exposes the run, ping, discovery, and status operations as
HTTP endpoints with JSON request and response bodies. It listens on port
7445 by default.

The core endpoints are:

```
GET  /                    Index of all endpoints
GET  /health              Liveness check
POST /ping                Test connectivity to one or more agents
POST /run                 Run an allowlisted script on one or more agents
GET  /status/{reqid}      Retrieve the stored result for a completed run
GET  /discovery           List all registered agents and their scripts
GET  /openapi.json        Static OpenAPI 3.1 specification
GET  /openapi-live.json   Live spec augmented with discovered hosts and scripts
```

A full endpoint reference is in `API.md` in the ctrl-exec repository. The
OpenAPI spec served at `/openapi.json` is the authoritative interface
definition.


## Interface contract

All ce-api-plugins plugins consume the ctrl-exec HTTP API as documented in
`openapi.json` and `API.md`. The base URL, credentials, and TLS settings
are provided by the operator at deployment time.

Plugins must not embed assumptions about hostnames or script names. These
are discovered at runtime via `GET /` and `GET /openapi-live.json`, which
return the live set of registered hosts and available scripts.


## Example: calling the API directly

```bash
# Liveness check
curl -s http://localhost:7445/health

# Ping a host
curl -s -X POST http://localhost:7445/ping \
  -H 'Content-Type: application/json' \
  -d '{"hosts": ["web-01"], "token": "mytoken"}'

# Run a script
curl -s -X POST http://localhost:7445/run \
  -H 'Content-Type: application/json' \
  -d '{
    "hosts":  ["web-01", "db-01"],
    "script": "check-disk",
    "token":  "mytoken"
  }'

# Run with arguments
curl -s -X POST http://localhost:7445/run \
  -H 'Content-Type: application/json' \
  -d '{
    "hosts":  ["db-01"],
    "script": "backup-mysql",
    "args":   ["--database", "myapp"],
    "token":  "mytoken"
  }'

# List all agents and their scripts
curl -s http://localhost:7445/discovery

# Retrieve a stored run result
curl -s http://localhost:7445/status/a1b2c3d4
```

The `reqid` field in a `/run` response matches the `REQID` in syslog on both
the ctrl-exec dispatcher and the agent. Use it to correlate API responses with
log entries:

```bash
grep REQID=a1b2c3d4 /var/log/syslog
```


## Example: async pattern

Long-running scripts should use the async pattern to avoid HTTP timeouts.
Submit the job, note the top-level `reqid`, then poll for the result:

```bash
# Submit
REQID=$(curl -s -X POST http://localhost:7445/run \
  -H 'Content-Type: application/json' \
  -d '{"hosts": ["db-01"], "script": "backup-mysql", "token": "mytoken"}' \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['reqid'])")

# Poll until complete
curl -s "http://localhost:7445/status/${REQID}"
```

Results are retained for 24 hours after the run completes. Poll at a
reasonable interval - every 5 seconds is appropriate for most scripts.


## TLS and authentication

If TLS is enabled on the API (`api_cert` and `api_key` set in
`ctrl-exec.conf`), clients must trust the CA or present a cert from a
public CA depending on how the server cert was issued.

Authentication is entirely handled by the auth hook configured on the
ctrl-exec host. Manager plugins pass credentials supplied by the operator -
they do not implement their own access control.

For any internet-facing deployment:

- Implement a real auth hook on the ctrl-exec host
- Consider placing the API behind a reverse proxy for TLS termination and
  IP allowlisting
- Restrict `api_port` to localhost if only local clients need access


## Plugin conventions

All ce-api-plugins plugins in this category follow these conventions.

Runtime discovery
: Host lists and script names are retrieved from the live API at runtime,
  not hardcoded. Use `GET /openapi-live.json` or `GET /discovery` for
  enumeration.

No embedded credentials
: Base URL, tokens, and TLS material are provided by the operator via
  configuration, environment variables, or prompts. No credentials appear
  in committed plugin files.

Async awareness
: Plugins that submit `/run` requests document the async pattern and the
  polling strategy for long-running scripts. Include the recommended polling
  interval and timeout strategy.

British English in output and documentation
: Consistent with the ctrl-exec project convention.
