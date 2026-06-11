---
title: ctrl-exec-plugins - insomnia
subtitle: Insomnia collection for the ctrl-exec HTTP API
brand: odcc
---

# insomnia

## Purpose

`insomnia` is a ready-to-import [Insomnia](https://insomnia.rest/) collection
(v4 export) for the ctrl-exec HTTP API, for teams where Insomnia is the
established HTTP tool.

**What it gives you:** the same endpoint coverage as the `postman` and `bruno`
plugins - `health`, `ping`, `discovery`, synchronous `run`, asynchronous `run`,
and `status` - with a Base environment for the base URL, token, and target
host/script. Import it and you have an organised workspace to explore and call
the API in the client your team already uses.

## Dependencies

- The [Insomnia](https://insomnia.rest/) app, or the `inso` CLI for headless
  runs.
- A reachable `ctrl-exec-api`.

## Installation

In Insomnia: *Import* → *From File* → `ctrl-exec.insomnia.json`. This creates a
**ctrl-exec** collection with a **Base** environment. Select the environment and
fill in your values (see *Configuration*).

## Configuration

Edit the **Base** environment (or duplicate it per deployment):

| Variable | Purpose |
| --- | --- |
| `baseUrl` | API base URL (default `http://localhost:7445`). |
| `token` | Auth token forwarded to the API. |
| `host` | Target agent hostname used by `ping` and `run`. |
| `script` | Allowlisted script name used by `run`. |
| `reqid` | Used by `Status`; set it after an async run. |

Host and script names are not hardcoded in the requests - they come from the
environment. Use the `Discovery` request to find the real values at runtime.

## Examples

1. **Discovery** - see which hosts and scripts exist; set `host`/`script`.
2. **Run (async)** - submit; the response is `202` with a `reqid`.
3. **Status** - put that `reqid` in the environment (or reference the async
   response) and send; re-send to poll until `complete` is `true`.

## Limitations

- **Requires Insomnia.** This is an Insomnia v4 export, not an OpenAPI spec or a
  Postman/Bruno collection (see those plugins, or the `/openapi.json` endpoint).
- **Manual reqid for Status.** Unlike the `postman` and `bruno` collections,
  this one does not auto-capture the async `reqid` into the environment (that
  needs an Insomnia plugin or a response reference); copy it across by hand, or
  use the `ctrl-exec-cli` `wait` command for scripted polling.
- **No embedded credentials.** The committed environment leaves `token` blank -
  fill it locally; do not commit real secrets.
