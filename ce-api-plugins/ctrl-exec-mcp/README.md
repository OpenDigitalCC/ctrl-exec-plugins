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
protocol core, the MCP lifecycle (`initialize`), the stdio transport, and a
discovery-backed tool catalogue: `tools/list` reflects the live fleet, with
one tool per script synthesised from `GET /discovery` and grouped by schema
version (a script split across versions appears as `name@<version>` tools, each
scoped to the hosts running that version). `/run`-backed execution and the
Streamable HTTP transport land in subsequent commits (see *Limitations*).

## Dependencies

- Perl 5 with core modules only: `JSON::PP`, `HTTP::Tiny`, `FindBin`.
- A reachable `ctrl-exec-api` endpoint (default `http://localhost:7445`).

No CPAN modules are required.

## Installation

Copy the plugin directory to the control host and run the entry point as the
MCP server command. It needs no build step.

```bash
cp -r ce-api-plugins/ctrl-exec-mcp /opt/ctrl-exec-mcp
/opt/ctrl-exec-mcp/ctrl-exec-mcp        # speaks MCP over stdio
```

Most MCP clients launch the server themselves as a subprocess; point the client
at the `ctrl-exec-mcp` path (see *Examples*).

## Configuration

Configuration is supplied by the operator through environment variables; no
credentials are committed.

| Variable | Default | Purpose |
| --- | --- | --- |
| `CTRLEXEC_API_URL` | `http://localhost:7445` | Base URL of `ctrl-exec-api`. |
| `CTRLEXEC_TOKEN` | (none) | Auth token forwarded to the API for the auth hook. |

Host lists and script names are never hardcoded: they are discovered at runtime
from the API (`GET /discovery`). The bridge transports the operator-supplied
token to `/run`; ctrl-exec's auth hook remains the single policy point.

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

## Limitations

- **Scope: MCP tools only.** Resources, prompts, and sampling are not exposed.
- **Build status.** The protocol core, stdio transport, and discovery-backed
  tool catalogue are in place. `/run`-backed execution over the async path, the
  Streamable HTTP transport, per-call argument validation, and proactive
  `tools/list_changed` notifications are added in later commits; until
  execution lands, `tools/call` returns an error result. `tools/list` re-queries
  discovery on each call, so it stays current without a restart.
- **Long-running jobs.** Once execution is wired, `tools/call` dispatches via
  the ctrl-exec async path (`POST /run` with `async`, then poll
  `GET /status/{reqid}`) so calls are not bound by the API read timeout; the
  client blocks on the call while the bridge polls.
- **Identity.** The bridge performs no access control of its own; an
  unauthenticated transport (e.g. stdio on a shared host) inherits whatever the
  operator's `CTRLEXEC_TOKEN` permits. Protect the API and the token
  accordingly.
