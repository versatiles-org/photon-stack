#!/bin/bash
# The image's HEALTHCHECK: healthy once Photon's /status says "Ok", which it does
# as soon as the index is open (it reads nothing but the index metadata).
#
# Plain bash (/dev/tcp) rather than curl: the base image does not promise any
# HTTP client. eclipse-temurin:21 happens to ship curl, :25 ships neither curl
# nor wget, and a healthcheck that cannot run marks a working Photon unhealthy.
set -eu

exec 3<>/dev/tcp/127.0.0.1/2322
printf 'GET /status HTTP/1.0\r\nHost: localhost\r\n\r\n' >&3
grep -q '"status":"Ok"' <&3
