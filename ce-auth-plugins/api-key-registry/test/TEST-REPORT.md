# Test report: api-key-registry (ce-auth-plugins)
Generated: 2026-06-12T05:45:06Z

  PASS  no token -> bad credentials
  PASS  run-level key, run action -> authorised
  PASS  ping-level key, discovery action -> authorised
  PASS  ping-level key, run action -> insufficient privilege
  PASS  unknown key -> bad credentials
  PASS  missing registry -> deny (fail closed)

Results: 6 passed, 0 failed
VERDICT: PASS
