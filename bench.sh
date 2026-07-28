#!/usr/bin/env bash
# Latency benchmark against one or two Photon instances, bypassing nginx so
# the geocoder is measured in isolation.
#
#   ./bench.sh 2322            # one instance
#   ./bench.sh 2322 2323       # old vs new, same query set
#
# "cold" = queries the instance has not seen; those hit the disk-bound index
# and are what users actually feel.
#
# A query is only cold ONCE — after that its pages sit in the OS page cache.
# So the script keeps a run counter in .bench-run and takes a different slice
# of a 60-query pool each time. Reset with: rm -f .bench-run
set -euo pipefail
[[ $# -ge 1 ]] || { echo "usage: $0 <port> [port2]"; exit 1; }

cd "$(dirname "$0")"
RUN=$(( $(cat .bench-run 2>/dev/null || echo 0) ))
echo $(( RUN + 1 )) > .bench-run

python3 - "$RUN" "$@" <<'PY'
import json, sys, time, urllib.parse, urllib.request

RUN   = int(sys.argv[1])
PORTS = sys.argv[2:]

# Deliberately mixed: multilingual European (the coverage that must be kept)
# plus global, so nothing is served from one hot corner of the index.
POOL = [
    "Kirchstraße 12 Leipzig", "Via Roma 5 Torino", "Ulica Marszalkowska Warszawa",
    "Calle Mayor 3 Valladolid", "Rua da Prata Lisboa", "Nieuwstraat 8 Utrecht",
    "Bahnhofstrasse Winterthur", "Gran Via 44 Bilbao", "Karl-Marx-Allee 90 Berlin",
    "Boulevard Saint-Germain Paris", "Piazza del Duomo Milano", "Vaclavske namesti Praha",
    "Sydney Opera House", "Shibuya Crossing Tokyo", "Avenida Paulista Sao Paulo",
    "Nevsky Prospekt", "Mumbai Chhatrapati", "Nairobi Kenyatta Avenue",
    "Reykjavik Laugavegur", "Oxford Street London",
    "Grafton Street Dublin", "Stroget Kobenhavn", "Drottninggatan Stockholm",
    "Karl Johans gate Oslo", "Aleksanterinkatu Helsinki", "Kärntner Straße Wien",
    "Graben 12 Salzburg", "Bahnhofstrasse Zürich", "Rue Neuve Bruxelles",
    "Grand Rue Luxembourg", "Calea Victoriei Bucuresti", "Vitosha Boulevard Sofia",
    "Ban Jelacic Zagreb", "Presernov trg Ljubljana", "Vaci utca Budapest",
    "Ermou Athina", "Istiklal Caddesi Istanbul", "Rossio Lisboa",
    "Las Ramblas Barcelona", "Puerta del Sol Madrid", "Corso Buenos Aires Milano",
    "Piazza Navona Roma", "Königsallee Düsseldorf", "Reeperbahn Hamburg",
    "Zeil Frankfurt", "Schildergasse Köln", "Maximilianstraße München",
    "Prager Straße Dresden", "Domplatz Erfurt", "Lange Voorhout Den Haag",
    "Coolsingel Rotterdam", "Meir Antwerpen", "Rue Sainte-Catherine Bordeaux",
    "La Canebiere Marseille", "Place Bellecour Lyon", "Toronto Yonge Street",
    "Calle Florida Buenos Aires", "Orchard Road Singapore", "Bourke Street Melbourne",
]
n = 20
start = (RUN * n) % len(POOL)
COLD = [POOL[(start + i) % len(POOL)] for i in range(n)]
WARM = "Berlin Hauptbahnhof"
print(f"query slice {start}..{start+n-1} of {len(POOL)} (run #{RUN})")

def hit(port, q, limit=5):
    url = f"http://127.0.0.1:{port}/api?" + urllib.parse.urlencode({"q": q, "limit": limit})
    t = time.perf_counter()
    with urllib.request.urlopen(url, timeout=30) as r:
        body = r.read()
    return (time.perf_counter() - t) * 1000, len(json.loads(body).get("features", []))

def pct(xs, p):
    xs = sorted(xs)
    return xs[min(len(xs) - 1, int(len(xs) * p))]

for port in PORTS:
    try:
        hit(port, "warmup probe zzz")
    except Exception as e:
        print(f"\nport {port}: UNREACHABLE ({e})")
        continue

    lat, empty = [], 0
    for q in COLD:
        try:
            ms, n = hit(port, q)
        except Exception as e:
            print(f"  {q}: ERROR {e}")
            continue
        lat.append(ms)
        if n == 0:
            empty += 1
    warm = [hit(port, WARM)[0] for _ in range(6)][1:]  # discard first

    print(f"\n=== port {port} ===")
    print(f"  cold (n={len(lat)})  p50={pct(lat,.5):7.1f}ms  p90={pct(lat,.9):7.1f}ms  "
          f"max={max(lat):7.1f}ms  mean={sum(lat)/len(lat):7.1f}ms")
    print(f"  warm (n={len(warm)}) p50={pct(warm,.5):7.1f}ms  "
          f"mean={sum(warm)/len(warm):7.1f}ms")
    if empty:
        print(f"  !! {empty}/{len(lat)} queries returned zero results — check coverage")

if len(PORTS) == 2:
    print("\n  Same query set on both. Compare the cold p50: that is the number")
    print("  the index size and disk change are supposed to move.")
PY
