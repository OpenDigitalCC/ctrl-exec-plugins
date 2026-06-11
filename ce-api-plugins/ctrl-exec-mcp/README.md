---
title: ctrl-exec-plugins - ctrl-exec-mcp
subtitle: A Model Context Protocol server bridging LLM agents to the ctrl-exec API
brand: odcc
---

# ctrl-exec-mcp

## Purpose

`ctrl-exec-mcp` exposes a ctrl-exec fleet to an MCP client (such as an LLM
agent) as a set of tools. Each allowlisted script becomes a tool; the agent can
discover the available scripts and invoke them, but only ever the scripts an
operator has allowlisted, with the arguments an operator has described.

This is the security property that makes the bridge worthwhile: the **allowlist
and the per-script schema constrain the callable surface**. The model cannot
invent operations - it can only select an operator-approved script and fill
operator-defined argument fields. Identity is enforced by ctrl-exec's own auth
hook; the bridge adds no policy of its own, it only translates protocols.

The bridge is a thin translation layer: it speaks MCP (JSON-RPC 2.0) to the
client and the ctrl-exec HTTP API to the fleet. It runs on the control host and
consumes `ctrl-exec-api`; it holds no fleet state of its own.

The bridge speaks MCP over both stdio and Streamable HTTP. `tools/list` reflects
the live fleet, with one tool per script synthesised from `GET /discovery` and
grouped by schema version (a script split across versions appears as
`name@<version>` tools, each scoped to the hosts running that version).
`tools/call` validates its arguments against the tool's schema, then dispatches
asynchronously and polls for the result, so a long-running script is not bound
by the API read timeout. See *Limitations* for what is intentionally out of
scope.

## Dependencies

- Perl 5 with core modules only: `JSON::PP`, `HTTP::Tiny`, `FindBin`.
- A reachable `ctrl-exec-api` endpoint (default `http://localhost:7445`).

No CPAN modules are required.

## Installation

Copy the plugin directory to the control host and run the entry point as the
MCP server command. It needs no build step.

```bash
cp -r ce-api-plugins/ctrl-exec-mcp /opt/ctrl-exec-mcp
/opt/ctrl-exec-mcp/ctrl-exec-mcp                       # MCP over stdio (default)
CTRLEXEC_MCP_HTTP=127.0.0.1:7446 /opt/ctrl-exec-mcp/ctrl-exec-mcp   # Streamable HTTP
```

Most MCP clients launch the server themselves as a stdio subprocess; point the
client at the `ctrl-exec-mcp` path (see *Examples*). For networked clients, run
the Streamable HTTP transport and front it with a reverse proxy for TLS.

## Configuration

Configuration is supplied by the operator through environment variables; no
credentials are committed.

| Variable | Default | Purpose |
| --- | --- | --- |
| `CTRLEXEC_API_URL` | `http://localhost:7445` | Base URL of `ctrl-exec-api`. |
| `CTRLEXEC_TOKEN` | (none) | Auth token for the **stdio** transport (the operator's identity). |
| `CTRLEXEC_TIMEOUT` | `300` | Seconds to poll an async run before giving up. |
| `CTRLEXEC_MCP_HTTP` | (unset) | If set to `[host:]port`, serve Streamable HTTP instead of stdio. |
| `CTRLEXEC_MCP_REFRESH` | `0` | stdio only: poll discovery every N seconds and push `tools/list_changed` when the tool set changes (`0` = off). |

Host lists and script names are never hardcoded: they are discovered at runtime
from the API (`GET /discovery`). On **stdio**, the bridge forwards
`CTRLEXEC_TOKEN` as the single operator identity. On **HTTP**, each session is
bound to the token from its `Authorization: Bearer` header, so the HTTP client's
own identity is forwarded to the API. Either way, ctrl-exec's auth hook remains
the single policy point — the bridge adds no access control of its own.

## Examples

Register the server with an MCP client that launches it over stdio. For a
client using a JSON config:

```json
{
  "mcpServers": {
    "ctrl-exec": {
      "command": "/opt/ctrl-exec-mcp/ctrl-exec-mcp",
      "env": {
        "CTRLEXEC_API_URL": "http://localhost:7445",
        "CTRLEXEC_TOKEN": "operator-token"
      }
    }
  }
}
```

The protocol can also be driven by hand for testing - one JSON-RPC message per
line on stdin:

```bash
printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}' \
  | ./ctrl-exec-mcp
```

Over the Streamable HTTP transport, `initialize` returns an `Mcp-Session-Id`
header that subsequent requests must carry; the `Authorization` token becomes
the caller's ctrl-exec identity:

```bash
CTRLEXEC_MCP_HTTP=127.0.0.1:7446 ./ctrl-exec-mcp &

curl -si -X POST http://127.0.0.1:7446/ \
  -H 'Authorization: Bearer my-token' -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}'
# -> 200 with header: Mcp-Session-Id: <id>

curl -s -X POST http://127.0.0.1:7446/ \
  -H 'Mcp-Session-Id: <id>' -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":2,"method":"tools/list"}'
```

## Limitations

- **Scope: MCP tools only.** Resources, prompts, and sampling are not exposed.
- **`tools/list_changed`.** `tools/list` always re-queries discovery, so it is
  current on demand. Proactive `tools/list_changed` push is supported on the
  **stdio** transport only, and is opt-in via `CTRLEXEC_MCP_REFRESH=<seconds>`:
  the server then polls discovery on that interval and notifies the client when
  the synthesised tool set actually changes (a version-label change that does not
  alter the tools is not a change). It is off by default to avoid imposing
  periodic fleet-wide discovery load. The **HTTP** transport does not push
  (it would need the optional server→client SSE stream, which this transport
  does not implement); HTTP clients should re-list as needed. The advertised
  `listChanged` capability reflects this per transport.
- **HTTP concurrency.** The HTTP transport is single-process and sequential
  (sessions live in memory, so it must not fork); a long-running `tools/call`
  blocks other requests while it polls. Suitable for one or a few clients. There
  is no built-in TLS — terminate TLS at a reverse proxy.
- **Argument validation.** `tools/call` checks the requested hosts against the
  tool's host set and validates the named arguments against the tool's schema
  (types, enum/const, required, numeric and length bounds, array items, closed
  objects) before dispatch, failing fast with a clear message. This is a
  pragmatic JSON Schema subset, not a full validator; the agent's allowlist and
  auth hook remain the authoritative controls regardless.
- **Long-running jobs.** `tools/call` dispatches via the ctrl-exec async path
  (`POST /run` with `async`, then poll `GET /status/{reqid}`) so calls are not
  bound by the API read timeout; the client blocks on the call while the bridge
  polls, up to `CTRLEXEC_TIMEOUT`.
- **Identity.** The bridge performs no access control of its own; an
  unauthenticated transport (e.g. stdio on a shared host) inherits whatever the
  operator's `CTRLEXEC_TOKEN` permits. Protect the API and the token
  accordingly.
