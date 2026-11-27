#!/usr/bin/env bash
set -euo pipefail

# Rolls out a new nginx image, and nothing else. Runs daily from cron (see
# setup_auto_update.sh), so that a security fix in nginx, which reaches the
# official image the day nginx releases it, is live within a day. The same
# procedure as bin/nginx/update.sh in tiles.versatiles.org.
#
# It runs unattended, so it only acts when it is safe to:
#   - Nothing happens unless a newer image arrived under the same tag, or if
#     docker-compose.yml describes nginx differently from the running
#     container: that change is applied by hand (`docker compose up -d`).
#   - Before the switch, the nginx config must load in the new image
#     (tests/nginx-config.sh, the same check CI runs). If not, nginx keeps
#     running the previous image.
#   - The switch costs about 3 seconds of refused connections.
#   - Afterwards nginx must be healthy and answer HTTPS with the real
#     certificate. If not, it is recreated from the previous image.
#   - Afterwards the running nginx must be the newest release of a line that
#     nginx.org still maintains (bin/nginx/check_version.sh). That catches the
#     tag in docker-compose.yml going stale, which the rollout alone can't see.
# Photon is never touched (--no-deps), and the response cache survives the
# switch (a named volume).
#
# Exits 0 when nginx is up to date or was updated, 1 when something needs a
# look: see /var/log/nginx-update.log.

cd "$(dirname "$0")/../.."
# shellcheck source=/dev/null
. ./.env

log() { echo "$(date -u +%FT%TZ) $*"; }

# Fails when the nginx that runs is behind nginx.org, see check_version.sh.
check_version() {
    local running
    running=$(docker compose exec -T nginx nginx -v 2>&1 | sed -n 's#^nginx version: nginx/##p' || true)
    ./bin/nginx/check_version.sh "$running"
}

# One run at a time (cron and a manual run). The kernel releases the lock when
# the script exits, however it exits.
mkdir -p volumes
exec 9>volumes/.nginx-update.lock
if ! flock -n 9; then
    log "Error: another nginx update is running."
    exit 1
fi

if ! docker compose ps --status running --services | grep -qx nginx; then
    log "Error: nginx is not running. Not starting it unattended: run docker compose up -d."
    exit 1
fi
cid=$(docker compose ps -q nginx)

# The running container must match docker-compose.yml (the hash compose stored
# when it created the container). Otherwise a recreate would also roll out
# that definition change, unattended.
want_hash=$(docker compose config --hash nginx | awk '{print $2}')
have_hash=$(docker inspect -f '{{ index .Config.Labels "com.docker.compose.config-hash" }}' "$cid")
if [ "$want_hash" != "$have_hash" ]; then
    log "Error: docker-compose.yml describes nginx differently from the running container. Apply it by hand."
    exit 1
fi

image_ref=$(docker inspect -f '{{.Config.Image}}' "$cid")
old_image=$(docker inspect -f '{{.Image}}' "$cid")

docker compose pull --quiet nginx
new_image=$(docker image inspect -f '{{.Id}}' "$image_ref")

if [ "$new_image" = "$old_image" ]; then
    log "nginx is up to date ($image_ref)."
    check_version || exit 1
    exit 0
fi
log "A new $image_ref arrived: ${old_image:7:12} → ${new_image:7:12}."

# Point the tag back at the image nginx runs, so that nothing (this script, or
# a `docker compose up -d` by hand) picks up a new image that was not rolled out.
restore_old_tag() { docker tag "$old_image" "$image_ref"; }

recreate_nginx() {
    log "Recreating nginx: new connections are refused for a few seconds."
    docker compose up --detach --no-deps --force-recreate --timeout 3 nginx
}

# Healthy, and serving HTTPS with the real certificate: the healthcheck alone
# only asks for /healthz on port 80. robots.txt comes from nginx itself, so this
# works while Photon is down. Gives up after about two minutes.
nginx_works() {
    for _ in $(seq 1 40); do
        if [ "$(docker inspect -f '{{.State.Health.Status}}' nginx 2>/dev/null)" = healthy ] &&
            curl -fsS -o /dev/null --max-time 5 --resolve "$DOMAIN_NAME:443:127.0.0.1" "https://$DOMAIN_NAME/robots.txt"; then
            return 0
        fi
        sleep 3
    done
    return 1
}

if ! ./tests/nginx-config.sh; then
    restore_old_tag
    log "Error: the nginx config does not load in the new image. nginx keeps running the previous one."
    log "       Fix the config before the next docker compose pull, which would fetch the new image again."
    exit 1
fi

if ! recreate_nginx || ! nginx_works; then
    log "Error: nginx does not work with the new image. Rolling back to the previous image."
    restore_old_tag
    if recreate_nginx && nginx_works; then
        log "Rolled back: nginx runs the previous image again."
    else
        log "Error: nginx does not work with the previous image either. It needs a look now."
    fi
    exit 1
fi

log "nginx update completed: nginx runs the new image and answers HTTPS."
check_version || exit 1
