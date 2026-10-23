---
title: log-review
subtitle: Return a bounded slice of a named log on an agent, as JSON or plain text
---

# log-review

## Purpose

Operators read logs on agent hosts by logging in. `log-review` lets the
dispatcher (or a menu on top of it) ask an agent for the last lines of a named
log, or for what a log said in the last hour, through ctrl-exec's own
transport, trust and logging, with no shell on the host.

The caller names a **source** and a **window**. It never sends a path, a
journal unit, a pattern or a search string: what a name reads is fixed in the
agent's own `/etc/log-review/sources.conf`, and so is any filter. A name the
agent does not know is refused before anything is read.

### Who decides what

| | Decided by | Where |
| --- | --- | --- |
| Which log a name means (journal unit or identifier, file path) | the agent | `/etc/log-review/sources.conf` |
| Fixed priority, fixed `match=` filter | the agent | `sources.conf` |
| Which source is read, how many lines, how far back | the caller | the arguments of each run |
| Largest line count and span, default line count, reader timeout | the agent, within hard limits | `sources.conf` settings |

The hard limits are the owner's decision and the script enforces them whatever
the config says: **at most 1000 lines** per call (100 when the caller gives no
number) and **at most 7 days** of span. An agent may lower either, never raise
it; a config that tries is refused as a config error.

The script runs nothing but `journalctl`, by argument list and never through a
shell, and the only caller-supplied values that ever reach it are numbers the
script has validated.


## Dependencies

| Dependency | Needed on | For |
| --- | --- | --- |
| `perl` with core modules (JSON::PP, POSIX, Time::HiRes, Time::Local, Cwd, Encode, Fcntl, Sys::Hostname) | the agent | `log-review.pl` |
| `journalctl` (systemd), found in `/usr/bin` or `/bin` | the agent | `journal` sources only |
| `bash` | the agent | `install.sh`, `test/run.sh` |

A host with no systemd can still use `file` sources. Reading a source needs
the right group membership: see scripts.conf below.


## Installation

### Install with install.sh

Copy this plugin folder to the host and run it as root:

```bash
sudo ./install.sh --dry-run
sudo ./install.sh
```

`--script-dir DIR` sets where the agent script goes (default
`/opt/ctrl-exec-scripts`; use `--script-dir /srv/scripts` where the scripts
live there). `--dry-run` checks everything, says what would change and
changes nothing; it runs as any user. When `agent.conf` sets `script_dirs`,
the script directory must be under one of them (the agent refuses a script
anywhere else): otherwise the installer stops with `FAIL`, before changing
anything, and names the folders allowed.

It installs `log-review.pl` into the script directory (root:root 755; a
different copy is replaced, it is this plugin's own file), makes
`/etc/log-review/` (root:root 755) and puts `sources.conf.example` there as
`sources.conf` **only when there is none** (an existing config is kept, the
shipped one is written beside it as `sources.conf.new`), adds
`log-review = <script-dir>/log-review.pl profile=log-review` to
`/etc/ctrl-exec-agent/scripts.conf` when there is no `log-review` entry
(an existing entry is never changed), reloads the agent when that file
changed, and finally runs `log-review.pl --list` as the profile's `run_as`
user to show which sources it can read. Each step prints one line: `ok`,
`changed`, `skip`, `warn` or `FAIL`, then `done: N changed, N warnings`. A
second run changes nothing.

`agent.conf` is **never edited**. When it has no `[profile log-review]` the
installer warns and prints what to add (see scripts.conf below). A source the
profile's user cannot read is a warning, not a failure: fix the group
membership and run `log-review --list` again.

### Manual installation

```bash
sudo install -o root -g root -m 755 log-review.pl /opt/ctrl-exec-scripts/log-review.pl
sudo install -d -o root -g root -m 755 /etc/log-review
sudo install -o root -g root -m 644 sources.conf.example /etc/log-review/sources.conf
```

The config decides what the script reads, so it is root-owned and nobody
else may write it. The script runs as an unprivileged `run_as` user and must
be able to read it: mode 644, in a folder of its own (755) so that
`config-deploy` can push it (the folder is the only place `--check-config`
reads).

### sources.conf (agent)

Default path `/etc/log-review/sources.conf`; the environment variable
`LOG_REVIEW_CONF` overrides it (the tests use this; leave it unset on a real
host). `key = value` lines; a `#` starts a comment only at the start of a
line. Errors name the file and line and never repeat the value.

Settings (all optional):

`max_lines = 1000`
: The most lines a caller may ask for. May be lowered; a value above 1000 is
  refused.

`default_lines = 100`
: Lines returned when the caller gives none. Not above `max_lines`.

`max_span = 7d`
: The longest `--since`: a whole number and `s`, `m`, `h` or `d`. May be
  lowered; above 7 days (`7d`, `168h`) is refused.

`timeout = 15`
: Seconds `journalctl` may take (1 to 600). On expiry its process group is
  killed. Keep it well below the dispatcher's `read_timeout` (60 s by
  default).

Every other key is a source name, `[A-Za-z0-9_][A-Za-z0-9_-]*`, with one of:

```ini
<name> = journal unit=<name.service> [priority=<0-7 or name>] [match=<regex>]
<name> = journal id=<syslog identifier> [priority=<0-7 or name>] [match=<regex>]
<name> = file <absolute path> [match=<regex>]
```

`journal unit=...` or `journal id=...`
: Exactly one of the two, written out: `unit=` reads `journalctl -u`, `id=`
  reads `journalctl -t`. A bare word, both, or neither is refused rather than
  guessed at. The unit is letters, digits and `: _ @ . \ -`; the identifier is
  letters, digits and `. _ @ -`; neither may start with `-`.

`priority=`
: `journalctl -p`: `0` to `7` or `emerg`, `alert`, `crit`, `err`, `warning`,
  `notice`, `info`, `debug` (that level and more severe).

`file <absolute path>`
: A path with no spaces, `.`, `..`, `//` or trailing `/`. It must be a
  regular file at read time; a symlink as the last component is refused
  (opened with `O_NOFOLLOW`), as are directories, FIFOs and devices.

`match=<regex>`
: A Perl regular expression set by the agent, **last on the line** (the rest
  of the line is the regex, spaces included). It is compiled when the config is
  loaded and a bad one is refused with its line number; code blocks
  (`(?{ })`) are not allowed. Only lines it matches are returned; it applies
  to the line after control characters are removed. The caller can neither
  see it (only that a filter exists) nor change it.

Example (`sources.conf.example`):

```ini
auth          = journal id=sshd
syslog        = file /var/log/syslog
nginx-errors  = file /var/log/nginx/error.log
kernel        = journal id=kernel priority=warning
```

Every line returned has control characters other than tab removed and is cut
at 2000 characters (`" [line cut]"` is appended). Malformed UTF-8 becomes
U+FFFD.


## scripts.conf

On each agent, in `/etc/ctrl-exec-agent/scripts.conf`:

```ini
log-review = /opt/ctrl-exec-scripts/log-review.pl profile=log-review
```

`nobody`, the usual `[profile default]`, normally cannot read system logs, so
give the script a profile whose user can. In `/etc/ctrl-exec-agent/agent.conf`:

```ini
[profile log-review]
run_as            = ce-logs          # a system user in groups adm and systemd-journal
no_new_privileges = yes
```

Create the user once, with no login and no password, and put it in the groups
that can read what you configure:

```bash
sudo useradd --system --no-create-home --shell /usr/sbin/nologin ce-logs
sudo usermod -aG adm,systemd-journal ce-logs
```

`adm` reads `/var/log/syslog`, `auth.log`, nginx and most other files under
`/var/log`; `systemd-journal` reads the whole journal. Add only what the
sources need. **No root**: the script never needs it. Profiles apply only when
the executor is enabled; a changed `agent.conf` needs `systemctl restart
ctrl-exec-agent`, a changed `scripts.conf` a reload.

Whether the profile reaches the source is something `--list` shows: run it as
the caller would (`ctrl-exec-cli run agent-01 --script log-review -- --list`)
and read `readable` and `reason`.

The script name must match the name the dispatcher is given (`--script
log-review`). The sidecar `log-review.pl.schema.json` describes the arguments
for tools that read it.

### Pushing sources.conf with config-deploy

The config lives in a folder of its own, root:root 755, for this reason. With
the `config-deploy` plugin, add to `/etc/ctrl-exec-agent/config-deploy.conf`:

```ini
log-review = /etc/log-review/sources.conf owner=root:root mode=0644 validate=/opt/ctrl-exec-scripts/log-review.pl --check-config {}
```

and `/etc/log-review` to the `writable` list of the `[profile config-deploy]`
(a colon-separated list, so `writable = /etc/nagios-checks:/etc/log-review`). config-deploy stages the new file in
`/etc/log-review/`, runs the validate command on the staged file and installs
it only when `--check-config` exits 0, so a typo or an over-limit setting
never reaches the live config.


## Subcommands

`log-review <name> [--lines N] [--since DURATION] [--text]`
: Return the source `<name>`.
  - `--lines N`: 1 to `max_lines` (1000 at most), default `default_lines`
    (100). Anything else is an error, exit 2.
  - `--since DURATION`: `<int>` and `s`, `m`, `h` or `d` (`90m`, `2d`), not
    longer than `max_span` (7d at most). Without it the answer is the last N
    lines. With it, the lines of that window, at most N: the **newest** N, with
    `truncated` true when the window held more.
  - `--text`: the lines only, one per line, instead of JSON. For people, the
    command line and menus.

`log-review --list`
: Every source: name, kind (`journal` or `file`), target (unit or identifier,
  or path), `readable` (and a `reason` when false), whether a `filter` applies,
  and the priority of a journal source. Also the effective limits. Always exit
  0. The journal is probed once with a fixed `journalctl -n 1`.

  ```json
  {"host":"agent-01","settings":{"default_lines":100,"max_lines":1000,"max_span_seconds":604800,"timeout":15},
   "sources":[
    {"name":"auth","kind":"journal","target":"sshd","filter":false,"readable":true},
    {"name":"syslog","kind":"file","target":"/var/log/syslog","filter":false,"readable":false,"reason":"permission denied for user nobody"}]}
  ```

`log-review --check-config <file>`
: Parse `<file>` with the same parser and limits as the real config and run
  nothing (no journalctl, no file read). Prints what `--list` prints, without
  `readable`, and exits 0 when it parses; exit 3 with an `error` naming the
  line when not. Only a file in the config's own folder (`/etc/log-review/`)
  is read; any other path, a symlink, a missing file exits 3 unread, so a
  caller cannot have other files parsed and echoed back. This is the validate
  command for deploying the config with `config-deploy`.

Anything else (an unknown flag, a second name, a path, `--text` without a
name, a repeated flag) prints usage on stderr and exits 2.

### Output

```json
{"host":"agent-01","name":"auth","kind":"journal","target":"sshd",
 "lines":["2026-10-23T10:00:01+0000 agent-01 sshd[801]: Accepted publickey for ops from 10.0.0.5",
          "2026-10-23T10:04:12+0000 agent-01 sshd[907]: Failed password for invalid user admin"],
 "count":2,"truncated":false,"since":"1h","duration_ms":41}
```

`since` appears only when `--since` was given. Errors are
`{"host":"agent-01","error":"..."}`, or one line on stderr with `--text`.
Warnings (such as `truncated` in text mode) go to stderr only.

Exit codes:

| Code | Meaning |
| --- | --- |
| 0 | ok, including an empty answer |
| 1 | the source could not be read: file missing, unreadable, symlink, not a regular file; journalctl missing, failing or timed out; `--since` on a file with no usable timestamps |
| 2 | usage, an unknown or malformed source name, a value out of bounds |
| 3 | config error (cannot read, line does not parse, limit above the cap) |

### How a source is read

**Journal.** `journalctl --no-pager -o short-iso -q -n N` plus `-u UNIT` or
`-t ID`, `-p PRIORITY` when set, and `--since=-<seconds> seconds` when the
caller gave a span. For a source with no `match=`, N is the line count asked
(one more when `--since` is given, only to learn whether the window held more).
For a source with `match=` the script must read more than N to find N matches,
so it asks for **20000 lines** and keeps the newest N matching ones; if that
bound was hit with fewer than N matches (or, with `--since`, at all), the
answer says `truncated: true` because older matching lines may exist. A
timeout kills journalctl's whole process group. An empty answer from a journal
the user may not read (the `-q` flag hides journalctl's permission warning) is
re-checked and reported as an error, not as "no lines".

**File.** The tail is read in Perl, backwards from the end in 64 KiB blocks
(no external `tail`), so a file of any size is cheap; at most 64 MiB are
scanned. With `match=` or `--since`, the last 20000 lines are the search
area, with the same `truncated` rule as above.

`--since` on a file works only when the lines start with a timestamp the script
can read: ISO-8601 (`2026-10-23T10:00:01Z`, `...+01:00`, or with a space
instead of `T`, fractions allowed), `2026/10/23 10:00:01` (nginx error log), or
syslog (`Oct 23 10:00:01`; no year, the current one is assumed). A timestamp
with no zone is read as the agent's local time. A line with no timestamp (a
stack trace) belongs to the line before it. If none of the last 40 lines
starts with a timestamp the call fails with `--since is not supported for this
file`, exit 1. Rotated files are not read.


## Examples

What does this host offer, and can it read it:

```bash
ctrl-exec-cli run agent-01 --script log-review -- --list
```

The last 50 lines of the auth log as people read it:

```bash
ctrl-exec-cli run agent-01 --script log-review -- auth --lines 50 --text
```

What the kernel warned about in the last two hours (JSON):

```bash
ctrl-exec-cli --json run agent-01 --script log-review -- kernel --since 2h
```

Lines of the answer from a script (`jq` on the dispatcher):

```bash
ctrl-exec-cli --json run agent-01 --script log-review -- auth --since 1d --lines 200 \
  | jq -r '.results[0].stdout | fromjson | .lines[]'
```

Trying a configuration on an agent without ctrl-exec:

```bash
LOG_REVIEW_CONF=./sources.conf.example ./log-review.pl --list
```

### Running the plugin's tests

```bash
bash test/run.sh | tee test/TEST-REPORT.md
```

The suite uses temporary files, and for journal sources a stub `journalctl`
that records the argument list it was called with, selected by
`LOG_REVIEW_JOURNALCTL` (a test-only variable naming the program to run instead
of `/usr/bin/journalctl`; leave it unset on a real host). The tests assert the
exact argument list and that no text from the caller reaches it. It needs
`perl` and `bash`, no network, no root and no real journal; the timeout tests
wait one or two seconds.


## Limitations

- Output may contain sensitive text (user names, addresses, tokens printed by
  careless programs). Whoever can run `log-review` on an agent can read every
  configured source; configure only what that audience may see, and use
  `match=` to remove the rest at the agent. The script returns lines as they
  are; it redacts nothing.
- The caller cannot search. A search string from the caller is deliberately not
  supported; filters are the agent's `match=` only.
- A source name reads one unit, identifier or file. Rotated files
  (`syslog.1`, `*.gz`) are not read.
- `match=` is a Perl regex run by the script: a pathological pattern can be
  slow. The script is stopped after `timeout` plus a few seconds. Only the
  agent's own config supplies it.
- A symlink as the last component of a file path is refused; a symlinked
  directory earlier in the path is followed.
- With `match=` the search area is the last 20000 lines of the journal or file;
  matches older than that are not found and `truncated` says so.
- `--since` on a file needs timestamps at the start of the lines (see above);
  other files can only be read by line count. File timestamps without a zone
  are taken as the agent's local time.
- The lines are returned in the order the source holds them (oldest first).
  JSON strings are UTF-8; control characters and over-long lines are altered as
  described above.
- ctrl-exec does not run the same script twice at once on one agent; a second
  call while one is in progress is refused with a lock conflict.
- The script keeps no state and does no alerting.
