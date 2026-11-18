#!/usr/bin/env bash
set -euo pipefail

# Starts an image with a real Photon index and sends it a search.
#
# The index is Andorra's (about 2 MB, rebuilt weekly by GraphHopper), so this
# needs network but no disk space worth mentioning. The container runs under
# the calling user's uid, as `user:` in docker-compose.yml does on the server:
# OpenSearch writes into the index folder, so the uid has to own it.
#
# Usage: tests/smoke.sh <image>
# Run by CI (.github/workflows/image.yml) on amd64 and arm64.

IMAGE=${1:?usage: tests/smoke.sh <image>}
NAME=photon-smoke-$$
PORT=${SMOKE_PORT:-2399}
URL=https://download1.graphhopper.com/public/europe/andorra/photon-db-andorra-1.0-latest.tar.bz2

WORK=$(mktemp -d)
cleanup() {
    docker rm -f "$NAME" >/dev/null 2>&1 || true
    rm -rf "$WORK"
}
trap cleanup EXIT

echo "Downloading the Andorra index"
curl -fsS -o "$WORK/index.tar.bz2" "$URL"
EXPECTED=$(curl -fsS "$URL.md5" | cut -d' ' -f1)
ACTUAL=$( (md5sum "$WORK/index.tar.bz2" 2>/dev/null || md5 -r "$WORK/index.tar.bz2") | cut -d' ' -f1)
if [ "$EXPECTED" != "$ACTUAL" ]; then
    echo "FAIL: MD5 mismatch: expected $EXPECTED, got $ACTUAL" >&2
    exit 1
fi
mkdir "$WORK/data"
tar -xjf "$WORK/index.tar.bz2" -C "$WORK/data"

echo "Starting $IMAGE"
docker run -d --name "$NAME" \
    --user "$(id -u):$(id -g)" \
    -p "127.0.0.1:$PORT:2322" \
    -e JAVA_TOOL_OPTIONS="-Xms256m -Xmx512m" \
    -v "$WORK/data:/photon/data" \
    "$IMAGE" -cors-any -query-timeout 5 >/dev/null

# The image's own HEALTHCHECK decides, as on the server.
STATUS=
for _ in $(seq 1 60); do
    STATUS=$(docker inspect "$NAME" --format '{{.State.Status}} {{.State.Health.Status}}')
    case "$STATUS" in
        "running healthy" | exited*) break ;;
    esac
    sleep 2
done
if [ "$STATUS" != "running healthy" ]; then
    echo "FAIL: container is '$STATUS' instead of healthy" >&2
    docker logs "$NAME" 2>&1 | tail -40 >&2
    exit 1
fi
echo "Healthy"

STATUS_JSON=$(curl -fsS "http://127.0.0.1:$PORT/status")
echo "/status: $STATUS_JSON"
case "$STATUS_JSON" in
    *'"status":"Ok"'*) ;;
    *) echo "FAIL: /status is not Ok" >&2; exit 1 ;;
esac

RESULT=$(curl -fsS "http://127.0.0.1:$PORT/api?q=andorra%20la%20vella&limit=1")
case "$RESULT" in
    *'"name":"Andorra la Vella"'*) echo "Search OK" ;;
    *) echo "FAIL: unexpected search result: $RESULT" >&2; exit 1 ;;
esac

# -cors-any reached Photon, so arguments given to the container are passed on.
if ! curl -fsS -o /dev/null -D - -H 'Origin: https://example.org' "http://127.0.0.1:$PORT/status" \
    | grep -q -i '^access-control-allow-origin: \*'; then
    echo "FAIL: arguments given to the container did not reach Photon (no CORS header)" >&2
    exit 1
fi
echo "Container arguments OK"
