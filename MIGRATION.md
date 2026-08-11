# Migration: Photon 0.6.2 → 1.2.1, volume → local NVMe

Record of the migration this stack was built for, kept because the reasoning and
the rollback path are worth having.

> **Note:** `migrate.sh`, referenced throughout the runbook below, is not
> checked into this repo.

## Why

Measured on the box (8 cores, 15 GB RAM, Hetzner CX/fsn1):

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

**The volume does not need to grow.** The index moves off it entirely; it
becomes staging and backup space, and there is already enough.

## Honest limits

- ~100 GB against 15 GB RAM is still only ~11 % cached. Expect ~60–90 ms cold,
  not the 8–25 ms seen warm. This is a 5–8× improvement, not "in-memory fast".
- The ~100 GB figure is inferred, not measured. `preflight` requires 115 GB
  free before it will let you proceed. Check the extracted size after `fetch`
  and before `cleanup`.
- For consistently sub-20 ms globally, the only route on this hardware is a
  two-tier setup (small hot-region index fully in RAM, planet as fallback).
  Everything here is compatible with adding that later.

## Prerequisites

```bash
apt-get update
apt-get install -y lbzip2        # parallel bzip2 decompress; pbzip2 alone may
                                 # fall back to single-threaded (~80 min)
# Docker was not installed:
curl -fsSL https://get.docker.com | sh
```

## Runbook

The old service keeps serving on 2322 through every stage up to `cutover`. The
new one is built on 2323. They are on different disks, so they coexist and
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

Once satisfied — these are the irreversible ones:

```bash
./migrate.sh cleanup     # stops+disables 0.6.2, deletes the old index (frees
                         # 175 GB on the volume), removes the /home/photon
                         # leftovers, drops `discard` from fstab, arms
                         # fstrim.timer          [asks: type 'decommission']

./migrate.sh purge       # openjdk + ca-certificates-java (190 MB), 13 rc-state
                         # kernels + orphaned module dirs (~61 MB), orphaned GUI
                         # libs (~63 MB), apt cache and lists (~244 MB), journald
                         # capped at 500 MB and vacuumed (~3.5 GB)
                         #                        [asks: type 'purge']

./migrate.sh rebootcheck # read-only: fstab valid, volume has nofail, vmlinuz +
                         # initrd present for the newest kernel, docker/nginx/
                         # certbot enabled, compose restart policy set,
                         # old photon.service disabled
reboot
```

Both `cleanup` and `purge` refuse to run unless the new instance answers on 2323
*and* nginx is actually pointing at it. `purge` additionally refuses to remove
openjdk while `photon.service` is still running.

### Notes on individual stages

- **`fetch` has no resume.** 62 GB compressed plus ~106 GB extracted will not
  both fit, so there is no intermediate file, so a network drop means starting
  the stage over. It verifies the upstream MD5 inline via `tee` without ever
  storing the archive, and stages into `.incoming/` so a partial extract never
  becomes the live index.
- **`cutover` is safe.** It backs up the current site file, runs `nginx -t`, and
  restores the backup automatically if the test fails.
- **`cleanup`** handles the `discard` → `fstrim.timer` swap itself, backing up
  `/etc/fstab`, validating with `findmnt --verify`, and restoring the backup if
  that fails.

## Rollback summary

| stage reached   | how to undo                                           |
|-----------------|-------------------------------------------------------|
| through `up`    | nothing to undo; nginx still points at 2322           |
| after `cutover` | `./migrate.sh rollback`                               |
| after `cleanup` | no quick path — re-run `fetch` against the old layout |

## After cleanup

What is left is a decision, not a command: the volume is now staging/backup
only, and ~62 GB free is enough to stage a future dump. There will be 175 GB,
so consider shrinking it.

The new nginx config also turns `access_log` back on with `$request_time` and
`$upstream_cache_status`, so the next round of this is measurable rather than
reconstructed from Elasticsearch counters.

## Comparing old vs new

```bash
./bench.sh 2322 2323
```

If the old instance has already served a query slice, it benefits from a warm
cache the new instance does not have. That biases *against* the new instance,
so any improvement measured is a lower bound.
