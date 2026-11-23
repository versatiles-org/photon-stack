#!/usr/bin/env bash
set -euo pipefail

# Deploys what was pushed to main: pulls this repository and applies it to the
# running stack. Run it by hand on the server after a push.
#
#   bin/update.sh             pull and apply
#   bin/update.sh --dry-run   fetch only, and list what a pull would bring
#
# Steps:
#   1. git pull --ff-only, refused if the checkout has local changes. If new
#      commits arrived, the script starts itself again, so that their version
#      of it does the rest.
#   2. nginx: the config must load first (tests/nginx-config.sh, the check CI
#      runs). If it doesn't, nothing is applied, and the checkout goes back to
#      the commit before the pull, so a restart still finds a working config.
#      Then the templates are rendered again and nginx reloads gracefully,
#      without a gap. This runs every time, so a run that stopped halfway is
#      completed by the next one. Only when the container no longer matches
#      docker-compose.yml (a new image tag, a changed definition) is it
#      recreated instead, which refuses connections for about 3 seconds.
#   3. Checks that nginx is healthy and answers HTTPS with the real certificate,
#      and that Photon answers /status through it.
#
# Photon is never touched. A new Photon version can't be undone once it has
# opened the index (README, "Upgrading Photon"). When Photon's container doesn't
# match .env and docker-compose.yml, or this pull changed the image's files, the
# script prints what to run by hand.
#
# Exits 0 when everything is applied and works, 1 when something needs a look.

cd "$(dirname "$0")/.."
# shellcheck source=/dev/null
. ./.env

log() { echo "$(date -u +%FT%TZ) $*"; }

dry_run=false
case "${1:-}" in
    "") ;;
    --dry-run) dry_run=true ;;
    *)
        echo "Usage: $0 [--dry-run]" >&2
        exit 2
        ;;
esac

# Whether a service's container matches docker-compose.yml and .env: compose
# stores a hash of the service's definition on the container it creates.
# A newer image under the same tag doesn't count; bin/nginx/update.sh rolls
# those out for nginx.
up_to_date() {
    local cid want have
    cid=$(docker compose ps -q "$1")
    [ -n "$cid" ] || return 1
    want=$(docker compose config --hash "$1" | awk '{print $2}')
    have=$(docker inspect -f '{{ index .Config.Labels "com.docker.compose.config-hash" }}' "$cid")
    [ "$want" = "$have" ]
}

running() { docker compose ps --status running --services | grep -qx "$1"; }

if [ "$dry_run" = true ]; then
    git fetch --quiet
    if ! git diff --quiet HEAD --; then
        log "The checkout has local changes, so bin/update.sh would refuse to pull:"
        git status --short
    fi
    if [ -z "$(git log --oneline 'HEAD..@{u}')" ]; then
        log "No new commits to pull."
    else
        log "A pull would bring:"
        git log --oneline 'HEAD..@{u}'
        git diff --stat HEAD '@{u}'
    fi
    exit 0
fi

# Step 1: pull. Skipped when the script has just started itself again after a
# pull: UPDATE_FROM then holds the commit from before it.
if [ -z "${UPDATE_FROM:-}" ]; then
    # One run at a time, and not while bin/nginx/update.sh (cron) runs: both
    # replace nginx. The lock is held by file descriptor 9, which the script
    # keeps when it starts itself again below.
    mkdir -p volumes
    exec 9>volumes/.nginx-update.lock
    if ! flock -n 9; then
        log "Error: bin/update.sh or bin/nginx/update.sh is already running."
        exit 1
    fi

    if ! git diff --quiet HEAD --; then
        log "Error: the checkout has local changes. Not pulling over them:"
        git status --short
        exit 1
    fi

    before=$(git rev-parse HEAD)
    git pull --ff-only --quiet
    if [ "$(git rev-parse HEAD)" != "$before" ]; then
        log "Pulled:"
        git log --oneline "$before..HEAD"
        UPDATE_FROM=$before exec "$0"
    fi
    log "No new commits. Applying the current checkout."
fi

# Step 2: nginx.
if ! config_test=$(./tests/nginx-config.sh 2>&1); then
    echo "$config_test"
    log "Error: the nginx config does not load. Nothing applied: nginx keeps its current config."
    # The templates are read when nginx starts, so a restart (a reboot, say)
    # would now fail. Going back is safe: the pull was a fast-forward onto a
    # clean checkout. The next run pulls again, once the config is fixed.
    if [ -n "${UPDATE_FROM:-}" ]; then
        git reset --hard --quiet "$UPDATE_FROM"
        log "Reset the checkout to $(git log --oneline -1), so that nginx still starts after a restart."
    fi
    exit 1
fi

if up_to_date nginx; then
    log "Reloading nginx with the current config (no gap)."
    docker compose exec -T nginx sh -c \
        '/docker-entrypoint.d/20-envsubst-on-templates.sh >/dev/null && nginx -t -q && nginx -s reload'
else
    log "The nginx container doesn't match docker-compose.yml. Recreating it: new connections are refused for a few seconds."
    docker compose pull --quiet nginx
    docker compose up --detach --no-deps --force-recreate --timeout 3 nginx
fi

# Step 3: checks. Healthy, and serving HTTPS with the real certificate: the
# healthcheck alone only asks for /healthz on port 80. robots.txt comes from
# nginx itself, so this works while Photon is down. Gives up after about two
# minutes. (The same check as in bin/nginx/update.sh.)
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

if ! nginx_works; then
    log "Error: nginx is not healthy or doesn't answer HTTPS. It needs a look now: docker compose logs nginx"
    exit 1
fi
log "nginx is healthy and answers HTTPS."

result=0
if ! running photon; then
    log "Photon is not running. Is an index update running (bin/index/update.sh)? Otherwise: docker compose up -d --wait photon"
    result=1
elif ! curl -fsS -o /dev/null --max-time 10 --resolve "$DOMAIN_NAME:443:127.0.0.1" "https://$DOMAIN_NAME/status"; then
    log "Photon doesn't answer /status. Look at: docker compose logs photon"
    result=1
fi

if running photon && ! up_to_date photon; then
    log "Photon's container doesn't match .env and docker-compose.yml, e.g. after a new PHOTON_VERSION. Not touched:"
    log "a new Photon version can't be undone once it has opened the index. Read README, \"Upgrading Photon\", then run:"
    log "  docker compose pull photon && docker compose up -d --wait photon"
    result=1
fi

if [ -n "${UPDATE_FROM:-}" ] && git diff --name-only "$UPDATE_FROM" HEAD | grep -qxE 'Dockerfile|entrypoint\.sh|healthcheck\.sh'; then
    log "This pull changed the Photon image. Once CI has published it (.github/workflows/image.yml), run:"
    log "  docker compose pull photon && docker compose up -d --wait photon"
    result=1
fi

[ "$result" = 0 ] && log "Update completed."
exit "$result"
