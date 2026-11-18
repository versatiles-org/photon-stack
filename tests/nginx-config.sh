#!/usr/bin/env bash
set -euo pipefail

# Checks that the nginx configuration loads: the template is rendered and tested
# with `nginx -t`, in the nginx image docker-compose.yml pins and with the same
# mounts. Starts no server and needs no network. (As in tiles.versatiles.org.)
#
# Usage: tests/nginx-config.sh
# Run by CI (.github/workflows/nginx.yml); run it locally before changing
# anything under nginx/.

cd "$(dirname "$0")/.."

DOMAIN=geocode.example.org

# The nginx image docker-compose.yml pins. compose only needs the variables to
# be set to something; .env may not exist here.
NGINX_IMAGE=$(env DOMAIN_NAME=x PHOTON_VERSION=x PHOTON_DATA_DIR=/x PHOTON_HOST_PORT=1 \
    PHOTON_UID=1 PHOTON_GID=1 JAVA_HEAP_MIN=1g JAVA_HEAP_MAX=1g \
    docker compose --env-file /dev/null config --images | grep -E '^nginx:')
echo "Testing the nginx config with $NGINX_IMAGE"

# A throwaway self-signed certificate where certbot keeps the real one.
CERT_DIR=$(mktemp -d)
trap 'rm -rf "$CERT_DIR"' EXIT
mkdir -p "$CERT_DIR/live/$DOMAIN"
openssl req -nodes -new -x509 -subj "/CN=$DOMAIN" \
    -keyout "$CERT_DIR/live/$DOMAIN/privkey.pem" \
    -out "$CERT_DIR/live/$DOMAIN/fullchain.pem" 2>/dev/null
chmod -R a+rX "$CERT_DIR"

# The image's entrypoint renders the template (as at a real container start),
# then `nginx -t` loads the result.
#   --add-host  the upstream names Photon `photon`; there is none here
docker run --rm \
    --add-host photon:127.0.0.1 \
    -e "DOMAIN_NAME=$DOMAIN" \
    -v "$PWD/nginx/nginx.stub.conf:/etc/nginx/nginx.conf:ro" \
    -v "$PWD/nginx/:/etc/nginx/repo/:ro" \
    -v "$PWD/nginx/templates/:/etc/nginx/templates/:ro" \
    -v "$CERT_DIR:/etc/letsencrypt/:ro" \
    "$NGINX_IMAGE" nginx -t

echo "nginx config OK"
