#!/bin/bash
# run-jobs-entrypoint.sh
# Runs run-jobs.sh every 5 minutes. Sleeps until the next 5-minute boundary.
# Runs as PID 1 - handles SIGTERM cleanly.

set -euo pipefail

trap 'echo "[run-jobs] Shutting down"; exit 0' TERM INT

echo "[run-jobs] Orchestrator starting"
echo "[run-jobs] Scripts dir: ${JOBS_SCRIPTS_DIR:-/etc/run-jobs/scripts}"
echo "[run-jobs] State dir:   ${JOBS_STATE_DIR:-/var/lib/run-jobs/state}"

while true; do
    /usr/local/bin/run-jobs.sh &
    wait $!

    # Sleep until next 5-minute boundary
    now=$(date +%s)
    next=$(( now + 300 - (now % 300) ))
    sleep_for=$(( next - now ))
    sleep "$sleep_for" &
    wait $!
done
