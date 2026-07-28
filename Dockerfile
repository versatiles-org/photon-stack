# Photon geocoder — pinned, reproducible image.
# No official upstream image exists, so we build a thin layer over a JRE.
# Photon 1.x embeds OpenSearch 3.x, which requires Java 21+.
FROM eclipse-temurin:21-jre-noble

ARG PHOTON_VERSION=1.2.1
# Must match the owner of the bind-mounted index directory on the host.
# The existing host user `photon` is uid/gid 1000.
ARG PHOTON_UID=1000
ARG PHOTON_GID=1000

# curl is only needed for the container healthcheck.
RUN apt-get update \
 && apt-get install -y --no-install-recommends curl ca-certificates \
 && rm -rf /var/lib/apt/lists/*

# Ubuntu Noble ships an `ubuntu` user at uid/gid 1000, which collides with the
# host's `photon` user. Remove the squatter so the container uid matches the
# owner of the bind-mounted index — otherwise the mount is unreadable.
RUN set -eux; \
    if getent passwd "${PHOTON_UID}" >/dev/null; then \
        userdel -r "$(getent passwd "${PHOTON_UID}" | cut -d: -f1)" 2>/dev/null || true; \
    fi; \
    if ! getent group "${PHOTON_GID}" >/dev/null; then \
        groupadd -g "${PHOTON_GID}" photon; \
    fi; \
    useradd -u "${PHOTON_UID}" -g "${PHOTON_GID}" -M -d /photon -s /usr/sbin/nologin photon; \
    mkdir -p /photon/data /photon/tmp; \
    chown -R "${PHOTON_UID}:${PHOTON_GID}" /photon

ADD --chown=1000:1000 \
    "https://github.com/komoot/photon/releases/download/${PHOTON_VERSION}/photon-${PHOTON_VERSION}.jar" \
    /photon/photon.jar

COPY --chown=1000:1000 entrypoint.sh /photon/entrypoint.sh
RUN chmod +x /photon/entrypoint.sh

USER photon
WORKDIR /photon
EXPOSE 2322
ENTRYPOINT ["/photon/entrypoint.sh"]
