---
title: ctrl-exec-plugins - bruno
subtitle: Bruno API collection for the ctrl-exec HTTP API
brand: odcc
---

# bruno

## Purpose

`bruno` is a ready-to-run [Bruno](https://www.usebruno.com/) collection for the
ctrl-exec HTTP API. Bruno is an open-source API client (a Postman alternative)
whose collections are **plain-text `.bru` files that live in git** - no binary
export, no cloud account, clean diffs.

**What it gives you:** a working, version-controlled set of requests covering
every endpoint - `health`, `ping`, `discovery`, synchronous `run`, asynchronous
`run`, and `status` - with an environment template for the base URL, token, and
target host/script. The async request even captures the returned `reqid` into
the environment automatically, so the `Status` request can poll it with one
click. It is the fastest way for someone to start *calling* the API (rather than
just reading it), and because it commits as text, the collection evolves with
the API in the same repo.

## Dependencies

- The [Bruno](https://www.usebruno.com/) desktop app, or `@usebruno/cli` (`bru`)
  for headless/CI runs.
- A reachable `ctrl-exec-api`.

## Installation

Open the collection in Bruno:

- **Desktop:** *Open Collection* → select this `bruno/` directory.
- **CLI:** `cd` into this directory and run requests with `bru run`.

Then select the **Local** environment and fill in your values (see
*Configuration*).

## Configuration

Environment variables live in `environments/Local.bru`; edit them or duplicate
the file for other deployments:

| Variable | Purpose |
| --- | --- |
| `baseUrl` | API base URL (default `http://localhost:7445`). |
| `token` | Auth token forwarded to the API for the auth hook. |
| `host` | Target agent hostname used by `ping` and `run`. |
| `script` | Allowlisted script name used by `run`. |
| `reqid` | Set automatically by `Run (async)`; used by `Status`. |

Host and script names are **not** hardcoded in the requests - they come from the
environment. Discover the real values at runtime with the `Discovery` request.

## Examples

A typical async flow, entirely in Bruno:

1. **Discovery** - see which hosts and scripts exist; set `host` and `script` in
   the environment accordingly.
2. **Run (async)** - submit the job; the response is `202` with a `reqid`, which
   the request's post-response script stores into the `reqid` variable.
3. **Status** - fetch the result; re-send to poll until `complete` is `true`.

Headless (CI) run of a single request:

```bash
bru run "Run (async).bru" --env Local
```

## Limitations

- **Requires Bruno.** The `.bru` format is Bruno's; it is not a Postman or
  OpenAPI file. (For those, see the `postman` / `insomnia` collections and the
  `openapi.json` endpoint.)
- **Manual polling.** `Status` is re-sent by hand (or scripted) to poll an async
  run; there is no built-in wait loop. The `ctrl-exec-cli` plugin's `wait`
  command does that for scripting.
- **No embedded credentials.** The committed environment leaves `token` blank by
  design - fill it locally and do not commit real secrets.
