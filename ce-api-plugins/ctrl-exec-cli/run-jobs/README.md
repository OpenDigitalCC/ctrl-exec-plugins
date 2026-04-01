# run-jobs

A lightweight job orchestrator for [ctrl-exec](https://ctrl-exec.io/). Runs scheduled
bash scripts on a five-minute heartbeat, using the ctrl-exec CLI to dispatch work to
agents via the ctrl-exec API.

`run-jobs` lives inside the `ctrl-exec-cli` directory because it has no function
without the CLI. The CLI script is copied into the build context at image build time.

## Security note

The ctrl-exec API uses plain HTTP. This component must only be deployed on a
privileged internal network - a private Docker network, management VLAN, or loopback.
Do not expose the API port to untrusted networks.

## Overview

`run-jobs` is a container that:

- fires every five minutes, clock-aligned
- reads job definitions from a scripts directory
- executes any job whose schedule matches the current time
- supports recurring schedules (`schedule=`) and one-off execution (`runat=`)
- records exit code, timing, trigger, and output to a state directory
- logs activity to syslog (`local0`) forwarded over TLS to a remote syslog server

Jobs are bash scripts. Each script has a sidecar `.conf` file that defines its
schedule. The ctrl-exec CLI is installed in the container and available to scripts
for dispatching work to ctrl-exec agents.

## Files

```
ctrl-exec-cli/
├── ctrl-exec-cli                    the CLI (peer, copied into build)
└── run-jobs/
    ├── Dockerfile.run-jobs
    ├── compose.yml
    ├── rsyslog.conf
    ├── rsyslog-forward.conf
    ├── run-jobs.sh
    ├── run-jobs-entrypoint.sh
    ├── README.md
    └── scripts/
        ├── example-health.sh
        ├── example-health.conf
        ├── example-run.sh
        └── example-run.conf
```

## Job definitions

Each job is a pair of files in the scripts directory.

`backup.sh`
: The script to run. Must be executable. Has access to `ctrl-exec-cli` in `PATH`
  and to `CTRL_EXEC_API_URL`, `CTRL_EXEC_TOKEN`, and `CTRL_EXEC_USERNAME` from
  the container environment.

`backup.conf`
: Sidecar config. Supports two keys: `schedule=` for recurring jobs and `runat=`
  for one-off execution. Both may appear in the same file, and multiple `runat=`
  lines are supported.

### schedule=

Standard five-field cron expression:

```
schedule = 0 2 * * *
```

Supports `*`, `*/n` step syntax, and comma-separated lists per field. The runner
fires every five minutes - schedules with finer granularity than five minutes will
not trigger more frequently than that.

### runat=

ISO datetime for a one-off execution:

```
runat = 2026-04-02 22:00
```

The job runs once when the five-minute tick falls within the specified minute. Once
that time has passed the entry is silently ignored - leave the file in place, no
cleanup required. Multiple `runat=` lines are supported:

```
runat = 2026-04-02 22:00
runat = 2026-04-05 22:00
```

### Combining schedule= and runat=

Both may coexist in the same `.conf`. If `schedule=` matches on a given tick,
the script runs once and `runat=` is not evaluated for that tick:

```
schedule = 0 3 * * *
runat    = 2026-04-02 22:00
runat    = 2026-04-05 22:00
```

### Example - recurring discovery check

`scripts/check-agents.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

ctrl-exec-cli discovery
```

`scripts/check-agents.conf`:

```
schedule = */15 * * * *
```

### Example - daily backup with one-off override

`scripts/daily-backup.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

ctrl-exec-cli run db-01 --script backup-mysql
```

`scripts/daily-backup.conf`:

```
schedule = 0 2 * * *
runat    = 2026-04-02 22:00
```

## State

For each job, two files are written to the state directory on each run,
overwriting the previous result:

`backup.state`
: Plain text record of the last run:

```
script=backup
trigger=schedule
started=2026-03-25T02:00:01+00:00
finished=2026-03-25T02:00:04+00:00
duration=3s
exit_code=0
```

For one-off jobs, `trigger` shows the runat datetime:

```
trigger=runat=2026-04-02 22:00
```

`backup.out`
: Combined stdout and stderr from the last run.

Syslog (`local0`, tag `run-jobs`) receives start, finish, exit code, and duration
for each job, and a `tick: nothing due` line when nothing is scheduled. Messages
are forwarded over TLS to the remote syslog server at `log:6514`.

## Syslog configuration

`rsyslog` runs inside the container. Two config files are mounted from the host:

`rsyslog.conf`
: Minimal base config - loads `imuxsock` (for `logger`) and disables `imklog`
  (not available in containers).

`rsyslog-forward.conf`
: Forwards `local0.*` over TLS to `log:6514` using the system CA bundle
  (`/etc/ssl/certs/ca-certificates.crt`). Compatible with Let's Encrypt
  certificates on the remote server.

Both files must be present on the host before starting the container. They are
mounted read-only.

## Deployment

### With the ctrl-exec dispatcher (recommended)

`run-jobs` and the dispatcher run together in a single compose on the same
Docker network, with `run-jobs` reaching the dispatcher by service name.

#### Build and start

Copy the CLI into the build context, then build and start:

```bash
cp ../ctrl-exec-cli .
docker compose up -d --build
```

#### Verify

```bash
docker logs run-jobs
docker exec run-jobs ctrl-exec-cli health
```

### Standalone (dispatcher on same host, different network)

If `run-jobs` cannot join the dispatcher's network directly, connect it
after starting:

```bash
docker compose up -d --build
docker network connect ctrl-exec-net run-jobs
```

Or publish the dispatcher API port to the host and use the host IP:

```yaml
environment:
  CTRL_EXEC_API_URL: http://192.168.1.10:7445
```

Note: the API is plain HTTP. Only use a host IP when the host is on a
privileged management network.

### Standalone (no ctrl-exec)

`run-jobs` can be used without ctrl-exec. Jobs are plain bash scripts - the
ctrl-exec CLI is available but not required. Remove `CTRL_EXEC_*` environment
variables from the compose file and write jobs that perform their work locally
or via other means.

## Configuration reference

Environment variables read by the container:

`CTRL_EXEC_API_URL`
: ctrl-exec API base URL. Default: `http://localhost:7445`.
  Example: `http://dispatcher:7445`

`CTRL_EXEC_TOKEN`
: Auth token passed to the API. Optional - required only if the dispatcher
  auth hook enforces token authentication.

`CTRL_EXEC_USERNAME`
: Username sent with API requests. Default: `run-jobs`.

`JOBS_SCRIPTS_DIR`
: Path to the scripts directory inside the container.
  Default: `/etc/run-jobs/scripts`

`JOBS_STATE_DIR`
: Path to the state directory inside the container.
  Default: `/var/lib/run-jobs/state`

## Installing the ctrl-exec CLI

`ctrl-exec-cli` is a single Perl script with no non-core dependencies
(`HTTP::Tiny`, `JSON::PP`, `Getopt::Long` are all part of the Perl standard
library). It lives in the parent directory and must be copied into the build
context before building the image:

```bash
cp ../ctrl-exec-cli .
docker compose up -d --build
```

The CLI is available from the
[ctrl-exec-plugins](https://github.com/OpenDigitalCC/ctrl-exec-plugins)
repository under `ce-api-plugins/ctrl-exec-cli/`.

Full CLI usage:

```bash
ctrl-exec-cli --help
ctrl-exec-cli run --help
ctrl-exec-cli discovery
```

## Volumes

Scripts and state are bind-mounted from the host directory, so they persist
across container rebuilds and are included in any host-level backup or migration.

`./scripts`
: Mount point: `/etc/run-jobs/scripts`. Place `.sh` and `.conf` pairs here.
  Scripts must be executable (`chmod 755`).

`./state`
: Mount point: `/var/lib/run-jobs/state`. Written by the runner. Can be
  inspected directly on the host.

To add a script to a running container, copy files into the host `scripts/`
directory and set permissions:

```bash
cp myjob.sh myjob.conf /srv/docker-vol/ctrl-exec/scripts/
chmod 755 /srv/docker-vol/ctrl-exec/scripts/myjob.sh
```

The change takes effect at the next five-minute tick - no restart needed.
