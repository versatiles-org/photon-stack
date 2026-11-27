#!/usr/bin/env bash
set -euo pipefail

# Sets up a nightly cron job (0:10am) that runs bin/log/rotate.sh: it moves the
# nginx logs into their archives (the usage statistics on the 1st of each month
# only) and deletes request and error log archives older than 28 days.
# Safe to run again: it replaces an existing entry instead of adding a second.

cd "$(dirname "$0")/../.."
PROJECT_DIR="$(pwd)"
CRON_CMD="10 0 * * * cd '${PROJECT_DIR}' && ./bin/cron/run.sh log-rotate 86400 ./bin/log/rotate.sh >> /var/log/nginx-log-rotation.log 2>&1"

if crontab -l 2>/dev/null | grep -qxF "$CRON_CMD"; then
    echo "Log rotation cron job already configured."
else
    (crontab -l 2>/dev/null | grep -v "bin/log/rotate.sh" || true; echo "$CRON_CMD") | crontab -
    echo "Log rotation cron job set (nightly at 0:10am) for ${PROJECT_DIR}."
fi
