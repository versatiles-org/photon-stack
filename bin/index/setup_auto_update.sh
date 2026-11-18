#!/usr/bin/env bash
set -euo pipefail

# Sets up a monthly cron job (the 1st, 02:00 server time) that runs
# bin/index/update.sh. Opt-in: nothing updates the index until this has run.
# Safe to run again: it replaces an existing entry instead of adding a second.
#
# 02:00 is far from the busiest hours (11, 13 and 21-22 UTC in November 2026).
# An update may still run during the certificate renewal (Sundays 03:00); that
# is fine, as the renewal needs only nginx.
#
# To turn it off again: `crontab -e` and delete the bin/index/update.sh line.

cd "$(dirname "$0")/../.."

PROJECT_DIR="$(pwd)"
CRON_CMD="0 2 1 * * cd '${PROJECT_DIR}' && ./bin/index/update.sh >> /var/log/photon-index-update.log 2>&1"

if crontab -l 2>/dev/null | grep -qxF "$CRON_CMD"; then
    echo "Index update cron job already configured."
else
    (crontab -l 2>/dev/null | grep -v "bin/index/update.sh" || true; echo "$CRON_CMD") | crontab -
    echo "Index update cron job set (monthly on the 1st at 2am) for ${PROJECT_DIR}."
fi
