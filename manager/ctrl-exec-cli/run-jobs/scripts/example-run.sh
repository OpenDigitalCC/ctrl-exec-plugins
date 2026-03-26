#!/usr/bin/env bash
# example-run.sh
# Dispatches an allowlisted script to a ctrl-exec agent.
# Edit AGENT and SCRIPT to match your environment.
# Runs daily at 02:00.

set -euo pipefail

AGENT="my-agent"
SCRIPT="my-script"

echo "==> Running ${SCRIPT} on ${AGENT}"
ctrl-exec-cli run "${AGENT}" --script "${SCRIPT}"
