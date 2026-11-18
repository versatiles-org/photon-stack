# Cutover: host nginx → nginx in compose

One-time runbook for geocode.versatiles.org (November 2026): from the copied
files, host nginx and host certbot to a git checkout with Photon, nginx and
certbot in compose. Run as root on the server. Each step ends with a check;
go on only if it passes. "Back" says how to undo the step.

**Outage:** Photon restarts once (about a minute; the host nginx keeps
answering cached queries meanwhile), and ports 80/443 change hands once (a few
seconds). Pick an hour without the batch client's bursts: in November 2026 they
came at 11, 13 and 21–22 UTC.

**What stays untouched until the cleanup (phase 5)**, so going back is always
possible: the host nginx and its config, `/etc/letsencrypt`, the old copy of
this repo, the old image `photon-local:1.2.1`. Photon keeps its port 2323, which
the host nginx proxies to.

## 1. Prepare (no effect on the running service)

```bash
apt-get install -y git
git clone https://github.com/versatiles-org/photon-stack.git /root/photon-stack.new
cd /root/photon-stack.new
cp template.env .env
sed -i 's/^PHOTON_HOST_PORT=.*/PHOTON_HOST_PORT=2323/' .env   # the host nginx (way back) proxies to 2323
diff <(grep -v '^#' /root/photon-stack/.env | grep .) <(grep -v '^#' .env | grep .)
```

Check: the `diff` shows only the new `DOMAIN_NAME` line. Index path, uid/gid,
heap and port are unchanged.

```bash
mkdir -p volumes/certbot-www
cp -a /etc/letsencrypt volumes/letsencrypt
ls -l volumes/letsencrypt/live/geocode.versatiles.org/
crontab -l > /root/crontab.before-cutover
docker compose config -q && echo compose OK
docker compose pull
docker compose --profile donotstart pull certbot
tests/nginx-config.sh | tail -1
```

Check: `fullchain.pem` and `privkey.pem` are listed (as links into
`../../archive/`), `compose OK`, three images pulled, `nginx config OK`.

Swap the folders, so that compose sees the same project name (`photon-stack`)
and replaces the running Photon container instead of starting a second one:

```bash
mv /root/photon-stack /root/photon-stack.old
mv /root/photon-stack.new /root/photon-stack
cd /root/photon-stack
```

Back: `mv /root/photon-stack /root/photon-stack.unused && mv /root/photon-stack.old /root/photon-stack`
(nothing is running from the new folder yet).

## 2. Photon from GHCR (about a minute without Photon)

```bash
docker compose up -d photon
until [ "$(docker inspect -f '{{.State.Health.Status}}' photon)" = healthy ]; do sleep 5; done; echo healthy
curl -s http://127.0.0.1:2323/status; echo
docker inspect -f '{{.Config.Image}} {{.Config.User}}' photon
```

Check: `healthy`, `/status` says `"status":"Ok"` with `"version":"1.2.1"`, and
the image is `ghcr.io/versatiles-org/photon:1.2.1` with user `1000:1000`. The
public site is still the host nginx, which proxies to the new container now.

Back: start the old definition under the same project name:

```bash
cd /root/photon-stack.old && docker compose -p photon-stack up -d photon
```

## 3. nginx in compose (a few seconds without 80/443)

One line, so the ports are free for as short as possible:

```bash
systemctl stop nginx && docker compose up -d nginx
docker compose ps
```

Check: `photon` and `nginx` are both `(healthy)` (nginx after about 10 s).

Back: `docker compose stop nginx && systemctl start nginx`

## 4. Check

From the server:

```bash
curl -s https://geocode.versatiles.org/status; echo
for i in 1 2; do curl -s -o /dev/null -D - 'https://geocode.versatiles.org/api?q=Berlin' | grep -i -E '^(HTTP|x-cache-status)'; done
curl -s -o /dev/null -D - https://geocode.versatiles.org/ | grep -i -E '^(HTTP|x-robots-tag)'
curl -s https://geocode.versatiles.org/robots.txt
curl -s -o /dev/null -D - 'http://geocode.versatiles.org/status' | grep -i -E '^(HTTP|location)'
echo | openssl s_client -connect geocode.versatiles.org:443 -servername geocode.versatiles.org 2>/dev/null | openssl x509 -noout -enddate
docker compose logs --no-log-prefix nginx | tail -5
```

Check:

- `/status` is `Ok`.
- The search answers 200, first `MISS` (or `HIT`), then `HIT`.
- `/` is `204` with `x-robots-tag: noindex`; `robots.txt` disallows `/api` and `/reverse`.
- `http://` answers `301` with `location: https://…`.
- The certificate is the existing one (`notAfter=Jan  8 … 2027`).
- The log lines have anonymised addresses and no query strings.

Real client addresses, from a machine with IPv6 and one with IPv4 (not the
server). The marker path is answered with 404 by Photon and shows up in the log:

```bash
curl -6 -s -o /dev/null https://geocode.versatiles.org/ipv6-check
curl -4 -s -o /dev/null https://geocode.versatiles.org/ipv4-check
```

```bash
docker compose logs --no-log-prefix nginx | grep -E 'ipv[46]-check'
```

Check: the IPv6 line starts with the first two groups of your IPv6 address
(`2a02:8108::` or similar), not with `172.` or `fd…`; the IPv4 line with your
IPv4 address, last octet zeroed. A `172.` address means the IPv6 network did
not take effect, and the rate limit would treat every IPv6 visitor as one.

Certificate renewal, end to end against Let's Encrypt's staging server:

```bash
bin/cert/renew.sh --dry-run
```

Check: `Congratulations, all simulated renewals succeeded` and
`nginx reloaded`.

## 5. Retire the host services

Only after step 4 has passed:

```bash
systemctl disable nginx
systemctl disable --now certbot.timer
crontab -l | grep -v -E 'certbot renew|service nginx reload' | crontab -
bin/cert/setup_renewal.sh
crontab -l
```

Check: `crontab -l` shows the new weekly `bin/cert/renew.sh` line and neither
of the two old lines (`certbot renew` at 23:42, `service nginx reload` at
23:47).

Why each: the host nginx must not take ports 80/443 at the next boot; the host
certbot would renew a copy of the certificate nginx no longer reads.

Back: `systemctl enable nginx`, `systemctl enable --now certbot.timer`,
`crontab /root/crontab.before-cutover`.

Then point the uptime monitor at `https://geocode.versatiles.org/status`
(expected text: `"status":"Ok"`). That URL is never answered from the cache,
so the monitor sees Photon fail.

## 6. Reboot test (optional, recommended)

```bash
reboot
```

After a minute: `docker compose ps` in `/root/photon-stack` shows both
containers healthy, and `systemctl is-active nginx` says `inactive`.

## Afterwards: cleanup (phase 5)

After a few days without problems: remove the host nginx and certbot packages,
`/etc/nginx/sites/geocode.versatiles.org`, the old logs in `/var/log/nginx/`
(full IP addresses and search texts), `/root/photon-stack.old`, the image
`photon-local:1.2.1`, the orphaned network `photon-stack_default`, the
`/mnt/photon-data` line in `/etc/fstab`; set `PHOTON_HOST_PORT=2322`.
