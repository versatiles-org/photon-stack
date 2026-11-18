#!/usr/bin/env bash
set -euo pipefail

# Renews the certificate if it is due (30 days before it expires) and makes
# nginx load it. Run weekly from cron (bin/cert/setup_renewal.sh); safe to run
# any time, as certbot does nothing while the certificate is not due.
#
# Usage: bin/cert/renew.sh [certbot options, e.g. --dry-run]

cd "$(dirname "$0")/../.."

# certbot proves domain ownership through files that the running nginx serves
# from volumes/certbot-www. Without nginx a renewal cannot succeed.
if ! docker compose ps --status running --services | grep -qx nginx; then
    echo "Error: nginx is not running — cannot renew certificates." >&2
    exit 1
fi

# --no-deps: do not let compose touch nginx or Photon. Without it, `compose run`
# first brings the services certbot depends on in line with docker-compose.yml,
# which could recreate them unattended at night.
docker compose run --rm --no-deps certbot renew "$@"

# Reload, so a renewed certificate is used. Cheap, and harmless when nothing was
# renewed. -T: from cron there is no TTY.
docker compose exec -T nginx nginx -s reload

echo "Certificate renewal checked, nginx reloaded."
