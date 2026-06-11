---
title: ctrl-exec-plugins - redoc
subtitle: ReDoc reference documentation for the ctrl-exec API
brand: odcc
---

# redoc

## Purpose

`redoc` is a single HTML file that renders the ctrl-exec API as clean,
three-panel **reference documentation** using [ReDoc](https://github.com/Redocly/redoc).
Unlike `rapidoc` and `swagger-ui`, it is **read-only**: no try-it execution, no
live host/script enumeration. It points at the static `/openapi.json`.

**What it gives you:** publishable, professional API reference - the kind you put
on a docs site, an internal wiki, or a developer portal so people can read and
understand the API without a running server in front of them. It pairs well with
the interactive consoles: use `rapidoc`/`swagger-ui` for hands-on exploration
against a live API, and `redoc` for stable, link-shareable documentation. One
file, no build, nothing to execute - safe to host anywhere.

## Dependencies

- A web browser.
- The static spec at `/openapi.json` (or any OpenAPI spec URL you point it at).
- Internet access **at view time** to fetch the ReDoc bundle from the CDN - or
  vendor it locally (see *Installation*).

No build step, no server-side component.

## Installation

Serve `index.html` from any static host - a docs site, an object store, an
internal wiki, or behind the API's reverse proxy. With the default same-origin
`/openapi.json`, place it alongside the API:

```
https://ctrl-exec.example/reference/   -> index.html  (this plugin)
https://ctrl-exec.example/openapi.json -> the API spec
```

To document a fixed spec on a site separate from the API, pass an absolute spec
URL (see *Configuration*) and ensure CORS allows it, or vendor a copy of the
spec next to the HTML. **Offline:** download `redoc.standalone.js` and replace
the CDN URL with a local path.

## Configuration

The spec URL is resolved at load time:

- Default: `/openapi.json` (the static spec - stable, fast, no fleet query).
- Override: `index.html?spec=https://ctrl-exec.example/openapi.json`, or
  `?spec=/openapi-live.json` to document the live spec (with host/script enums
  and `x-ctrl-exec-scripts`).

ReDoc options can be passed in the `Redoc.init(spec, {...}, ...)` call in
`index.html`.

## Examples

Same-origin static reference:

```
https://ctrl-exec.example/reference/
```

Document the live spec instead:

```
https://ctrl-exec.example/reference/?spec=/openapi-live.json
```

## Limitations

- **Read-only.** No request execution. For an interactive console use `rapidoc`
  or `swagger-ui`.
- **Static spec by default.** `/openapi.json` does not include live host/script
  enumeration or `x-ctrl-exec-scripts`; point it at `/openapi-live.json` if you
  need those (at the cost of a fleet query per load and a CORS requirement when
  cross-origin).
- **CDN dependency.** Defaults to the CDN-hosted bundle; vendor it for offline or
  air-gapped publishing.
