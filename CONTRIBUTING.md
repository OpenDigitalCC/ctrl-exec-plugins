---
title: exec-plugins - Contributing
subtitle: Requirements, structure, and validation for plugin submissions
brand: odcc
---

# Contributing

Thank you for considering a contribution. This document covers everything
needed to submit a plugin: structure requirements, category-specific
interface contracts, and how to run the validator before submitting a pull
request.

Read the category README for the category you are contributing to before
starting. The interface contracts differ by category.

- [ce-agent-plugins/README.md](ce-agent-plugins/README.md)
- [ce-api-plugins/README.md](ce-api-plugins/README.md)
- [ce-auth-pluginsREADME.md](ce-auth-pluginsREADME.md)


## Plugin structure

Every plugin lives in its own subfolder under its category:

```
<category>/<plugin-name>/
    README.md
    LICENSE
    sbom.json
    test/
        run.sh
        TEST-REPORT.md
    <plugin files>
```

All three metadata files are required for every plugin in every category.
A plugin missing any of them will not pass validation.

Every plugin must also ship a `test/` directory with a `run.sh` test runner
and a committed `TEST-REPORT.md` (see [Tests and test reports](#tests-and-test-reports)).


## Required metadata files

`README.md`
: Documents the plugin. Required headings differ by category (see below).
  Written in British English. No index of other plugins; each README covers
  only its own plugin.

`LICENSE`
: The licence for this plugin. The licence may differ from other plugins in
  the repository. Document it clearly. MIT is the default if there is no
  reason to use another.

`sbom.json`
: Software Bill of Materials in CycloneDX JSON format. Must be valid JSON
  and must contain `bomFormat`, `specVersion`, and `components` fields.
  List all runtime dependencies, including system packages. For Debian
  packages, use `pkg:deb/debian/<package>` as the `purl`.

Minimal `sbom.json` example:

```json
{
  "bomFormat": "CycloneDX",
  "specVersion": "1.5",
  "version": 1,
  "metadata": {
    "component": {
      "type": "application",
      "name": "my-plugin",
      "version": "0.1.0",
      "description": "One-line description"
    }
  },
  "components": [
    {
      "type": "library",
      "name": "bash",
      "version": "5.2",
      "description": "GNU Bourne Again shell",
      "purl": "pkg:deb/debian/bash"
    }
  ]
}
```


## Tests and test reports

Every plugin must ship its own tests under a `test/` subdirectory, along with
a committed test report. This is a submission requirement, not optional.

```
<category>/<plugin-name>/test/
    run.sh            # the test runner - self-contained, no network fixtures
    TEST-REPORT.md    # the committed output of the latest run.sh
    *.t               # optional: Perl unit tests (run via prove), etc.
```

`test/run.sh`
: A self-contained runner invoked as `bash test/run.sh` from the plugin
  directory. It must exit 0 only when every check passes and non-zero on any
  failure. It prints a Markdown report to stdout that starts with a
  `# Test report: <plugin> (<category>)` heading and a `Generated:` timestamp,
  and ends with a `VERDICT: PASS` or `VERDICT: FAIL` line. Tests must be
  deterministic: stand up any dependency locally (a temp file, a mock endpoint
  with a readiness poll - never a fixed `sleep`) and `SKIP` cleanly when an
  optional tool is absent rather than failing.

`test/TEST-REPORT.md`
: The captured output of the latest `bash test/run.sh`, committed alongside the
  runner. Regenerate it whenever the plugin or its tests change:

  ```bash
  bash test/run.sh | tee test/TEST-REPORT.md
  ```

The `test/` subdirectory is deliberate: keeping the runner out of the plugin
root means a `test/run.sh` is never mistaken for an agent `*.sh` script by the
validator's allowlist detection.

What to test depends on the category:

- **Agent scripts** - the no-args and unknown-subcommand paths exit non-zero
  (the validator contract), each schema-advertised subcommand is dispatched
  (cross-check the sidecar enum against the script), and each read-only
  subcommand runs where its tool is present.
- **Auth hooks** - the full exit-code matrix (0 authorised / 1 fail-closed /
  2 bad credentials / 3 insufficient privilege) across empty, valid, wrong,
  and unknown credentials, using temp registries/files or a local mock
  endpoint.
- **API plugins** - run the unit suite (e.g. `prove` for Perl) and/or
  structurally validate the collection: every endpoint present, environment
  variables declared, async runs wired to capture the reqid.
- **Viewer plugins** - structural HTML checks: the document parses, mounts the
  viewer container, loads its library, and wires the spec URL.


## README required headings

Each category has a specific set of required headings. The validator checks
for these exactly. Use ATX-style headers (`## Heading`).

Agent scripts (`ce-agent-plugins/`):

```
## Purpose
## Dependencies
## Installation
## scripts.conf
## Subcommands
## Examples
## Limitations
```

Auth hooks (`ce-auth-plugins`):

```
## Purpose
## Dependencies
## Installation
## Configuration
## Exit codes
## Examples
## Limitations
```

API plugins (`ce-api-plugins/`):

```
## Purpose
## Dependencies
## Installation
## Configuration
## Examples
## Limitations
```


## Category interface contracts

### ce-agent-plugins

Scripts receive a JSON context object on stdin. Discard it if not needed:

```bash
exec 0</dev/null
```

Scripts must exit 0 on success and non-zero on failure. stdout and stderr
are both captured and returned to the caller.

Scripts must use the subcommand pattern: the first argument selects the
operation. Calling the script with no arguments must print usage to stderr
and exit non-zero. Calling with an unrecognised subcommand must do the same.

Script names must match `[a-zA-Z0-9_-]+`. This is the allowlist name pattern
enforced by the agent.

Test scripts against a real `scripts.conf` entry before submitting. Verify
each subcommand runs correctly and that the no-args path exits non-zero.

### auth hooks

Hooks receive full request context as environment variables and as JSON on
stdin. Read `ce-auth-pluginsREADME.md` for the full variable and field reference.

Hooks must handle malformed or empty stdin without crashing - exit 1 (denied)
on any unhandled error. This is a hard requirement: ctrl-exec treats a
crash the same as a denial, but a hook that produces unexpected output or
leaves background processes running creates operational problems.

Exit codes must be exactly 0, 1, 2, or 3. No output on stdout or stderr.

### ctrl-exec-cli

API plugins consume the ctrl-exec HTTP API. Do not hardcode hostnames
or script names - use `GET /openapi-live.json` or `GET /discovery` for
runtime enumeration.

Document the async pattern (`POST /run` → `GET /status/{reqid}`) wherever
the plugin submits long-running scripts. Include the recommended polling
interval and timeout strategy.


## Running the validator

Run the validator against your plugin before opening a pull request. The
validator is at `tools/validate-plugin` in the repository root.

```bash
tools/validate-plugin ce-agent-plugins/my-plugin
tools/validate-plugin ce-auth-pluginsmy-hook
tools/validate-plugin ce-api-plugins/my-ce-api-plugins
```

The validator checks:

- Required files present (`README.md`, `LICENSE`, `sbom.json`)
- Required README headings present for the category
- `sbom.json` is valid JSON with required CycloneDX fields
- For agent scripts: script is executable, has a shebang, name matches the
  allowlist pattern, exits non-zero with output when called with no args
- For auth hooks: hook is executable, has a shebang, exits with a valid
  code (0–3) on empty stdin and on a synthetic ping payload

A plugin must produce `VALID` with zero failures before submission. Pull
requests are validated automatically on open and on each subsequent push.

Example of a passing run:

```
Validating plugin: linux-audit (category: ce-agent-plugins)
Path: ce-agent-plugins/linux-audit

[ Required files ]
  PASS  README.md exists
  PASS  LICENSE exists
  PASS  sbom.json exists

[ README sections ]
  PASS  README has '## Purpose'
  ...

Results: 21 passed, 0 failed
VALID
```


## General guidelines

Dependencies
: Prefer Debian trixie system packages. If a dependency is not in the Debian
  trixie package set, document why and what the operator must install manually.
  OpenWRT scripts may depend on OpenWRT-specific tools.

Testing
: Test against the minimum dependency set where practical. Include a worked
  test run in the README Examples section showing real output from a real host.

Privilege
: Document any privilege requirements explicitly. If a script requires root,
  say so. If it can run as a less-privileged user, show the sudoers rule
  needed to enable this.

Idempotency
: Scripts that modify state should be idempotent where possible. Document
  any cases where running the same subcommand twice has different effects.

Atomicity
: Write operations that modify files should use a write-to-temp-then-rename
  pattern to avoid partial writes.

British English
: All written content - README, comments, output strings - uses British
  English spelling throughout.
