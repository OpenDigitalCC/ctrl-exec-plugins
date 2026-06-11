---
title: ctrl-exec-plugins - rapidoc
subtitle: Single-file browser interface to the ctrl-exec API
brand: odcc
---

# rapidoc

## Purpose

`rapidoc` is a single HTML file that renders the ctrl-exec API as a browsable,
try-it-out interface in any web browser, using the [RapiDoc](https://rapidocweb.com/)
OpenAPI web component. It points at the API's **live** spec
(`/openapi-live.json`), so it shows the *current* fleet: the real list of
registered hosts, the scripts available on them, and - because the live spec
now carries `x-ctrl-exec-scripts` - the typed arguments of any script that ships
a schema sidecar.

**What it gives you:** zero-install, always-current API documentation that
doubles as an operator console. An operator can read every endpoint, see which
hosts and scripts exist right now, fill in a form, and execute `ping`, `run`, or
`discovery` against the live API - no `curl`, no Postman, no build step. It is
the fastest way to make the API approachable to someone who has never seen it,
and a handy day-to-day console for those who have.

## Dependencies

- A web browser.
- A reachable `ctrl-exec-api` serving `/openapi-live.json` (and `/openapi.json`).
- Internet access **at view time** to fetch the RapiDoc component from the CDN -
  or vendor it locally for offline/air-gapped use (see *Installation*).

No build step and no server-side component beyond the API itself.

## Installation

Serve `index.html` from anywhere a browser can reach it. The simplest and
CORS-free option is to serve it from the **same origin** as the API (e.g. behind
the reverse proxy that already fronts `ctrl-exec-api`), so the default
same-origin `/openapi-live.json` just works:

```
https://ctrl-exec.example/            -> index.html  (this plugin)
https://ctrl-exec.example/openapi-live.json  -> the API
```

Or open `index.html` directly from disk and pass the spec URL as a query string
(see *Configuration*) - this requires CORS to be enabled on the API.

**Offline / air-gapped:** download `rapidoc-min.js` and replace the CDN
`<script src=...>` with a local path, then ship the JS alongside `index.html`.

## Configuration

The spec URL is resolved at load time:

- Default: same-origin `/openapi-live.json`.
- Override with a `spec` query parameter:
  `index.html?spec=https://ctrl-exec.example:7445/openapi-live.json`.

Point it at `/openapi.json` instead for the static spec (no live host/script
enumeration). Theme, layout, and the try-it toggle are RapiDoc attributes on the
`<rapi-doc>` element in `index.html`; edit them to taste.

## Examples

Same-origin (no query string needed):

```
https://ctrl-exec.example/
```

Local file pointing at a remote API (needs CORS on the API):

```
file:///path/to/index.html?spec=https://ctrl-exec.example:7445/openapi-live.json
```

From the interface you can: read the full endpoint reference; expand `/run` and
see the live `script` enum and per-script argument schemas; fill the form and
execute a `ping` or a `run`; and copy the equivalent `curl` for scripting.

## Limitations

- **CORS.** When `index.html` and the API are on different origins, the browser
  blocks the spec fetch and the try-it calls unless the API (or its proxy) sends
  CORS headers. Serving the file same-origin avoids this entirely - the
  recommended deployment.
- **Authentication.** RapiDoc can send a token with try-it requests, but it has
  no special handling for the ctrl-exec auth hook; supply whatever the hook
  expects (e.g. a bearer token / the `token` field) via RapiDoc's auth controls.
  Treat the console as privileged - anyone who can reach it can attempt calls.
- **CDN dependency.** The default loads RapiDoc from a CDN; vendor it for offline
  use. No data leaves the browser to the CDN beyond fetching the script asset.
- **Live spec cost.** `/openapi-live.json` queries the fleet on each load; on a
  large fleet that is a real (if infrequent) cost. Use `/openapi.json` if you
  only need the static reference.
