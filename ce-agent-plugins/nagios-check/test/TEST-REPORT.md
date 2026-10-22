# Test report: nagios-check (ce-agent-plugins)
Generated: 2026-10-22T17:56:14Z

## Contract: no arguments and the sidecar

  PASS  no arguments exits 3
  PASS  no arguments prints usage on stderr
  PASS  no arguments: stdout is one JSON document
  PASS  no arguments: state UNKNOWN with an error
  PASS  nagios-check.pl is executable
  PASS  nagios-check.pl has a perl shebang
  PASS  schema sidecar is valid JSON with arguments, argv and read_only
  PASS  perl -c passes
  PASS  wrapper stays small (304 lines)

## State mapping and the overall state

  PASS  OK: exit 0
  PASS  OK: state, code, summary
  PASS  OK: host is set
  PASS  OK: check fields
  PASS  OK: duration_ms is a number
  PASS  WARNING: exit 1
  PASS  WARNING: state and code
  PASS  CRITICAL: exit 2
  PASS  CRITICAL: state
  PASS  UNKNOWN: exit 3
  PASS  OK+WARNING: overall WARNING, exit 1
  PASS  OK+WARNING: per-check states kept
  PASS  OK+UNKNOWN: overall UNKNOWN, exit 3
  PASS  WARNING+UNKNOWN: overall WARNING (CRITICAL > WARNING > UNKNOWN > OK), exit 1
  PASS  all four: overall CRITICAL, exit 2
  PASS  all four: order as asked
  PASS  all four: top-level state
  PASS  a name given twice runs once
  PASS  --all runs every configured check in config order
  PASS  --all: exit is the worst (CRITICAL)
  PASS  a plugin that prints nothing: OK with an empty summary
  PASS  non-UTF-8 plugin output still gives valid JSON
  PASS  the plugin gets no stdin

## Perfdata

  PASS  perf plugin: exit 1
  PASS  summary stops at the first |
  PASS  ten items parsed, the malformed one skipped
  PASS  quoted label with a space, unit, all five fields
  PASS  '' inside a quoted label is one quote
  PASS  no unit: empty uom, other fields null
  PASS  fractional value, empty fields are null
  PASS  ranges stay strings (10:20 style, @ prefix), unit s
  PASS  value U is null
  PASS  percent unit
  PASS  ~:5 and 10: ranges kept as strings
  PASS  long output is the lines between, up to the |
  PASS  a | in the long output starts more perfdata
  PASS  ...and its unit c (counter)
  PASS  lines after that are perfdata too
  PASS  trailing empty fields (more=2;;) are null
  PASS  simple perfdata after a plain summary

## Failures are UNKNOWN with a reason, and never hide other checks

  PASS  timeout: UNKNOWN
  PASS  timeout: the reason says so
  PASS  timeout: returned promptly (1s)
  PASS  timeout: the next check still ran
  PASS  timeout: overall exit 3 (UNKNOWN beats OK)
  PASS  timeout: the plugin's child is killed too
  PASS  exit 7: UNKNOWN, reason and output
  PASS  killed by signal: UNKNOWN
  PASS  missing plugin: reason
  PASS  missing plugin: UNKNOWN
  PASS  non-executable plugin: reason
  PASS  symlink out of plugin_dir refused
  PASS  plugin with a / (absolute) refused
  PASS  plugin with a / (relative) refused
  PASS  plugin named .. refused
  PASS  one bad check does not hide the others
  PASS  plugin_dir missing: the check is UNKNOWN, not a crash

## Wrapper errors (exit 3, one JSON document with an error)

  PASS  name 'nosuch': error, exit 3
  PASS  name 'nosuch': exit 3 and valid JSON
  PASS  name 'a/b': error, exit 3
  PASS  name 'a/b': exit 3 and valid JSON
  PASS  name '..': error, exit 3
  PASS  name '..': exit 3 and valid JSON
  PASS  name '../ok': error, exit 3
  PASS  name '../ok': exit 3 and valid JSON
  PASS  name '--bogus': error, exit 3
  PASS  name '--bogus': exit 3 and valid JSON
  PASS  name 'OK;id': error, exit 3
  PASS  name 'OK;id': exit 3 and valid JSON
  PASS  name 'ok ': error, exit 3
  PASS  name 'ok ': exit 3 and valid JSON
  PASS  name '': error, exit 3
  PASS  name '': exit 3 and valid JSON
  PASS  one unknown name stops the run before anything runs
  PASS  ...and no check results
  PASS  --list with names: exit 3
  PASS  --all with names: exit 3
  PASS  missing config: exit 3
  PASS  missing config: names the file
  PASS  unreadable config: exit 3
  PASS  unreadable config: names the user that could not read it
  PASS  bad config 'garbage': exit 3
  PASS  bad config: error names the line
  PASS  bad config 'ok = ': exit 3
  PASS  bad config: error names the line
  PASS  bad config 'timeout = abc': exit 3
  PASS  bad config: error names the line
  PASS  bad config 'timeout = 0': exit 3
  PASS  bad config: error names the line
  PASS  bad config 'budget = 0': exit 3
  PASS  bad config: error names the line
  PASS  bad config 'budget = 1.5': exit 3
  PASS  bad config: error names the line
  PASS  bad config 'bad name = ok_p': exit 3
  PASS  bad config: error names the line
  PASS  bad config 'dup = ok_p / dup = ok_p': exit 3
  PASS  bad config: error names the line
  PASS  bad config 'q = ok_p 'unterminated': exit 3
  PASS  bad config: error names the line
  PASS  bad config 'q = ok_p "unterminated': exit 3
  PASS  bad config: error names the line
  PASS  empty config, --all: exit 3

## --list and the config format

  PASS  --list: exit 0
  PASS  --list: names in config order, settings are not checks
  PASS  --list: only host and checks
  PASS  --list: plugin name and availability, no arguments
  PASS  spaces around = and no spaces both work: exit 0
  PASS  both checks ran
  PASS  default plugin_dir: both Debian directories, in order, named in the summary
  PASS  --list names the plugin and the directories searched
  PASS  default config path is /etc/nagios-checks/checks.conf

## Config folder: default path, fallback to the old path

  PASS  new path exists: it is used
  PASS  new path exists: nothing on stderr
  PASS  only the old path exists: exit 0
  PASS  only the old path exists: it is used
  PASS  only the old path exists: stdout is one JSON document
  PASS  only the old path exists: one stderr line says so
  PASS  only the old path exists: exactly one line
  PASS  only the old path exists: a run works
  PASS  only the old path exists: a run's state
  PASS  neither exists: exit 3
  PASS  neither exists: the error names the new path
  PASS  neither exists: no fallback line
  PASS  NAGIOS_CHECKS_CONF set: no fallback to the old path
  PASS  NAGIOS_CHECKS_CONF set: no fallback line

## --check-config

  PASS  --check-config: exit 0 although a plugin is missing
  PASS  --check-config: stdout is one JSON document
  PASS  --check-config: the file's checks, one available, one not
  PASS  --check-config: the missing plugin has a reason
  PASS  --check-config: settings
  PASS  --check-config: names the file and the host
  PASS  --check-config: the configured config is not needed (absent.conf)
  PASS  --check-config: reads the file given, not the configured one
  PASS  --check-config: default settings when the file has none
  PASS  --check-config: a config with no checks parses (exit 0)
  PASS  --check-config: ...with an empty list
  PASS  --check-config: no plugin is run
  PASS  --check-config bad 'garbage topsecretword': exit 3
  PASS  --check-config bad: error names the file and a line
  PASS  --check-config bad: the line is not echoed
  PASS  --check-config bad: state and no checks
  PASS  --check-config bad 'ok = ': exit 3
  PASS  --check-config bad: error names the file and a line
  PASS  --check-config bad: the line is not echoed
  PASS  --check-config bad: state and no checks
  PASS  --check-config bad 'timeout = abc': exit 3
  PASS  --check-config bad: error names the file and a line
  PASS  --check-config bad: the line is not echoed
  PASS  --check-config bad: state and no checks
  PASS  --check-config bad 'budget = 0': exit 3
  PASS  --check-config bad: error names the file and a line
  PASS  --check-config bad: the line is not echoed
  PASS  --check-config bad: state and no checks
  PASS  --check-config bad 'bad name = ok_p': exit 3
  PASS  --check-config bad: error names the file and a line
  PASS  --check-config bad: the line is not echoed
  PASS  --check-config bad: state and no checks
  PASS  --check-config bad 'dup = ok_p / dup = ok_p': exit 3
  PASS  --check-config bad: error names the file and a line
  PASS  --check-config bad: the line is not echoed
  PASS  --check-config bad: state and no checks
  PASS  --check-config bad 'q = ok_p 'unterminated topsecretword': exit 3
  PASS  --check-config bad: error names the file and a line
  PASS  --check-config bad: the line is not echoed
  PASS  --check-config bad: state and no checks
  PASS  --check-config bad 'x = ok_p / y topsecretword': exit 3
  PASS  --check-config bad: error names the file and a line
  PASS  --check-config bad: the line is not echoed
  PASS  --check-config bad: state and no checks
  PASS  --check-config: a file outside the config folder: exit 3
  PASS  --check-config: ...says where it may read
  PASS  --check-config: ...and echoes nothing of it
  PASS  --check-config: a symlink in the folder: exit 3
  PASS  --check-config: ...echoes nothing of its target
  PASS  --check-config: a path that resolves into the folder is read
  PASS  --check-config: missing file exit 3
  PASS  --check-config: missing file named
  PASS  --check-config without a file: exit 3
  PASS  --check-config with two files: exit 3
  PASS  --check-config with a check name too: exit 3
  PASS  sidecar describes --check-config

## Argument splitting and no shell

  PASS  quotes group words, adjacent pieces join, '' is an empty argument
  PASS  shell metacharacters reach the plugin literally
  PASS  nothing was executed by a shell
  PASS  unquoted metacharacters are not run either
  PASS  ...they are plain words

## Run budget, default timeout and the warning

  PASS  default timeout 10: six checks add up to 60s, over the default budget of 50s
  PASS  the warning is also on stderr
  PASS  with a warning, stdout is still one JSON document
  PASS  with a warning the checks still ran
  PASS  five checks (50s) fit the default budget: no warning field
  PASS  ...and nothing on stderr
  PASS  budget spent: stdout is one JSON document
  PASS  effective timeout is capped by the budget left
  PASS  a check that cannot start is UNKNOWN 'not run' with duration 0
  PASS  the reply still comes back: three checks, overall UNKNOWN
  PASS  timeouts (15s) over the budget: warning names both
  PASS  a fast check within budget is untouched
  PASS  budget must be a whole number >= 1

## --list availability and plugin_dir with several directories

  PASS  --list with unavailable plugins: exit 3
  PASS  --list: available and unavailable, plugin name only
  PASS  --list: reason for a missing plugin
  PASS  --list: reason for a non-executable plugin
  PASS  --list: reason for a link that leaves plugin_dir
  PASS  --list: an available check has no reason and shows no arguments
  PASS  run: the summary names the plugin
  PASS  --list when all are available: exit 0
  PASS  several dirs: the first match wins
  PASS  several dirs: a plugin only in a later dir is found
  PASS  containment is checked against the dir the plugin was found in
  PASS  not found: every dir is named
  PASS  several dirs: order decides (reversed)

## check_mem

  PASS  check_mem is executable
  PASS  62% available: exit 0
  PASS  OK output with sizes
  PASS  perfdata in MB with warn/crit/min/max
  PASS  7% available, defaults: WARNING exit 1
  PASS  WARNING output
  PASS  2% available, defaults: CRITICAL exit 2
  PASS  CRITICAL output
  PASS  20% with -w 25 -c 10: WARNING
  PASS  10% with -w 25 -c 10: WARNING (CRITICAL is below the limit)
  PASS  9% with -w 25 -c 10: CRITICAL
  PASS  bad -w: UNKNOWN exit 3
  PASS  bad -w: says UNKNOWN
  PASS  -w below -c: UNKNOWN
  PASS  unknown option: UNKNOWN
  PASS  stray argument: UNKNOWN
  PASS  no MemAvailable: exit 3
  PASS  no MemAvailable: UNKNOWN names it
  PASS  no meminfo file: exit 3
  PASS  real /proc/meminfo: exit 0
  PASS  through the wrapper: perfdata parsed

## Real monitoring plugins

  SKIP  real plugins: /usr/lib/nagios/plugins/check_load not installed (monitoring-plugins)

## Job: nagios-checks.sh against a stub ctrl-exec-cli and logger

  PASS  all OK: exit 0
  PASS  all OK: one summary line, user.info
  PASS  all OK: the summary is also printed
  PASS  the CLI is asked with names only, one call per host
  PASS  WARNING and CRITICAL: exit 1
  PASS  WARNING line at user.warning
  PASS  CRITICAL line at user.err
  PASS  OK checks get no line
  PASS  summary: worst state, counts, user.err
  PASS  three lines in all (two checks plus summary)
  PASS  WARNING only: summary at user.warning
  PASS  unreachable agent: exit 1
  PASS  unreachable agent: each of its checks is UNKNOWN with the reason
  PASS  unreachable agent: counted
  PASS  agent refuses the script: UNKNOWN with the agent's words
  PASS  API error: UNKNOWN with the API's words
  PASS  unreadable reply: UNKNOWN
  PASS  agent lacks a requested check: wrapper error shown as UNKNOWN
  PASS  NAGIOS_TAG sets the tag
  PASS  NAGIOS_SCRIPT sets the agent script name
  PASS  no check lines: exit 1
  PASS  no check lines: status=unknown
  PASS  check line without names: exit 1
  PASS  check line without names: logged
  PASS  missing job config: exit 1
  PASS  missing job config: logged
  PASS  example config: agent-03 asked for its check
  PASS  example config: agent-01 asked for three checks
  PASS  example config: one agent, local and network checks in separate calls
  PASS  example config: ...the second call
  PASS  example config has a schedule
  PASS  nagios-checks.sh is executable

## install.sh (temp root, fake systemctl and runuser, no root needed)

  PASS  fresh install: exit 0
  PASS  fresh install: reports 5 changes (script, check_mem, folder, config, scripts.conf)
  PASS  fresh install: script installed 755
  PASS  fresh install: script is a copy of ours
  PASS  fresh install: check_mem installed
  PASS  fresh install: config is 644
  PASS  fresh install: config folder is 755
  PASS  fresh install: the folder is reported
  PASS  fresh install: nothing at the old path
  PASS  fresh install: scripts.conf entry added
  PASS  fresh install: agent reloaded
  PASS  fresh install: verify line printed
  PASS  second run: nothing changed
  PASS  second run: no changed line
  PASS  second run: no reload
  PASS  second run: scripts.conf has one entry
  PASS  existing config: kept
  PASS  existing config: shipped one in .new
  PASS  existing config: warned
  PASS  existing config: mode fixed and said so
  PASS  existing config: mode is 644
  PASS  different script replaced
  PASS  old path only: exit 0
  PASS  old path only: reported as changed
  PASS  old path only: the old file is gone
  PASS  old path only: contents kept
  PASS  old path only: the unprivileged user can read it (mode fixed)
  PASS  old path only: the shipped config is offered as .new
  PASS  old path only: not replaced by the example
  PASS  old path only, second run: nothing more to move
  PASS  old path only, second run: no move
  PASS  old path equals the example: moved
  PASS  old path equals the example: then matches it
  PASS  old path equals the example: no .new
  PASS  both exist: the new one is not overwritten
  PASS  both exist: the old one is left
  PASS  both exist: warned that the old one is not read
  PASS  both exist: nothing is moved
  PASS  existing folder: mode left alone
  PASS  existing folder: not created again
  PASS  existing folder that others cannot enter: warned
  PASS  dry-run, old path only: says it would move
  PASS  dry-run, old path only: nothing moved or made
  PASS  scripts.conf other path: warned with the path
  PASS  scripts.conf other path: left alone
  PASS  scripts.conf other path: no reload
  PASS  no scripts.conf: exit 1
  PASS  no scripts.conf: FAIL line
  PASS  no scripts.conf: says why
  PASS  no plugins: still exit 0
  PASS  no plugins: warns
  PASS  no default profile: warns
  PASS  no default profile: gives the snippet
  PASS  no default profile: agent.conf untouched
  PASS  dry-run: exit 0
  PASS  dry-run: says what would change
  PASS  dry-run: nothing written
  PASS  dry-run: scripts.conf untouched
  PASS  dry-run: no reload
  PASS  --script-dir: used
  PASS  non-root without --dry-run: exit 1
  PASS  non-root without --dry-run: FAIL
  PASS  install.sh is shellcheck clean

Results: 337 passed, 0 failed, 1 skipped
VERDICT: PASS
