---
title: cert-deploy
subtitle: Issue a certificate on one agent, deploy it to many, restart and verify
---

# cert-deploy

## Purpose

Certificate renewal for hosts that cannot, or should not, each run their own
ACME client. A certificate is issued once, on one ctrl-exec agent, and then
pushed to every host that needs it, the services that use it are restarted,
and each service is checked to confirm it now serves the new certificate.

The plugin has two halves.

On each destination agent, three allowlisted scripts:

| Script | Does | Profile |
| --- | --- | --- |
| `agent-cert-deploy.sh` | Writes a certificate, key and CA chain into a folder | `cert-deploy` |
| `agent-service-restart.sh` | Restarts docker compose services | `svc-restart` |
| `agent-cert-check.sh` | Checks the certificate a service is serving, Nagios style | `default` |

On the dispatcher, one [run-jobs](../../ce-api-plugins/ctrl-exec-cli/run-jobs/README.md)
job, `run-jobs/deploy-cert.sh`, which drives them from a configuration file:
it asks the issuing agent for each certificate, deploys it to the configured
targets, restarts the services of every target that received a certificate,
and verifies what each service then serves. It exits non-zero if any step
failed, so run-jobs records the failure. The certificate, key and CA reach the
destinations as confidential input, never as arguments.

The scripts are kept simple on purpose. Who may run them, as which user, and
where they may write is set by ctrl-exec (the allowlist, the profile and the
auth hooks), not by the scripts.

Each script ships a schema sidecar (`*.sh.schema.json`). The agent advertises
it through `/discovery`, so the scripts appear as typed tools in
`/openapi-live.json` and in the `ctrl-exec-mcp` bridge. `agent-cert-check` is
declared read-only; the other two change state. The certificate, key and CA
of `agent-cert-deploy` are not arguments but run input fields (see
[Confidential input](#confidential-input)); its sidecar lists them and marks
`key` as a private key. The `ctrl-exec-mcp` bridge cannot send run input, so
it can call `agent-cert-deploy --test` but not a deploy; deploys come from the
job.

## Confidential input

The private key never travels as a script argument, which would show it in
the process table of both hosts, in auth hook environments and in the request
body. `deploy-cert.sh` sends the certificate, key and CA as named input fields
and `agent-cert-deploy` installs from them.

Field names (the contract is `^[A-Za-z0-9_.-]{1,64}$`):

| Field | Holds |
| --- | --- |
| `cert` | the certificate (fullchain), PEM text |
| `key` | the private key, PEM text (**secret**) |
| `ca` | the CA certificate chain, PEM text |

On the dispatcher the job pipes a JSON object of the three fields to
`ctrl-exec-cli run <agent> --script agent-cert-deploy --json --input-fields -
-- <target-dir> <domain> <group> <layout>`. Only the target folder, domain,
group and layout are arguments. On the agent the script is declared
`input=fields` (see [scripts.conf](#scriptsconf)), so ctrl-exec writes each
field to a file `$CTRL_EXEC_INPUT/<field>` (mode 0600) in a private per-run
folder (mode 0700) owned by the profile's `run_as` user, and removes the
folder when the script ends. The script reads the three files and writes the
layout; the key is never in its arguments or environment.

Transport: the input is as private as the hop that carries it. Run
`ctrl-exec-cli` over the API's unix socket (`--socket`, or `socket` in
`~/.ctrl-exec-cli.conf`) or over TLS (an `https://` URL with `--ca`). Over
plain HTTP to another host the key crosses the network unencrypted; the CLI
warns when that would happen.

Deprecated argv form: for **one release**, `agent-cert-deploy` still accepts
the old arguments (`<target-dir> <basename> <group> <cert-b64> <key-b64>
<ca-b64> [layout]`) when no input arrived, so a new agent script works with an
older dispatcher job during a rolling upgrade. Input counts as arrived when
`CTRL_EXEC_INPUT` is set and its folder holds files; a script declared
`input=fields` but called without input gets an empty folder and uses the
argument form. This fallback shows the key in the process table and **will be
removed in the next release**: upgrade `deploy-cert.sh` and declare
`input=fields`. The reverse mix does not work: the new job against an agent
script that is the old version or is not declared `input=fields` fails, with a
message saying input is needed, and nothing is written. Upgrade the agents
first.

Where secret material is handled:

- Dispatcher, `run-jobs/deploy-cert.sh`: the issuing agent's response is held
  in shell variables, never exported, never in a file (this response used to be
  written to `CERT_OUTPUT_DIR` for a moment); the fields JSON is built by
  `perl` from stdin and sent with `printf` (a builtin) into the CLI's stdin.
  No argument, environment variable or temporary file holds it.
- Destination, `agent-cert-deploy.sh`: reads the files in `$CTRL_EXEC_INPUT`
  and writes the certificate files, mode 640 (`umask 027`, then `chmod`).
  ctrl-exec owns and removes the input folder.

## Dependencies

All dependencies are available as Debian trixie system packages.

| Command | Package | Used by |
| --- | --- | --- |
| `bash` | `bash` | all scripts |
| `base64`, `chgrp`, `chmod`, `stat`, `mkdir`, `sed`, `timeout` | `coreutils`, `sed` | all scripts (`base64` only for the deprecated argument form) |
| `getent` | `libc-bin` | `agent-cert-deploy --test` |
| `openssl` | `openssl` | `agent-cert-check` |
| `docker compose` (v2; v2.17 or later for `--test`) | `docker-compose-v2` or Docker's own packages | `agent-service-restart` |
| `ctrl-exec-cli`, `jq`, `perl` (core modules only), `logger` | in the run-jobs image | `run-jobs/deploy-cert.sh` |

The job also needs an issuing agent script that prints the certificate (see
[The job](#the-job)). The plugin does not include one.

## Installation

### On each destination agent

As root:

```bash
install -o root -g root -m 755 agent-cert-deploy.sh agent-service-restart.sh agent-cert-check.sh /opt/ctrl-exec-scripts/
install -o root -g root -m 644 agent-cert-deploy.sh.schema.json agent-service-restart.sh.schema.json agent-cert-check.sh.schema.json /opt/ctrl-exec-scripts/
```

The allowlist requires scripts owned by root. Updating a script that is
already installed needs nothing more. Install only the scripts a host needs:
a host that serves no containers does not need `agent-service-restart`.

### On the dispatcher

Copy `run-jobs/deploy-cert.sh` into the run-jobs scripts directory, make it
executable, and put its configuration next to it as `deploy-cert.conf`
(start from `run-jobs/deploy-cert.conf.example`). run-jobs runs the job on the
`schedule` in that file; see the run-jobs README.

## scripts.conf

Add to `/etc/ctrl-exec-agent/scripts.conf` on each destination agent:

```ini
agent-cert-deploy     = /opt/ctrl-exec-scripts/agent-cert-deploy.sh      profile=cert-deploy input=fields
agent-service-restart = /opt/ctrl-exec-scripts/agent-service-restart.sh  profile=svc-restart
agent-cert-check      = /opt/ctrl-exec-scripts/agent-cert-check.sh
```

`input=fields` makes ctrl-exec hand `agent-cert-deploy` the run's input as
files under `$CTRL_EXEC_INPUT`. Without it the script receives no input and
(for one release) falls back to the deprecated argument form.

Define the profiles in `/etc/ctrl-exec-agent/agent.conf`:

```ini
[profile cert-deploy]
run_as   = root
caps     = CAP_CHOWN
writable = /srv/app/certs

[profile svc-restart]
run_as = svc-docker      # in the docker group, with a home directory

[profile default]
run_as            = nobody
no_new_privileges = yes
```

`cert-deploy`
: Needs to run as a user that can write the certificate folder, and
  `CAP_CHOWN` to set a group it is not a member of. Set `writable` to the
  folder the certificates go into: with the executor enabled, that is what
  confines where the script can write. The input folder is readable inside
  that confinement; it needs no entry in `writable`.

`svc-restart`
: The `run_as` user must be in the `docker` group and have a home directory
  that exists. The executor gives scripts no `HOME`, so the docker CLI falls
  back to the home in `/etc/passwd`, and fails if it is missing.

`default`
: `agent-cert-check` reads no files and needs no privilege, so it uses the
  restrictive `default` profile: list it in `scripts.conf` with no
  `profile=`. A script without `profile=` uses the profile named `default`,
  and that profile must be **defined** in `agent.conf`. Nothing is built in:
  the agent refuses to start (exit 78, "reference an undefined profile: ...
  -> default") without it.

The agent rereads `scripts.conf` on `systemctl reload ctrl-exec-agent`. The
executor notices a changed `agent.conf` by itself, but the agent does not
reread `agent.conf` on reload, so after adding or changing a profile run
`systemctl restart ctrl-exec-agent`.

Profiles are applied only when the executor is enabled (`executor_socket` in
`agent.conf`). Without it every script runs as the agent's own user and
`run_as`, `caps` and `writable` are ignored.

## Subcommands

The scripts take no subcommands. Each has a normal mode and a `--test` mode,
and calling one with no arguments prints usage to stderr and exits non-zero.

### agent-cert-deploy

```
agent-cert-deploy <target-dir> <basename> <group|-> [named|pem]     (input fields cert, key, ca)
agent-cert-deploy --test <target-dir> <basename> <group|-> [named|pem]
```

The certificate, key and CA are the input fields `cert`, `key` and `ca`
(see [Confidential input](#confidential-input)). Deprecated, removed in the
next release: with no input, the old form
`<target-dir> <basename> <group|-> <cert-b64> <key-b64> <ca-b64> [named|pem]`
is still accepted. If input arrived but a field is missing, the script exits 1
naming it (`input field 'key' is missing`) and writes nothing.

Writes, overwriting in place, in one of two layouts. `named` (the default):

- `<target-dir>/<basename>.crt` - the certificate
- `<target-dir>/<basename>.key` - the private key
- `<target-dir>/<basename>.ca` - the CA chain
- `<target-dir>/<basename>.fullchain.crt` - certificate then CA, for nginx

`pem`, for services that expect these two names in a folder of their own
(certbot style; an identity provider such as Authentik can import
`certs/<name>/` this way). Only these two files are written, so nothing else
in the folder is picked up:

- `<target-dir>/fullchain.pem` - certificate then CA
- `<target-dir>/privkey.pem` - the private key

Files are mode 640 and the folder 750. With a group (a name or a numeric
gid), the folder and files are given that group so a service running in it
can read the key; `-` leaves the group as it is. The folder is created if it
does not exist. Files are overwritten in place, so a container that
bind-mounts a single file keeps seeing the new content.

`--test` creates a probe file in the folder (or the nearest existing parent,
if the folder does not exist yet), sets the group and mode on it, and removes
it. It also re-applies the folder's current mode and checks every existing
certificate file can be overwritten. Nothing is changed.

### agent-service-restart

```
agent-service-restart <compose-file> [service ...]
agent-service-restart --test <compose-file> [service ...]
```

Runs `docker compose -f <compose-file> restart [service ...]`. With no
services, the whole stack is restarted. A stack split over several compose
files is given as one argument joined with `:`, as in `COMPOSE_FILE`
(`/srv/app/compose.yml:/srv/app/compose.outpost.yml`); each is passed with its
own `-f`, in order.

Scope, by design: any compose stack on the host can be restarted. The script
does not limit which compose file it is given. Whoever is allowed to run it,
by the dispatcher's auth hook and the agent's allowlist, is trusted to
restart any service on the host; the dispatcher is already trusted with far
more. A host that needs narrower scope can check the arguments in the agent's
`auth_hook`.

`--test` checks the docker daemon is reachable, the compose file parses and
defines the services, and each service has a container to restart (a service
with no container is a failure: `restart` would silently do nothing). It then
runs the restart with `docker compose --dry-run` (compose v2.17 or later).

### agent-cert-check

```
agent-cert-check -p <port> -n <name> [-H <host>] [-P <starttls>]
                 [-w <days>] [-c <days>] [-f <sha256>] [-C <ca-file>] [-t <secs>]
```

Connects to `<host>:<port>` (default `localhost`), with STARTTLS when `-P`
names the protocol (`xmpp`, `smtp`, `imap`, ...), asks for `<name>`, and
checks what is served:

- the certificate covers `<name>`
- days to expiry: WARNING under `-w` (default 30), CRITICAL under `-c`
  (default 7) or expired
- the chain verifies against the system CAs (or `-C`); a service sending its
  certificate without the intermediate fails here
- with `-f`, the served certificate has that SHA-256 fingerprint, which
  proves the service serves a given certificate rather than an older one

Output and exit codes follow the Nagios plugin conventions, so it can also be
used from monitoring: one status line with performance data, and exit 0 OK,
1 WARNING, 2 CRITICAL, 3 UNKNOWN.

```
SSL OK - app.example.com on localhost:443: CN=*.example.com, expires 2027-01-18 (89 days), chain 2, verified | days=89;30;7 chain=2
SSL CRITICAL - chain does not verify: unable to verify the first certificate (chain of 1) - ...
```

## The job

`run-jobs/deploy-cert.sh` is a run-jobs job. Its configuration,
`deploy-cert.conf`, sits beside it; `run-jobs/deploy-cert.conf.example`
documents every key, grouped by host with a block per service.

```
schedule    = <cron expression>
agent       = <issuing-agent>
certificate = <domain> [wildcard]
target      = <name> <agent> <dir> <group|-> [named|pem]
deploy      = <domain> <target-name>
restart     = <target-name> <compose-file> [service ...]
verify      = <target-name> <name> <[address:]port> [starttls-protocol]
```

`certificate`
: A certificate to issue. The job runs
  `issue-cert <domain> [--wildcard]` on the issuing agent and expects the
  agent script's output to hold `### CERT ###`, `### KEY ###` and
  `### CA ###` sections, each followed by a PEM block. The issuing script is
  not part of this plugin; its name defaults to `ctrl-exec-hestia` and is set
  with `CE_AGENT_SCRIPT`.

`target`
: One destination: an agent, a folder on it, the group for the files and the
  file layout. An agent can have several targets. Target names are unique.
  For a service in a container, the group is the numeric gid of the
  service's user **inside the container** (`docker exec <container> id <user>`),
  not a host group of the same name: the two usually differ.

`deploy`
: Sends a certificate to a target. May repeat, one line per domain and
  target.

`restart`
: Runs once per run, on the target's agent, when that target received at
  least one successful deploy in the run, after all deploys.

`verify`
: Optional. After the restarts, when the target received a certificate
  covering `<name>` in this run (the domain itself, or one label under it for
  a wildcard), `agent-cert-check` on the target's agent connects to the port
  (on `localhost`, or to `<address>:<port>`), asks for `<name>` and confirms
  it serves the certificate just issued: same fingerprint, name covered,
  chain verifies, not near expiry. It retries while the service comes back
  up. A WARNING (expiry within the check's warning days) is logged but does
  not fail the run.

Comments go on their own line only: a `#` after a value becomes part of the
value. The job logs to syslog under the tag `run-jobs.deploy-cert` and ends
with a summary line such as `complete: issued 1 ok 0 failed | deployed 1 ok 0
failed | restarted 1 ok 0 failed`. The response from the issuing agent holds
the private key, so the job keeps it in memory only (shell variables) and
never writes it to a file. The destinations' scripts need `input=fields` (see
[scripts.conf](#scriptsconf)).

Environment overrides: `CE_AGENT_SCRIPT`, `CE_DEPLOY_SCRIPT`,
`CE_RESTART_SCRIPT`, `CE_CHECK_SCRIPT` (script names, defaults as the scripts
above), `VERIFY_TRIES` (default 4), `VERIFY_WAIT` (seconds between attempts,
default 20, kept wide so retries stay under the agent's connection rate
limit) and `CERT_OUTPUT_DIR`.

## Examples

### Testing before a real run

Run the tests through ctrl-exec, from the dispatcher side, so they run under
the profile exactly as the job will. Run by hand on the host they test your
own permissions instead.

```bash
ctrl-exec-cli run <agent> --script agent-cert-deploy -- \
    --test /srv/app/certs example.com 101

ctrl-exec-cli run <agent> --script agent-service-restart -- \
    --test /srv/app/compose.yml nginx
```

Each prints `ok`, `FAIL` or `info` lines and ends with "all checks passed"
(exit 0) or the number of failures (exit 1). Check the `user:` line shows the
profile's `run_as` user; if it shows the agent's own user, the executor is not
enabled. Use the same values as the `target` and `restart` lines in
`deploy-cert.conf`.

### Checking what a service serves

```bash
ctrl-exec-cli run <agent> --script agent-cert-check -- \
    -p 443 -n www.example.com

ctrl-exec-cli run <agent> --script agent-cert-check -- \
    -H 192.0.2.10 -p 636 -n ldap.example.org -f <sha256-fingerprint>
```

### Running a deploy by hand

Run the job from the run-jobs container; leave off the domain to process
every certificate in `deploy-cert.conf`:

```bash
docker compose exec run-jobs /etc/run-jobs/scripts/deploy-cert.sh example.com; echo "exit=$?"
journalctl -t run-jobs.deploy-cert --since -10min
```

A good run exits 0 and logs the summary line shown above. A hand run does not
touch the run-jobs state.

### Verifying a deploy

A successful deploy and restart does not prove the service uses the new
certificate. After a deploy, check on the destination host:

- The files have the expected date, mode and group: `ls -ln <target-dir>`.
- The service's own user can read the key, tested as that user. For a
  container, `docker exec -u <service-user> <container> cat <key-path>`; a
  plain `docker exec` runs as root and reads anything, so it proves nothing.
- The service's own certificate check passes, if it has one.
- What the service actually serves: `agent-cert-check` against its port, by
  hand or through `verify` lines in `deploy-cert.conf` so every run checks it.

### Running the plugin's tests

```bash
bash test/run.sh | tee test/TEST-REPORT.md
```

It also covers the confidential input: `agent-cert-deploy` installing from a
simulated `CTRL_EXEC_INPUT` folder (0700, files 0600), the argument fallback
and a missing field, and `deploy-cert.sh` against a stub `ctrl-exec-cli` that
records every call's arguments, environment and stdin, asserting the key is on
stdin only.

The suite needs no network beyond 127.0.0.1, no real docker and no root. It
runs the agent-check against local `openssl s_server` instances, the restart
script against a stub `docker`, and the job against a stub `ctrl-exec-cli`.
Sections that need `openssl`, `jq` or `perl` are skipped when the tool is
absent.

## Limitations

- The deprecated argument form of `agent-cert-deploy` (one release) still
  shows the key in the process table; it is used only when no input arrives.
  The key is also in the memory of the issuing agent script, the job's shell
  and the receiving script while they run, and in the certificate files on the
  destination, mode 640.
- Issuing a wildcard certificate can take longer than the dispatcher's
  `read_timeout`; raise it to suit the issuing agent. `ctrl-exec-cli` also
  gives up after 120 seconds with no response.
- `agent-service-restart` can restart any compose stack on the host, by
  design (see its scope note above). It supports docker compose only.
- The job issues, deploys and restarts in one pass and does not roll back: a
  failed deploy to one target leaves the others deployed, and the run exits
  non-zero.
- `agent-cert-check` verifies the chain against the system CAs of the agent
  it runs on, or `-C`. A private CA must be present there or given with `-C`.
- The issuing agent script is not part of this plugin.
