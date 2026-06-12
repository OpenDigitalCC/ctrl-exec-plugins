# Test report: agent-file-transfer (ce-agent-plugins)
Generated: 2026-06-12T05:38:49Z

  PASS  no args -> exit 2 (--port required)
  PASS  missing --output -> exit 2
  PASS  non-numeric --port -> exit 2
  PASS  non-numeric --timeout -> exit 2
  PASS  unknown argument -> exit 2 (usage)
  PASS  every schema argv flag is declared and parsed
  PASS  schema marks the receiver destructive
  PASS  ce-file-transfer no args -> nonzero (usage)
  PASS  ce-push-blob no args -> nonzero (usage)

Results: 9 passed, 0 failed
VERDICT: PASS
