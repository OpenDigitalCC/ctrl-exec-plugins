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
- logs activity to syslog (`local0`) when the container has a syslog socket,
  and to the container log otherwise
- explains, without running anything, what a tick would run (`--explain`)

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
: Sidecar config. Supports two keys: `schedule=` for recurring jobs and `runat=`
  for one-off execution. Both may appear in the same file, and multiple `runat=`
  lines are supported. Any other keys are ignored by the runner, so a job can
  keep its own settings in the same file.

### When a job runs

The runner ticks on every five-minute boundary. Each tick covers every minute
since the previous tick, so a job runs at the first tick at or after the minute
it is scheduled for - never before it - and at most once per tick:

- `schedule = 7 9 * * *` runs at the 09:10 tick.
- `schedule = * * * * *` runs once per tick, every five minutes.
- `runat = 2026-04-02 22:03` runs at the 22:05 tick.

When a tick overruns because a job is slow, the next tick picks up the minutes
it missed. The runner records the last tick in `.last-tick` in the state
directory, so a restart neither repeats a job nor skips one. After a gap of
more than an hour, such as a container that was stopped, missed minutes are
not caught up: the first tick covers only the last five minutes.

Jobs in a tick run one after another, in file name order.

### schedule=

Standard five-field cron expression:

```
schedule = 0 2 * * *
```

Fields are minute, hour, day of month, month and day of week, as in
cron(5). Each field takes `*`, a number, a range (`1-5`), a step on any of
those (`*/15`, `9-17/4`, `5/20`), or a comma-separated list of them. Sunday is
`0` or `7`. When both the day-of-month and day-of-week fields are restricted, a
day matching either one runs the job, as cron does. Names (`mon`, `jan`) and
the `@daily` forms are not supported.

An invalid expression is logged on every tick as a `problem:` line naming the
field at fault, and the job does not run.

### runat=

ISO datetime for a one-off execution:

```
runat = 2026-04-02 22:00
```

Any time `date -d` understands is accepted. The job runs once, at the first
tick at or after that minute. Once that time has passed the entry is ignored -
leave the file in place, no cleanup required. Multiple `runat=` lines are
supported:

```
runat = 2026-04-02 22:00
runat = 2026-04-05 22:00
```

### Combining schedule= and runat=

Both may coexist in the same `.conf`. If `schedule=` and a `runat=` fall in
the same tick, the script runs once, with trigger `schedule`:

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

A job that exits non-zero is recorded here and does not stop the tick or the
runner.

`.last-tick`
: The last tick the runner covered, in epoch seconds. Written by the runner;
  see [When a job runs](#when-a-job-runs).

## Logging

The runner logs start, finish, exit code and duration for each job, a
`problem:` line for each invalid `schedule=` or `runat=`, and a
`tick: nothing due` line when nothing ran.

Lines go to syslog (`local0`, tag `run-jobs`) through `logger` when the
container has a `/dev/log` socket. The image does not include a syslog daemon;
without a socket the same lines go to stderr, prefixed `run-jobs:`, and
`docker logs run-jobs` shows them. A logging failure never stops a tick.

## Checking jobs without running them

`--explain` reports what a tick would do and when each job runs next. It
executes nothing and writes nothing:

```bash
docker exec run-jobs run-jobs.sh --explain
docker exec run-jobs run-jobs.sh --explain --at '2026-10-20 02:00'
docker exec run-jobs run-jobs.sh --explain daily-backup
```

On the host, point it at the scripts directory instead:

```bash
./run-jobs.sh --explain --dir ./scripts
```

```
run-jobs explain - nothing is executed
tick       2026-10-20 02:00 UTC, covering 01:56-02:00
scripts    /etc/run-jobs/scripts

daily-backup
  schedule   0 2 * * *
  runat      2026-04-02 22:00 - past, ignored
  this tick  RUNS (trigger=schedule)
  next       2026-10-21 02:00
             2026-10-22 02:00
             2026-10-23 02:00

weekday-report
  schedule   7 9 * * 1-5
  this tick  -
  next       2026-10-20 09:10 (for 09:07)
             2026-10-21 09:10 (for 09:07)
             2026-10-22 09:10 (for 09:07)

check-agents
  schedule   */15 * * * mon
  this tick  -
  PROBLEM    schedule '*/15 * * * mon': day-of-week: bad value 'mon'

3 job(s): 1 would run in this tick, 1 problem(s)
```

`--at` takes any time `date -d` understands; the default is the next tick.
Name one or more jobs to explain only those. Explain covers the schedule only:
it shows that a job would start, not what the job would do once started.

Problems reported: an invalid or never-matching `schedule=`, a `runat=` that
is not a date, a script that is missing or not executable, a `.sh` with no
`.conf`, and a `.conf` with neither key. The exit status is 0 with no problems
and 1 with any, so `--explain` can gate a deploy of new job files.

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
Run `--explain` first to confirm the job will run when you expect.
