# Test report: htpasswd (ce-auth-plugins)
Generated: 2026-06-12T05:45:06Z

  PASS  no credentials -> bad credentials
  PASS  valid user + password -> authorised
  PASS  wrong password -> bad credentials
  PASS  unknown user -> bad credentials
  PASS  missing file -> deny (fail closed)

Results: 5 passed, 0 failed
VERDICT: PASS
