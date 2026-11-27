#!/usr/bin/env bash
set -euo pipefail

# Sets up a weekly cron job (Sundays at 3am) that runs bin/cert/renew.sh.
# Safe to run again: it replaces an existing entry instead of adding a second.

cd "$(dirname "$0")/../.."

PROJECT_DIR="$(pwd)"
CRON_CMD="0 3 * * 0 cd '${PROJECT_DIR}' && ./bin/cron/run.sh cert-renew 604800 ./bin/cert/renew.sh >> /var/log/cert-renewal.log 2>&1"

if crontab -l 2>/dev/null | grep -qxF "$CRON_CMD"; then
    echo "Certificate renewal cron job already configured."
else
    (crontab -l 2>/dev/null | grep -v "bin/cert/renew.sh" || true; echo "$CRON_CMD") | crontab -
    echo "Certificate renewal cron job set (weekly on Sundays at 3am) for ${PROJECT_DIR}."
fi
