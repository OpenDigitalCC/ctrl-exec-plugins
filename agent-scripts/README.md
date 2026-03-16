---
title: dispatcher-plugins - agent-scripts
subtitle: Ready-built scripts for dispatcher agent hosts
brand: odcc
---

# agent-scripts

Ready-built scripts for deployment on dispatcher agent hosts. Each script is
installed on the agent, added to the allowlist in `scripts.conf`, and then
callable from the dispatcher control host.


## How agent scripts work

The dispatcher runs allowlisted scripts on agents over mTLS. When a script
is invoked, the agent:

1. Validates the script name against `scripts.conf`
2. Executes the script via `exec` with no shell - arguments are passed as a
   list, preventing shell injection
3. Pipes a JSON context object to the script on stdin
4. Captures stdout and stderr and returns both to the caller

The JSON context on stdin contains:

```json
{
  "script":     "my-script",
  "args":       ["arg1", "arg2"],
  "reqid":      "a1b2c3d4",
  "peer_ip":    "192.0.2.1",
  "username":   "alice",
  "token":      "...",
  "timestamp":  "2026-01-01T12:00:00Z"
}
```

Scripts that do not need this context should discard stdin immediately:

```bash
exec 0</dev/null
```


## Installing a script

Copy the script to the agent host, set ownership and permissions, then add
an entry to the allowlist:

```bash
sudo cp my-script.sh /opt/ctrl-exec-scripts/
sudo chmod 750 /opt/ctrl-exec-scripts/my-script.sh
sudo chown root:ctrl-exec-agent /opt/ctrl-exec-scripts/my-script.sh

echo "my-script = /opt/ctrl-exec-scripts/my-script.sh" \
    | sudo tee -a /etc/ctrl-exec-agent/scripts.conf

sudo systemctl kill --signal=HUP ctrl-exec-agent
```

The `HUP` signal reloads the allowlist without restarting the agent or
dropping in-flight connections.

If `script_dirs` is set in `agent.conf`, the script path must be under one
of the approved directories or the agent will reject the entry at load time.


## Calling a script from the dispatcher

All scripts in this category use a subcommand pattern. The subcommand is
passed as the first argument after `--`:

```bash
dispatcher run <host> <script-name> -- <subcommand>
```

Arguments beyond the subcommand are passed positionally to the script:

```bash
dispatcher run <host> <script-name> -- <subcommand> arg1 arg2
```

To run the same script on multiple hosts in parallel:

```bash
dispatcher run host-a host-b host-c <script-name> -- <subcommand>
```

To capture output as JSON for scripted consumption:

```bash
dispatcher run host-a <script-name> --json -- <subcommand>
```

The request ID in the output (`req:`) matches the `REQID` field in syslog on
both the dispatcher and the agent. Use it to correlate output with log entries:

```bash
grep REQID=a1b2c3d4 /var/log/syslog
```


## Script conventions

All scripts in this category follow these conventions.

Subcommand pattern
: The first argument is the subcommand. Calling the script with no arguments,
  or with an unrecognised subcommand, prints usage to stderr and exits 1.

Exit codes
: 0 for success, 1 for script errors, 2 for configuration or usage errors.
  The dispatcher reports the exit code alongside stdout and stderr.

No interactive input
: Scripts must not block waiting for input. The dispatcher closes stdin after
  writing the JSON context (or immediately if the script discards it).

Idempotent where possible
: Scripts that modify state should be safe to run more than once with the same
  arguments and produce the same result.

No hardcoded paths or credentials
: Credentials are handled via OS mechanisms (`.pgpass`, service accounts,
  environment files). Paths use standard system locations or are configurable
  via arguments.

British English in output and documentation
: Consistent with the dispatcher project convention.


## File permissions on the agent host

```
/opt/ctrl-exec-scripts/<script>.sh    0750  root:ctrl-exec-agent
```

The `ctrl-exec-agent` service runs as root by default. Scripts that should
run as a less-privileged user can drop privileges explicitly:

```bash
exec sudo -u appuser "$0" "$@"
```

Add a targeted sudoers rule to permit this without a password prompt:

```
ctrl-exec-agent ALL=(appuser) NOPASSWD: /opt/ctrl-exec-scripts/my-script.sh
```
