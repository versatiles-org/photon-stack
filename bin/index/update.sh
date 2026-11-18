#!/usr/bin/env bash
set -euo pipefail

# Replaces the Photon index with the latest dump (PHOTON_DUMP_URL), in place.
#
# The disk has no room for a second index next to the first (on
# geocode.versatiles.org: a 92 GB index and ~50 GB free), so this stops
# Photon, deletes the old index and streams the dump straight into place:
# download, decompress and unpack in one pipe, with no archive on disk. Photon
# is down meanwhile; nginx keeps answering the searches it has cached. If the
# download fails, there is no old index to go back to: Photon stays stopped
# until this script is run again.
#
# Before anything is stopped, it checks that the dump is reachable, that it is
# not the one already installed (by its MD5, kept in $PHOTON_DATA_DIR/dump.md5)
# and that it fits on the disk.
#
# Usage: bin/index/update.sh [--check | --force]
#   --check  only report whether the dump differs from the installed one
#   --force  install the dump even if it is the one already installed
#
# Run as root: it deletes the old index and hands the new one to PHOTON_UID.
# Off by default; bin/index/setup_auto_update.sh runs it monthly from cron.

cd "$(dirname "$0")/../.."

MODE=${1:-}
case "$MODE" in
    "" | --check | --force) ;;
    *) echo "Usage: $0 [--check | --force]" >&2; exit 2 ;;
esac

set -a
# shellcheck source=/dev/null
. ./.env
set +a

URL=${PHOTON_DUMP_URL:-https://download1.graphhopper.com/public/photon-db-planet-1.0-latest.tar.bz2}
DATA=${PHOTON_DATA_DIR:?PHOTON_DATA_DIR is not set in .env}
INDEX=$DATA/photon_data
OLD=$DATA/photon_data.old        # the old index, while it is being deleted
NEW=$DATA/photon_data.incoming   # the dump unpacks here, as photon_data/
MARKER=$DATA/dump.md5

log() { echo "$(date -u +%FT%TZ) $*"; }
die() { log "Error: $*" >&2; exit 1; }
size() { awk -v n="$1" 'BEGIN { if (n < 1e9) printf "%d MB", n / 1e6; else printf "%.1f GB", n / 1e9 }'; }
took() { echo "$(((SECONDS - START) / 60)) min $(((SECONDS - START) % 60)) s"; }

[[ $DATA == /?* ]] || die "PHOTON_DATA_DIR must be an absolute path, not '$DATA'"
[ -d "$DATA" ] || die "$DATA does not exist"

# The only recursive delete here, so it accepts nothing but the two folders
# above.
remove() {
    case "$1" in
        "$OLD" | "$NEW") ;;
        *) die "refusing to delete $1" ;;
    esac
    if [ -e "$1" ]; then
        rm -r --one-file-system -- "$1"
    fi
}

exec 9>"$DATA/.update.lock"
flock -n 9 || die "another update is running"

# --- What is there to install? ----------------------------------------------

REMOTE_MD5=$(curl -fsSL "$URL.md5" | cut -d' ' -f1) || die "cannot fetch $URL.md5"
[[ $REMOTE_MD5 =~ ^[0-9a-f]{32}$ ]] || die "no checksum in $URL.md5"
HEADERS=$(curl -fsSIL "$URL" | tr -d '\r') || die "cannot reach $URL"
SIZE=$(awk 'tolower($1) == "content-length:" {n = $2} END {print n}' <<<"$HEADERS")
DATE=$(sed -n 's/^[Ll]ast-[Mm]odified: //p' <<<"$HEADERS" | tail -1)
[[ $SIZE =~ ^[0-9]+$ ]] || die "no size for $URL"
INSTALLED=$(cat "$MARKER" 2>/dev/null || true)
DUMP="dump of ${DATE:-unknown date}, $(size "$SIZE") compressed"

if [ "$REMOTE_MD5" = "$INSTALLED" ] && [ "$MODE" != --force ]; then
    log "Already installed: the $DUMP."
    exit 0
fi
if [ "$MODE" = --check ]; then
    if [ -z "$INSTALLED" ]; then
        log "Available: the $DUMP. Which dump is installed is not recorded."
    else
        log "Available: the $DUMP, not the installed one."
    fi
    exit 0
fi

# --- Does it fit? -----------------------------------------------------------

# Unpacked, a dump takes about 1.45 times its compressed size (planet in
# November 2026: 63 GB, 92 GB unpacked; Andorra: 1.6 times). Require 1.6
# times, plus 5 GB for the rest of the disk (nginx cache, logs). The old index
# and any leftovers of an earlier run count as free: they are deleted first.
AVAIL=$(df --output=avail -B1 "$DATA" | tail -1)
FREED=0
for dir in "$INDEX" "$OLD" "$NEW"; do
    if [ -e "$dir" ]; then
        FREED=$((FREED + $(du -s -B1 "$dir" | cut -f1)))
    fi
done
NEED=$((SIZE * 16 / 10 + 5 * 1000 ** 3))
if [ $((AVAIL + FREED)) -lt "$NEED" ]; then
    die "the $DUMP needs about $(size "$NEED"), but only $(size $((AVAIL + FREED))) would be free. Nothing changed."
fi

# --- Replace ----------------------------------------------------------------

log "Installing the $DUMP."
log "Stopping Photon. Until it is back, nginx answers only the searches in its cache."
docker compose stop photon
START=$SECONDS

remove "$OLD"
remove "$NEW"
rm -f "$MARKER"    # describes the index about to be deleted
if [ -e "$INDEX" ]; then
    mv "$INDEX" "$OLD"
fi
remove "$OLD"
log "Old index deleted."

DECOMPRESS=bzip2
if command -v lbzip2 >/dev/null; then
    DECOMPRESS=lbzip2    # multithreaded, several times faster
fi

# bzip2 checks a CRC for every block and for the whole stream, so a corrupted
# or truncated download fails here.
#
# No `curl --retry`: it would restart the transfer from the beginning, into
# the same pipe. A failed attempt starts over from an empty folder instead.
# --speed-limit/--speed-time: give up on a stalled transfer rather than hang.
for attempt in 1 2 3; do
    remove "$NEW"
    mkdir "$NEW"
    log "Downloading and unpacking $URL (attempt $attempt, $DECOMPRESS)."
    if curl -fsSL --speed-limit 1000000 --speed-time 300 "$URL" \
        | "$DECOMPRESS" -dc \
        | tar -x --no-same-owner -C "$NEW"; then
        break
    fi
    if [ "$attempt" = 3 ]; then
        die "the download failed three times. Photon stays stopped; run $0 again."
    fi
    log "Attempt $attempt failed; trying again in 5 minutes."
    sleep 300
done

[ -d "$NEW/photon_data/node_1" ] || die "the dump has no photon_data/node_1. Photon stays stopped."
mv "$NEW/photon_data" "$INDEX"
remove "$NEW"
chown -R "${PHOTON_UID:?}:${PHOTON_GID:?}" "$INDEX"
echo "$REMOTE_MD5" >"$MARKER"
log "Unpacked, $(took) after Photon was stopped. Starting Photon."

docker compose up -d --wait --wait-timeout 1800 photon
log "Photon is healthy again, $(took) after it was stopped."
