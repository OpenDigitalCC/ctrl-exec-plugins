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

All dependencies are included in Perl's core distribution and require no
additional installation on a standard Debian trixie system.

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

The base URL, token, and username are resolved in priority order:
flag > environment variable > config file > default.

Config file (`~/.ctrl-exec-cli.conf`):

```ini
url      = http://myhost:7445
token    = mytoken
username = alice
```

Environment variables:

```
CTRL_EXEC_API_URL    API base URL (default: http://localhost:7445)
CTRL_EXEC_TOKEN      Auth token
CTRL_EXEC_USERNAME   Username (default: $USER)
```

Global flags (override all other sources):

```
--url <url>        API base URL
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
ctrl-exec-cli run <host> [host...] --script <n> [--async] [--json] [-- arg...]
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

- HTTPS is supported (HTTP::Tiny uses TLS via `IO::Socket::SSL` if available),
  but certificate verification requires `libio-socket-ssl-perl` to be installed.
  Without it, HTTPS connections proceed without CA verification.
- `wait <reqid>` polls an async job to completion (every 2s, until `--timeout`).
  For custom cadence or backoff, poll `status <reqid>` from your own script.
- There is no retry logic. Connection errors and timeouts are reported and
  exit 1.
- `discovery` without a host filter queries all registered agents via
  `GET /discovery`. On large fleets this may be slow.
- The client timeout is 120 seconds. Long-running synchronous jobs that exceed
  this will be reported as a connection error even if the job completes on the
  agent. Use `--async` for jobs expected to run longer than two minutes.
