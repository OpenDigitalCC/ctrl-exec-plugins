---
title: linux-audit
subtitle: Read-only system audit script for dispatcher agents
---

# linux-audit

## Purpose

A read-only audit script for Linux hosts managed by dispatcher. Provides
structured output across eight areas: recent logins, failed authentication
attempts, listening ports, systemd service status, disk usage, memory and
swap, and open file descriptor counts. Intended for scheduled compliance
checks and ad-hoc operational review.

All subcommands are read-only. No system state is modified.

## Dependencies

All dependencies are available as Debian trixie system packages. No additional
installation is required on a standard Debian system.

| Command | Package | Notes |
| --- | --- | --- |
| `bash` | `bash` | Required |
| `last` | `util-linux` | For `logins` |
| `ss` | `iproute2` | For `ports` |
| `systemctl` | `systemd` | For `services` |
| `df` | `coreutils` | For `disk` |
| `free` | `procps` | For `memory` |
| `lsof` | `lsof` | For `open-files` |
| `journalctl` | `systemd` | For `auth-failures` (preferred) |

The `auth-failures` subcommand falls back to `/var/log/auth.log` if
`journalctl` is not available.

## Installation

Copy the script to the agent host and add entries to `scripts.conf`:

```bash
sudo cp linux-audit.sh /opt/ctrl-exec-scripts/
sudo chmod 750 /opt/ctrl-exec-scripts/linux-audit.sh
sudo chown root:ctrl-exec-agent /opt/ctrl-exec-scripts/linux-audit.sh
```

Then add the entry to `/etc/ctrl-exec-agent/scripts.conf` and reload
(see scripts.conf section below).

## scripts.conf

Add to `/etc/ctrl-exec-agent/scripts.conf` on each agent host:

```ini
linux-audit = /opt/ctrl-exec-scripts/linux-audit.sh
```

Reload the allowlist without restarting the agent:

```bash
kill -HUP $(pgrep -f ctrl-exec-agent)
```

## Subcommands

All subcommands are passed as the first argument after `--`.

`logins`
: Recent successful logins. Equivalent to `last -n 20 --time-format iso`.
  Shows user, terminal, source IP, and login time for the last 20 sessions.

`auth-failures`
: Failed authentication attempts in the last 24 hours. Uses `journalctl`
  filtered to the SSH unit on systemd hosts; falls back to
  `/var/log/auth.log` on non-systemd hosts. Shows up to 50 entries.

`ports`
: Listening TCP and UDP ports. Equivalent to `ss -tlunp`. Includes the
  process name and PID for each listener.

`services`
: Two sections: failed systemd units (all types), and running services
  (top 40, non-kernel). Useful for spotting unexpected failures or
  confirming expected services are active.

`disk`
: Filesystem disk usage excluding tmpfs, devtmpfs, and squashfs mounts.
  Columns: source, filesystem type, size, used, available, use%, mount point.

`memory`
: Memory and swap usage via `free -h`. Shows total, used, free, shared,
  buffer/cache, and available figures.

`open-files`
: Open file descriptor count per process, top 20 by count. Useful for
  spotting file descriptor leaks. Requires `lsof`.

`all`
: Runs all subcommands in sequence. Output is sectioned with `=== name ===`
  headers between each section.

## Examples

```bash
# Check disk usage on a single host
ced run web-01 linux-audit -- disk

# Check listening ports on multiple hosts in parallel
ced run web-01 web-02 db-01 linux-audit -- ports

# Full audit of a single host
ced run db-01 linux-audit -- all

# JSON output for scripted consumption
ced run web-01 linux-audit --json -- services

# Run the script directly on the agent host (for testing)
/opt/ctrl-exec-scripts/linux-audit.sh disk
/opt/ctrl-exec-scripts/linux-audit.sh all
```

## Limitations

- `auth-failures` covers SSH authentication events only. PAM events for
  other services (sudo, console login) are not included.
- `open-files` requires `lsof`, which may not be installed on minimal
  systems. Install with `apt install lsof`.
- `services` output is truncated to 40 running services. Hosts with many
  services will not show a complete list.
- `auth-failures` on non-systemd hosts reads `/var/log/auth.log` directly.
  The agent process must have read access to this file; on some systems
  this requires adding `ctrl-exec-agent` to the `adm` group:
  `usermod -aG adm ctrl-exec-agent`.
- All subcommands reflect the state at the moment of execution. There is
  no historical comparison or trending.
