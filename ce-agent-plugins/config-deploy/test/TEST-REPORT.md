# Test report: config-deploy (ce-agent-plugins)
Generated: 2026-10-22T17:48:22Z

## Contract: usage, the script and the sidecar

  PASS  no arguments exits 2
  PASS  no arguments prints usage on stderr
  PASS  no arguments: nothing on stdout
  PASS  unknown flag exits 2
  PASS  unknown flag prints usage on stderr
  PASS  --test without a name exits 2
  PASS  --list with a name exits 2
  PASS  two names exit 2
  PASS  agent-config-deploy.pl is executable
  PASS  agent-config-deploy.pl has a perl shebang
  PASS  perl -c passes
  PASS  sidecar: valid JSON, destructive, input field content

## The map: what is refused

  PASS  a good map is accepted
  PASS  comments, blank lines and spaces are fine
  PASS  entries kept in map order
  PASS  missing map: exit 1
  PASS  missing map: stdout is one JSON document
  PASS  missing map: error says why
  PASS  missing map: a write too: exit 1
  PASS  missing map: a write too: stdout is one JSON document
  PASS  missing map: a write too: error says why
  PASS  group-writable map: exit 1
  PASS  group-writable map: stdout is one JSON document
  PASS  group-writable map: error says why
  PASS  world-writable map: a write too: exit 1
  PASS  world-writable map: a write too: stdout is one JSON document
  PASS  world-writable map: a write too: error says why
  PASS  map not owned by root: exit 1
  PASS  map not owned by root: stdout is one JSON document
  PASS  map not owned by root: error says why
  PASS  unparsable line: exit 1
  PASS  unparsable line: stdout is one JSON document
  PASS  unparsable line: error says why
  PASS  unparsable line: the line is not echoed
  PASS  text after the path: exit 1
  PASS  text after the path: stdout is one JSON document
  PASS  text after the path: error says why
  PASS  text after the path: not echoed
  PASS  unknown option: exit 1
  PASS  unknown option: stdout is one JSON document
  PASS  unknown option: error says why
  PASS  unknown option: the value is not echoed
  PASS  option twice: exit 1
  PASS  option twice: stdout is one JSON document
  PASS  option twice: error says why
  PASS  no path: exit 1
  PASS  no path: stdout is one JSON document
  PASS  no path: error says why
  PASS  name with a space: exit 1
  PASS  name with a space: stdout is one JSON document
  PASS  name with a space: error says why
  PASS  name with a dot: exit 1
  PASS  name with a dot: stdout is one JSON document
  PASS  name with a dot: error says why
  PASS  duplicate name: exit 1
  PASS  duplicate name: stdout is one JSON document
  PASS  duplicate name: error says why
  PASS  duplicate name: names it
  PASS  relative path: exit 1
  PASS  relative path: stdout is one JSON document
  PASS  relative path: error says why
  PASS  path with ..: exit 1
  PASS  path with ..: stdout is one JSON document
  PASS  path with ..: error says why
  PASS  path with .. in the middle: exit 1
  PASS  path with .. in the middle: stdout is one JSON document
  PASS  path with .. in the middle: error says why
  PASS  path with //: exit 1
  PASS  path with //: stdout is one JSON document
  PASS  path with //: error says why
  PASS  path with .: exit 1
  PASS  path with .: stdout is one JSON document
  PASS  path with .: error says why
  PASS  path with a trailing /: exit 1
  PASS  path with a trailing /: stdout is one JSON document
  PASS  path with a trailing /: error says why
  PASS  path in /etc/ctrl-exec-agent: exit 1
  PASS  path in /etc/ctrl-exec-agent: stdout is one JSON document
  PASS  path in /etc/ctrl-exec-agent: error says why
  PASS  path is /etc/ctrl-exec-agent: exit 1
  PASS  path is /etc/ctrl-exec-agent: stdout is one JSON document
  PASS  path is /etc/ctrl-exec-agent: error says why
  PASS  path in /etc/ctrl-exec-dispatcher: exit 1
  PASS  path in /etc/ctrl-exec-dispatcher: stdout is one JSON document
  PASS  path in /etc/ctrl-exec-dispatcher: error says why
  PASS  path in a protected folder (CONFIG_DEPLOY_PROTECTED): exit 1
  PASS  path in a protected folder (CONFIG_DEPLOY_PROTECTED): stdout is one JSON document
  PASS  path in a protected folder (CONFIG_DEPLOY_PROTECTED): error says why
  PASS  path through a symlink into a protected folder: exit 1
  PASS  path through a symlink into a protected folder: stdout is one JSON document
  PASS  path through a symlink into a protected folder: error says why
  PASS  ...a write too: exit 1
  PASS  ...a write too: stdout is one JSON document
  PASS  ...a write too: error says why
  PASS  path is the map file itself: exit 1
  PASS  path is the map file itself: stdout is one JSON document
  PASS  path is the map file itself: error says why
  PASS  path is a symlink to the map file: exit 1
  PASS  path is a symlink to the map file: stdout is one JSON document
  PASS  path is a symlink to the map file: error says why
  PASS  unknown user: exit 1
  PASS  unknown user: stdout is one JSON document
  PASS  unknown user: error says why
  PASS  unknown group: exit 1
  PASS  unknown group: stdout is one JSON document
  PASS  unknown group: error says why
  PASS  owner without a group: exit 1
  PASS  owner without a group: stdout is one JSON document
  PASS  owner without a group: error says why
  PASS  mode not octal: exit 1
  PASS  mode not octal: stdout is one JSON document
  PASS  mode not octal: error says why
  PASS  mode with 8: exit 1
  PASS  mode with 8: stdout is one JSON document
  PASS  mode with 8: error says why
  PASS  setuid mode: exit 1
  PASS  setuid mode: stdout is one JSON document
  PASS  setuid mode: error says why
  PASS  empty validate: exit 1
  PASS  empty validate: stdout is one JSON document
  PASS  empty validate: error says why
  PASS  validate not absolute: exit 1
  PASS  validate not absolute: stdout is one JSON document
  PASS  validate not absolute: error says why
  PASS  validate with ..: exit 1
  PASS  validate with ..: stdout is one JSON document
  PASS  validate with ..: error says why
  PASS  validate without {}: exit 1
  PASS  validate without {}: stdout is one JSON document
  PASS  validate without {}: error says why
  PASS  a refused map refuses every call, not only the bad line: exit 1
  PASS  a refused map refuses every call, not only the bad line: stdout is one JSON document
  PASS  a refused map refuses every call, not only the bad line: error says why

## Write: new file, unchanged, changed

  PASS  new file: exit 0
  PASS  new file: stdout is one JSON document
  PASS  new file: changed true, no previous
  PASS  new file: sha256 of the content
  PASS  new file: host is set
  PASS  new file: validate did not run
  PASS  new file: content is exact
  PASS  new file: mode 0640 applied
  PASS  new file: no .prev
  PASS  new file: nothing left but the file
  PASS  unchanged: exit 0
  PASS  unchanged: changed false, previous equals sha
  PASS  unchanged: file not rewritten (inode and mtime)
  PASS  unchanged: no .prev
  PASS  unchanged: nothing left behind
  PASS  changed: exit 0
  PASS  changed: changed true, previous is the old sha
  PASS  changed: new sha256
  PASS  changed: the new content is installed
  PASS  changed: .prev holds the old content
  PASS  changed: .prev has the old file's mode (600)
  PASS  changed: the new file has the mapped mode, not the old one
  PASS  changed: nothing else left behind
  PASS  .prev is replaced by the file just superseded
  PASS  empty content: written
  PASS  empty content: the file is empty
  PASS  .prev symlink: write works
  PASS  .prev symlink: the link target is untouched

## Owner and mode

  PASS  default mode is 0644
  PASS  mode=600 applied
  PASS  mode=0664 applied
  PASS  owner of the caller applied, no warning
  PASS  owner applied
  PASS  not root, default owner root:root: warned on stderr
  PASS  warning stays off stdout (one JSON document)

## validate

  PASS  validate ok: exit 0
  PASS  validate ok: ran, exit 0
  PASS  validate ok: output captured
  PASS  validate ok: the staged file is beside the target
  PASS  validate ok: it saw the new content
  PASS  validate ok: installed
  PASS  validate ok: no staged file left
  PASS  validate with a leading argument and {} last: accepted
  PASS  validate fail: exit 1
  PASS  validate fail: stdout is one JSON document
  PASS  validate fail: error has the exit code
  PASS  validate fail: error has stdout of validate
  PASS  validate fail: error has stderr of validate
  PASS  validate fail: validate object
  PASS  validate fail: the old file is untouched
  PASS  validate fail: no staged file, no .prev
  PASS  validate fail on a new file: exit 1
  PASS  validate fail on a new file: nothing created
  PASS  validate fail on a new file: no leftovers
  PASS  validate: {} as its own word
  PASS  validate: no shell, the command ran as one argument list
  PASS  validate: nothing after ; was run
  PASS  validate: $HOME arrived unexpanded
  PASS  validate command missing: exit 1
  PASS  validate command missing: says so
  PASS  validate command not executable: exit 1
  PASS  validate output: at most 2000 characters
  PASS  validate output: not empty
  PASS  validate output: trimmed
  PASS  validate timeout: exit 1
  PASS  validate timeout: says so
  PASS  validate timeout: returned promptly
  PASS  validate timeout: old file untouched
  PASS  validate timeout: nothing left behind
  PASS  validate timeout: its children are killed
  PASS  default validate timeout is 30 s
  PASS  changed content: validate runs
  PASS  unchanged content: validate does not run

## Size limit, input, names, targets

  PASS  exactly 1 MiB: accepted
  PASS  exactly 1 MiB: written whole
  PASS  over 1 MiB: exit 1
  PASS  over 1 MiB: stdout is one JSON document
  PASS  over 1 MiB: error says why
  PASS  over 1 MiB: the file is untouched
  PASS  over 1 MiB: nothing created
  PASS  over 1 MiB: nothing left behind
  PASS  no input file: exit 1
  PASS  no input file: stdout is one JSON document
  PASS  no input file: error says why
  PASS  no CTRL_EXEC_INPUT at all: exit 1
  PASS  no CTRL_EXEC_INPUT at all: stdout is one JSON document
  PASS  no CTRL_EXEC_INPUT at all: error says why
  PASS  input with another field only: exit 1
  PASS  input with another field only: stdout is one JSON document
  PASS  input with another field only: error says why
  PASS  unknown name: exit 1
  PASS  unknown name: stdout is one JSON document
  PASS  unknown name: error says why
  PASS  unknown name: no paths in the answer
  PASS  name with odd characters: exit 1
  PASS  name with odd characters: stdout is one JSON document
  PASS  name with odd characters: error says why
  PASS  name with a path: exit 1
  PASS  name with a path: stdout is one JSON document
  PASS  name with a path: error says why
  PASS  unknown name with --test: exit 1
  PASS  unknown name with --test: stdout is one JSON document
  PASS  unknown name with --test: error says why
  PASS  folder missing: exit 1
  PASS  folder missing: stdout is one JSON document
  PASS  folder missing: error says why
  PASS  folder missing: not created
  PASS  folder is a file: exit 1
  PASS  folder is a file: stdout is one JSON document
  PASS  folder is a file: error says why
  PASS  symlink target: exit 1
  PASS  symlink target: stdout is one JSON document
  PASS  symlink target: error says why
  PASS  symlink target: the linked file is untouched
  PASS  symlink target with --test: exit 1
  PASS  symlink target with --test: stdout is one JSON document
  PASS  symlink target with --test: error says why
  PASS  dangling symlink target: exit 1
  PASS  dangling symlink target: stdout is one JSON document
  PASS  dangling symlink target: error says why
  PASS  dangling symlink: nothing created behind it
  PASS  target is a folder: exit 1
  PASS  target is a folder: stdout is one JSON document
  PASS  target is a folder: error says why
  PASS  folder that is a symlink into a protected folder (checked at write time): exit 1
  PASS  folder that is a symlink into a protected folder (checked at write time): stdout is one JSON document
  PASS  folder that is a symlink into a protected folder (checked at write time): error says why
  PASS  ...and nothing was written there

## --test

  PASS  --test new file: exit 0
  PASS  --test new file: would_change true, changed false
  PASS  --test new file: nothing created, nothing left
  PASS  --test existing: file untouched
  PASS  --test existing: no .prev, no staged file
  PASS  --test existing: previous sha is the installed file's
  PASS  --test same content: would_change false, validate not run
  PASS  --test with failing validate: exit 1
  PASS  --test with failing validate: error
  PASS  --test with failing validate: nothing left
  PASS  --test without input: exit 1
  PASS  --test without input: stdout is one JSON document
  PASS  --test without input: error says why

## --list

  PASS  --list: exit 0
  PASS  --list: stdout is one JSON document
  PASS  --list: names in order
  PASS  --list: an installed file
  PASS  --list: sha256 of the installed file
  PASS  --list: owner of the installed file
  PASS  --list: an absent file
  PASS  --list: a symlink is flagged and not read
  PASS  --list: contents are not shown
  PASS  --list needs no input

## The shipped map example, and the nagios-check validate

  PASS  config-deploy.conf.example is a valid map
  PASS  example: one entry, nagios-checks
  PASS  example: path /etc/nagios-checks/checks.conf
  PASS  example: has a validate command
  PASS  example: generic (no real host names)

## config-push.sh (STUB ctrl-exec-cli over the real agent script, STUB logger)

  PASS  push: exit 0
  PASS  push: the CLI is called per line, name on the command line, contents not
  PASS  push: syslog line per agent, user.info
  PASS  push: second agent
  PASS  push: summary line
  PASS  push: the summary is also printed
  PASS  push: file arrives byte for byte (quotes, backslash, UTF-8)
  PASS  push: ...on the second agent
  PASS  push: the CLI's stdin was one JSON object with content
  PASS  push: contents are in no argument
  PASS  second push: exit 0
  PASS  second push: unchanged
  PASS  second push: summary counts
  PASS  second push: no .prev written
  PASS  edited source: changed again
  PASS  edited source: the agent kept .prev
  PASS  --check same: exit 0
  PASS  --check: only --list is called, no input sent
  PASS  --check same: result=same
  PASS  --check same: summary
  PASS  --check differs/missing: exit 1
  PASS  --check: missing file
  PASS  --check: differing file
  PASS  --check: summary status=differs at user.warning
  PASS  --check changes nothing on the agents
  PASS  --check does not create the missing file
  PASS  agent filter: only that agent is called
  PASS  agent filter: summary counts one line
  PASS  --check with agents: both called
  PASS  agent filter matching nothing: exit 1
  PASS  agent filter matching nothing: logged
  PASS  unknown option: exit 2
  PASS  unreachable agent: exit 1
  PASS  unreachable agent: failed with the reason, user.err
  PASS  unreachable agent: the other agent is still done
  PASS  unreachable agent: summary status=failed at user.err
  PASS  unreachable agent: --check failed too
  PASS  agent refuses the script: failed with the agent's words
  PASS  API error: failed with the API's words
  PASS  unreadable reply: failed
  PASS  agent's validate fails: exit 1
  PASS  agent's validate fails: its words in the log
  PASS  name unknown on the agent: failed with the agent's words
  PASS  --check, name unknown on the agent: failed
  PASS  missing source: exit 1
  PASS  missing source: failed, named
  PASS  missing source: the agent is not called
  PASS  source not UTF-8: failed
  PASS  source not UTF-8: the agent is not called
  PASS  source over 1 MiB: failed before any call
  PASS  source over 1 MiB: the agent is not called
  PASS  absolute source path: works
  PASS  relative source resolves from the conf's folder, not the cwd
  PASS  CONFIG_PUSH_TAG sets the tag
  PASS  CONFIG_PUSH_SCRIPT sets the agent script name
  PASS  no push lines: exit 1
  PASS  no push lines: logged
  PASS  push line without a source: exit 1
  PASS  push line without a source: logged
  PASS  missing job config: exit 1
  PASS  missing job config: logged
  PASS  default config path is beside the script
  PASS  example config: three agents, names only
  PASS  example config: no call is made while the source is missing
  PASS  example config has no schedule line
  PASS  config-push.sh is executable
  PASS  config-push.sh is shellcheck clean

## nagios-check --check-config as the validate command

  SKIP  nagios-check --check-config not available

## install.sh (temp root, fake systemctl, no root needed)

  PASS  fresh install: exit 0
  PASS  fresh install: reports 3 changes
  PASS  fresh install: script installed 755
  PASS  fresh install: script is a copy of ours
  PASS  fresh install: the map is mode 600
  PASS  fresh install: the map holds the nagios-checks entry
  PASS  fresh install: scripts.conf entry added
  PASS  fresh install: agent reloaded
  PASS  fresh install: ends with --list output
  PASS  fresh install: profile present
  PASS  fresh install: agent.conf untouched
  PASS  second run: nothing changed
  PASS  second run: no changed line
  PASS  second run: no reload
  PASS  second run: scripts.conf has one entry
  PASS  existing map: kept
  PASS  existing map: the shipped one is in .new
  PASS  existing map: .new is mode 600
  PASS  existing map: warned
  PASS  different script replaced
  PASS  existing map, second run: .new not rewritten, still warned
  PASS  scripts.conf other path: warned with the path
  PASS  scripts.conf other path: left alone
  PASS  scripts.conf other path: no reload
  PASS  no scripts.conf: exit 1
  PASS  no scripts.conf: FAIL line
  PASS  no scripts.conf: says why
  PASS  no profile: warns
  PASS  no profile: gives the snippet
  PASS  no profile: agent.conf untouched
  PASS  dry-run: exit 0
  PASS  dry-run: says what would change
  PASS  dry-run: nothing written
  PASS  dry-run: scripts.conf untouched
  PASS  dry-run: no reload
  PASS  --script-dir: used in scripts.conf
  PASS  --script-dir: the map's validate follows it
  PASS  --script-dir: script installed there
  PASS  non-root without --dry-run: exit 1
  PASS  non-root without --dry-run: FAIL
  PASS  install.sh: unknown option exits 2
  PASS  install.sh is shellcheck clean

Results: 398 passed, 0 failed, 1 skipped
VERDICT: PASS
