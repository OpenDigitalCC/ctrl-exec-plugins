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
- executes any job whose cron schedule matches the current time
- records exit code, timing, and output to a state directory
- logs activity to syslog

Jobs are bash scripts. Each script has a sidecar `.conf` file that defines its
schedule. The ctrl-exec CLI is installed in the container and available to scripts
for dispatching work to ctrl-exec agents.

## Files

```
ctrl-exec-cli/
├── ctrl-exec-cli                    the CLI (peer, copied into build)
└── run-jobs/
    ├── Dockerfile.run-jobs
    ├── compose.run-jobs.yml
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
: Sidecar config. Currently one required key:

```
schedule = 0 2 * * *
```

Standard five-field cron expression. Supports `*`, `*/n` step syntax, and
comma-separated lists per field. The runner fires every five minutes - schedules
with finer granularity than five minutes will not trigger more frequently than
that.

### Example job

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

Runs a discovery check every 15 minutes.

### Example job calling an agent script

`scripts/daily-backup.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

ctrl-exec-cli run db-01 --script backup-mysql
```

`scripts/daily-backup.conf`:

```
schedule = 0 2 * * *
```

Runs at 02:00 daily.

## State

For each job, two files are written to the state directory on each run,
overwriting the previous result:

`backup.state`
: Plain text record of the last run:

```
script=backup
started=2026-03-25T02:00:01+00:00
finished=2026-03-25T02:00:04+00:00
duration=3s
exit_code=0
```

`backup.out`
: Combined stdout and stderr from the last run.

Syslog (tag `run-jobs`) receives start, finish, exit code, and duration for
each job, and a `tick: nothing due` line when the runner fires but no jobs
are scheduled.

## Deployment

### With the ctrl-exec dispatcher (recommended)

The dispatcher runs its own Docker network. `run-jobs` joins that network
as an external member, reaching the dispatcher by service name.

#### Prerequisites

- ctrl-exec dispatcher running with its compose project
- The dispatcher's Docker network name (typically `ctrl-exec-net`)

#### Configure

In `compose.run-jobs.yml`, verify the external network name matches the
dispatcher's network:

```yaml
networks:
  ctrl-exec-net:
    external: true
```

Set the API URL to the dispatcher service name:

```yaml
environment:
  CTRL_EXEC_API_URL: http://dispatcher:7445
```

If the dispatcher auth hook requires a token, set:

```yaml
  CTRL_EXEC_TOKEN: your-token-here
```

#### Build and start

Copy the CLI into the build context, then build and start:

```bash
cp ../ctrl-exec-cli .
docker compose -f compose.run-jobs.yml up -d --build
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
docker compose -f compose.run-jobs.yml up -d --build
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
docker compose -f compose.run-jobs.yml up -d --build
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

`run-jobs-scripts`
: Mount point: `/etc/run-jobs/scripts`. Place `.sh` and `.conf` pairs here.
  Scripts must be executable (`chmod 755`).

`run-jobs-state`
: Mount point: `/var/lib/run-jobs/state`. Written by the runner. Can be
  inspected from the host or mounted read-only by a monitoring tool.

To add a script to a running container:

```bash
docker cp myjob.sh run-jobs:/etc/run-jobs/scripts/
docker cp myjob.conf run-jobs:/etc/run-jobs/scripts/
docker exec run-jobs chmod 755 /etc/run-jobs/scripts/myjob.sh
```

The change takes effect at the next five-minute tick - no restart needed.
