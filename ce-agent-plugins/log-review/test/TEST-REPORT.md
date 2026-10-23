# Test report: log-review (ce-agent-plugins)
Generated: 2026-10-23T08:33:23Z

## Contract: usage, the script and the sidecar

  PASS  no arguments exits 2
  PASS  no arguments prints usage on stderr
  PASS  no arguments prints nothing on stdout
  PASS  log-review.pl is executable
  PASS  log-review.pl has a perl shebang
  PASS  perl -c passes
  PASS  script stays small (517 lines)
  PASS  core modules only
  PASS  no shell: no system, qx, backticks or piped open
  PASS  schema sidecar is valid JSON with arguments, argv and read_only
  PASS  schema sidecar: lines 1..1000, since pattern, flags

## Config: parsing and refusals (each names the line, none echoes a value)

  PASS  no equals sign: exit 3
  PASS  no equals sign: says why
  PASS  no equals sign: does not echo the value
  PASS  no equals sign: stdout is one JSON document
  PASS  bad source name: exit 3
  PASS  bad source name: says why
  PASS  bad source name: does not echo the value
  PASS  bad source name: stdout is one JSON document
  PASS  duplicate source: exit 3
  PASS  duplicate source: says why
  PASS  duplicate source: does not echo the value
  PASS  duplicate source: stdout is one JSON document
  PASS  unknown kind: exit 3
  PASS  unknown kind: says why
  PASS  unknown kind: does not echo the value
  PASS  unknown kind: stdout is one JSON document
  PASS  journal bare word: exit 3
  PASS  journal bare word: says why
  PASS  journal bare word: does not echo the value
  PASS  journal bare word: stdout is one JSON document
  PASS  journal unit and id: exit 3
  PASS  journal unit and id: says why
  PASS  journal unit and id: does not echo the value
  PASS  journal unit and id: stdout is one JSON document
  PASS  journal neither: exit 3
  PASS  journal neither: says why
  PASS  journal neither: does not echo the value
  PASS  journal neither: stdout is one JSON document
  PASS  journal unknown option: exit 3
  PASS  journal unknown option: says why
  PASS  journal unknown option: does not echo the value
  PASS  journal unknown option: stdout is one JSON document
  PASS  journal option twice: exit 3
  PASS  journal option twice: says why
  PASS  journal option twice: does not echo the value
  PASS  journal option twice: stdout is one JSON document
  PASS  journal bad priority: exit 3
  PASS  journal bad priority: says why
  PASS  journal bad priority: does not echo the value
  PASS  journal bad priority: stdout is one JSON document
  PASS  journal priority 8: exit 3
  PASS  journal priority 8: says why
  PASS  journal priority 8: does not echo the value
  PASS  journal priority 8: stdout is one JSON document
  PASS  journal unit with shell characters: exit 3
  PASS  journal unit with shell characters: says why
  PASS  journal unit with shell characters: does not echo the value
  PASS  journal unit with shell characters: stdout is one JSON document
  PASS  journal id starting with a dash: exit 3
  PASS  journal id starting with a dash: says why
  PASS  journal id starting with a dash: does not echo the value
  PASS  journal id starting with a dash: stdout is one JSON document
  PASS  journal id with a slash: exit 3
  PASS  journal id with a slash: says why
  PASS  journal id with a slash: does not echo the value
  PASS  journal id with a slash: stdout is one JSON document
  PASS  file relative path: exit 3
  PASS  file relative path: says why
  PASS  file relative path: does not echo the value
  PASS  file relative path: stdout is one JSON document
  PASS  file dot-dot: exit 3
  PASS  file dot-dot: says why
  PASS  file dot-dot: does not echo the value
  PASS  file dot-dot: stdout is one JSON document
  PASS  file dot segment: exit 3
  PASS  file dot segment: says why
  PASS  file dot segment: does not echo the value
  PASS  file dot segment: stdout is one JSON document
  PASS  file double slash: exit 3
  PASS  file double slash: says why
  PASS  file double slash: does not echo the value
  PASS  file double slash: stdout is one JSON document
  PASS  file trailing slash: exit 3
  PASS  file trailing slash: says why
  PASS  file trailing slash: does not echo the value
  PASS  file trailing slash: stdout is one JSON document
  PASS  file root: exit 3
  PASS  file root: says why
  PASS  file root: does not echo the value
  PASS  file root: stdout is one JSON document
  PASS  file two paths: exit 3
  PASS  file two paths: says why
  PASS  file two paths: does not echo the value
  PASS  file two paths: stdout is one JSON document
  PASS  file no path: exit 3
  PASS  file no path: says why
  PASS  file no path: does not echo the value
  PASS  file no path: stdout is one JSON document
  PASS  file path with control character: exit 3
  PASS  file path with control character: says why
  PASS  file path with control character: does not echo the value
  PASS  file path with control character: stdout is one JSON document
  PASS  bad regex: exit 3
  PASS  bad regex: says why
  PASS  bad regex: does not echo the value
  PASS  bad regex: stdout is one JSON document
  PASS  regex with code block: exit 3
  PASS  regex with code block: says why
  PASS  regex with code block: does not echo the value
  PASS  regex with code block: stdout is one JSON document
  PASS  empty regex: exit 3
  PASS  empty regex: says why
  PASS  empty regex: does not echo the value
  PASS  empty regex: stdout is one JSON document
  PASS  max_lines above 1000: exit 3
  PASS  max_lines above 1000: says why
  PASS  max_lines above 1000: does not echo the value
  PASS  max_lines above 1000: stdout is one JSON document
  PASS  max_lines zero: exit 3
  PASS  max_lines zero: says why
  PASS  max_lines zero: does not echo the value
  PASS  max_lines zero: stdout is one JSON document
  PASS  max_lines text: exit 3
  PASS  max_lines text: says why
  PASS  max_lines text: does not echo the value
  PASS  max_lines text: stdout is one JSON document
  PASS  default_lines text: exit 3
  PASS  default_lines text: says why
  PASS  default_lines text: does not echo the value
  PASS  default_lines text: stdout is one JSON document
  PASS  max_span above 7d: exit 3
  PASS  max_span above 7d: says why
  PASS  max_span above 7d: does not echo the value
  PASS  max_span above 7d: stdout is one JSON document
  PASS  max_span above 7d in hours: exit 3
  PASS  max_span above 7d in hours: says why
  PASS  max_span above 7d in hours: does not echo the value
  PASS  max_span above 7d in hours: stdout is one JSON document
  PASS  max_span bad unit: exit 3
  PASS  max_span bad unit: says why
  PASS  max_span bad unit: does not echo the value
  PASS  max_span bad unit: stdout is one JSON document
  PASS  max_span no number: exit 3
  PASS  max_span no number: says why
  PASS  max_span no number: does not echo the value
  PASS  max_span no number: stdout is one JSON document
  PASS  timeout zero: exit 3
  PASS  timeout zero: says why
  PASS  timeout zero: does not echo the value
  PASS  timeout zero: stdout is one JSON document
  PASS  timeout too big: exit 3
  PASS  timeout too big: says why
  PASS  timeout too big: does not echo the value
  PASS  timeout too big: stdout is one JSON document
  PASS  default_lines above max_lines: exit 3
  PASS  default_lines above max_lines: says why
  PASS  default_lines above max_lines: does not echo the value
  PASS  default_lines above max_lines: stdout is one JSON document
  PASS  default_lines above a later max_lines: exit 3
  PASS  default_lines above a later max_lines: says why
  PASS  default_lines above a later max_lines: does not echo the value
  PASS  default_lines above a later max_lines: stdout is one JSON document
  PASS  comments, blanks and spacing: exit 0
  PASS  comments, blanks and spacing: both sources
  PASS  missing config: exit 3
  PASS  missing config: names the path and the user
  PASS  limits exactly at the caps are accepted
  PASS  limits at the caps: settings
  PASS  lowered caps: settings (default_lines follows max_lines)
  PASS  defaults: 1000 lines, 100 default, 7d, 15 s
  PASS  'key=value' without spaces is accepted
  PASS  names with - and _, templated unit: exit 0
  PASS  a regex with spaces and '=' is kept whole (the rest of the line)

## The caller: names, bounds and usage

  PASS  unknown name: exit 2
  PASS  unknown name: error names the known sources
  PASS  name 'a/b': exit 2
  PASS  name '../etc/passwd': exit 2
  PASS  name '/etc/passwd': exit 2
  PASS  name 'a;ls': exit 2
  PASS  name 'a b': exit 2
  PASS  name '$HOME': exit 2
  PASS  name '`id`': exit 2
  PASS  name 'a*': exit 2
  PASS  name '': exit 2
  PASS  bad name: says so, does not echo it
  PASS  --lines '0': exit 2
  PASS  --lines '0': error is JSON
  PASS  --lines '1001': exit 2
  PASS  --lines '1001': error is JSON
  PASS  --lines 'abc': exit 2
  PASS  --lines 'abc': error is JSON
  PASS  --lines '-5': exit 2
  PASS  --lines '-5': error is JSON
  PASS  --lines '1.5': exit 2
  PASS  --lines '1.5': error is JSON
  PASS  --lines '': exit 2
  PASS  --lines '': error is JSON
  PASS  --lines ' 5': exit 2
  PASS  --lines ' 5': error is JSON
  PASS  --lines '5x': exit 2
  PASS  --lines '5x': error is JSON
  PASS  --lines '99999999': exit 2
  PASS  --lines '99999999': error is JSON
  PASS  --lines 1001: error says the range
  PASS  --since '8d': exit 2
  PASS  --since '169h': exit 2
  PASS  --since '604801s': exit 2
  PASS  --since '10081m': exit 2
  PASS  --since '7x': exit 2
  PASS  --since '0m': exit 2
  PASS  --since '1': exit 2
  PASS  --since 'd': exit 2
  PASS  --since '-1h': exit 2
  PASS  --since '1h;ls': exit 2
  PASS  --since '1 h': exit 2
  PASS  --since '1.5h': exit 2
  PASS  --since '99999999999d': exit 2
  PASS  --since '': exit 2
  PASS  --lines 1000 --since 7d are the caps and accepted
  PASS  ...and the file is refused for its lines, not the bounds
  PASS  --since 168h is accepted (7 days)
  PASS  lowered cap: 51 refused
  PASS  lowered cap: message gives the lowered limit
  PASS  lowered span: 121m refused
  PASS  lowered cap: 50 accepted
  PASS  --lines without a value: usage, exit 2
  PASS  --lines without a value: usage on stderr
  PASS  usage: '--bogus' exits 2
  PASS  usage: '--bogus' prints usage on stderr
  PASS  usage: '--bogus' prints nothing on stdout
  PASS  usage: '-x' exits 2
  PASS  usage: '-x' prints usage on stderr
  PASS  usage: '-x' prints nothing on stdout
  PASS  usage: 'f g' exits 2
  PASS  usage: 'f g' prints usage on stderr
  PASS  usage: 'f g' prints nothing on stdout
  PASS  usage: 'f --list' exits 2
  PASS  usage: 'f --list' prints usage on stderr
  PASS  usage: 'f --list' prints nothing on stdout
  PASS  usage: '--list f' exits 2
  PASS  usage: '--list f' prints usage on stderr
  PASS  usage: '--list f' prints nothing on stdout
  PASS  usage: '--list --text' exits 2
  PASS  usage: '--list --text' prints usage on stderr
  PASS  usage: '--list --text' prints nothing on stdout
  PASS  usage: '--list --lines 5' exits 2
  PASS  usage: '--list --lines 5' prints usage on stderr
  PASS  usage: '--list --lines 5' prints nothing on stdout
  PASS  usage: '--check-config' exits 2
  PASS  usage: '--check-config' prints usage on stderr
  PASS  usage: '--check-config' prints nothing on stdout
  PASS  usage: '--check-config /tmp/log-review-test.8fa62d/etc/sources.conf f' exits 2
  PASS  usage: '--check-config /tmp/log-review-test.8fa62d/etc/sources.conf f' prints usage on stderr
  PASS  usage: '--check-config /tmp/log-review-test.8fa62d/etc/sources.conf f' prints nothing on stdout
  PASS  usage: '--check-config /tmp/log-review-test.8fa62d/etc/sources.conf --text' exits 2
  PASS  usage: '--check-config /tmp/log-review-test.8fa62d/etc/sources.conf --text' prints usage on stderr
  PASS  usage: '--check-config /tmp/log-review-test.8fa62d/etc/sources.conf --text' prints nothing on stdout
  PASS  usage: '--text' exits 2
  PASS  usage: '--text' prints usage on stderr
  PASS  usage: '--text' prints nothing on stdout
  PASS  usage: '--lines 5' exits 2
  PASS  usage: '--lines 5' prints usage on stderr
  PASS  usage: '--lines 5' prints nothing on stdout
  PASS  usage: 'f --lines 5 --lines 6' exits 2
  PASS  usage: 'f --lines 5 --lines 6' prints usage on stderr
  PASS  usage: 'f --lines 5 --lines 6' prints nothing on stdout
  PASS  usage: 'f --since 1h --since 2h' exits 2
  PASS  usage: 'f --since 1h --since 2h' prints usage on stderr
  PASS  usage: 'f --since 1h --since 2h' prints nothing on stdout
  PASS  usage: 'f --text --text' exits 2
  PASS  usage: 'f --text --text' prints usage on stderr
  PASS  usage: 'f --text --text' prints nothing on stdout
  PASS  usage: '--check-config /tmp/log-review-test.8fa62d/etc/sources.conf --list' exits 2
  PASS  usage: '--check-config /tmp/log-review-test.8fa62d/etc/sources.conf --list' prints usage on stderr
  PASS  usage: '--check-config /tmp/log-review-test.8fa62d/etc/sources.conf --list' prints nothing on stdout
  PASS  usage: 'f --check-config /tmp/log-review-test.8fa62d/etc/sources.conf' exits 2
  PASS  usage: 'f --check-config /tmp/log-review-test.8fa62d/etc/sources.conf' prints usage on stderr
  PASS  usage: 'f --check-config /tmp/log-review-test.8fa62d/etc/sources.conf' prints nothing on stdout
  PASS  usage: 'f --all' exits 2
  PASS  usage: 'f --all' prints usage on stderr
  PASS  usage: 'f --all' prints nothing on stdout
  PASS  usage: 'f --lines=5' exits 2
  PASS  usage: 'f --lines=5' prints usage on stderr
  PASS  usage: 'f --lines=5' prints nothing on stdout
  PASS  usage: '--help' exits 2
  PASS  usage: '--help' prints usage on stderr
  PASS  usage: '--help' prints nothing on stdout
  PASS  usage: 'f -- g' exits 2
  PASS  usage: 'f -- g' prints usage on stderr
  PASS  usage: 'f -- g' prints nothing on stdout
  PASS  usage: 'f --since' exits 2
  PASS  usage: 'f --since' prints usage on stderr
  PASS  usage: 'f --since' prints nothing on stdout
  PASS  no journalctl was run by any caller error
  PASS  default lines: 100 of 300
  PASS  default lines: the last 100

## File sources: the tail

  PASS  exit 0
  PASS  stdout is one JSON document
  PASS  document: lines, count, kind, name, truncated
  PASS  document: target is the path
  PASS  document: host and duration_ms present, no since
  PASS  fewer lines than asked: all 300
  PASS  fewer lines than asked: not truncated
  PASS  fewer lines than asked: from the first
  PASS  no trailing newline: the last line counts
  PASS  no trailing newline: whole file
  PASS  trailing newline: the last two, no empty line
  PASS  single line without newline
  PASS  empty file: no lines, not truncated
  PASS  blank lines are lines
  PASS  CRLF: the CR is stripped
  PASS  large file: --lines 1 equals tail -n 1
  PASS  large file: --lines 7 equals tail -n 7
  PASS  large file: --lines 1000 equals tail -n 1000
  PASS  large file: first and last of 1000
  PASS  block boundary on a line start: --lines 511 equals tail
  PASS  block boundary on a line start: --lines 512 equals tail
  PASS  block boundary on a line start: --lines 513 equals tail
  PASS  block boundary on a line start: --lines 1000 equals tail
  PASS  one line longer than a block: cut at 2000 and marked

## File sources: match= (agent-set filter)

  PASS  match: the last 3 matching lines
  PASS  match: the last matching line
  PASS  match: whole file read, not truncated
  PASS  list: filter true
  PASS  match beyond the read bound (last 20000 lines): nothing, truncated says so
  PASS  match: 10 found in the bound, truncated (older lines were not searched)
  PASS  match: they are in order
  PASS  match: inline flags work
  PASS  match with --text

## File sources: cleaning and the line cap

  PASS  control characters: stdout is one JSON document
Wide character in print at -e line 4, <STDIN> line 1.
  PASS  control characters: stripped
  PASS  line cap: 2000 kept, 2001 and 5000 cut and marked, 1999 kept
  PASS  line cap: the marker
  PASS  line cap in --text
  PASS  UTF-8 text survives
  PASS  UTF-8 text in --text

## File sources: what may be read

  PASS  symlink: exit 1
  PASS  symlink: refused
  PASS  directory: exit 1
  PASS  directory: not a regular file
  PASS  missing file: exit 1
  PASS  missing file: says so
  PASS  missing folder: says so
  PASS  fifo: refused at once (exit 1, no hang)
  PASS  fifo: not a regular file
  PASS  unreadable file: exit 1
  PASS  unreadable file: permission denied, names the user
  PASS  errors are JSON {host,error}
  PASS  error document: only host and error
  PASS  error in --text: stdout empty
  PASS  error in --text: on stderr
  PASS  error in --text: exit 1
  PASS  list: exit 0 even with unreadable sources
  PASS  list: readable flags
  PASS  list: reasons
  PASS  list: rows carry name, kind, target, filter

## File sources: --since

  PASS  iso: the last hour (two entries and the continuation)
  PASS  iso: since is echoed, not truncated
  PASS  iso: the last day
  PASS  iso: four days (all)
  PASS  iso: --lines 1 keeps the newest, truncated
  PASS  iso: --text, last 30 s
  PASS  syslog format: the last hour
  PASS  iso with an offset is read as that zone
  PASS  nginx-style YYYY/MM/DD timestamps
  PASS  no timestamps: exit 1
  PASS  no timestamps: error says it is not supported
  PASS  since with match=: filters inside the window
  PASS  window larger than the read bound: newest 5, truncated

## Journal sources (stub journalctl)

  PASS  journal: exit 0
  PASS  journal: exact argv (default 100 lines, identifier)
  PASS  journal: kind, target, lines passed through
  PASS  journal: exact argv (unit, priority, -n 7)
  PASS  journal: numeric priority, -n 1000
  PASS  journal: --since becomes seconds, one more line is asked for to know about truncation
  PASS  journal: since echoed
  PASS  journal: 7d is 604800 s, default 100+1 lines
  PASS  journal: since, exactly N lines back: not truncated
  PASS  journal: since, N+1 lines back: only the newest N, truncated
  PASS  journal: no --since: just the lines journalctl gave, not truncated
  PASS  journal with match=: reads up to the bound (20000), not N
  PASS  journal with match=: the matches are 1, 2, 11, 12, 21, 22; the newest 3 are kept
  PASS  journal with match=: newest 2
  PASS  journal with match=: three newest ending in 1 or 2
  PASS  journal with match=, no --since, N matches found: not truncated
  PASS  journal with match= and --since, more matches than N: truncated
  PASS  journal with match= and --since, all matches fit: not truncated
  PASS  journal with match=, nothing matches, bound not reached: empty, not truncated
  PASS  journal with match=, nothing matches, bound reached: truncated says the search stopped
  PASS  journal: a large answer keeps the newest 5
  PASS  journal: ESC, BEL, NUL stripped
  PASS  journal: long line cut and marked
  PASS  no caller text reaches journalctl: nothing ran for bad input
  PASS  only validated numbers reach it
  PASS  one run, one journalctl call
  PASS  journalctl fails: exit 1
  PASS  journalctl fails: says so with its message
  PASS  journalctl fails silently: exit code shown
  PASS  timeout: exit 1
  PASS  timeout: says so
  PASS  timeout: returned in 1 s
  PASS  timeout: the stub was killed
  PASS  empty answer and a permission warning: exit 1
  PASS  empty answer and a permission warning: journal not readable
  PASS  empty answer, journal readable: exit 0, no lines
  PASS  empty answer, journal readable: no lines
  PASS  journalctl missing: exit 1
  PASS  journalctl missing: message
  PASS  list: journal rows
  PASS  list: the journal is probed once, with a fixed argv
  PASS  list: one journalctl call for any number of journal sources
  PASS  list: unreadable journal reported with the reason
  PASS  list: journalctl failure reported
  PASS  list: journalctl timeout reported
  PASS  list: no journal source, no journalctl call

## --text

  PASS  text: only the lines
  PASS  text: flags in any order
  PASS  text: journal lines, the newest 2 of what the stub gave
  PASS  text: journal line content
  PASS  text: unsupported --since is an error on stderr
  PASS  text: truncated is said on stderr
  PASS  text: and stdout is only the line
  PASS  text: not truncated, stderr empty

## --check-config

  PASS  folder file, absolute: exit 0
  PASS  folder file: sources with filter flags, no readable probe
  PASS  folder file: config and settings
  PASS  folder file: the regex is not echoed
  PASS  check-config runs nothing (no journalctl)
  PASS  folder file, relative from inside the folder: accepted
  PASS  folder file, ./ relative: accepted
  PASS  staged file that does not parse: exit 3
  PASS  staged file that does not parse: names the line
  PASS  staged file that does not parse: no echo
  PASS  bad source: exit 3
  PASS  bad source: line 2
  PASS  file outside the folder: exit 3
  PASS  file outside the folder: says what is read
  PASS  file outside the folder: unread
  PASS  /etc/passwd: exit 3, unread
  PASS  /etc/passwd: nothing echoed
  PASS  ..-path to another folder: exit 3
  PASS  path through a missing subfolder: exit 3
  PASS  symlink in the folder to elsewhere: exit 3
  PASS  symlink in the folder to elsewhere: unread
  PASS  symlink in the folder to a folder file: also refused
  PASS  the folder reached through a symlinked folder: same folder, accepted
  PASS  missing file in the folder: exit 3
  PASS  missing file in the folder: cannot read
  PASS  the folder itself: exit 3
  PASS  the shipped example parses
  PASS  the shipped example: four sources

## Output hygiene

  PASS  JSON answer is one line
  PASS  nothing on stderr for a normal run
  PASS  nothing on stderr for --list

## install.sh (temp root, fake systemctl and runuser, no root needed)

  PASS  script_dirs excludes the dir: exit 1
  PASS  script_dirs excludes the dir: FAIL names the allowed folders
  PASS  script_dirs excludes the dir: nothing installed
  PASS  script_dirs excludes the dir: scripts.conf untouched
  PASS  script_dirs excludes the dir: dry-run fails too
  PASS  script_dirs includes the dir: exit 0
  PASS  script_dirs includes the dir: ok line
  PASS  script_dirs: a subfolder of an allowed dir is accepted
  PASS  script_dirs: a name prefix is not a folder prefix
  PASS  no script_dirs: no script_dirs line
  PASS  fresh install: exit 0
  PASS  fresh install: reports 4 changes (script, folder, config, scripts.conf)
  PASS  fresh install: script installed 755
  PASS  fresh install: script mode
  PASS  fresh install: script is a copy of ours
  PASS  fresh install: config is 644
  PASS  fresh install: config folder is 755
  PASS  fresh install: config is the example
  PASS  fresh install: the folder is reported
  PASS  fresh install: scripts.conf entry added with the profile
  PASS  fresh install: agent reloaded
  PASS  fresh install: profile found
  PASS  fresh install: verify line printed
  PASS  fresh install: verify lists the sources
  PASS  fresh install: agent.conf untouched
  PASS  second run: nothing changed
  PASS  second run: no changed line
  PASS  second run: no reload
  PASS  second run: scripts.conf has one entry
  PASS  second run: scripts.conf entry recognised
  PASS  second run: no .new
  PASS  existing config: kept
  PASS  existing config: shipped one in .new
  PASS  existing config: warned
  PASS  existing config: mode fixed and said so
  PASS  existing config: mode is 644
  PASS  different script replaced
  PASS  existing config, second run: .new not rewritten
  PASS  existing folder: mode left alone
  PASS  existing folder: not created again
  PASS  existing folder that others cannot enter: warned
  PASS  scripts.conf other path: warned with the path
  PASS  scripts.conf other path: left alone
  PASS  scripts.conf other path: no reload
  PASS  scripts.conf entry without the profile: warned
  PASS  scripts.conf entry without the profile: left alone
  PASS  no scripts.conf: exit 1
  PASS  no scripts.conf: FAIL line
  PASS  no scripts.conf: says why
  PASS  no log-review profile: still exit 0
  PASS  no log-review profile: warns
  PASS  no log-review profile: gives the snippet
  PASS  no log-review profile: names the groups
  PASS  no log-review profile: agent.conf untouched
  PASS  dry-run: exit 0
  PASS  dry-run: says what would change
  PASS  dry-run: nothing written
  PASS  dry-run: scripts.conf untouched
  PASS  dry-run: no reload
  PASS  --script-dir: used
  PASS  unreadable source: installer still exit 0
  PASS  unreadable source: verify warns with the reason
  PASS  unreadable source: names it
  PASS  install.sh: unknown option exits 2
  PASS  non-root without --dry-run: exit 1
  PASS  non-root without --dry-run: FAIL
  PASS  install.sh is shellcheck clean

Results: 522 passed, 0 failed, 0 skipped
VERDICT: PASS
