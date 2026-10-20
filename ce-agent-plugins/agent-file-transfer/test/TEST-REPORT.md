# Test report: agent-file-transfer (ce-agent-plugins)
Generated: 2026-10-20T14:23:09Z

  PASS  no args -> exit 2 (--port required)
  PASS  missing --output -> exit 2
  PASS  non-numeric --port -> exit 2
  PASS  non-numeric --timeout -> exit 2
  PASS  unknown argument -> exit 2 (usage)
  PASS  --status without --output -> exit 2
  PASS  --status with a non-hex id -> exit 2
  PASS  --status unknown transfer -> exit 1
  PASS  every schema argv flag is declared and parsed
  PASS  schema marks the receiver destructive
  PASS  ce-file-transfer no args -> nonzero (usage)
  PASS  ce-push-blob no args -> nonzero (usage)
  PASS  receiver exits 0 once the listener is up
  PASS  receiver returns at once, not after --timeout
  PASS  stdout carries a 64-hex fingerprint:
  PASS  stdout carries a hex id:
  PASS  listener still running after the receiver exited
  PASS  listener holds no pipe on stdout/stderr
  PASS  listener runs in its own session
  PASS  throwaway cert exists while listening
  PASS  --status reports pending before the transfer
  PASS  a fingerprint probe does not end the transfer
  PASS  --status reports received:<bytes> after the transfer
  PASS  --status reports the sha256
  PASS  received file is identical to the sent file
  PASS  listener removed its throwaway cert
  PASS  listener exits after the transfer
  PASS  no .failed file after a good transfer
  PASS  --status reports timedout when no sender connects
  PASS  --status exits 1 for timedout
  PASS  timed-out listener leaves no output or .failed file
  PASS  --status reports failed for a non-archive
  PASS  failed transfer keeps its data as .failed.<epoch>
  PASS  unwritable output directory -> exit 1
  PASS  the error names the writable requirement
  PASS  ce-push-blob completes against the stub API (sync)
  PASS  ce-push-blob confirms receipt through --status (sync)
  PASS  pushed file arrives intact (sync)
  PASS  confirmation goes through the --status run call (sync)
  PASS  ce-push-blob sends no tokenless status poll (sync)
  PASS  ce-file-transfer completes against the stub API (sync)
  PASS  ce-file-transfer confirms receipt through --status (sync)
  PASS  ce-file-transfer confirms through the --status run call (sync)
  PASS  ce-file-transfer sends no tokenless status poll (sync)
  PASS  ce-push-blob completes against the stub API (async)
  PASS  ce-push-blob confirms receipt through --status (async)
  PASS  pushed file arrives intact (async)
  PASS  confirmation goes through the --status run call (async)
  PASS  ce-push-blob sends no tokenless status poll (async)
  PASS  async status polls carry the Bearer token
  PASS  ce-file-transfer completes against the stub API (async)
  PASS  ce-file-transfer confirms receipt through --status (async)
  PASS  ce-file-transfer confirms through the --status run call (async)
  PASS  ce-file-transfer sends no tokenless status poll (async)
  PASS  ce-push-blob with a wrong token fails

Results: 55 passed, 0 failed
VERDICT: PASS
