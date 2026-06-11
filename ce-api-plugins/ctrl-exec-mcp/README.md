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

This plugin is built incrementally. It currently provides the JSON-RPC 2.0
protocol core, the MCP lifecycle (`initialize`), the stdio transport, a
discovery-backed tool catalogue, and `/run`-backed execution. `tools/list`
reflects the live fleet, with one tool per script synthesised from
`GET /discovery` and grouped by schema version (a script split across versions
appears as `name@<version>` tools, each scoped to the hosts running that
version). `tools/call` dispatches asynchronously and polls for the result, so a
long-running script is not bound by the API read timeout. The Streamable HTTP
transport lands in a subsequent commit (see *Limitations*).

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
- **Build status.** The protocol core, the stdio and Streamable HTTP transports,
  the discovery-backed tool catalogue, and `/run`-backed execution are in place.
  Per-call argument validation against the tool schema and proactive
  `tools/list_changed` notifications are added in a later commit. `tools/list`
  re-queries discovery on each call, so it stays current without a restart.
- **HTTP concurrency.** The HTTP transport is single-process and sequential
  (sessions live in memory, so it must not fork); a long-running `tools/call`
  blocks other requests while it polls. Suitable for one or a few clients. There
  is no built-in TLS — terminate TLS at a reverse proxy.
- **Argument handling.** `tools/call` validates only that requested hosts are in
  the tool's set; full validation of the named arguments against the schema is a
  later commit. The agent's allowlist and auth hook remain the authoritative
  controls regardless.
- **Long-running jobs.** `tools/call` dispatches via the ctrl-exec async path
  (`POST /run` with `async`, then poll `GET /status/{reqid}`) so calls are not
  bound by the API read timeout; the client blocks on the call while the bridge
  polls, up to `CTRLEXEC_TIMEOUT`.
- **Identity.** The bridge performs no access control of its own; an
  unauthenticated transport (e.g. stdio on a shared host) inherits whatever the
  operator's `CTRLEXEC_TOKEN` permits. Protect the API and the token
  accordingly.
