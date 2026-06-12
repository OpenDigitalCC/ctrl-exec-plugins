# Test report: unix-user (ce-auth-plugins)
Generated: 2026-06-12T05:18:50Z

  PASS  no username -> bad credentials
  PASS  existing local user -> authorised
  PASS  user in its primary group -> authorised
  PASS  user not in required group -> insufficient privilege
  PASS  unknown user -> bad credentials

Results: 5 passed, 0 failed
VERDICT: PASS
