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
  then confirms completion from both sides.

No new agent scripts are required. This plugin reuses `agent-file-transfer`
(sender) and `agent-file-receive` (receiver) which must both be installed and
allowlisted on their respective agents.

> Status: proof of concept

## Purpose

Move log archives, database snapshots, or deployment artefacts between agents
without staging through the dispatcher. Useful when the dispatcher host has
limited disk space, when transfers are large, or when the agents are on a fast
local network relative to the dispatcher.

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
<─────────────────────────────────────────────── Print fingerprint:<hex>
Dispatch agent-file-transfer ──────────────────>
(with --dest <to-host:port>
 --cert-fingerprint <hex>)
                            Archive path
                            Verify fingerprint
                            Connect ─────────────────────────────────────>
                            Stream archive ──────────────────────────────>
                                                       Receive and verify
                            Print size:<bytes>         Print received:<bytes>
<──────────── Confirm completion from both sides ─────────────────────────
```

## Security model

Control channel
: Both agents are authenticated via ctrl-exec mTLS before any transfer begins.

Data channel
: The receiving agent generates a throwaway TLS cert per transfer. The cert
  is deleted on exit.

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
