#!/bin/sh
# Starts `photon serve`. JAVA_OPTS and PHOTON_ARGS are the image's defaults (see
# the Dockerfile); arguments given to the container (`docker run … <args>`, or
# `command:` in compose) are appended to PHOTON_ARGS. JVM options of a
# deployment, such as the heap size, go into JAVA_TOOL_OPTIONS, which the JVM
# reads by itself.
# Word-splitting of $JAVA_OPTS / $PHOTON_ARGS is intentional here.
set -eu

if [ ! -d "/photon/data/photon_data" ]; then
    echo "FATAL: /photon/data/photon_data not found." >&2
    echo "       The index bind-mount is missing or the dump was never extracted." >&2
    echo "       Expected on the host: ${PHOTON_DATA_DIR:-/var/lib/photon}/photon_data" >&2
    exit 1
fi

echo "photon: starting with JAVA_OPTS=[${JAVA_OPTS:-}] PHOTON_ARGS=[${PHOTON_ARGS:-} $*]"

# shellcheck disable=SC2086
exec java ${JAVA_OPTS:-} -jar /photon/photon.jar serve ${PHOTON_ARGS:-} "$@"
