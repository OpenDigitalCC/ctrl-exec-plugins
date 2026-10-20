---
title: ctrl-exec-cli cli
subtitle: Perl CLI client for the ctrl-exec HTTP API
brand: odcc
---

# cli

A monolithic Perl script providing full CLI access to the ctrl-exec HTTP API.
Covers every endpoint (health, ping, run, status, discovery) and the async run
lifecycle (`run --async`, `status`, `wait`). Intended as a
reference implementation and a portable tool for testing API functions before
building higher-level interfaces.

No CPAN dependencies. Uses only modules available as Debian trixie system
packages.

## Purpose

Exposes the complete ctrl-exec HTTP API as a command-line interface with
human-readable output by default and raw JSON output on request. Useful for
scripted automation, ad-hoc operations, and as a reference for how each
endpoint behaves before implementing a UI or integration.

## Dependencies

| Module | Debian package | Notes |
| --- | --- | --- |
| `HTTP::Tiny` | `perl` (core) | HTTP client |
| `JSON::PP` | `perl` (core) | JSON encode/decode |
| `Getopt::Long` | `perl` (core) | Argument parsing |
| `IO::Socket::UNIX` | `perl` (core) | `--socket`: the API's unix socket |
| `IO::Socket::SSL` | `libio-socket-ssl-perl` | Only for an `https://` API (`--ca`); loaded by HTTP::Tiny on demand |

All dependencies except `IO::Socket::SSL` are included in Perl's core
distribution. `IO::Socket::SSL` is needed only to reach the API over HTTPS.

## Installation

Copy the script to any location on the ctrl-exec host or any host with
network access to the API port:

```bash
sudo cp ctrl-exec-cli /usr/local/bin/
sudo chmod 755 /usr/local/bin/ctrl-exec-cli
```

Verify:

```bash
ctrl-exec-cli --version
ctrl-exec-cli health
```

## Configuration

The API address, CA, token, and username are resolved in priority order:
flag > environment variable > config file > default.

The API is reached either at a URL or on its unix socket (`api_socket` in the
dispatcher's `ctrl-exec.conf`, e.g. `/run/ctrl-exec-api/api.sock`). The first
source in priority order that sets either one decides, so `--url` overrides a
`socket` in the config file and `--socket` overrides a `url`. `--url` and
`--socket` together are refused. On the socket, the socket file's permissions
decide who may connect (mode 0660, the API's `api_socket_group`), and the
API's auth hook applies as over TCP.

For an `https://` URL, `--ca FILE` names the CA certificate the API's
certificate must chain to (and the certificate must name the URL's host).
Without it HTTP::Tiny's default verification applies.

Config file (`~/.ctrl-exec-cli.conf`):

```ini
url      = http://myhost:7445
# or, on the dispatcher host:
# socket = /run/ctrl-exec-api/api.sock
ca       = /etc/ssl/certs/api-ca.crt
token    = mytoken
username = alice
```

Environment variables:

```
CTRL_EXEC_API_URL    API base URL (default: http://localhost:7445)
CTRL_EXEC_API_SOCKET API unix socket path
CTRL_EXEC_API_CA     CA certificate for an https:// API
CTRL_EXEC_TOKEN      Auth token
CTRL_EXEC_USERNAME   Username (default: $USER)
```

Global flags (override all other sources):

```
--url <url>        API base URL
--socket <path>    API unix socket (instead of --url)
--ca <file>        CA certificate to verify an https:// API
--token <token>    Auth token
--username <n>     Username
--json             Raw JSON output for all commands
```

Use `CTRL_EXEC_TOKEN` rather than `--token` to prevent the token value
appearing in `ps` output.

## Subcommands

### health

Check API server liveness and version. No authentication required.

```
ctrl-exec-cli health [--json]
```

### ping

Test mTLS connectivity to one or more agents. Reports cert expiry and agent
version per host. Accepts `hostname` or `hostname:port` (port defaults to 7443).

```
ctrl-exec-cli ping <host> [host...] [--json]
```

Output columns: HOST, STATUS, RTT, CERT EXPIRY, VERSION.

Failed hosts are reported inline and the command exits 1 if any host did not
respond.

### run

Run an allowlisted script on one or more agents in parallel. `--script` is
required. Everything after `--` is passed to the script as positional arguments.

```
ctrl-exec-cli run <host> [host...] --script <n> [--async] [--json]
    [--input FILE|- | --input-fields FILE|-] [-- arg...]
```

Without `--async`, the command blocks until all hosts complete. stdout from
the script is printed to stdout; stderr to stderr. The top-level reqid is
printed as a header for log correlation. Exit code is 0 if all hosts
succeeded, 1 if any host failed.

With `--async`, the request is sent with `"async": true`: the server returns
immediately and the agent runs the script **detached**, so a long job is not
bound by the API read timeout. Per-host acceptance (`accepted` / `busy` /
`error`) is printed to stderr and the bare reqid to stdout (so
`REQID=$(... --async)` captures just the id). Retrieve the result later with
`status`, or block until it finishes with `wait`.

#### Confidential input

Arguments are visible in `ps`, shell history and logs. To give a script data
that must stay confidential (a key, a password, a certificate), use input:

- `--input FILE|-` reads FILE (or stdin for `-`) and sends its content as the
  single field `input`.
- `--input-fields FILE|-` reads a JSON object of string fields (at most 32;
  names 1-64 characters of `A-Z a-z 0-9 _ . -`) and sends it as given.

The two are mutually exclusive, and only one source may be stdin. Input is read
only from a file or stdin - there is no `--input=VALUE` form, by design. The
request body carries it as `input`; the receiving agent's `scripts.conf`
`input=` setting decides how the script gets it (stdin, or files under
`$CTRL_EXEC_INPUT`). The CLI never prints, logs or echoes input values: error
messages name the option or field only.

The content must be valid UTF-8 text because the API carries JSON strings. The
CLI refuses anything else; base64-encode binary content first
(`base64 key.der | ctrl-exec-cli run ... --input -`). If the API rejects the
input (HTTP 400), its message is shown. Send input only over the API's unix
socket (`--socket`) or TLS (an `https://` URL verified with `--ca`): over plain
HTTP to another host it crosses the network unencrypted. The CLI prints a
warning to stderr (and still sends) when `--input` or `--input-fields` would go
over plain HTTP to an address that is not loopback (`localhost`, `127.x.x.x`,
`::1`).

```
ctrl-exec-cli run web-01 --script set-secret --input secret.txt
ctrl-exec-cli run web-01 --script deploy-cert --input-fields - < fields.json
ctrl-exec-cli --socket /run/ctrl-exec-api/api.sock \
    run web-01 --script deploy-cert --input-fields - < fields.json
ctrl-exec-cli --url https://dispatcher.example.net:7445 --ca api-ca.crt \
    run web-01 --script deploy-cert --input-fields - < fields.json
```

### status

Show the current state of a run by reqid. Records are retained for 24 hours.

```
ctrl-exec-cli status <reqid> [--json]
```

The reqid is the top-level `reqid` printed by `run`, or from the JSON response.
A 404 means the reqid is unknown, has expired, or predates result persistence.

The output adapts to the run:

- **Synchronous run** - reqid, script, host list, completion timestamp, then
  the per-host result blocks (as `run` prints them).
- **Asynchronous run** - reqid, script, whether the run is `complete`, the list
  of still-`pending` hosts, then each host's state: `running` / `done` (with
  exit code and output) / `busy` / `error` / `expired`.

Exit code is 0 unless the run is complete with one or more failed hosts (then 1).

### wait

Poll a run until it completes, then print the result (same output as `status`).
A synchronous run is already complete, so `wait` returns at once; an async run
is polled until done or the timeout elapses.

```
ctrl-exec-cli wait <reqid> [--timeout <seconds>] [--json]
```

`--timeout` defaults to 300 seconds. Exit code: `0` complete and all hosts
succeeded, `1` complete with failures, `2` timed out while still pending.

### discovery

List registered agents and their allowlisted scripts.

```
ctrl-exec-cli discovery [host...] [--scripts] [--json]
```

Without `--scripts`, outputs a summary table showing host, status, version,
and script count.

With `--scripts`, outputs one block per host listing each script name and
absolute path. This is the view to use when you want to see what scripts are
available on each agent.

Optional host arguments filter the results to specific agents. Without host
arguments, all registered agents are queried.

## Examples

```bash
# Check the API is reachable
ctrl-exec-cli health

# Ping agents
ctrl-exec-cli ping web-01
ctrl-exec-cli ping web-01 web-02 db-01

# Discovery - summary table (host, status, version, script count)
ctrl-exec-cli discovery

# Discovery - show scripts available on each host
ctrl-exec-cli discovery --scripts

# Discovery - show scripts for specific hosts only
ctrl-exec-cli discovery --scripts web-01 db-01

# Run a script
ctrl-exec-cli run web-01 --script deploy

# Run a script on multiple hosts in parallel
ctrl-exec-cli run web-01 web-02 --script check-disk

# Run with arguments passed to the script
ctrl-exec-cli run db-01 --script backup-mysql -- --database myapp

# Run and get JSON output
ctrl-exec-cli run web-01 --script check-disk --json

# Run asynchronously - submit and get reqid immediately
ctrl-exec-cli run db-01 --script long-job --async

# Capture reqid from async run and retrieve result later
REQID=$(ctrl-exec-cli run db-01 --script long-job --async)
ctrl-exec-cli status $REQID

# Submit async and block until it finishes (up to 10 minutes)
ctrl-exec-cli wait "$(ctrl-exec-cli run db-01 --script long-job --async)" --timeout 600

# Retrieve a result by reqid
ctrl-exec-cli status a1b2c3d4
ctrl-exec-cli status a1b2c3d4 --json

# Override URL and token for a single invocation
ctrl-exec-cli --url http://myhost:7445 --token mytoken ping web-01

# Configure via environment variables
export CTRL_EXEC_API_URL=http://myhost:7445
export CTRL_EXEC_TOKEN=mytoken
ctrl-exec-cli discovery --scripts
ctrl-exec-cli run web-01 --script deploy
```

## Limitations

- HTTPS needs `IO::Socket::SSL` (`libio-socket-ssl-perl`). Pass `--ca` to
  verify the API's certificate against a specific CA.
- `--socket` speaks HTTP/1.0 over the unix socket, one request per
  connection, as the API serves it.
- `wait <reqid>` polls an async job to completion (every 2s, until `--timeout`).
  For custom cadence or backoff, poll `status <reqid>` from your own script.
- There is no retry logic. Connection errors and timeouts are reported and
  exit 1.
- `discovery` without a host filter queries all registered agents via
  `GET /discovery`. On large fleets this may be slow.
- The client timeout is 120 seconds. Long-running synchronous jobs that exceed
  this will be reported as a connection error even if the job completes on the
  agent. Use `--async` for jobs expected to run longer than two minutes.
