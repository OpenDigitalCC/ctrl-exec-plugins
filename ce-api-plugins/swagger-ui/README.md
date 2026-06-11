---
title: ctrl-exec-plugins - swagger-ui
subtitle: Swagger UI browser interface for the ctrl-exec API
brand: odcc
---

# swagger-ui

## Purpose

`swagger-ui` is a single HTML file that renders the ctrl-exec API as an
interactive [Swagger UI](https://swagger.io/tools/swagger-ui/) page in any
browser. It points at the API's **live** spec (`/openapi-live.json`), so it
lists the current registered hosts and their scripts, and shows the typed
per-script arguments carried in `x-ctrl-exec-scripts` for scripts that ship a
schema sidecar.

**What it gives you:** the same zero-install, always-current console as the
`rapidoc` plugin, but in Swagger UI - the OpenAPI interface most developers
recognise on sight. If your operators already know Swagger UI from other APIs,
this is the lowest-friction way to give them a browsable, try-it-out view of
ctrl-exec: read every endpoint, expand `/run` to see the live host/script enums,
fill the form, and execute against the API. It is interchangeable with `rapidoc`
and `redoc`; pick whichever your team prefers.

## Dependencies

- A web browser.
- A reachable `ctrl-exec-api` serving `/openapi-live.json`.
- Internet access **at view time** to fetch Swagger UI from the CDN - or vendor
  the assets locally (see *Installation*).

No build step, no server-side component beyond the API.

## Installation

Serve `index.html` from anywhere a browser can reach. The CORS-free option is to
serve it from the **same origin** as the API (e.g. behind the reverse proxy that
fronts `ctrl-exec-api`), so the default same-origin `/openapi-live.json` works:

```
https://ctrl-exec.example/            -> index.html  (this plugin)
https://ctrl-exec.example/openapi-live.json  -> the API
```

Or open `index.html` from disk and pass the spec URL as a query string (requires
CORS on the API). **Offline / air-gapped:** download `swagger-ui.css` and
`swagger-ui-bundle.js` and replace the CDN URLs with local paths.

## Configuration

The spec URL is resolved at load time:

- Default: same-origin `/openapi-live.json`.
- Override: `index.html?spec=https://ctrl-exec.example:7445/openapi-live.json`.

Use `/openapi.json` for the static spec (no live host/script enumeration).
Display options (deep linking, try-it) are set in the `SwaggerUIBundle({...})`
call in `index.html`.

## Examples

Same-origin (no query string):

```
https://ctrl-exec.example/
```

Local file against a remote API (needs CORS on the API):

```
file:///path/to/index.html?spec=https://ctrl-exec.example:7445/openapi-live.json
```

From the page: browse all endpoints; expand `POST /run` to see the live `script`
enum and per-script argument schemas; "Try it out" to run a `ping` or `run`.

## Limitations

- **CORS.** Cross-origin spec fetch and try-it calls are blocked unless the API
  (or its proxy) sends CORS headers. Serving same-origin avoids this - the
  recommended deployment.
- **Authentication.** Supply whatever the auth hook expects via Swagger UI's
  Authorize control (e.g. a bearer token); the page applies no policy of its
  own. Treat the console as privileged.
- **CDN dependency.** Defaults to CDN-hosted assets; vendor them for offline use.
- **Live spec cost.** `/openapi-live.json` queries the fleet on each load; use
  `/openapi.json` if you only need the static reference.
