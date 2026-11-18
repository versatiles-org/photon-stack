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
  and anonymised addresses; the error log only `crit`. Keep it that way.
- **The healthcheck uses bash's `/dev/tcp`**, not curl or wget: `eclipse-temurin`
  images don't promise either.
- **The real client address** reaches nginx over IPv6 only because the compose
  network has `enable_ipv6`. Rate limiting depends on it.

## Checks

- `shellcheck` on the files `.github/workflows/image.yml` lists.
- `tests/smoke.sh <image>` after a `docker build`, `tests/nginx-config.sh` after
  any change under `nginx/`.
- To test `bin/index/update.sh` without the server: a copy of the repo with its
  own `.env` (`PHOTON_DUMP_URL` set to the Andorra dump, a scratch
  `PHOTON_DATA_DIR`), run from a Debian container with the Docker CLI, `lbzip2`
  and the Docker socket, with the scratch folder mounted at the same path.

## Deploying

A push to `main` publishes the image (`.github/workflows/image.yml`). On the
server: `git pull`; for a new Photon version, set `PHOTON_VERSION` in `.env`
before `docker compose pull photon`, then `docker compose up -d --wait photon`.
