# photon-stack

Deployment for **[Photon](https://github.com/komoot/photon)**, the OpenStreetMap
geocoder behind <https://geocode.versatiles.org>.

Photon 1.x in Docker, fronted by nginx with a response cache. Planet index,
all languages. There is no official Photon image, so this repo builds a thin
one, pins the version, and publishes it as `ghcr.io/versatiles-org/photon`.

```
client ──► nginx :443 ──► photon :2323 (container) ──► ~100 GB index on local NVMe
           cache 4g/6h                                 mmapped, served from page cache
```

## Quick start

Needs Docker and a Photon index already extracted at
`$PHOTON_DATA_DIR/photon_data` (~100 GB — see [MIGRATION.md](MIGRATION.md) for
how to fetch one).

```bash
$EDITOR .env                            # index path, port, version, heap
docker compose pull
docker compose up -d
docker compose logs -f photon           # opening a ~100 GB index takes a minute or more

curl 'http://127.0.0.1:2323/api?q=berlin&limit=1'
```

nginx is not managed by compose — copy `nginx/geocode.versatiles.org.conf` into
`/etc/nginx/sites/`, `nginx -t`, reload.

## The image

`.github/workflows/image.yml` builds the image on every push and pull request
and runs `tests/smoke.sh` against it on amd64 and arm64 (the server is a
Hetzner arm64 machine). On `main` it publishes `linux/amd64` and `linux/arm64`
to `ghcr.io/versatiles-org/photon` with three tags: the Photon version (what
`PHOTON_VERSION` in `.env` names), `latest`, and `sha-<commit>`.

The image runs on its own; compose only adds what is specific to this server:

```bash
docker run -d -p 2322:2322 -v /path/to/index:/photon/data \
    ghcr.io/versatiles-org/photon:1.2.1 -cors-any
```

Arguments after the image name are passed to `photon serve`, after the image's
own (`-data-dir`, listen address and port). JVM options such as the heap size go
into `JAVA_TOOL_OPTIONS`. The container runs as uid 1000; give `--user` if the
index belongs to someone else.

**Upgrading Photon:** `.github/workflows/photon-release.yml` checks weekly for a
new release and opens an issue with the new `PHOTON_VERSION` and `PHOTON_SHA256`
for the `Dockerfile`. The base image is pinned by digest and kept current by
Dependabot. Test a change locally with:

```bash
docker build -t photon-test .
tests/smoke.sh photon-test
```

## Layout

|                              |                                                                                       |
|------------------------------|---------------------------------------------------------------------------------------|
| `.env`                       | version, index path, port, heap — start here                                          |
| `docker-compose.yml`         | the service; read the `mem_limit` comment before editing                              |
| `Dockerfile`                 | `eclipse-temurin:21-jre` + the Photon jar (1.x embeds OpenSearch 3.x, needs Java 21+) |
| `entrypoint.sh`              | fails fast and loudly if the index bind-mount is missing                              |
| `tests/smoke.sh`             | runs an image against a small real index (Andorra) and sends it a search              |
| `.github/`                   | image build and publishing, Dependabot, weekly check for new Photon releases          |
| `nginx/`                     | TLS termination, upstream keepalive, `proxy_cache`                                    |
| `bench.sh`                   | cold/warm latency measurement                                                         |
| [MIGRATION.md](MIGRATION.md) | the 0.6.2 → 1.2.1 migration this stack came out of                                    |

## The one thing that determines performance

The index is ~100 GB against 15 GB of RAM, so ~11 % of it is cacheable and
every query that misses the page cache pays a disk seek. Everything else is
downstream of that:

- **The index must sit on local NVMe** (`/dev/sda1`, 0.19 ms seeks), not the
  Hetzner volume (1.08 ms). 5.8× on every cache miss.
- **No `mem_limit` in compose.** This host is cgroup v2, where page cache for
  the mmapped Lucene index is charged to the container. A memory limit tells
  the kernel to reclaim exactly the pages the service depends on.
- **Bind-mount, not a named volume**, keeping the index off the overlay2
  graph driver.
- **Small heap** (`-Xmx4g`). Measured peak is 1.9 GB with 0 full GCs in 428
  days; every GB of heap is a GB the kernel cannot use to cache the index.
- **nginx caches responses** (6 h, 4 GB) with `proxy_cache_lock`, so concurrent
  identical misses collapse into one upstream request.

Expect **~60–90 ms cold, 8–25 ms warm**. Not "in-memory fast" — for that you'd
need a two-tier setup (hot-region index in RAM, planet as fallback), which this
config is compatible with adding later.

## Benchmarking

```bash
./bench.sh 2323          # one instance
./bench.sh 2322 2323     # two instances, same query set
```

A query is only cold once, so the script walks a different slice of a 60-query
multilingual pool each run (counter in `.bench-run`, reset with `rm -f
.bench-run`). It hits Photon directly, bypassing the nginx cache.

Once nginx is live, latency is also in the access log:

```bash
awk '{for(i=1;i<=NF;i++) if($i ~ /^rt=/) print substr($i,4)}' \
    /var/log/nginx/photon.access.log | sort -n | tail -20
```
