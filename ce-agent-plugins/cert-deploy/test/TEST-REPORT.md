# Test report: cert-deploy (ce-agent-plugins)
Generated: 2026-10-21T05:14:15Z

## Contract: no arguments

  PASS  agent-cert-deploy.sh with no arguments exits non-zero
  PASS  agent-cert-deploy.sh with no arguments prints usage
  PASS  agent-service-restart.sh with no arguments exits non-zero
  PASS  agent-service-restart.sh with no arguments prints usage
  PASS  agent-cert-check.sh with no arguments exits non-zero
  PASS  agent-cert-check.sh with no arguments prints usage
  PASS  agent-cert-deploy.sh is executable
  PASS  agent-cert-deploy.sh has a shebang
  PASS  agent-cert-deploy.sh schema sidecar is valid JSON with arguments and argv
  PASS  agent-service-restart.sh is executable
  PASS  agent-service-restart.sh has a shebang
  PASS  agent-service-restart.sh schema sidecar is valid JSON with arguments and argv
  PASS  agent-cert-check.sh is executable
  PASS  agent-cert-check.sh has a shebang
  PASS  agent-cert-check.sh schema sidecar is valid JSON with arguments and argv
  PASS  agent-cert-check sidecar is read_only
  PASS  agent-cert-deploy sidecar is not read_only
  PASS  agent-service-restart sidecar is not read_only
  PASS  agent-cert-deploy sidecar: no secret in the arguments
  PASS  agent-cert-deploy sidecar declares input fields cert,key,ca
  PASS  agent-cert-deploy sidecar: input field names match the contract
  PASS  agent-cert-deploy sidecar layout enum

## agent-cert-deploy

  PASS  deploy, named layout (default)
  PASS  named layout writes the four files
  PASS  named: file mode 640
  PASS  named: folder mode 750
  PASS  named: group set (numeric gid)
  PASS  named: fullchain is certificate then CA
  PASS  named: key written byte for byte
  PASS  named: output names the layout
  PASS  deploy, named given explicitly, group -
  PASS  explicit named is identical to the default
  PASS  deploy, pem layout, group by name
  PASS  pem layout writes exactly two files
  PASS  pem: file mode 640
  PASS  pem: fullchain is certificate then CA
  PASS  pem: privkey.pem is the key
  PASS  deploy again over existing files (idempotent)
  PASS  existing key overwritten in place
  PASS  bad layout rejected on deploy
  PASS  bad layout names the problem
  PASS  bad layout wrote nothing
  PASS  deploy without the base64 arguments rejected
  PASS  relative target-dir rejected
  PASS  target-dir with '..' rejected
  PASS  basename with '/' rejected
  PASS  invalid group characters rejected
  PASS  input fields: deploy, named layout (default)
  PASS  input fields: result is identical to the argv form
  PASS  input fields: file mode 640
  PASS  input fields: folder mode 750
  PASS  input fields: output does not echo the key
  PASS  input fields: deploy, pem layout
  PASS  input fields: pem result is identical to the argv form
  PASS  input fields: fields without a final newline
  PASS  input fields: fullchain is certificate then CA, no joined line
  PASS  input fields: no line joins the END and BEGIN markers
  PASS  input fields with the old base64 arguments: rejected
  PASS  …and nothing was written
  PASS  input fields: 'cert' missing: fails
  PASS  input fields: 'cert' missing: the field is named
  PASS  input fields: 'cert' missing: nothing written
  PASS  input fields: 'key' missing: fails
  PASS  input fields: 'key' missing: the field is named
  PASS  input fields: 'key' missing: nothing written
  PASS  input fields: 'ca' missing: fails
  PASS  input fields: 'ca' missing: the field is named
  PASS  input fields: 'ca' missing: nothing written
  PASS  deprecated argv form: empty input directory (input=fields, nothing sent)
  PASS  deprecated argv form: same result
  PASS  deprecated argv form: CTRL_EXEC_INPUT unset, pem layout
  PASS  no input and no base64 arguments: fails
  PASS  …and says to declare input=fields
  PASS  empty input directory and no base64 arguments: fails
  PASS  …and nothing was written
  PASS  --test with input present
  PASS  script marks the argv form deprecated
  PASS  --test, existing folder, own group by name
  PASS  --test reports success
  PASS  --test names the layout
  PASS  --test, numeric gid of own group
  PASS  --test says no host entry is needed
  PASS  --test, group that does not exist
  PASS  --test names the missing group
  PASS  --test, folder to be created
  PASS  --test says the folder would be created
  PASS  --test did not create the folder
  PASS  --test, pem layout over existing files
  PASS  --test pem names the layout
  PASS  --test pem checks an existing file
  PASS  --test, bad layout
  PASS  --test left no probe file behind
  PASS  --test left the existing key unchanged
  PASS  --test left the existing key's mode unchanged
  PASS  --test, unwritable folder
  PASS  --test explains the unwritable folder
  PASS  --test, read-only existing key
  PASS  --test names the read-only file
  PASS  --test, group the user is not a member of

## agent-service-restart (stub docker)

  PASS  --test, running and stopped services
  PASS  --test reports a running service
  PASS  --test reports a stopped service
  PASS  --test ran the dry-run restart
  PASS  --test, service with no container fails
  PASS  --test explains the missing container
  PASS  --test, service not defined fails
  PASS  --test names the undefined service
  PASS  --test, whole stack fails while a service has no container
  PASS  --test, two compose files
  PASS  --test passes each file with its own -f, in order
  PASS  --test, no docker socket access fails
  PASS  --test explains the docker access problem
  PASS  --test, compose file that does not exist
  PASS  --test, second compose file that does not exist
  PASS  relative compose path rejected
  PASS  compose path with '..' rejected
  PASS  service name starting with '-' rejected
  PASS  restart, two compose files, two services
  PASS  restart runs docker compose restart with the files and services
  PASS  restart, whole stack
  PASS  whole-stack restart names no service
  PASS  whole-stack restart says so

## agent-cert-check (local openssl s_server)

  PASS  healthy chain: exit 0 (OK)
  PASS  healthy chain: status line
  PASS  healthy chain: verified, chain of 2
  PASS  healthy chain: performance data
  PASS  fingerprint match: exit 0
  PASS  fingerprint match: reported
  PASS  fingerprint match: lower case, no colons
  PASS  fingerprint mismatch: exit 2 (CRITICAL)
  PASS  fingerprint mismatch: reported
  PASS  missing intermediate: exit 2
  PASS  missing intermediate: chain does not verify
  PASS  chain to an unknown CA (no -C): exit 2
  PASS  wrong name: exit 2
  PASS  wrong name: reported
  PASS  20 days left: exit 1 (WARNING)
  PASS  20 days left: status line
  PASS  20 days left, -w 10: exit 0
  PASS  3 days left: exit 2 (CRITICAL)
  PASS  closed port: exit 2
  PASS  closed port: reason
  PASS  missing -n: exit 3 (UNKNOWN)
  PASS  bad port: exit 3
  PASS  bad name: exit 3
  PASS  non-numeric -w: exit 3
  PASS  unreadable CA file: exit 3
  PASS  unknown option: exit 3
  PASS  -h prints usage, exit 0

## deploy-cert.sh (stub ctrl-exec-cli)

  PASS  two targets on one agent: exit 0
  PASS  two targets: named layout passed for the first
  PASS  two targets: pem layout passed for the second
  PASS  two targets: both restarts ran
  PASS  two targets: summary line
  PASS  private key not left on disk
  PASS  secret: one stdin record per deploy
  PASS  secret: stdin is a JSON object of cert, key and ca with the issued values
  PASS  secret: key content in no argv
  PASS  secret: key (base64) in no argv
  PASS  secret: certificate content in no argv
  PASS  secret: no base64 blob in any recorded call
  PASS  secret: key in no environment
  PASS  secret: key in no file under the job's directory (output, TMPDIR, log, stdout)
  PASS  secret: nothing left in TMPDIR
  PASS  secret: the deploy call used --input-fields -
  PASS  single certificate by name: exit 0
  PASS  restart only for the target that got a certificate
  PASS  no restart for the target that got none
  PASS  no verify call for the target that got none
  PASS  deploy to an unknown target: exit 1
  PASS  unknown target is named in the log
  PASS  nothing restarted after a failed deploy
  PASS  bad layout in a target line: exit 1
  PASS  bad target line logged
  PASS  bad target line stops before anything is issued
  PASS  duplicate target name: exit 1
  PASS  duplicate target name logged
  PASS  target line without a name: exit 1
  PASS  target line without a name logged
  PASS  deploy line with extra fields: exit 1
  PASS  bad deploy line logged
  PASS  deploy fails on the agent: exit 1
  PASS  agent error is logged
  PASS  no restart when every deploy failed
  PASS  restart for an unknown target: exit 1
  PASS  bad restart line logged
  PASS  certificate with no deploy line: exit 0
  PASS  no-deploy case logged
  PASS  no restart without a deploy
  PASS  no agent in the configuration: exit 1
  PASS  verify by name: exit 0
  PASS  restart passes ':'-joined compose files as one argument
  PASS  wildcard covers one label: address:port
  PASS  wildcard does not cover two labels
  PASS  wildcard domain itself is covered
  PASS  exact certificate does not cover a sub-name
  PASS  port on localhost via address:port
  PASS  verify: three checks ran
  PASS  bad verify addresses: exit 1
  PASS  each bad verify line is logged
  PASS  no check ran for a bad verify line
  PASS  verify for an unknown target: exit 1
  PASS  verify for a target that got no certificate: exit 0
  PASS  …and no check ran
  PASS  verify OK: exit 0
  PASS  verify passes the issued fingerprint and STARTTLS protocol
  PASS  verify OK: one check (no retry)
  PASS  verify OK: logged
  PASS  verify WARNING does not fail the run
  PASS  verify WARNING is logged
  PASS  verify retries while the service comes back: exit 0
  PASS  verify retried until it answered
  PASS  verify CRITICAL: exit 1
  PASS  verify gives up after VERIFY_TRIES
  PASS  verify failure logged
  PASS  no verify lines: exit 0
  PASS  no verify lines: summary has no verified count
  PASS  deploy-cert.conf.example runs cleanly
  PASS  example: named target deployed
  PASS  example: pem target deployed
  PASS  example: two-file restart passed through

Results: 221 passed, 0 failed, 0 skipped
VERDICT: PASS
