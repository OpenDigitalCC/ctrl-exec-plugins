---
title: "ctrl-exec-plugins - Development Queue"
subtitle: "Plugin development items by category"
brand: plain
toc: false
---

# ctrl-exec-plugins - Development Queue

Development queue for the plugin ecosystem, migrated from the old WISHLIST.
Each entry states its purpose, the interface it uses, implementation
considerations under the current API, and what a completed plugin looks like.
Grouped by category; within a category, loosely by theme.

Every plugin is a folder under its category with `README.md`, `LICENSE`, and a
CycloneDX `sbom.json`, ships a `test/` suite (a `run.sh` runner plus a
committed `TEST-REPORT.md`), and must pass `tools/validate-plugin` (required
files, the category's required README headings, and the category checks). Read
the category README and `CONTRIBUTING.md` before starting one.

Work one item at a time, confirm scope before building, and establish ground
truth from the API/agent contract first. Completed items are removed; finished
work stays in git history.

Two cross-cutting notes under the current API:

- **API client plugins should cover async.** Long runs use `POST /run` with
  `"async": true` -> `202` + reqid -> poll `GET /status/{reqid}` until complete,
  not just the synchronous path. `/status` aggregates per-host state.
- **Agent script plugins should ship a schema sidecar.** A
  `<script>.schema.json` next to the script gives it typed arguments in
  `/openapi-live.json` (`x-ctrl-exec-scripts`) and as a typed tool in the
  `ctrl-exec-mcp` bridge. See `docs/SCHEMA-SIDECAR.md` in the ctrl-exec repo.


# API plugins (ce-api-plugins)

Consume the ctrl-exec HTTP API (`/`, `/health`, `/ping`, `/run`, `/status`,
`/discovery`, `/openapi.json`, `/openapi-live.json`). Discover hosts and scripts
at runtime; never hardcode them. Required README headings: Purpose,
Dependencies, Installation, Configuration, Examples, Limitations.

## Client libraries and wrappers

perl-client
: A reusable Perl **library** exposing `ping`, `run` (sync or `async`),
  `status`, and `discovery`, returning plain Perl data structures, using core
  modules only (`HTTP::Tiny`, `JSON::PP`). Distinct from the existing
  `ctrl-exec-cli` (a command-line tool): this is the importable module for
  automation and agentic integrations. Could be factored out of the CLI's
  internals. Done: a script can `use` it and drive a full async run.

cli-wrapper (bash)
: A bash wrapper over the endpoints using `curl` and `jq` - the same surface as
  the Perl CLI with no Perl dependency, for environments that have only bash,
  curl, and jq. Cover async (submit + poll). Done: each subcommand maps to an
  endpoint and returns parsed output.

jupyter
: A Python notebook (using `requests`) demonstrating discovery, a synchronous
  run, async dispatch + poll, and log correlation by reqid. An onboarding and
  exploration tool for operators comfortable with Python. Done: runs top to
  bottom against a live API.

## Office / data tools

excel
: An Excel workbook using Power Query to call the API and show discovery and run
  results. Documents the CORS config needed for browser access. Covers discovery
  and ping; run is included with the synchronous-blocking caveat and the async
  alternative (submit, then refresh against `/status/{reqid}`).

libreoffice-calc
: The Excel equivalent using Basic macros, for LibreOffice shops. Same coverage,
  same async note. Useful where LibreOffice is the standard office suite.


# Agent plugins (ce-agent-plugins)

Allowlisted scripts deployed to agent hosts. They receive request context JSON
on stdin (discard with `exec 0</dev/null` if unused), must exit 0 on success /
non-zero on failure, must use the subcommand pattern (first arg selects the
operation; no-args prints usage to stderr and exits non-zero), and names match
`[a-zA-Z0-9_-]+`. Required README headings add `scripts.conf` and `Subcommands`.
Each write-capable subcommand must be allowlisted individually, and each plugin
**should ship a `<script>.schema.json` sidecar** so its subcommands surface as
typed tools. Document a per-subcommand privilege matrix and declare runtime
deps in `sbom.json`.

## System and host management

linux-sysadmin
: Write-capable companion to `linux-audit`: restart service, rotate logs, clear
  tmp, check disk, report memory. Write operations allowlisted per subcommand.
  Needs a clear per-subcommand privilege matrix (some need root, some should drop
  to a service account). The natural high-value pairing with the already-shipped
  read-only audit plugin.

## Web servers

nginx
: Test config, reload, rotate access logs, report active connections. Runs
  without root if the agent user is in the `www-data` group, except log rotation
  (needs write access to the log dir). Document the group requirement.

## Databases

postgres
: Backup via `pg_dump`, report replication lag, vacuum, connection count.
  Credentials via `.pgpass` or environment - never in `scripts.conf` or
  arguments. The agent user needs a role with the right privileges; document the
  minimum grant per subcommand. Backups are a strong async use case (long
  `pg_dump` via `run --async`).

## Containers

docker
: List containers, pull image, restart container, prune unused images. Runs as a
  user in the `docker` group - no root needed, but docker-group membership is
  root-equivalent in practice; state this clearly in Limitations.

## Communications and telephony

asterisk
: Reload dialplan, show active channels, list SIP peers, restart service, via
  `asterisk -rx`. The agent user needs permission to run `asterisk -rx` (sudoers
  rule or `asterisk` group membership, install-dependent).

prosody
: Reload config, list connected users, check module status, via `prosodyctl`.
  The agent user typically runs `prosodyctl` as the `prosody` user via sudo.

## Hosting control panels

hestia
: List domains/users/databases, suspend/unsuspend a user, rebuild a web domain
  config, via the `v-` Hestia CLI. The agent user needs permission to call `v-`
  commands (sudoers or `admin` group, with documented security implications).

## Network and embedded

openwrt
: Reload firewall, list connected clients, restart services, read the system log
  tail, via `ubus` and OpenWRT CLI tools. Target current OpenWRT stable
  (Alpine-based, not Debian); the `sbom.json` dependency declarations differ
  from the Debian agent scripts.

## Certificates and security operations

certbot
: Check certificate expiry, trigger renewal, report the renewal log tail. Expiry
  checks run as any user; renewal needs root/sudo to `certbot`. Useful for
  scheduled fleet-wide expiry checks (a natural `run-jobs` consumer).

fail2ban
: List active jails, list banned IPs in a jail, unban an IP, via
  `fail2ban-client` (needs sudo). The unban subcommand is a write operation -
  document that it requires explicit allowlisting.

## Advanced / topology

ctrl-exec-chain
: A script that, when run by an agent, calls a *second* ctrl-exec instance and
  relays the result back to the original caller - enabling an agent to sit
  between two ctrl-exec instances for network separation, security zoning, or
  audit. The target URL and credentials arrive as arguments and must be
  explicitly allowlisted on the intermediate agent. Significant trust surface;
  the README must document the implications carefully. Relates to multi-hop and
  multi-dispatcher topologies (see the ctrl-exec repo's multiple-dispatcher
  item).


# Auth hooks (ce-auth-plugins)

Executables called before a run, receiving full request context as environment
variables and JSON on stdin. They must exit exactly 0 (authorised), 1 (denied),
2 (bad credentials), or 3 (insufficient privilege), produce no stdout/stderr,
and handle malformed/empty stdin without crashing (exit 1 on any unhandled
error). Required README headings add `Configuration` and `Exit codes`. No
credentials in the hook script.

## Token validators

jwt
: Validate a JWT against a statically configured secret or public key; extract
  standard claims (`sub`, `exp`, `iat`). No issuer discovery (that is `oidc`).
  Suitable for machine-to-machine tokens from an internal issuer.

oidc
: Validate an OIDC access token (JWT) against a configured issuer and JWKS
  endpoint, mapping roles/groups from claims to ctrl-exec privilege levels.
  Performs dynamic issuer discovery; needs network access to the JWKS endpoint
  at validation time.

biscuit
: Validate a Biscuit token, checking attenuation claims against the requested
  action, script, and target hosts. Self-contained and verifiable offline -
  suited to air-gapped deployments. Needs `biscuit-cli` or a Biscuit library.


## Directory and credential validators

ldap
: Bind to LDAP/AD with the provided username and password, then check group
  membership for the requested action. Config via environment or a sidecar file.
  Needs `ldapsearch` or an LDAP client library.

pam
: Validate via PAM, delegating to the host's PAM stack (Unix passwords, SSSD/
  LDAP, smart cards, etc.) through one interface. Needs to run as root or with
  PAM permissions. The most flexible option where PAM is already configured.


radius
: Forward credentials to a RADIUS server, for sites with existing RADIUS
  infrastructure. Needs `radtest` or a RADIUS client library.

## Delegation to an external decision

http-session
: Validate a session cookie or bearer token against a configurable HTTP
  endpoint, mapping the response code to a ctrl-exec exit code. For ctrl-exec
  deployed behind an app that already manages sessions. (Compare the implemented
  `rest-query`, which delegates the whole decision to an HTTP endpoint.)
