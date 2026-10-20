---
title: agent-to-agent-transfer
subtitle: Transfer files directly between two ctrl-exec agents
brand: odcc
---

# agent-to-agent-transfer

Transfers a file archive directly between two ctrl-exec agents without the
data passing through the dispatcher host. The dispatcher orchestrates both
sides via the ctrl-exec API but carries no file data itself.

One component:

`ce-file-transfer`
: Coordinator. Runs on the dispatcher host. Instructs the receiving agent to
  start `agent-file-receive`, captures the cert fingerprint, instructs the
  sending agent to run `agent-file-transfer` pointing directly at the receiver,
  then confirms receipt with the receiver's `--status` call.

No new agent scripts are required. This plugin reuses `agent-file-transfer`
(sender) and `agent-file-receive` (receiver) which must both be installed and
allowlisted on their respective agents.

> Status: proof of concept

## Purpose

Move log archives, database snapshots, or deployment artefacts between agents
without staging through the dispatcher. Useful when the dispatcher host has
limited disk space, when transfers are large, or when the agents are on a fast
local network relative to the dispatcher.

The agent-side receiver (`agent-file-receive.sh`) ships a schema sidecar
(`agent-file-receive.sh.schema.json`) so it is advertised as a typed tool via
`/discovery` and the `ctrl-exec-mcp` bridge - its `port` / `output` / `timeout`
/ `status` arguments are typed, and it is flagged **destructive** (it writes a
file to the receiving host).

## How the receiver works

`agent-file-receive.sh` is one allowlisted script with two calls.

Receive (`--port <n> --output <file> [--timeout <s>]`)
: Generates a throwaway cert, starts a **detached listener** (its own session,
  stdin/stdout/stderr on `/dev/null`) and returns at once with exit 0 and two
  lines on stdout: `fingerprint:<hex>` and `id:<hex>`. The ctrl-exec run is
  finished by then, so the coordinator has the fingerprint straight away; no
  `async` run is needed. The listener keeps its own `--timeout`, writes the
  data to `--output`, verifies it as a gzip tar archive, deletes its cert, and
  records the result in a status file beside the output
  (`<output dir>/.agent-file-receive.<id>.status`). Status files older than
  a day are removed by the next receive call in that directory.

Status (`--status <id> --output <file>`)
: Reads that status file. `--output` is the same path as the receive call (the
  status file lives in its directory). Prints `pending` (exit 0);
  `received:<bytes>` and `sha256:<hex>` (exit 0); `failed:<reason>` or
  `timedout:<reason>` (exit 1). An unknown id exits 1. The coordinators call
  this through `/run` until it reports a final state.

Run with no arguments, or with an unknown one, the script prints usage and
exits 2. On failure or timeout the partial output is renamed to
`<file>.failed.<epoch>`.

### Allowlisting and profile

Both calls are the same script, so one `scripts.conf` entry covers them:

```
agent-file-receive = /opt/ctrl-exec-scripts/agent-file-receive.sh profile=receive
```

The receiving agent's profile must let the script write the output directory,
because the output, the status file and any `.failed` file go there:

- a profile with a `writable` list needs the output directory on it (the
  listener keeps the profile's mount namespace for as long as it lives, so the
  list applies to it exactly as to the run that started it);
- a profile with no `writable` list needs the output directory writable by the
  profile's `run_as` user.

If the directory cannot be written the receive call fails at once with exit 1
and says so.

### Caveats

- Under systemd the detached listener stays in the executor's cgroup, and
  `ctrl-exec-exec.service` uses the default `KillMode` (control-group). Stopping
  or restarting the executor (an upgrade, `Restart=on-failure`) therefore kills
  an in-flight listener: that transfer fails and must be retried. Starting a
  receive call after the restart is enough; nothing is left behind except the
  status file, which reports `failed`.
- The sender (`ce-push-blob`, and the `agent-file-transfer` sender) streams
  with `openssl s_client`. On Alpine 3.21 (OpenSSL 3.3.7) `s_client` was seen
  to send nothing when a single read from stdin returns 8192 bytes or more, so
  an archive larger than that never arrives and the transfer times out. Run the
  coordinator on a host with another OpenSSL build (Debian's 3.0 and 3.5 send
  correctly); the receiver side is unaffected.
- One transfer per port at a time; the listener serves one archive and then
  exits.
- A connection that sends no data (a fingerprint check) does not end the
  transfer. Any data sent on it does: a sender must not write to a probe
  connection and must close its side when the archive is complete
  (`openssl s_client -quiet -no_ign_eof -nocommands`).

## Relay via dispatcher

If a direct network path between agents is not available - due to firewalling,
NAT, or network segmentation - the same result can be achieved by chaining
`ce-collect-blob` and `ce-push-blob`: collect the file from the source agent
to the dispatcher, then push it from the dispatcher to the destination agent.

```bash
# Step 1: pull from source agent to dispatcher
ce-collect-blob \
  --host db-01 \
  --path /var/log/app \
  --port 9100 \
  --output /tmp/relay.tar.gz

# Step 2: push from dispatcher to destination agent
ce-push-blob \
  --host backup-01 \
  --file /tmp/relay.tar.gz \
  --output /var/backups/db-01-app.tar.gz \
  --port 9101
```

This relay pattern requires the dispatcher to have sufficient disk space for
the intermediate file, and doubles the transfer time. The direct method
(`ce-file-transfer`) is preferred when network connectivity permits.

## Dependencies

Receiving agent: `openssl`, `tar`, `ss` (iproute2), `setsid` (util-linux),
`sha256sum` (coreutils).

Agent hosts:

| Script | Plugin | Role |
| --- | --- | --- |
| `agent-file-transfer.sh` | `agent-file-transfer` | Installed on sending agent |
| `agent-file-receive.sh` | `agent-file-receive` | Installed on receiving agent |

Dispatcher host:

| Tool | Package | Notes |
| --- | --- | --- |
| `curl` | `curl` | ctrl-exec API calls |
| `jq` | `jq` | JSON construction and parsing |

## Installation

### Sending agent

Install `agent-file-transfer` plugin. See `agent-file-transfer/README.md`.

### Receiving agent

Install `agent-file-receive` plugin. See `agent-file-receive/README.md`.

### Dispatcher host

Copy the coordinator:

```bash
sudo cp ce-file-transfer /usr/local/bin/
sudo chmod 755 /usr/local/bin/ce-file-transfer
```

## scripts.conf

No `scripts.conf` changes in this plugin. Entries are managed by
`agent-file-transfer` and `agent-file-receive` respectively.

## Subcommands

### ce-file-transfer (coordinator)

```
--from <agent>      Sending agent hostname (required)
--to <agent>        Receiving agent hostname (required)
--path <path>       Path or glob to collect from the sender (required)
--output <path>     Destination path on the receiving agent (required)
--port <n>          Transfer port - must be reachable from sender to receiver (required)
--timeout <n>       Transfer timeout in seconds (default: 300)
--api-url <url>     ctrl-exec API base URL (default: $CTRL_EXEC_API_URL)
--token <token>     Auth token (default: $CTRL_EXEC_TOKEN)
--username <n>      Username for auth hook
```

Environment variables: `CTRL_EXEC_API_URL`, `CTRL_EXEC_TOKEN`, `CTRL_EXEC_USERNAME`

### agent-file-receive (on the receiving agent)

```
--port <n>          TCP port to listen on (receive)
--output <file>     Output path for the archive (receive and status)
--timeout <n>       Seconds the listener waits (receive, default 300)
--status <id>       Report the transfer <id> printed by the receive call
```

Both coordinators (`ce-file-transfer` and `ce-push-blob`) pass the token as
the API requires: in the body of `POST /run`, and as `Authorization: Bearer`
on every `GET /status` poll.

## Examples

```bash
# Transfer /var/log/app from db-01 to backup-01 (direct)
ce-file-transfer \
  --from db-01 \
  --to backup-01 \
  --path /var/log/app \
  --output /var/backups/db-01-app.tar.gz \
  --port 9100

# With auth and custom timeout
CTRL_EXEC_TOKEN=mytoken \
ce-file-transfer \
  --from web-01 \
  --to archive-01 \
  --path /var/www/uploads \
  --output /mnt/archive/web-01-uploads.tar.gz \
  --port 9100 \
  --timeout 900
```

## Coordination sequence

```
Dispatcher                  Sending agent (--from)     Receiving agent (--to)
----------                  ----------------------     ----------------------
Dispatch agent-file-receive ─────────────────────────────────────────────>
                                                       Generate cert
                                                       Start detached listener
<─────────────────────────────── Print fingerprint:<hex> and id:<hex>, exit 0
Dispatch agent-file-transfer ──────────────────>
(with --dest <to-host:port>
 --cert-fingerprint <hex>)
                            Archive path
                            Verify fingerprint
                            Connect ─────────────────────────────────────>
                            Stream archive ──────────────────────────────>
                                                       Receive and verify
                            Print size:<bytes>         Verify, write status file
Dispatch agent-file-receive --status <id> ───────────────────────────────>
<─────────────────────────────────────── received:<bytes> sha256:<hex>
<──────────── Confirm completion from both sides ─────────────────────────
```

## Security model

Control channel
: Both agents are authenticated via ctrl-exec mTLS before any transfer begins.

Data channel
: The receiving agent generates a throwaway TLS cert per transfer. The
  listener deletes it when the transfer ends, whatever the outcome.

Fingerprint binding
: The receiver's fingerprint is returned through the authenticated ctrl-exec
  channel to the dispatcher, which passes it to the sender through a second
  authenticated ctrl-exec call. The sender verifies the fingerprint before
  connecting, preventing connection to an unintended receiver.

No data on dispatcher
: The dispatcher host carries no file data. Only fingerprints and status
  are exchanged via the ctrl-exec API.

## Limitations

- The transfer port must be open from the sending agent to the receiving agent.
  This is the primary deployment constraint - agents on different networks or
  behind NAT may not have a direct path. Use the relay pattern (see above) when
  a direct path is not available.
- One concurrent transfer per port on the receiving agent.
- Both agents must be reachable by the dispatcher and paired with the same
  ctrl-exec instance.
- The receiving agent's hostname (`--to`) must be resolvable from the sending
  agent for the direct connection. If it is not, use the IP address and ensure
  the agent is registered under that address in ctrl-exec.
