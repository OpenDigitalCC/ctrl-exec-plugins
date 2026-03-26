---
title: ctrl-exec-plugins - wishlist
subtitle: Plugin concepts for future implementation
brand: odcc
---

# ctrl-exec-plugins TODO

Plugin concepts by category. Each entry is a brief summary of purpose,
interface, and any notable implementation considerations.


## ctrl-exec-ce-api-plugins


### rapidoc

Static single-file HTML page pointing `spec-url` at `/openapi-live.json`.
Provides a browser-based interactive interface to the API with live host and
script enumeration. No build step; no server-side component beyond the
ctrl-exec API itself. The version stamp on the live spec changes on each
generation, causing RapiDoc to treat each load as fresh.


### swagger-ui

Equivalent to `rapidoc` using Swagger UI. Single HTML file, no build step.
Included because Swagger UI is the most widely recognised OpenAPI interface
and familiar to most developers encountering the API for the first time.


### redoc

Read-only documentation rendering of `openapi.json`. No interactive execution.
Suitable for publishing API reference documentation on a static site or internal
wiki. Single HTML file pointing at the static spec endpoint.


### postman

Postman collection importable from `openapi.json`. Includes an environment
template for base URL, token, and username. Documents the async pattern:
`POST /run` → note top-level reqid → `GET /status/{reqid}`. Covers all
endpoints with worked examples.


### bruno

Bruno collection equivalent to the Postman collection. Bruno is open source,
gaining adoption as a Postman alternative, and collection files commit to git
directly as plain text. Same endpoint coverage and async pattern documentation.


### insomnia

Insomnia collection covering the same endpoints as Postman and Bruno. Included
for environments where Insomnia is the established HTTP tool.


### perl-client

Perl library providing `ping`, `run`, `status`, and
`discovery` methods over HTTP using `LWP::UserAgent`. Returns plain Perl data
structures. Intended for Perl automation scripts and agentic AI integrations.
No CPAN dependencies beyond `libwww-perl` and `libjson-perl`, both available
as Debian trixie system packages.


### jupyter

Jupyter notebook demonstrating API usage in Python using `requests`. Covers
discovery, synchronous run, the async poll pattern via `/status/{reqid}`, and
log correlation by reqid. Intended as an onboarding and exploration tool for
operators comfortable with Python.


### excel

Excel workbook using Power Query to call the API and display discovery and run
results. Documents the required CORS configuration if the API is accessed from
a browser context. Covers discovery and ping; run is included with a clear
warning about synchronous blocking from Power Query.


### libreoffice-calc

LibreOffice Calc equivalent using Basic macros. Covers discovery and ping; run
is included with a warning about synchronous blocking. Useful for operators
in environments where LibreOffice is the standard office suite.


### cli-wrapper (bash)

Bash script wrapping the API endpoints with a simple command interface, using
`curl` and `jq`. Similar surface to the Perl CLI but with no Perl dependency.
Useful as a reference for shell scripting against the API and for environments
where only bash, curl, and jq are available.


---

## ce-agent-plugins


### linux-audit

✅ Implemented. Read-only system audit: recent logins, failed auth attempts,
listening ports, systemd service status, disk usage, memory and swap, open
file descriptor counts. No external dependencies beyond standard Debian tools.


### linux-sysadmin

Write-capable companion to `linux-audit`. Subcommands: restart service, rotate
logs, clear tmp, check disk, report memory. Write operations must be explicitly
allowlisted per subcommand in `scripts.conf`. Raises the question of privilege
handling - some operations require root, others should drop to a service account.
Needs a clear per-subcommand privilege matrix in the README.


### asterisk

Reload dialplan, show active channels, list SIP peers, restart service. Uses
`asterisk -rx` commands. Requires the `ctrl-exec-agent` user to have
permission to run `asterisk -rx` - typically via a sudoers rule or membership
of the `asterisk` group depending on the installation.


### openwrt

Reload firewall, list connected clients, restart services, read system log
tail. Uses `ubus` and standard OpenWRT CLI tools. Scripts must target current
OpenWRT stable; Alpine-based rather than Debian. Dependency declarations in
`sbom.json` will differ from other agent scripts.


### hestia

List domains, users, and databases; suspend/unsuspend user; rebuild web domain
config. Uses `v-` Hestia CLI commands. The `ctrl-exec-agent` user needs
permission to call `v-` commands, either via a sudoers rule or by being added
to the `admin` group (with documented security implications).


### prosody

Reload config, list connected users, check module status. Uses `prosodyctl`
commands. The agent user typically needs to run `prosodyctl` as the `prosody`
user via sudo.


### nginx

Test config, reload, rotate access logs, report active connections. All
operations available without root if the agent user is in the `www-data`
group, except log rotation which requires write access to the log directory.


### postgres

Backup database via `pg_dump`, report replication lag, vacuum, connection
count. Credentials via `.pgpass` or environment - no passwords in `scripts.conf`
or arguments. The agent user needs a PostgreSQL role with appropriate privileges;
document the minimum required grants for each subcommand.


### docker

List containers, pull image, restart container, prune unused images. Runs as
a user in the `docker` group; does not require root on the agent host. Note
that docker group membership is equivalent to root for practical purposes -
document this clearly in Limitations.


### certbot

Check certificate expiry, trigger renewal, report renewal log tail. Renewal
requires root or sudo access to `certbot`. Expiry checking can run as any user.
Useful for scheduled checks across a fleet of web servers.


### fail2ban

List active jails, list banned IPs in a jail, unban an IP. Uses `fail2ban-client`.
Requires the agent user to run `fail2ban-client` via sudo. The unban subcommand
is a write operation and should be documented as requiring explicit allowlisting.


### ctrl-exec-chain

A script that, when executed by an agent, calls a second ctrl-exec instance
and relays the result back to the original caller. Enables topologies where
an agent sits between two ctrl-exec instances for network separation, security
zoning, or audit reasons. The chain script receives the target ctrl-exec URL
and credentials as arguments; these must be explicitly allowlisted in
`scripts.conf` on the intermediate agent. Significant security surface - the
README must document trust implications carefully.


---

## auth


### biscuit

Validates a Biscuit token provided as the `token` field. Checks attenuation
claims against the requested action, script, and target hosts. Biscuit tokens
are self-contained and verifiable without a remote call, making this suitable
for offline or air-gapped deployments. Requires the `biscuit-cli` tool or a
Perl/Python Biscuit library.


### ldap

Binds to an LDAP or Active Directory server with the provided username and
password, then checks group membership for the requested action. Config via
environment or a sidecar config file - no credentials in the hook script.
Requires `ldapsearch` or a suitable LDAP client library.


### oidc

Validates an OIDC access token (JWT) against a configured issuer and JWKS
endpoint. Extracts roles or groups from claims and maps to ctrl-exec privilege
levels. Requires network access to the JWKS endpoint at validation time.
Distinct from the `jwt` plugin in that issuer discovery is performed
dynamically.


### http-session

Validates a session cookie or bearer token against a configurable HTTP
endpoint. The endpoint returns an authorisation decision; the hook maps the
HTTP response code to a ctrl-exec exit code. Useful when ctrl-exec is
deployed behind an application that already manages sessions.


### unix-user

Checks that the username exists as a local Unix user and optionally belongs to
a specified group. No password check - intended for trusted internal networks
where identity is established upstream (e.g. SSH forced commands or PAM
pre-authentication). Zero external dependencies.


### htpasswd

Validates username and password against an Apache-compatible htpasswd file.
Supports bcrypt and SHA hashes. Simple deployment with no external
dependencies beyond `openssl` for hash verification. Documents the security
limitations clearly - htpasswd is not suitable for high-security deployments.


### text-file

Validates against a plain text file of `username:token` pairs. Minimal
dependency, suitable for embedded or minimal environments where no other auth
infrastructure exists. Documents the security limitations clearly: tokens are
stored in plaintext, file must be 0600, and rotation requires editing the file.


### radius

Forwards credentials to a RADIUS server for validation. Useful in environments
with existing RADIUS infrastructure managing network equipment, VPN, or other
services. Requires `radtest` or a RADIUS client library.


### jwt

Validates a JWT with a configured secret or public key. Extracts standard
claims (`sub`, `exp`, `iat`). Distinct from `oidc` in that no issuer
discovery is performed - the key is configured statically. Suitable for
machine-to-machine tokens issued by an internal service.


### api-key-registry

Validates an API key against a local registry file mapping keys to usernames
and privilege levels. Supports key rotation without service restart by
re-reading the file on each request. Distinct from `htpasswd` in that keys
are opaque tokens rather than passwords, and privilege levels are encoded
in the registry rather than derived from group membership.


### pam

Validates credentials via PAM, delegating to whatever PAM stack is configured
on the host. Covers Unix passwords, LDAP via SSSD, smart cards, and others
through a single interface. Requires the hook to run as root or with
appropriate PAM permissions. The most flexible option for sites with existing
PAM configuration.


### rest-query

Forwards the full request context JSON to a configurable HTTP endpoint and
maps the HTTP response status to a ctrl-exec exit code. Allows any external
auth system to be integrated without writing a new hook. The endpoint contract
is simple and documented in the plugin README, enabling straightforward
implementation on any HTTP framework.
