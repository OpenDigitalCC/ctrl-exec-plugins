---
title: nagios-check
subtitle: Run named Nagios plugins on an agent and get the result back as JSON
---

# nagios-check

## Purpose

Hosts usually have the Nagios plugins already (`monitoring-plugins`: disk,
load, swap, procs, http, ssl, dns, ntp and many more). `nagios-check` lets the
dispatcher run them through ctrl-exec and read the answer as one JSON
document, so their results sit beside other statistics and can be aggregated
the same way for every host. It does what NRPE does, with ctrl-exec's own
transport, trust and logging and no extra daemon or port.

The plugin has two halves.

`nagios-check.pl`
: The agent script, Perl with core modules only. Given check names it runs the
  matching plugins and prints one JSON document: per check the state, summary,
  parsed performance data, long output and duration, and the worst state
  overall. The exit code is that overall state.

`run-jobs/nagios-checks.sh`
: A dispatcher-side run-jobs job. It names the checks to run on each agent and
  logs one syslog line per check that is not OK, and one summary line per run.

### Who decides what

The caller at the dispatcher decides **what** is checked and **when**. The
agent decides **how**.

| | Decided by | Where |
| --- | --- | --- |
| Which checks run | the caller | the names given as arguments on each run |
| When they run | the caller | its own schedule (a run-jobs job, cron, a person) |
| Which plugin and arguments a name means | the agent | `nagios-checks.conf` on the agent |
| Thresholds, paths, plugin directories, timeout, run budget | the agent | `nagios-checks.conf` on the agent |

The script sends nothing to a plugin that the agent's own file did not
contain. The caller can only choose among the names the agent offers; it
cannot add an argument, change a threshold or name a plugin. A name the agent
does not know is refused before anything runs. The agent never runs a check
on its own initiative, and there is no default set: a run with no arguments
fails. `--all` is an explicit request for every configured check.


## Dependencies

| Dependency | Needed on | For |
| --- | --- | --- |
| `perl` with core modules (JSON::PP, POSIX, Time::HiRes, Cwd, Encode, Sys::Hostname) | the agent | `nagios-check.pl` |
| the Nagios plugins (`monitoring-plugins-basic`, and `-standard` for http, ssl and similar) | the agent | the checks themselves |
| `ctrl-exec-cli`, `perl`, `logger` | the run-jobs image | `run-jobs/nagios-checks.sh` |
| `bash` | both | `test/run.sh` and the job |

The plugins live in `/usr/lib/nagios/plugins` on Debian and Ubuntu; plugins
you add yourself can go in `/usr/local/lib/nagios/plugins`, which is searched
too. Other layouts set `plugin_dir`. `monitoring-plugins` has no memory check;
this plugin ships one, `plugins/check_mem` (see below).


## Installation

On each agent, install the script and its configuration:

```bash
sudo install -o root -g root -m 755 nagios-check.pl /opt/ctrl-exec-scripts/nagios-check
sudo install -o root -g root -m 644 nagios-checks.conf /etc/nagios-checks.conf
```

Keep both owned by root and not writable by others: the configuration
decides what the script executes. The script normally runs as an unprivileged
`run_as` user (see scripts.conf below), so the configuration must be readable
by that user: root-owned, mode 644. It is not under `/etc/ctrl-exec-agent`
because that directory is mode 750 and the unprivileged user cannot enter it.
When the file cannot be read, the error names the user that tried
(`cannot read config /etc/nagios-checks.conf as user nobody: Permission denied`).

`nagios-checks.conf.example` is a standard set of checks for a Debian host
(disk, load, mem, swap, zombies, procs): copy it and adjust the thresholds.

On the dispatcher, copy `run-jobs/nagios-checks.sh` and a
`nagios-checks.conf` (from `nagios-checks.conf.example`) into the run-jobs
scripts folder.

### nagios-checks.conf (agent)

Default path `/etc/nagios-checks.conf`; the environment
variable `NAGIOS_CHECKS_CONF` overrides it (the tests use this).

```ini
# Settings (all optional)
plugin_dir = /usr/lib/nagios/plugins:/usr/local/lib/nagios/plugins
timeout    = 10
budget     = 50

# Checks: name = plugin and its fixed arguments
disk_root  = check_disk -w 20% -c 10% -p /
load       = check_load -r -w 2,1.5,1 -c 4,3,2
swap       = check_swap -w 50% -c 20%
web        = check_http -H www.example.com -u /health -w 1 -c 3
cert       = check_http -H www.example.com -S -C 21,7
```

`key = value` lines; blank lines and lines starting with `#` are ignored.
Comments go on their own line only.

Settings and checks
: `plugin_dir`, `timeout` and `budget` are the reserved keys. Every other key
  is a check name, so those three words cannot be check names. A name is letters,
  digits, `_` and `-`. Names are unique; a repeated name is an error.

`plugin_dir`
: The directories the plugins are in, separated by `:` and searched in order;
  the first directory that has the file wins. Default
  `/usr/lib/nagios/plugins:/usr/local/lib/nagios/plugins`, so plugins added
  locally need no write access to the package's directory.

`timeout`
: Seconds each check may run. Default 10. When it expires the plugin's whole
  process group is killed and the check is UNKNOWN.

`budget`
: Seconds one run (one call of the script) may take in all. A whole number of
  at least 1; default 50. See Run budget below.

Check value
: The first word is the plugin: a file name in `plugin_dir`, with no `/`. The
  rest are its arguments. There is no shell. Words split on whitespace;
  `'single'` or `"double"` quotes group words (quotes are removed; there are no
  escape characters, so use the other kind of quote to include one); a quoted
  piece next to other text joins into one word; `''` is an empty argument.
  `$`, `;`, `|`, `*`, backticks and `>` mean nothing and reach the plugin as
  they are.

A configuration the script cannot read or parse stops the run with exit 3 and
an `error` naming the file and line.

Each plugin is started by `exec` of the resolved path. The plugin name must
contain no `/`, and the path, after resolving symlinks, must be inside
the `plugin_dir` directory it was found in; a symlink that leads elsewhere is
refused. A check that fails either test, or whose plugin is missing or not
executable, is UNKNOWN at once and the other checks still run. The summary
names the plugin and the directories searched, for example
`check_mem: plugin not found in /usr/lib/nagios/plugins:/usr/local/lib/nagios/plugins`.

### Run budget

The checks in one call run one after another, and the dispatcher waits for the
whole call at most its `read_timeout` (default 60 s). If the call is still
running then, the dispatcher gives up and every check on that host is lost,
including those that had finished (logged UNKNOWN "read timeout"). The
`budget` makes sure a reply always comes back first: keep it **below the
dispatcher's `read_timeout`** (50 against 60 by default).

- Each check gets the smaller of its `timeout` and the budget left. A check cut
  short this way reports `timed out after 1s (run budget)`.
- A check that cannot start because the budget is spent is UNKNOWN with the
  summary `not run: run budget of 50s spent` and a duration of 0.
- When the timeouts of the selected checks add up to more than the budget
  (six checks at 10 s are 60 s), the JSON has a top-level `warning` and the
  same text goes to stderr; the JSON on stdout stays one valid document:

  ```json
  {"host":"agent-01","warning":"check timeouts add up to 70s, over the 50s budget; split the checks over several calls or lower timeout", ...}
  ```

The sum counts every check at its full timeout, although most finish at once;
it is a bound, not a forecast. Split local checks (disk, load, mem, swap,
procs: quick) from network checks (http, ssl, ping, dns: can wait for their
timeout) into separate calls, so a slow network check cannot starve the local
ones and each call has its own budget. In the job that is two `check =` lines
for the same agent.

### check_mem

`plugins/check_mem` is a small bash plugin: available memory as a percent of
total, from `MemTotal` and `MemAvailable` in `/proc/meminfo`.

```bash
sudo install -o root -g root -m 755 plugins/check_mem /usr/local/lib/nagios/plugins/check_mem
```

```
check_mem [-w <pct>] [-c <pct>]
```

WARNING when available memory is below `-w` percent of total, CRITICAL below
`-c` (defaults 10 and 5; `-w` must not be below `-c`). Exit 0, 1, 2, or 3 with
an UNKNOWN line on bad arguments or when `MemAvailable` is missing:

```
MEM OK - 62% available (9.8 GiB of 15.6 GiB) | available=10522MB;1597;798;0;15972 available_pct=62%;10;5;0;100
```

The variable `CHECK_MEM_MEMINFO` names a file to read instead of
`/proc/meminfo`. It is for the tests only; leave it unset.


## scripts.conf

On each agent, in `/etc/ctrl-exec-agent/scripts.conf`:

```ini
nagios-check = /opt/ctrl-exec-scripts/nagios-check profile=monitor
```

The script reads no files except its configuration and runs only the plugins
named there, so run it under a profile with no more privilege than the
plugins need. In `/etc/ctrl-exec-agent/agent.conf`:

```ini
[profile monitor]
run_as = nagios
```

Use a profile that has `run_as` set to an unprivileged account rather than
root; `nagios` above is an example name, create the account if the host has
none. Some plugins need more. Profiles set no_new_privileges by default, so a
setuid plugin such as `check_icmp` does not gain its privilege under one: use
a check that needs none (`check_ping`), or a profile with the capability it
needs. Checks that read protected logs need a user that can read them. Reload with `systemctl reload
ctrl-exec-agent`; a changed `agent.conf` needs `systemctl restart
ctrl-exec-agent`. Profiles are applied only when the executor is enabled.

The script name must match the name the dispatcher is given (`--script
nagios-check`). The sidecar `nagios-check.pl.schema.json` describes the
arguments for tools that read it.


## Subcommands

The arguments are check names, or one of two options.

`nagios-check <name> [<name> ...]`
: Run the named checks, in the order given (a name repeated runs once).
  Every name is checked against the configuration first; one unknown name
  stops the run before anything executes.

`nagios-check --list`
: Print the checks this host offers and whether each plugin can be run, so a
  caller can see before running:

  ```json
  {"host":"agent-01","checks":[
    {"name":"disk","plugin":"check_disk","available":true},
    {"name":"mem","plugin":"check_mem","available":false,"reason":"plugin not found in /usr/lib/nagios/plugins"}]}
  ```

  Only the plugin name is shown, not its arguments; those are the agent's
  business. Exit 0 when every plugin is available, 3 when any is not (missing,
  not executable, or outside `plugin_dir`).

`nagios-check --all`
: Run every configured check. An explicit request; a run with no arguments is
  an error.

### Output

One JSON document on stdout:

```json
{"host":"agent-01","state":"WARNING","code":1,"checks":[
  {"name":"disk_root","state":"WARNING","code":1,
   "summary":"DISK WARNING - free space: / 2800 MB (16%)",
   "perfdata":[{"label":"/","value":14280,"uom":"MB","warn":13824,"crit":15552,"min":0,"max":17280}],
   "long_output":"","duration_ms":41}]}
```

State and exit code
: `OK` 0, `WARNING` 1, `CRITICAL` 2, `UNKNOWN` 3. The overall state is the
  worst check by severity **CRITICAL > WARNING > UNKNOWN > OK**, so a
  CRITICAL anywhere shows as CRITICAL (exit 2), and an UNKNOWN beside only OK
  checks shows as UNKNOWN (exit 3). The script exits with the code of the
  overall state, so a plain `ctrl-exec-cli run` caller can read it without
  parsing.

UNKNOWN with a reason
: A check is UNKNOWN, with the reason as its summary, when the plugin is not
  found or not executable, resolves outside `plugin_dir`, exceeds the timeout,
  is killed by a signal, or exits with a code other than 0 to 3. The reason is
  followed by the plugin's first output line when it printed one.

Wrapper errors
: No arguments, an unreadable or invalid configuration, an unknown or
  malformed check name: exit 3 and
  `{"state":"UNKNOWN","code":3,"error":"unknown check 'nosuch'"}`. With no
  arguments the usage line is also written to stderr.

Plugin output
: The first line is `summary | perfdata`. Later lines are long output; a `|`
  in a later line starts more perfdata, which runs to the end, as the Nagios
  plugin guidelines say. The plugin's stderr is merged into its output.
  Output is read up to 64 KiB per check.

Performance data
: Each item `'label'=value[UOM];[warn];[crit];[min];[max]` becomes an object.
  Quoted labels may contain spaces and `''` for a quote. `value`, `min`, `max`,
  `warn` and `crit` are JSON numbers when numeric and `null` when empty or `U`;
  `warn` and `crit` stay strings when they are ranges (`10:20`, `@5:10`,
  `~:5`, `10:`). `uom` is the unit text (`s`, `ms`, `us`, `%`, `B`, `KB`, `MB`,
  `GB`, `TB`, `c`) or an empty string. An item with no readable value is
  skipped.


## The job

`run-jobs/nagios-checks.sh` is a run-jobs job; its configuration
`nagios-checks.conf` sits beside it (`nagios-checks.conf.example` is the
template).

```ini
schedule = */5 * * * *
check    = agent-01 disk_root load swap
check    = agent-02 disk_root load
check    = agent-03 disk load mem
check    = agent-03 web_health ping_gateway
```

The schedule is the caller's timing; each `check =` line is one call to one
agent with the names to ask it for. An agent can have several lines: they are
separate calls, each with its own run budget, which is how to split local
checks from network checks (agent-03 above). For each line the job runs

```bash
ctrl-exec-cli --json run agent-01 --script nagios-check -- disk_root load swap
```

and logs, with `logger -t ctrl-exec-nagios`, one line per check that is not OK
and one summary line per run:

```
host=agent-01 check=disk_root state=CRITICAL summary="DISK CRITICAL - free space: / 120 MB (1%)"
status=critical hosts=2 checks=5 ok=3 warning=0 critical=1 unknown=1
```

Priorities: OK `user.info`, WARNING `user.warning`, CRITICAL and UNKNOWN
`user.err`; the summary line takes the priority of the worst state. An agent
that cannot be reached, refuses the script, or returns something unreadable
makes each of its checks UNKNOWN, with the reason in the summary. The job
exits 0 when every check is OK and 1 otherwise, and prints the summary line.
Environment: `NAGIOS_TAG` (default `ctrl-exec-nagios`), `NAGIOS_SCRIPT`
(default `nagios-check`), `NAGIOS_JOB_CONF`.

Log monitor rule, in prose: alert on any `ctrl-exec-nagios` line containing
`state=WARNING`, `state=CRITICAL` or `state=UNKNOWN`, and when no
`status=ok` summary has been seen for three scheduled runs.


## Examples

What does this host offer:

```bash
ctrl-exec-cli run agent-01 --script nagios-check -- --list
```

Run two checks and read the JSON:

```bash
ctrl-exec-cli --json run agent-01 --script nagios-check -- disk_root load
```

The `stdout` of each entry in `results` is the document above; `exit` is the
overall code. The plain form prints it under the host name and ctrl-exec-cli
exits 1 for any non-zero code.

Several agents at once, the same names:

```bash
ctrl-exec-cli --json run agent-01 agent-02 --script nagios-check -- load
```

Read one check's state from a script (`jq` on the dispatcher):

```bash
ctrl-exec-cli --json run agent-01 --script nagios-check -- disk_root \
  | jq -r '.results[0].stdout | fromjson | .checks[0].state'
```

Trying a configuration on an agent without ctrl-exec:

```bash
NAGIOS_CHECKS_CONF=./nagios-checks.conf ./nagios-check.pl --list
NAGIOS_CHECKS_CONF=./nagios-checks.conf ./nagios-check.pl load; echo $?
```

### Running the plugin's tests

```bash
bash test/run.sh | tee test/TEST-REPORT.md
```

The suite uses fake plugins in a temporary folder (small shell scripts), a
fake meminfo for `check_mem`, and a stub `ctrl-exec-cli` and `logger` for the
job. When `monitoring-plugins` is
installed it also runs a real `check_load` and `check_disk`; otherwise that
section is skipped. It needs `perl` and `bash`, no network and no root, and
each timeout test waits one or two seconds.


## Limitations

- Checks run one after another, within the run budget (default 50 s) that
  keeps the whole call under the dispatcher's `read_timeout` (default 60 s).
  Checks whose timeouts add up to more than the budget may be reported "not
  run"; split them across calls, lower `timeout`, or raise both `budget` and
  `read_timeout` (keeping the budget below the read timeout).
- The plugin's stderr is merged with its stdout, and each check's output is
  read up to 64 KiB.
- A symlink in a `plugin_dir` directory that resolves outside that directory
  is refused, so a plugin that is a link into another directory (some
  distributions do this) has to be reached through a `plugin_dir` entry that
  contains the real file.
- The plugin runs with no standard input, `LC_ALL=C`, and the environment the
  agent gives the script (`PATH` is set if the agent gave none). Plugins that
  need other variables are not supported.
- ctrl-exec does not run the same script twice at once on one agent; a second
  run while one is in progress is refused with a lock conflict, which the job
  reports as UNKNOWN for that agent.
- The script keeps no history and does no alerting of its own. Trends,
  acknowledgements and notification belong to whatever reads the syslog lines
  or the JSON.
- Nothing distributes `nagios-checks.conf` to the agents; install it as any
  other agent configuration.
