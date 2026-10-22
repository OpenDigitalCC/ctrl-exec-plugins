---
title: config-deploy
subtitle: Write named config files on an agent from contents the dispatcher sends
---

# config-deploy

## Purpose

Changing a config file on an agent usually means logging in and copying it.
`config-deploy` lets the dispatcher carry the file through ctrl-exec instead,
with tighter limits than root ssh or a configuration-management agent: the
dispatcher can write only the files the agent's own map names, to the places
the map gives, and only if the agent's own check accepts them.

The plugin has two halves.

`agent-config-deploy.pl`
: The agent script, Perl with core modules only. Given a name and the new
  contents it writes the file the map calls that name: staged beside the
  target, owner and mode set, checked by the map's `validate` command, the old
  file kept as `<path>.prev`, then renamed into place. It answers with one
  JSON document.

`run-jobs/config-push.sh`
: A dispatcher-side run-jobs job. It reads `push = <agent> <name> <source file>`
  lines, sends each file, and logs one syslog line per push and one summary
  per run. `--check` compares what the agents have with the local files and
  pushes nothing.

### Who decides what

| | Decided by | Where |
| --- | --- | --- |
| Which names exist, and what each is | the agent | `config-deploy.conf` on the agent |
| The path, owner and mode a file gets | the agent | `config-deploy.conf` on the agent |
| Whether new contents are acceptable | the agent | the map's `validate` command |
| Which agent gets which file, and when | the caller | `config-push.conf`, or a person |
| The contents | the caller | input field `content` |

The caller sends a name and the contents. It cannot name a path, an owner, a
mode or a command; a name the map does not know is refused before anything is
written. The map itself is never writable through this script: its path is
refused as a target, and so is everything under `/etc/ctrl-exec-agent` and
`/etc/ctrl-exec-dispatcher`.

### Files only

Scripts are deliberately **not** a supported target. A script that ctrl-exec
runs as root, replaced by whatever the dispatcher sends, would make the
dispatcher root on the agent, which is the opposite of what the allowlist and
the profiles are for. Keep the map to configuration that a program reads, and
do not map a file that ctrl-exec, cron, systemd or a login will run. Pushing
scripts, or extending the map from the dispatcher under supervision, needs its
own design (task T-072) and is not done here.


## Dependencies

| Dependency | Needed on | For |
| --- | --- | --- |
| `perl` with core modules (JSON::PP, Digest::SHA, POSIX, Cwd, Encode, File::Basename, Fcntl, IO::Handle, Sys::Hostname, Time::HiRes) | the agent | `agent-config-deploy.pl` |
| the executor (`executor_socket` in `agent.conf`) | the agent | the profile's `writable` confinement and `input=fields`; without it the script runs as the agent's own user |
| `ctrl-exec-cli`, `perl`, `logger` | the run-jobs image | `run-jobs/config-push.sh` |
| `bash` | both | `install.sh`, `test/run.sh` and the job |

ctrl-exec 0.13.0 or later is needed for `input=fields`.


## Installation

### Install with install.sh

Copy this plugin folder to the agent host and run it as root:

```bash
sudo ./install.sh --dry-run
sudo ./install.sh
```

`--script-dir DIR` sets where the agent script goes (default
`/opt/ctrl-exec-scripts`; use `--script-dir /srv/scripts` where the scripts
live there). `--dry-run` checks everything, says what would change and
changes nothing; it runs as any user.

It installs `agent-config-deploy.pl` into the script directory (root:root
755; a different copy is replaced, it is this plugin's own file), puts
`config-deploy.conf.example` at `/etc/ctrl-exec-agent/config-deploy.conf`
(root:root, mode 600) when there is none, adds
`agent-config-deploy = <script-dir>/agent-config-deploy.pl profile=config-deploy input=fields`
to `/etc/ctrl-exec-agent/scripts.conf`, reloads the agent when that file
changed, and finally runs `--list` to show what the map offers. Each step
prints one line: `ok`, `changed`, `skip`, `warn` or `FAIL`, then
`done: N changed, N warnings`. A second run changes nothing.

It never overwrites what the host already has. An existing map is kept and
the shipped one is written beside it as `config-deploy.conf.new`, with a
warning. An existing `agent-config-deploy =` line in `scripts.conf` is left as
it is, with a warning when it names another path. `agent.conf` is never
edited: when it has no `[profile config-deploy]` the installer warns and
prints the profile to add (see scripts.conf below). It stops with FAIL when
`scripts.conf` does not exist (agent not installed).

### Manual installation

```bash
sudo install -o root -g root -m 755 agent-config-deploy.pl /opt/ctrl-exec-scripts/agent-config-deploy.pl
sudo install -o root -g root -m 600 config-deploy.conf.example /etc/ctrl-exec-agent/config-deploy.conf
```

On the dispatcher, copy `run-jobs/config-push.sh` and a `config-push.conf`
(from `config-push.conf.example`) into the run-jobs scripts folder.

### config-deploy.conf (agent)

Default path `/etc/ctrl-exec-agent/config-deploy.conf`; the environment
variable `CONFIG_DEPLOY_MAP` overrides it (the tests use this). One entry per
line; blank lines and lines starting with `#` are ignored. Comments go on
their own line only.

```ini
<name> = <absolute path> [owner=<user>:<group>] [mode=<octal>] [validate=<command and args, {} = staged file>]
```

```ini
nagios-checks = /etc/nagios-checks/checks.conf owner=root:root mode=0644 validate=/opt/ctrl-exec-scripts/nagios-check.pl --check-config {}
```

`name`
: What the caller asks for: letters, digits, `_` and `-`. Unique.

`path`
: Absolute, with no `..`, `.` or empty segment and no trailing `/`. The
  folder must already exist; it is never created. The file is replaced if it
  exists and created if it does not. The path may not be, or be under,
  `/etc/ctrl-exec-agent` or `/etc/ctrl-exec-dispatcher` (the folder is
  resolved through symlinks first, so a link into them is caught), and may not
  be the map file.

`owner`
: `user:group`, names or numbers, that must exist on the host. Default
  `root:root`.

`mode`
: Octal, such as `0644` or `600`; no setuid, setgid or sticky bits. Default
  `0644`.

`validate`
: Takes the rest of the line, so it comes last. The command and its arguments
  split on whitespace and are run as an argument list, never through a shell;
  every `{}` becomes the path of the staged file. The first word must be an
  absolute path to an executable and at least one `{}` is required. Exit 0
  accepts the contents; anything else refuses them. It runs with no input, for
  at most 30 seconds, as the user and with the capabilities of the script's
  profile.

The whole map is refused, with exit 1 and an `error` that names the line,
when it is not owned by root, is group- or world-writable, or has a line that
breaks any rule above. The error names the key or option at fault and never
repeats the line. A map that is refused refuses every call, `--list` included.


## scripts.conf

On each agent, in `/etc/ctrl-exec-agent/scripts.conf`:

```ini
agent-config-deploy = /opt/ctrl-exec-scripts/agent-config-deploy.pl profile=config-deploy input=fields
```

`input=fields` makes ctrl-exec hand the script the run's input as files under
`$CTRL_EXEC_INPUT`; the contents are the file `content`.

Define the profile in `/etc/ctrl-exec-agent/agent.conf`:

```ini
[profile config-deploy]
run_as   = root
writable = /etc/nagios-checks
```

`run_as = root`
: The script has to write root-owned folders and set owners.

`writable`
: A colon-separated list of the **folders** the map's files are in (each
  absolute). With the executor enabled that confines the script: it can write
  nowhere else, whatever the map says, so a mistake in the map cannot reach
  past these folders. Add a folder here when a map entry needs one. The staged
  file and `.prev` live in the target's folder, so no other folder is needed.
  The input folder is readable inside the confinement and needs no entry.

`caps`
: A profile holds only the capabilities it lists. Writing and renaming in a
  root-owned folder as root needs none. To give a file an owner other than the
  one root already is, add `caps = CAP_CHOWN`; to read or replace files owned
  by someone else with a restrictive mode, `CAP_DAC_OVERRIDE` would be needed
  and is better avoided by keeping those folders root-owned.

Reload with `systemctl reload ctrl-exec-agent`. The agent does not reread
`agent.conf` on reload, so after adding or changing a profile run
`systemctl restart ctrl-exec-agent`. Profiles are applied only when the
executor is enabled; without it the script runs as the agent's own user, and
`run_as`, `caps` and `writable` are ignored.

The script name must match the name the dispatcher is given (`--script
agent-config-deploy`). The sidecar `agent-config-deploy.pl.schema.json`
declares the call destructive and describes the `content` input field.


## Subcommands

`agent-config-deploy <name>`
: Write the file. The contents come from the input field `content` (at most
  1 MiB). Steps, in order:

  1. The name must be in the map; the folder must exist; the target must not
     be a symlink and must be a regular file if it exists.
  2. When the sha256 of the installed file equals the new contents, nothing is
     written: `changed` is `false`, no `.prev` is made, validate does not run.
  3. Otherwise the contents are staged as `.<file>.new.<pid>` in the target's
     folder, the owner and mode are set, and `validate` runs on the staged
     file. A non-zero exit, a timeout or a missing command removes the staged
     file and stops with exit 1; the installed file is untouched.
  4. The installed file is copied to `<path>.prev` (mode and owner kept;
     replacing an older `.prev`), and the staged file is renamed over the
     target, which is atomic.

`agent-config-deploy --test <name>`
: Everything except the last step: the contents are staged and validated,
  then the staged file is removed. Reports `would_change`.

`agent-config-deploy --list`
: Every entry in the map, in order. Contents are never shown.

No arguments or an unknown option prints the usage on stderr and exits 2.

### Output

One JSON document on stdout; warnings go to stderr only.

A write:

```json
{"host":"agent-01","name":"nagios-checks","path":"/etc/nagios-checks/checks.conf",
 "changed":true,"sha256":"9f2b...","previous_sha256":"41c0...",
 "validate":{"ran":true,"exit":0,"output":""}}
```

`previous_sha256` is `null` when the file is new; `validate.ran` is `false`
when the map has no `validate` or nothing needed writing. `--test` adds
`"test":true,"would_change":true|false` and always has `changed:false`.

`--list`:

```json
{"host":"agent-01","files":[
  {"name":"nagios-checks","path":"/etc/nagios-checks/checks.conf","exists":true,
   "sha256":"9f2b...","size":1042,"owner":"root:root","mode":"0644","validate":true}]}
```

A missing file has `exists:false` and `null` for sha256, size, owner and mode.
A target that is a symlink shows `exists:true,"symlink":true` and no hash.

An error, with exit 1:

```json
{"host":"agent-01","error":"validate failed (exit 3): line 4: unknown option 'x'",
 "name":"nagios-checks","path":"/etc/nagios-checks/checks.conf",
 "validate":{"ran":true,"exit":3,"output":"line 4: unknown option 'x'"}}
```

The validate output (stdout and stderr together) is trimmed and cut at 2000
characters. `name`, `path` and `validate` are present on a validate failure
only. An unknown name lists the known names and nothing else: `unknown config
name 'x'; known: nagios-checks, app-settings`.

When the script is not running as root (tests, or no executor with an
unprivileged agent) the owner cannot be set; the mode still is, and a warning
goes to stderr when the owner would differ.

### Exit codes

`0` worked (also when nothing needed writing), `1` refused or failed (the
document has `error`), `2` bad usage.


## The job

`run-jobs/config-push.sh` is a run-jobs job; its configuration
`config-push.conf` sits beside it (`config-push.conf.example` is the
template).

```ini
push = agent-01 nagios-checks sources/nagios-checks.conf
push = agent-02 nagios-checks sources/nagios-checks.conf
```

Each line is one call to one agent. A relative source file is taken from the
folder of the config file. There is no `schedule` line: run the job when a
file has changed. A `schedule = <cron expression>` line can be added if
run-jobs should push on a timer; unchanged files cost one call each and write
nothing.

```bash
./config-push.sh                  # push every line
./config-push.sh agent-01         # only the lines for agent-01 (more agents may follow)
./config-push.sh --check          # compare only; push nothing
```

For each line the job runs

```bash
ctrl-exec-cli run agent-01 --script agent-config-deploy --json --input-fields - -- nagios-checks
```

with the file's text on stdin as `{"content":"..."}`; it is built with perl
and held in a shell variable, so it is in no argument and no environment. The
source must be UTF-8 text of at most 1 MiB. With `--check` it runs
`... --json -- --list`, compares the agent's sha256 with the source's and
sends nothing.

It logs with `logger -t ctrl-exec-config` one line per result and a summary,
and prints the same:

```
agent=agent-01 name=nagios-checks result=changed sha256=9f2b0c41aa07
agent=agent-02 name=nagios-checks result=unchanged sha256=9f2b0c41aa07
agent=agent-03 name=nagios-checks result=failed error="validate failed (exit 3): line 4: ..."
status=failed mode=push lines=3 changed=1 unchanged=1 same=0 differs=0 missing=0 failed=1
```

`result` is `changed`, `unchanged` or `failed` for a push, and `same`,
`differs`, `missing` or `failed` for `--check`. Priorities: `changed`,
`unchanged` and `same` info; `differs` and `missing` warning; `failed` err; the
summary takes the worst. An agent that cannot be reached, refuses the script,
refuses the contents or returns something unreadable is `failed` with the
reason. The job carries on with the other lines. Exit 0 when every line was
pushed (or is the same, with `--check`), 1 otherwise.

Environment: `CONFIG_PUSH_TAG` (default `ctrl-exec-config`),
`CONFIG_PUSH_SCRIPT` (default `agent-config-deploy`), `CONFIG_PUSH_CONF`.


## Examples

What does this agent accept, and what does it hold now:

```bash
ctrl-exec-cli run agent-01 --script agent-config-deploy -- --list
```

Try a file without installing it (the contents on stdin as input fields):

```bash
echo '{"content":"..."}' | ctrl-exec-cli run agent-01 --script agent-config-deploy --json --input-fields - -- --test nagios-checks
```

Push a file to one agent, and check all of them:

```bash
./config-push.sh agent-01
./config-push.sh --check
```

Read the result of a push from a script (`jq` on the dispatcher):

```bash
ctrl-exec-cli run agent-01 --script agent-config-deploy --json --input-fields - -- nagios-checks < fields.json \
  | jq -r '.results[0].stdout | fromjson | .changed'
```

Trying the script without ctrl-exec:

```bash
mkdir -p /tmp/in && cp my.conf /tmp/in/content
CONFIG_DEPLOY_MAP=./map CONFIG_DEPLOY_ALLOW_NONROOT=1 CTRL_EXEC_INPUT=/tmp/in ./agent-config-deploy.pl --test nagios-checks
```

### Running the plugin's tests

```bash
bash test/run.sh | tee test/TEST-REPORT.md
```

The suite uses a temporary folder as the target, a stub `ctrl-exec-cli` that
runs the real script, and a stub `logger` and `systemctl`. It needs `perl` and
`bash`, no network and no root; the checks that need root are skipped when it
is not. Test-only environment: `CONFIG_DEPLOY_ALLOW_NONROOT=1` (skip the
map-owned-by-root check), `CONFIG_DEPLOY_PROTECTED` (extra folders that may
not be targets) and `CONFIG_DEPLOY_VALIDATE_TIMEOUT` (seconds, default 30).
Leave them unset on a real host.


## Limitations

- Files only, by design (see Purpose). Changing the map, or pushing a script,
  is not possible through this plugin.
- One file per call, at most 1 MiB, text from the dispatcher side (the job
  refuses a source that is not UTF-8; the script itself writes any bytes).
- The check for "unchanged" is the content only: a file whose owner or mode
  has drifted but whose contents match is left as it is. Fix the mode on the
  host, or change the contents.
- `.prev` keeps one generation: the file just replaced.
- The target must be a regular file and not a symlink; a symlinked folder is
  followed (and checked against the protected folders) but a symlinked file is
  refused.
- With the executor off the script has no confinement and runs as the agent's
  user: `run_as`, `caps` and `writable` are ignored, and the owner is not
  applied unless that user may do so.
- `validate` is only as good as the command: it should parse the file the way
  the program that reads it will.
- ctrl-exec does not run the same script twice at once on one agent; a second
  push to an agent while one is running is refused with a lock conflict,
  which the job reports as `failed`.
- Nothing reloads the service that reads the file. Make the program reread its
  configuration on its own, or follow the push with a service restart.
