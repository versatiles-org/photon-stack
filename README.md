# Photon migration: 0.6.2 → 1.2.1, volume → local NVMe

## Why

Measured on the current box (8 cores, 15 GB RAM, Hetzner CX/fsn1):

|                             |                                                                            |
|-----------------------------|----------------------------------------------------------------------------|
| Index                       | 174 GB, 353 M docs, 5 shards, Photon 0.6.2 / Elasticsearch 6.6.1           |
| Index location              | `/mnt/photon-data` — Hetzner volume, random 8K read **p50 1.076 ms**       |
| Local disk                  | `/dev/sda1`, random 8K read **p50 0.185 ms** — **5.8× faster**, 58 GB free |
| RAM available as page cache | ~9 GB → **5 % of the index** is cacheable                                  |
| Cold query latency          | **p50 288–476 ms, p90 1.4 s, max 2.6 s**                                   |
| Warm query latency          | 8–25 ms                                                                    |
| JVM heap                    | `-Xmx12G`, peak use **1.9 GB**, **0 full GCs in 428 days**                 |

The service is not CPU-bound (load 0.07, GC negligible). It is bound entirely
on random-read latency against an index 12× larger than RAM, stored on the
slower of the two available disks.

Two things fix that without touching the machine or dropping languages:

1. **Photon 1.x halves the index.** The 0.5/0.6 planet dump is 101 GB
   compressed → 174 GB on disk. The 1.x dump is 61.7 GB → ~95–106 GB on disk.
   Same planet coverage, same en/de/fr/local languages.
2. **`/home/photon/photon-db-latest.tar.bz2` is 79 GB of dead weight** — the
   original download from May 2025, long since extracted, sitting on the *fast*
   disk while the live index runs off the *slow* one. Delete it and the local
   disk has ~137 GB free, which the new index fits into.

Expected result — index roughly halves *and* moves to storage 5.8× faster:

|       | index   | storage    | seek p50 | in RAM | cold p50                  |
|-------|---------|------------|----------|--------|---------------------------|
| now   | 174 GB  | volume     | 1.076 ms | 5 %    | **288–476 ms** (measured) |
| after | ~100 GB | local NVMe | 0.185 ms | ~11 %  | **~60–90 ms** (estimated) |

**You do not need to grow the volume.** The index moves off it entirely; it
becomes staging and backup space, and you already have enough.

## Honest limits

- ~100 GB against 15 GB RAM is still only ~11 % cached. Expect ~60–90 ms cold,
  not the 8–25 ms you see warm. This is a 5–8× improvement, not "in-memory fast".
- The ~100 GB figure is inferred, not measured. `preflight` requires 115 GB
  free before it will let you proceed. Check the extracted size after `fetch`
  and before `cleanup`.
- If you ever need consistently sub-20 ms globally, the only route on this
  hardware is a two-tier setup (small hot-region index fully in RAM, planet as
  fallback). Everything here is compatible with adding that later.

## Files

|                                     |                                                                                                                       |
|-------------------------------------|-----------------------------------------------------------------------------------------------------------------------|
| `Dockerfile`                        | thin layer over `eclipse-temurin:21-jre` (Photon 1.x embeds OpenSearch 3.x, needs Java 21+); no official image exists |
| `entrypoint.sh`                     | fails fast and loudly if the index bind-mount is missing                                                              |
| `docker-compose.yml`                | the service; read the `mem_limit` comment before editing                                                              |
| `.env`                              | version, paths, port, heap                                                                                            |
| `nginx/geocode.versatiles.org.conf` | drop-in replacement for the live site file                                                                            |
| `migrate.sh`                        | staged migration                                                                                                      |
| `bench.sh`                          | before/after latency measurement                                                                                      |

## Three Docker footguns this config avoids

1. **No `mem_limit`.** This host is cgroup v2, where page cache for the mmapped
   Lucene index is charged to the container's cgroup. Photon's performance *is*
   page cache; a memory limit tells the kernel to reclaim exactly the pages the
   service depends on. Do not add one.
2. **Bind-mount, not a named volume.** Keeps the index on the raw filesystem
   rather than the overlay2 graph driver.
3. **Capped json-file logging.** The old setup produced a 392 MB unrotated
   `photon.log` (the same disk-watermark warning every 30 s). Docker's default
   driver would reproduce that faithfully.

## Prerequisites

```bash
apt-get update
apt-get install -y lbzip2        # parallel bzip2 decompress; pbzip2 alone may
                                 # fall back to single-threaded (~80 min)
# Docker is not currently installed:
curl -fsSL https://get.docker.com | sh
```

## Runbook

The old service keeps serving on 2322 through every stage up to `cutover`.
The new one is built on 2323. They are on different disks, so they coexist and
rollback is one step.

```bash
cd /root/photon-stack

./migrate.sh preflight   # read-only; verifies disk, tools, dump reachability
./migrate.sh reclaim     # deletes the stale 79 GB tarball   [asks: type 'delete']
./migrate.sh fetch       # streams + extracts the 1.x dump (~30-60 min)
./migrate.sh up          # builds and starts the container on 2323
docker compose logs -f photon      # wait for startup; ~100 GB cold start is slow
./migrate.sh verify      # health, multilingual coverage, old-vs-new benchmark
./migrate.sh cutover     # nginx → 2323. THIS is the few seconds of downtime.
```

Then run on the new instance for a day. If anything is wrong:

```bash
./migrate.sh rollback    # nginx → 2322, old service untouched
```

Once satisfied:

```bash
./migrate.sh cleanup     # stops 0.6.2, frees 175 GB on the volume
                         # [asks: type 'decommission']
```

### Notes on individual stages

- **`fetch` has no resume.** 62 GB compressed plus ~106 GB extracted will not
  both fit, so there is no intermediate file, so a network drop means starting
  the stage over. It verifies the upstream MD5 inline via `tee` without ever
  storing the archive, and stages into `.incoming/` so a partial extract never
  becomes the live index.
- **`cutover` is safe.** It backs up the current site file, runs `nginx -t`, and
  restores the backup automatically if the test fails.
- **`cleanup` refuses** unless the new instance answers and nginx is actually
  pointing at it.

## After cleanup

Two leftovers from the old setup worth fixing while you are in there:

```bash
# 1. Drop the `discard` mount option — inline TRIM in the I/O path on a network
#    volume. Edit /etc/fstab, remove `discard` from the /mnt/photon-data line.
systemctl enable --now fstrim.timer

# 2. The volume is now staging/backup only. You need ~62 GB free there to stage
#    a future dump. You will have 175 GB. Consider shrinking it.
```

The nginx config also turns `access_log` back on with `$request_time` and
`$upstream_cache_status`, so the next round of this is measurable rather than
reconstructed from Elasticsearch counters:

```bash
tail -f /var/log/nginx/photon.access.log
awk '{for(i=1;i<=NF;i++) if($i ~ /^rt=/) print substr($i,4)}' \
    /var/log/nginx/photon.access.log | sort -n | tail -20   # slowest requests
```

## Benchmarking

```bash
./bench.sh 2322 2323     # old vs new, same query set
```

A query is only cold once — after that its pages are in the page cache. The
script keeps a run counter in `.bench-run` and uses a different slice of a
60-query pool each run. Reset with `rm -f .bench-run`. The pool is deliberately
multilingual-European plus global so it exercises the coverage you need to keep.

Caveat when comparing: if the old instance has already served a slice, it
benefits from a warm cache the new instance does not have. That biases *against*
the new instance, so any improvement you measure is a lower bound.

## Rollback summary

| stage reached   | how to undo                                           |
|-----------------|-------------------------------------------------------|
| through `up`    | nothing to undo; nginx still points at 2322           |
| after `cutover` | `./migrate.sh rollback`                               |
| after `cleanup` | no quick path — re-run `fetch` against the old layout |
