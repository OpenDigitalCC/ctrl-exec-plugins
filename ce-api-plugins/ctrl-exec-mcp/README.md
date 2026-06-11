---
title: ctrl-exec-plugins - ctrl-exec-mcp
subtitle: A Model Context Protocol server bridging LLM agents to the ctrl-exec API
brand: odcc
---

# ctrl-exec-mcp

## Purpose

`ctrl-exec-mcp` exposes a ctrl-exec fleet to an MCP client (such as an LLM
agent) as a set of tools. Each allowlisted script becomes a tool; the client can
discover the available scripts and invoke them - but only ever the scripts an
operator has allowlisted, with the arguments an operator has described.

This is the security property that makes the bridge worthwhile: the **allowlist
and the per-script schema constrain the callable surface**. The model cannot
invent operations - it can only select an operator-approved script and fill
operator-defined argument fields. Identity is enforced by ctrl-exec's own auth
hook; the bridge adds no policy of its own, it only translates protocols.

```
MCP client  <--JSON-RPC-->  ctrl-exec-mcp  <--HTTP-->  ctrl-exec-api  -->  agents
(LLM agent)   stdio/HTTP     (this plugin)   mTLS-fronted    fleet
```

The bridge is a thin, stateless translation layer that runs on the control host
and consumes `ctrl-exec-api`. It speaks MCP over both **stdio** (the client
launches it as a subprocess) and **Streamable HTTP** (a networked endpoint).
`tools/list` reflects the live fleet; `tools/call` validates its arguments,
dispatches the run asynchronously, and polls for the result so a long-running
script is not bound by the API read timeout.

## Dependencies

- Perl 5 with core modules only: `JSON::PP`, `HTTP::Tiny`, `FindBin`, `POSIX`.
  No CPAN modules.
- A reachable `ctrl-exec-api` (default `http://localhost:7445`) with at least one
  paired agent that has scripts in its allowlist - the tools the bridge exposes
  are exactly those scripts. With no reachable API or no allowlisted scripts, the
  bridge runs but advertises an empty tool list.

## Installation

Copy the plugin directory to the control host. There is no build step.

```bash
cp -r ce-api-plugins/ctrl-exec-mcp /opt/ctrl-exec-mcp
```

**Prerequisites.** Before connecting a client, confirm the API is reachable and
returns the scripts you expect:

```bash
curl -s http://localhost:7445/discovery | python3 -m json.tool   # hosts + scripts
```

If `hosts` is empty, pair an agent and add scripts to its `scripts.conf` first
(see the ctrl-exec `REFERENCE.md`). The bridge surfaces whatever discovery
returns.

Run it directly to check it starts:

```bash
/opt/ctrl-exec-mcp/ctrl-exec-mcp                                    # stdio (default)
CTRLEXEC_MCP_HTTP=127.0.0.1:7446 /opt/ctrl-exec-mcp/ctrl-exec-mcp   # Streamable HTTP
```

Most MCP clients launch the stdio form themselves as a subprocess; point the
client at the `ctrl-exec-mcp` path (see *Examples*). For networked clients, run
the HTTP form behind a reverse proxy that terminates TLS.

## Configuration

Configuration is by environment variable; no credentials are committed.

| Variable | Default | Purpose |
| --- | --- | --- |
| `CTRLEXEC_API_URL` | `http://localhost:7445` | Base URL of `ctrl-exec-api`. |
| `CTRLEXEC_TOKEN` | (none) | Auth token for the **stdio** transport (the operator's identity). |
| `CTRLEXEC_TIMEOUT` | `300` | Seconds to poll an async run before giving up. |
| `CTRLEXEC_MCP_HTTP` | (unset) | If set to `[host:]port`, serve Streamable HTTP instead of stdio. |
| `CTRLEXEC_MCP_REFRESH` | `0` | stdio only: poll discovery every N seconds and push `tools/list_changed` when the tool set changes (`0` = off). |

Host lists and script names are never hardcoded; they are discovered at runtime.
**Identity flows from the transport to the API:** on stdio the bridge forwards
`CTRLEXEC_TOKEN` as the single operator identity; on HTTP each session is bound
to the token from its `Authorization: Bearer` header, so the HTTP client's own
identity is forwarded. Either way ctrl-exec's auth hook remains the single policy
point - the bridge adds no access control of its own.

To make a script appear as a *typed* tool (named, documented arguments), give it
a schema sidecar on the agent - see *How scripts become tools* below.

## How scripts become tools

On each `tools/list` the bridge calls `GET /discovery`, then synthesises tools:

- **One tool per allowlisted script.** The tool name is the script name.
- **Untyped by default.** A script with no schema sidecar becomes a tool that
  takes `hosts` (which agents to run on) and `args` (a positional string array):

  ```json
  { "name": "env-dump",
    "inputSchema": { "type": "object", "properties": {
      "hosts": { "type": "array", "items": { "type": "string", "enum": ["web-01","web-02"] } },
      "args":  { "type": "array", "items": { "type": "string" } } } } }
  ```

- **Typed when the script has a schema sidecar.** To implement a typed tool, drop
  a `<script>.schema.json` file next to the script on the agent (the agent
  advertises it via discovery). Given
  `/opt/ctrl-exec-scripts/check-disk.sh.schema.json`:

  ```json
  { "version": "2",
    "description": "Check disk usage against a threshold",
    "read_only": true,
    "arguments": { "type": "object",
      "properties": { "threshold": { "type": "integer", "minimum": 1, "maximum": 100 } } },
    "argv": [ { "arg": "threshold" } ] }
  ```

  the bridge exposes a typed tool - the `arguments` become the tool's named
  inputs, `description` and the `read_only`/`destructive`/`idempotent` flags
  become the tool description and MCP annotations, and `argv` maps the named
  inputs onto the script's positional arguments. The full sidecar format,
  version rule, and security properties are documented in the ctrl-exec
  repository at
  [`docs/SCHEMA-SIDECAR.md`](https://github.com/OpenDigitalCC/ctrl-exec/blob/main/docs/SCHEMA-SIDECAR.md).

- **Versioned across the fleet.** If the same script carries different schema
  versions on different hosts, it splits into `name@<version>` tools, each scoped
  (via its `hosts` enum) to the hosts running that version, so drift is visible
  rather than silently merged.

`hosts` is optional on every tool: omit it to target all hosts running that
tool's version, or pass a subset (it is validated against the tool's host set).

## Examples

**Connect an MCP client over stdio** (e.g. Claude Desktop) - the client launches
the bridge as a subprocess:

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

**A full tools/call.** Having listed tools, the client invokes one by name with
the arguments the schema declares (`hosts` plus the named inputs):

```jsonc
// --> request
{ "jsonrpc": "2.0", "id": 5, "method": "tools/call",
  "params": { "name": "check-disk", "arguments": { "hosts": ["web-01"], "threshold": 90 } } }

// <-- response: per-host outcome as text, with structuredContent for machines
{ "jsonrpc": "2.0", "id": 5, "result": {
    "content": [ { "type": "text", "text": "Request a1b2...\n[web-01] done (exit 0)\nOK: disk usage 42%" } ],
    "isError": false,
    "structuredContent": { "reqid": "a1b2...", "complete": true,
      "hosts": { "web-01": { "status": "done", "exit": 0, "stdout": "OK: disk usage 42%\n", "stderr": "" } } } } }
```

`isError` is set only on total failure (no host succeeded, a dispatch error, or
a timeout); a partial success returns `isError: false` with the failing hosts
shown in the text and `structuredContent`.

**Drive stdio by hand** for a quick check - one JSON-RPC message per line:

```bash
printf '%s\n%s\n%s\n' \
  '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}' \
  '{"jsonrpc":"2.0","method":"notifications/initialized"}' \
  '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' \
  | CTRLEXEC_TOKEN=operator-token ./ctrl-exec-mcp
```

**Streamable HTTP.** `initialize` returns an `Mcp-Session-Id` header that
subsequent requests must carry; the `Authorization` token is the caller's
ctrl-exec identity:

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

## Troubleshooting

- **No tools listed.** The bridge surfaces whatever `GET /discovery` returns.
  Check the API is reachable (`curl $CTRLEXEC_API_URL/discovery`), that an agent
  is paired with scripts in its allowlist, and that the token is authorised - the
  auth hook can deny discovery, yielding an empty list.
- **A tool is untyped (just `args`).** That script has no schema sidecar; add one
  on the agent (see *How scripts become tools*).
- **`tools/call` returns `isError` with "Invalid arguments".** The arguments
  failed the tool's schema or named a host outside the tool's set; the message
  lists each problem. Fix the arguments and retry.
- **HTTP request returns 404.** The session expired or the `Mcp-Session-Id`
  header is missing; send `initialize` again to mint a new session.
- **A long run never returns.** It exceeded `CTRLEXEC_TIMEOUT`; raise it, or run
  the script faster. The agent keeps running the job regardless (ctrl-exec async).

## Architecture

The bridge is a handful of small Perl modules under `lib/CtrlExecMCP/` plus the
`ctrl-exec-mcp` entry point. The design separates the MCP protocol core from the
ctrl-exec backends behind two injected seams (a *catalogue* and a *runner*), so
the protocol is testable in isolation and the backends are swappable.

| Component | Responsibility |
| --- | --- |
| `ctrl-exec-mcp` | Entry point. Selects the transport (stdio vs HTTP), holds the `build_server($token)` factory, and runs the loops: the stdio `select`/`sysread` loop and the HTTP socket accept loop with minimal HTTP parsing. |
| `CtrlExecMCP::JsonRpc` | JSON-RPC 2.0 framing and the standard error codes. Pure data. |
| `CtrlExecMCP::Server` | The MCP dispatcher: `initialize`, `ping`, `tools/list`, `tools/call`, gated on initialize. Holds an injected catalogue + runner; `poll_list_changed` drives the optional notification. Knows nothing about HTTP or sockets. |
| `CtrlExecMCP::Discovery` | Client for `GET /discovery` → the hosts map. |
| `CtrlExecMCP::Catalog` | Versioned tool synthesis from discovery (`list_tools`/`has_tool`/`tool`/`refresh`) and the tool-name → script/hosts/argv index. |
| `CtrlExecMCP::Api` | Client for async dispatch (`POST /run`) and polling (`GET /status`). |
| `CtrlExecMCP::Runner` | `tools/call` execution: validate, render `argv`, dispatch, poll, shape the per-host result. |
| `CtrlExecMCP::Validate` | The pragmatic JSON Schema subset validator. |
| `CtrlExecMCP::Transport::Http` | Streamable HTTP sessions and the per-client `Authorization: Bearer` → token identity mapping. |

**Request lifecycle.** A transport reads a JSON-RPC message and calls
`Server->handle($msg)`. `tools/list` asks the catalogue (which re-queries
discovery and synthesises tools); `tools/call` hands off to the runner, which
validates the arguments, renders the script's `argv`, dispatches via the API
async path, polls `/status`, and shapes the result. The transport writes the
response back. On HTTP, each session gets its own `Server` (and thus its own
catalogue/runner) wired to that client's token by `build_server`.

**Seams for extension.**

- Add an MCP method by adding a branch in `Server->handle`.
- Change how scripts map to tools by editing `Catalog` (synthesis) - the rest is
  unaffected.
- Support another transport by writing one that reads messages and calls
  `Server->handle`; the protocol core is transport-agnostic.
- The catalogue, runner, HTTP agents (`Discovery`/`Api`), and the runner's clock
  and sleep are all injected, which is how the test suite exercises every path
  without networking or waiting.

**Tests.** `t/` mirrors `lib/`, one file per module, each using fakes for the
injected collaborators. Run them with:

```bash
prove -Ilib t/
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
  (it would need the optional server->client SSE stream, which this transport
  does not implement); HTTP clients should re-list as needed. The advertised
  `listChanged` capability reflects this per transport.
- **HTTP concurrency.** The HTTP transport is single-process and sequential
  (sessions live in memory, so it must not fork); a long-running `tools/call`
  blocks other requests while it polls. Suitable for one or a few clients. There
  is no built-in TLS - terminate TLS at a reverse proxy.
- **Argument validation.** `tools/call` checks the requested hosts against the
  tool's host set and validates the named arguments against the tool's schema
  (types, enum/const, required, numeric and length bounds, array items, closed
  objects) before dispatch, failing fast with a clear message. This is a
  pragmatic JSON Schema subset, not a full validator; the agent's allowlist and
  auth hook remain the authoritative controls regardless.
- **Identity.** The bridge performs no access control of its own; an
  unauthenticated transport (e.g. stdio on a shared host) inherits whatever the
  operator's `CTRLEXEC_TOKEN` permits. Protect the API and the token accordingly.
