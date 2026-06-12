# Test report: text-file (ce-auth-plugins)
Generated: 2026-06-12T05:45:06Z

  PASS  empty stdin, no credentials -> bad credentials
  PASS  valid username:token -> authorised
  PASS  wrong token -> bad credentials
  PASS  unknown user -> bad credentials
  PASS  empty token -> bad credentials
  PASS  missing file -> deny (fail closed)

Results: 6 passed, 0 failed
VERDICT: PASS
