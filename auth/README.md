---
title: dispatcher-plugins - auth
subtitle: Auth hooks for dispatcher and agent hosts
brand: odcc
---

# auth

Auth hooks for deployment on dispatcher or agent hosts. Each hook reads
request context from stdin as JSON and controls access by exit code,
integrating dispatcher with external identity and credential systems.


## How auth hooks work

Dispatcher has no built-in access control. All access policy is delegated
to an operator-supplied hook executable. The hook is called before every
`run` and `ping` from both the CLI and the API.

The hook receives request context in two forms: as environment variables,
and as a JSON object on stdin. It exits with a code that dispatcher maps to
an authorisation decision.

Exit codes:

```
0   authorised
1   denied - generic
2   denied - bad credentials
3   denied - insufficient privilege
```

Any exit code above 3, or a crash, is treated as a denial.

The hook must not produce output on stdout or stderr. These are discarded.
Use syslog for audit logging within the hook.


## Context available to the hook

Environment variables:

```
ENVEXEC_ACTION      run | ping
ENVEXEC_SCRIPT      script name (empty for ping)
ENVEXEC_HOSTS       comma-separated host list
ENVEXEC_ARGS        space-joined args
ENVEXEC_ARGS_JSON   args as a JSON array string (use for arg inspection)
ENVEXEC_USERNAME    username from request (may be empty)
ENVEXEC_TOKEN       token from request (may be empty)
ENVEXEC_SOURCE_IP   127.0.0.1 for CLI; caller IP for API
ENVEXEC_TIMESTAMP   ISO 8601 UTC timestamp
```

stdin JSON (same fields, with hosts and args as arrays):

```json
{
  "action":     "run",
  "script":     "backup-mysql",
  "hosts":      ["db-01", "db-02"],
  "args":       ["--database", "myapp"],
  "username":   "alice",
  "token":      "mytoken",
  "source_ip":  "192.0.2.10",
  "timestamp":  "2026-01-01T12:00:00Z"
}
```

The JSON form is preferred for inspection - use `ENVEXEC_ARGS_JSON` rather
than `ENVEXEC_ARGS` when examining arguments, as the space-joined form is
ambiguous when args contain spaces.


## Installing a hook

Place the hook executable on the dispatcher host and reference it in
`ctrl-exec.conf`:

```bash
sudo cp my-auth-hook /etc/ctrl-exec/auth-hook
sudo chmod 750 /etc/ctrl-exec/auth-hook
sudo chown root:dispatcher /etc/ctrl-exec/auth-hook
```

In `/etc/ctrl-exec/ctrl-exec.conf`:

```ini
auth_hook = /etc/ctrl-exec/auth-hook
```

Restart the API service for the change to take effect:

```bash
sudo systemctl restart ctrl-exec-api
```

The CLI picks up the change immediately on the next invocation.


## Agent-side hooks

Agents can also run their own auth hook, configured via `auth_hook` in
`agent.conf`. This runs after allowlist validation and receives the same
context, including the token and username forwarded from the dispatcher.

Agent-side hooks are useful for independent token validation in zero-trust
or multi-dispatcher deployments, where the agent does not fully trust the
dispatcher to have performed adequate access control.


## Example: static token

The simplest useful hook. All requests with the correct token are authorised;
all others are denied with exit 2 (bad credentials).

```bash
#!/bin/bash
[[ "$ENVEXEC_TOKEN" == "mysecrettoken" ]] || exit 2
exit 0
```


## Example: per-token script restriction

Different tokens permit different scripts. An ops token has full access;
a backup token may only call scripts whose names begin with `backup-`.

```bash
#!/bin/bash
case "$ENVEXEC_TOKEN" in
    backup-token)
        [[ "$ENVEXEC_SCRIPT" == backup-* ]] || exit 3
        exit 0 ;;
    ops-token)
        exit 0 ;;
    *)
        exit 2 ;;
esac
```


## Example: argument count enforcement

Reads args from the JSON form to avoid ambiguity. Denies any request passing
more than two arguments.

```bash
#!/bin/bash
ARG_COUNT=$(echo "$ENVEXEC_ARGS_JSON" \
    | python3 -c "import sys,json; print(len(json.load(sys.stdin)))")
[[ "$ARG_COUNT" -le 2 ]] || exit 3
exit 0
```


## Example: source IP restriction

Allows CLI calls (source IP is always 127.0.0.1) and restricts API calls
to a specific subnet.

```bash
#!/bin/bash
case "$ENVEXEC_SOURCE_IP" in
    127.0.0.1)        exit 0 ;;
    192.168.100.*)    exit 0 ;;
    *)                exit 1 ;;
esac
```


## Hook conventions

All auth plugins in this category follow these conventions.

Fail closed
: Any unhandled error, malformed stdin, or missing field exits with a
  non-zero code. The hook never exits 0 in an error path.

No output
: stdout and stderr are discarded by dispatcher. Do not attempt to
  communicate via output. Use syslog for audit logging.

Stdin tolerance
: The hook must handle empty or malformed stdin without crashing. Use
  defensive parsing and exit 1 on any parse failure.

No external state written
: Hooks are read-only with respect to the dispatcher's own data. Any
  external state (rate limit counters, session logs) is the hook's own
  responsibility to manage safely.

Token handling
: Tokens received on stdin or via environment must not be logged, echoed,
  or written to any file. Use syslog fields that exclude the token value
  if audit logging is needed.

British English in output and documentation
: Consistent with the dispatcher project convention.
