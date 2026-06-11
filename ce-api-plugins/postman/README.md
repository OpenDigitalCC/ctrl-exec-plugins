---
title: ctrl-exec-plugins - postman
subtitle: Postman collection for the ctrl-exec HTTP API
brand: odcc
---

# postman

## Purpose

`postman` is a ready-to-import [Postman](https://www.postman.com/) collection and
environment for the ctrl-exec HTTP API. Postman is the most widely used API
client, so this is the fastest way for the largest number of people to start
*calling* ctrl-exec.

**What it gives you:** every endpoint as a worked request - `health`, `ping`,
`discovery`, synchronous `run`, asynchronous `run`, and `status` - plus an
environment template for the base URL, token, and target host/script. The async
request runs a test script that captures the returned `reqid` into the
environment, so the `Status` request polls it with one click. Import, fill in the
environment, and you have an interactive, shareable workspace for the API; it
also runs headless in CI via `newman`.

## Dependencies

- The [Postman](https://www.postman.com/) app, or `newman` for headless/CI runs.
- A reachable `ctrl-exec-api`.

## Installation

Import both files into Postman:

- *Import* → `ctrl-exec.postman_collection.json`
- *Import* → `ctrl-exec.postman_environment.json`

Select the **ctrl-exec Local** environment and fill in your values (see
*Configuration*).

For CI / headless runs:

```bash
newman run ctrl-exec.postman_collection.json -e ctrl-exec.postman_environment.json
```

## Configuration

Edit the **ctrl-exec Local** environment (or duplicate it per deployment):

| Variable | Purpose |
| --- | --- |
| `baseUrl` | API base URL (default `http://localhost:7445`). |
| `token` | Auth token forwarded to the API (marked secret). |
| `host` | Target agent hostname used by `ping` and `run`. |
| `script` | Allowlisted script name used by `run`. |
| `reqid` | Set automatically by `Run (async)`; used by `Status`. |

Host and script names are not hardcoded in the requests - they come from the
environment. Use the `Discovery` request to find the real values at runtime.

## Examples

A full async flow inside Postman:

1. **Discovery** - see which hosts and scripts exist; set `host`/`script`.
2. **Run (async)** - submit; the response is `202` + `reqid`, captured by the
   request's test script.
3. **Status** - fetch the result; re-send to poll until `complete` is `true`.

## Limitations

- **Requires Postman/newman.** This is a Postman collection, not an OpenAPI file
  (for that, use the `/openapi.json` endpoint or the `rapidoc`/`swagger-ui`
  plugins) and not a Bruno/Insomnia collection (see those plugins).
- **Manual polling.** `Status` is re-sent to poll an async run; there is no wait
  loop. The `ctrl-exec-cli` plugin's `wait` command does that for scripting.
- **No embedded credentials.** The committed environment leaves `token` blank -
  fill it locally; do not commit real secrets.
