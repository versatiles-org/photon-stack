# photon-stack

Deployment for **[Photon](https://github.com/komoot/photon)**, the OpenStreetMap
geocoder behind <https://geocode.versatiles.org>.

Photon 1.x and nginx in Docker Compose: nginx terminates TLS, caches responses
and rate-limits clients; certbot renews the certificate. Planet index, all
languages. There is no official Photon image, so this repo builds a thin one,
pins the version, and publishes it as `ghcr.io/versatiles-org/photon`.

This README is about running the server. How to use it (endpoints, parameters,
rate limit, attribution) is in the guide at
<https://docs.versatiles.org/guides/use_geocode_versatiles_org>.

```
client ──► nginx :443 ──────────────► photon :2322 ──► ~92 GB index on local NVMe
           cache 4g/7d, 5 req/s/IP                     mmapped, served from page cache
```

## Quick start

Needs Docker 27+, `lbzip2`, and about 110 GB free for the planet index.

```bash
cp template.env .env && $EDITOR .env    # domain, index path, version, heap
# certificates: see "Certificates" below
docker compose pull
bin/index/update.sh                     # fetches the index, see "The index" below
docker compose up -d
docker compose logs -f photon           # opening a ~92 GB index takes a minute or more
bin/cert/setup_renewal.sh               # weekly renewal from cron
bin/nginx/setup_auto_update.sh          # daily nginx image update from cron
bin/log/setup_rotation.sh               # nightly log rotation from cron

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
- **Logs**, in `volumes/nginx-log/`, see "Logs" below.
- Port 80 redirects to HTTPS, except certbot's challenges.

After a change is pushed, `bin/update.sh` on the server deploys it: it pulls,
checks the config with `tests/nginx-config.sh`, renders the template again and
reloads nginx without a gap. If the config doesn't load, it applies nothing and
puts the checkout back to the commit before the pull. It recreates nginx only
when the container no longer matches `docker-compose.yml` (about three seconds
without nginx), checks that nginx answers HTTPS and Photon `/status`, and never
touches Photon: when Photon needs a new image or version, it says what to run.
`bin/update.sh --dry-run` lists what a pull would bring.

**New nginx images** go live by themselves: `bin/nginx/update.sh` runs daily
from cron (`bin/nginx/setup_auto_update.sh`), so a security fix in nginx is
live within a day of its release. It pulls the nginx image and does nothing
unless a newer one arrived. Then it checks the config with
`tests/nginx-config.sh`, recreates nginx (about 3 seconds without it) and checks
that it is healthy and answers HTTPS. If the config does not load, nginx keeps
the previous image; if the new one does not work, nginx is recreated from the
previous one. Photon is not touched. The log is `/var/log/nginx-update.log`; the
script exits 1 whenever something needs a look.

## Logs

nginx writes three files to `volumes/nginx-log/`, as on tiles.versatiles.org.
None of them has the query string, which for a geocoder is the search text.

| File                   | Contains                                                                         | Kept    |
|------------------------|----------------------------------------------------------------------------------|---------|
| `access.tsv.gz`        | Every request: time, anonymised client address, path, status, size, request and upstream time, cache status, referer origin, user agent | 28 days |
| `referer_stats.tsv.gz` | Every answered request (2xx, 304): referer origin, path, size, status, hour      | always  |
| `error.log`            | nginx's own errors, critical only                                                | 28 days |

- **Client address:** anonymised, the last octet of an IPv4 address zeroed, an
  IPv6 address cut to its first two groups (32 of 128 bits).
- **Referer:** only `scheme://host`, never the path or query string of the
  referring page.
- **Exception:** nginx writes `error.log` in a fixed format that includes the
  full client address and request line. `bin/log/rotate.sh` anonymises both
  and removes the query string every night, so they exist only in the live
  file, for a day at most.

`bin/log/rotate.sh` runs every night from cron (`bin/log/setup_rotation.sh`):
it moves the request and error logs into one archive per day
(`<name>.<YYYY-MM-DD>.…`) and deletes those older than 28 days, and on the 1st
the usage statistics into one archive per month (`referer_stats.<YYYY-MM>.tsv.gz`),
which are kept. The log is `/var/log/nginx-log-rotation.log`.

The access logs are compressed while they are written and reach the file with
up to a minute's delay. The last requests, the slowest, and the websites that
send the most:

```bash
gzip -dc volumes/nginx-log/access.tsv.gz 2>/dev/null | tail
gzip -dc volumes/nginx-log/access.tsv.gz 2>/dev/null | cut -f7 | sort -n | tail -20
gzip -dc volumes/nginx-log/referer_stats*.tsv.gz 2>/dev/null | cut -f1 | sort | uniq -c | sort -rn | head
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

## The index

`bin/index/update.sh` installs the dump that `PHOTON_DUMP_URL` names
(GraphHopper's planet dump by default, rebuilt about weekly). Run it as root.
`--check` only reports whether the dump differs from the installed one.

It replaces the index **in place**: the disk has no room for a second index
next to the first (a 92 GB index, 50 GB free). So it stops Photon, deletes
the old index and streams the dump straight into place, with no archive on
disk. The first run, in November 2026, kept Photon down for 49 minutes, nearly
all of it the download (63 GB at about 21 MB/s; lbzip2 keeps up with that).
Meanwhile nginx answers only the searches in its cache, which in November 2026
was 99.6 % of requests; new searches get a `502`. Before
stopping anything it checks that the dump is reachable, that it is not the one
already installed (its MD5, kept in `$PHOTON_DATA_DIR/dump.md5`), and that it
fits. A failed download is tried three times; after that Photon stays stopped
without an index, and a new run starts over.

Automatic updates are off. `bin/index/setup_auto_update.sh` turns them on: a
cron job on the 1st of each month at 02:00, logging to
`/var/log/photon-index-update.log`. Fine for a demo server; anything that
cannot go without new searches for a while needs a second disk instead.

Without `lbzip2` (`apt install lbzip2`) it falls back to single-threaded
`bzip2`, several times slower. The nginx cache keeps answers from the old
index for up to 7 days.

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
Dependabot.

**Security scan:** `.github/workflows/scan-images.yml` scans the images in
`docker-compose.yml` (Photon, nginx, certbot) for known vulnerabilities every
Monday. A run fails, and GitHub sends a failure email, when one has a CRITICAL
or HIGH vulnerability with a fix available; the findings are under Security →
Code scanning. The same workflow runs in tiles.versatiles.org. Trivy can't
check nginx itself in the official nginx image, only the other packages in it
(the workflow explains why).

Test a change locally with:

```bash
docker build -t photon-test .
tests/smoke.sh photon-test
```

**There is no way back by default.** Each Photon release embeds an OpenSearch
version, and OpenSearch records it in the index on start: after 1.3.0
(OpenSearch 3.8) has opened an index, 1.2.1 (3.7) refuses it with `cannot
downgrade a node`. The Lucene segments, nearly all of the 92 GB, stay
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
| `bin/update.sh`              | deploys a push: pull, check and reload nginx; never touches Photon                    |
| `bin/cert/`                  | certificate renewal and its cron job                                                  |
| `bin/index/`                 | index update, in place, and its opt-in cron job                                       |
| `bin/nginx/`                 | daily nginx image update and its cron job                                             |
| `bin/log/`                   | nightly log rotation and deletion after 28 days, and its cron job                     |
| `tests/`                     | `smoke.sh` (image against a small real index), `nginx-config.sh` (`nginx -t`)          |
| `.github/`                   | CI, image publishing, Dependabot, weekly Photon release check and vulnerability scan  |
| `volumes/`                   | certificates, ACME challenges and nginx logs, written on the server, not committed    |
| `bench.sh`                   | cold/warm latency measurement                                                         |

## The one thing that determines performance

The index is 92 GB against 15 GB of RAM, so ~11 % of it is cacheable and
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
