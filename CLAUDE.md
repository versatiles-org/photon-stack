# photon-stack

Photon, nginx and certbot in Docker Compose for <https://geocode.versatiles.org>.
README.md explains the stack and how to operate it; this file holds what to keep
in mind when changing it.

## The server

- Hetzner CAX31: arm64, 8 vCPU, 15 GB RAM, 150 GB local disk, Debian 12. The
  repo is checked out at `/root/photon-stack`; its `.env` is the server's config.
- A cheap, free demo server, not public infrastructure. An index months old is
  fine, and so is an hour without new searches during an index update (nginx
  answers cached ones). Don't add redundancy, a second disk or a bigger server
  to avoid either.
- Unattended upgrades install Debian security updates daily (around 06:45
  UTC) and reboot at 05:30 when one needs it, i.e. a new kernel. That is set
  on the server in `/etc/apt/apt.conf.d/52unattended-upgrades-local`, not in
  the repo. The cron jobs keep clear of it: index update on the 1st at 02:00
  (opt-in), certificate renewal on Sundays at 03:00, nginx update daily at
  04:30, log rotation nightly at 00:10. Docker itself is updated by hand.
- There is no access from here. The user runs commands on the server and pastes
  the output: give small blocks with one purpose each, say what to expect, and
  keep explanations out of code blocks (pasted prose once left the shell in a
  quote continuation).

## Easy to break

- **No `mem_limit` for Photon**, the index on **local disk**, as a **bind
  mount**: see README, "The one thing that determines performance".
- **No room for a second index.** 92 GB index, about 50 GB free: anything that
  unpacks or copies an index next to the current one fails. Hence the in-place
  `bin/index/update.sh`.
- **Photon upgrades can't be undone by default.** Each release embeds an
  OpenSearch version (`opensearchVersion` in komoot/photon's `build.gradle`),
  and an older one refuses an index a newer one has opened. If it changes, back
  up the metadata first (README, "Upgrading Photon").
- **Privacy in the logs.** The access log has no query string (the search text)
  and anonymised addresses; the error log only `crit`. Request and error logs
  are deleted after 28 days (`bin/log/rotate.sh`), and the usage statistics
  hold nothing about the client, as the planned terms of use say. Keep it that
  way, and keep `bin/log/rotate.sh` alike in tiles.versatiles.org.
- **The healthcheck uses bash's `/dev/tcp`**, not curl or wget: `eclipse-temurin`
  images don't promise either.
- **The real client address** reaches nginx over IPv6 only because the compose
  network has `enable_ipv6`. Rate limiting depends on it.

## Checks

- `shellcheck` on the files `.github/workflows/image.yml` lists.
- `tests/smoke.sh <image>` after a `docker build`, `tests/nginx-config.sh` after
  any change under `nginx/`.
- `tests/cron-run.sh` after a change to `bin/cron/run.sh`, and
  `tests/nginx-version.sh` after one to `bin/nginx/check_version.sh`. Both
  scripts must stay alike with the ones in tiles.versatiles.org.
- To test `bin/index/update.sh` without the server: a copy of the repo with its
  own `.env` (`PHOTON_DUMP_URL` set to the Andorra dump, a scratch
  `PHOTON_DATA_DIR`), run from a Debian container with the Docker CLI, `lbzip2`
  and the Docker socket, with the scratch folder mounted at the same path.

## Deploying

A push to `main` publishes the image (`.github/workflows/image.yml`). On the
server: `bin/update.sh` pulls and applies nginx changes, never Photon. For a new
Photon version, set `PHOTON_VERSION` in `.env` before `docker compose pull
photon`, then `docker compose up -d --wait photon`.

Testing `bin/update.sh` without the server: a scratch "origin" clone with the
change committed, a "server" clone of it with an `.env`, a self-signed
certificate with a SAN under `volumes/letsencrypt/live/<domain>/`, and nginx
started alone (`docker compose up -d --no-deps nginx`). Run the script in a
Linux container (macOS has no `flock`) with the Docker socket, the scratch
folder at the same path, `TMPDIR` inside it (for `tests/nginx-config.sh`),
`CURL_CA_BUNDLE` set to the certificate, and 127.0.0.1:443 forwarded to the
host. Start nginx from that container's compose too: compose versions can
compute different config hashes, which makes the script recreate nginx.
