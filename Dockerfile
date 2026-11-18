# Photon geocoder: pinned, reproducible image, published as ghcr.io/versatiles-org/photon.
# No official upstream image exists, so this is a thin layer over a JRE.
# Photon 1.x embeds OpenSearch 3.x, which requires Java 21+.
#
# The base image is pinned by digest: the tag alone moves with every Temurin and
# Ubuntu update, so two builds of the same commit could differ. Dependabot bumps
# the digest (.github/dependabot.yml).
FROM eclipse-temurin:25-jre-noble@sha256:e3b6f7887a50f20d8f07abf279d8a81a5953fb398a9555bd9edd56b9bd15968c

# Bump both together. The checksum is the release asset's `digest` on GitHub:
#   gh api repos/komoot/photon/releases/tags/<version> --jq '.assets[].digest'
# .github/workflows/photon-release.yml opens an issue with both values when a
# new release appears.
ARG PHOTON_VERSION=1.2.1
ARG PHOTON_SHA256=6ea66d598a3f6fc1b59b0f81ad4f8abee72ccdb9d3db03bc12008974cdebd58d

LABEL org.opencontainers.image.title="photon" \
      org.opencontainers.image.description="Photon geocoder (komoot/photon) as run on geocode.versatiles.org" \
      org.opencontainers.image.source="https://github.com/versatiles-org/photon-stack" \
      org.opencontainers.image.licenses="Apache-2.0" \
      org.opencontainers.image.version="${PHOTON_VERSION}"

# Before the ADD below: a folder that `ADD --chmod` creates gets the file's mode
# (644), which nobody can enter. WORKDIR creates it with 755.
WORKDIR /photon

# The jar runs on any platform, so this one download serves amd64 and arm64.
# --chmod: a file fetched from a URL is otherwise root-only (0600), and the
# container runs as a non-root uid.
ADD --checksum=sha256:${PHOTON_SHA256} --chmod=644 \
    "https://github.com/komoot/photon/releases/download/${PHOTON_VERSION}/photon-${PHOTON_VERSION}.jar" \
    /photon/photon.jar
COPY --chmod=755 entrypoint.sh /photon/entrypoint.sh

# /photon/data is where the index is mounted. /photon/tmp is world-writable
# (with the sticky bit, like /tmp), so the container works under any uid: the
# uid has to match the owner of the mounted index, and compose sets it with
# `user:` (PHOTON_UID/PHOTON_GID in .env).
RUN mkdir -p /photon/data /photon/tmp \
 && chmod 1777 /photon/tmp

# Only what every deployment needs. Heap size, CORS, timeouts and result limits
# are a deployment's choice; docker-compose.yml sets them for geocode.versatiles.org.
# Without -Xmx the JVM takes a quarter of the RAM it sees.
ENV JAVA_OPTS="-XX:+UseG1GC -XX:+ExitOnOutOfMemoryError -Djava.io.tmpdir=/photon/tmp -Dfile.encoding=UTF-8" \
    PHOTON_ARGS="-data-dir /photon/data -listen-ip 0.0.0.0 -listen-port 2322"

# uid/gid 1000 is the `ubuntu` user of the base image, and also the owner of
# the index on geocode.versatiles.org. Override with `--user` or `user:`.
USER 1000:1000
EXPOSE 2322

# /status answers once the index is open, and reads nothing but its metadata.
# Opening a planet index takes about a minute after a reboot, longer with a
# cold disk; --start-interval checks every 5 s during that time.
HEALTHCHECK --start-period=300s --start-interval=5s --interval=30s --timeout=15s --retries=3 \
    CMD curl -fsS http://localhost:2322/status >/dev/null || exit 1

ENTRYPOINT ["/photon/entrypoint.sh"]
