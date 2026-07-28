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

RUN groupadd -g "${PHOTON_GID}" photon \
 && useradd -u "${PHOTON_UID}" -g "${PHOTON_GID}" -M -d /photon -s /usr/sbin/nologin photon \
 && mkdir -p /photon/data /photon/tmp \
 && chown -R photon:photon /photon

ADD --chown=photon:photon \
    "https://github.com/komoot/photon/releases/download/${PHOTON_VERSION}/photon-${PHOTON_VERSION}.jar" \
    /photon/photon.jar

COPY --chown=photon:photon entrypoint.sh /photon/entrypoint.sh
RUN chmod +x /photon/entrypoint.sh

USER photon
WORKDIR /photon
EXPOSE 2322
ENTRYPOINT ["/photon/entrypoint.sh"]
