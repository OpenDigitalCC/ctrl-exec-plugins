#!/usr/bin/env bash
# example-health.sh
# Checks ctrl-exec API health and lists registered agents.
# Runs every 15 minutes. Results go to the state directory.

set -euo pipefail

echo "==> API health"
ctrl-exec-cli health

echo ""
echo "==> Registered agents"
ctrl-exec-cli discovery
