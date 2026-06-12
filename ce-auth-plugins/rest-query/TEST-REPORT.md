# Test report: rest-query (ce-auth-plugins)
Generated: 2026-06-12T05:18:50Z

  PASS  no endpoint configured -> deny (fail closed)
  PASS  empty endpoint URL -> deny (fail closed)
  PASS  endpoint 200 -> authorised
  PASS  endpoint 401 -> bad credentials
  PASS  endpoint 403 -> insufficient privilege
  PASS  endpoint 500 -> deny
  PASS  unreachable endpoint -> deny

Results: 7 passed, 0 failed
VERDICT: PASS
