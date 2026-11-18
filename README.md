# photon-stack

Deployment for **[Photon](https://github.com/komoot/photon)**, the OpenStreetMap
geocoder behind <https://geocode.versatiles.org>.

Photon 1.x and nginx in Docker Compose: nginx terminates TLS, caches responses
and rate-limits clients; certbot renews the certificate. Planet index, all
languages. There is no official Photon image, so this repo builds a thin one,
pins the version, and publishes it as `ghcr.io/versatiles-org/photon`.

```
client ──► nginx :443 ──────────────► photon :2322 ──► ~100 GB index on local NVMe
           cache 4g/7d, 5 req/s/IP                     mmapped, served from page cache
```

## Quick start

Needs Docker 27+ and a Photon index already extracted at
`$PHOTON_DATA_DIR/photon_data` (~100 GB — see [MIGRATION.md](MIGRATION.md) for
how to fetch one).

```bash
cp template.env .env && $EDITOR .env    # domain, index path, version, heap
# certificates: see "Certificates" below
docker compose pull
docker compose up -d
docker compose logs -f photon           # opening a ~100 GB index takes a minute or more
bin/cert/setup_renewal.sh               # weekly renewal from cron

curl "https://$DOMAIN_NAME/api?q=berlin&limit=1"
```

## nginx

Configuration in `nginx/`: `nginx.conf` for the general settings,
`templates/geocode.conf.template` for the server (rendered at container start,
with `DOMAIN_NAME` from `.env`). What it does:

- **Response cache**, 7 days, 4 GB. Answers change only with a new index.
  Concurrent identical misses collapse into one request to Photon.
- **Rate limit**, 5 requests per second per client address with a burst of 30,
  then `429` with `Retry-After`. Needs the real client address: that is why the
  compose network has IPv6 (see `docker-compose.yml`).
- **`/status`** is passed to Photon uncached: point uptime monitors there, as
  every other path may be answered from the cache even while Photon is down.
- **Not for search engines**: `X-Robots-Tag: noindex` on every response, and a
  `robots.txt` that keeps crawlers out of `/api` and `/reverse`.
- **Logs without personal data**: the access log has an anonymised client
  address and no query string (the search text); the error log only critical
  errors. Both go to the container log, which Docker rotates.
- Port 80 redirects to HTTPS, except certbot's challenges.

After a change: `nginx.conf` needs `docker compose exec nginx nginx -s reload`;
the template is rendered at start, so it needs `docker compose restart nginx`
(about two seconds without nginx). Check either first with `tests/nginx-config.sh`.

Logs, and latency from them:

```bash
docker compose logs --no-log-prefix nginx | tail
docker compose logs --no-log-prefix nginx | grep -o 'rt=[0-9.]*' | cut -d= -f2 | sort -n | tail -20
```

## Certificates

certbot keeps its data in `volumes/letsencrypt/`, which nginx reads. The
certbot service does not start with `docker compose up`; `bin/cert/renew.sh`
runs it, renews when the certificate is due (30 days before it expires) and
reloads nginx. `bin/cert/setup_renewal.sh` runs that weekly from cron.

```bash
bin/cert/renew.sh --dry-run             # the whole path, against Let's Encrypt staging
```

To move an existing certificate from a host certbot, copy its folder before the
first start: `cp -a /etc/letsencrypt/. volumes/letsencrypt/`. Its renewal
config names `/var/www` as webroot, which is where the certbot container sees
`volumes/certbot-www/`.

## The image

`.github/workflows/image.yml` builds the image on every push and pull request
and runs `tests/smoke.sh` against it on amd64 and arm64 (the server is a
Hetzner arm64 machine). On `main` it publishes `linux/amd64` and `linux/arm64`
to `ghcr.io/versatiles-org/photon` with three tags: the Photon version (what
`PHOTON_VERSION` in `.env` names), `latest`, and `sha-<commit>`.

The image runs on its own; compose only adds what is specific to this server:

```bash
docker run -d -p 2322:2322 -v /path/to/index:/photon/data \
    ghcr.io/versatiles-org/photon:1.3.0 -cors-any
```

Arguments after the image name are passed to `photon serve`, after the image's
own (`-data-dir`, listen address and port). JVM options such as the heap size go
into `JAVA_TOOL_OPTIONS`. The container runs as uid 1000; give `--user` if the
index belongs to someone else.

**Upgrading Photon:** `.github/workflows/photon-release.yml` checks weekly for a
new release and opens an issue with the new `PHOTON_VERSION` and `PHOTON_SHA256`
for the `Dockerfile`. The base image, nginx and certbot are kept current by
Dependabot. Test a change locally with:

```bash
docker build -t photon-test .
tests/smoke.sh photon-test
```

**There is no way back by default.** Each Photon release embeds an OpenSearch
version, and OpenSearch records it in the index on start: after 1.3.0
(OpenSearch 3.8) has opened an index, 1.2.1 (3.7) refuses it with `cannot
downgrade a node`. The Lucene segments, nearly all of the ~100 GB, stay
untouched; only the metadata (`_state`, `translog`, logs, a few MB) changes. So
before an upgrade, with Photon stopped, keep that metadata:

```bash
docker compose stop photon
tar -C /var/lib/photon -cf /root/photon-state.tar \
    --exclude='photon_data/node_1/data/nodes/0/indices/*/*/index' photon_data
```

To go back, with Photon stopped: move everything written since the backup into
a second archive (GNU tar's `--remove-files`), unpack the backup, and set the
old `PHOTON_VERSION` in `.env`:

```bash
cd /var/lib/photon && find photon_data \
    -path 'photon_data/node_1/data/nodes/0/indices/*/*/index' -prune -o \
    -type f -newer /root/photon-state.tar -print0 \
  | tar --null -T - --remove-files -cf /root/photon-state-new.tar
tar -C /var/lib/photon -xf /root/photon-state.tar
```

## Layout

|                              |                                                                                       |
|------------------------------|---------------------------------------------------------------------------------------|
| `template.env`               | domain, version, index path, port, heap — copy to `.env`, start there                 |
| `docker-compose.yml`         | Photon, nginx, certbot; read the `mem_limit` comment before editing                   |
| `Dockerfile`                 | `eclipse-temurin:25-jre` + the Photon jar (1.x embeds OpenSearch 3.x, needs Java 21+) |
| `entrypoint.sh`              | fails fast and loudly if the index bind-mount is missing                              |
| `nginx/`                     | TLS, response cache, rate limit, `robots.txt`                                         |
| `bin/cert/`                  | certificate renewal and its cron job                                                  |
| `tests/`                     | `smoke.sh` (image against a small real index), `nginx-config.sh` (`nginx -t`)          |
| `.github/`                   | CI, image publishing, Dependabot, weekly check for new Photon releases                |
| `volumes/`                   | certificates and ACME challenges, written on the server, not committed                |
| `bench.sh`                   | cold/warm latency measurement                                                         |
| [MIGRATION.md](MIGRATION.md) | the 0.6.2 → 1.2.1 migration this stack came out of                                    |
| [CUTOVER.md](CUTOVER.md)     | the move from host nginx and host certbot into compose (November 2026)                |

## The one thing that determines performance

The index is ~100 GB against 15 GB of RAM, so ~11 % of it is cacheable and
every query that misses the page cache pays a disk seek. Everything else is
downstream of that:

- **The index must sit on local NVMe** (0.19 ms seeks), not a Hetzner volume
  (1.08 ms). 5.8× on every cache miss.
- **No `mem_limit` in compose.** This host is cgroup v2, where page cache for
  the mmapped Lucene index is charged to the container. A memory limit tells
  the kernel to reclaim exactly the pages the service depends on.
- **Bind-mount, not a named volume**, keeping the index off the overlay2
  graph driver.
- **Small heap** (`-Xmx4g`). Measured peak is 1.9 GB with 0 full GCs in 428
  days; every GB of heap is a GB the kernel cannot use to cache the index.
- **nginx caches responses** (7 days, 4 GB), so repeated queries never reach
  Photon; in November 2026, 99.6 % of requests were answered from the cache.

Expect **~60–90 ms cold, 8–25 ms warm**. Not "in-memory fast" — for that you'd
need a two-tier setup (hot-region index in RAM, planet as fallback), which this
config is compatible with adding later.

## Benchmarking

```bash
./bench.sh 2322          # one instance (PHOTON_HOST_PORT)
./bench.sh 2322 2323     # two instances, same query set
```

A query is only cold once, so the script walks a different slice of a 60-query
multilingual pool each run (counter in `.bench-run`, reset with `rm -f
.bench-run`). It hits Photon directly through the loopback port, bypassing
nginx and its cache.
