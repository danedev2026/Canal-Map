"""
Bucket 2 producer: build stoppages.json from Canal & River Trust notices.

Run daily by GitHub Actions (see .github/workflows/update-stoppages.yml), which
commits the result so it is served as a static file. The app fetches it with
offline fallback — the map always renders from local files regardless.

IMPORTANT: the `stoppages.json` SCHEMA is the stable contract the app depends
on. The CRT ingestion in `fetch_crt_notices()` is BEST-EFFORT: CRT do not
publish a clean notices API (notices load via an undocumented client-side
endpoint, and give locations by NAME not coordinates). That function is the
one piece expected to need maintenance; everything else is stable.

Output schema (data/stoppages.json):
{
  "updated": "<ISO-8601 UTC>",
  "source": "Canal & River Trust notices",
  "stoppages": [
    {"id","title","type","reason","waterway","state","start","end","lat","lon","url"}
  ]
}
state ∈ {closed, restricted, advisory}  (drives the map marker colour)

Deps: requests. Run: python build_stoppages.py [--iso YYYY-MM-DDTHH:MM:SSZ]
(pass --iso so CI runs are reproducible; else current UTC is stamped.)
"""

import argparse
import json
import sys

import requests

CRT_NOTICES_URL = "https://canalrivertrust.org.uk/notices"
SEARCH_INDEX = "app/assets/search_index.json"  # waterway-name -> coordinate
OUT_PATH = "data/stoppages.json"
UA = {"User-Agent": "CanalMap/0.1 (personal narrowboat map; canal map)"}


def load_waterway_coords():
    """name -> (lat, lon) for every waterway in our bundled search index."""
    with open(SEARCH_INDEX, encoding="utf-8") as fh:
        idx = json.load(fh)
    return {e["name"]: (e["lat"], e["lon"]) for e in idx if e["type"] == "waterway"}


def classify_state(type_name):
    t = (type_name or "").lower()
    if "closure" in t:
        return "closed"
    if "restriction" in t:
        return "restricted"
    return "advisory"


def geocode(waterway, coords):
    """Coarse: place a notice at its waterway's representative point.

    Exact asset-level positions would need CRT to expose coordinates (they
    don't) or a gazetteer match; waterway-level is good enough for v1.
    """
    if not waterway:
        return None
    if waterway in coords:
        return coords[waterway]
    # loose contains-match (e.g. "Grand Union Canal (Paddington Arm)")
    for name, c in coords.items():
        if waterway in name or name in waterway:
            return c
    return None


def fetch_crt_notices():
    """Return a list of raw notices: {id,title,type,reason,waterway,start,end}.

    BEST-EFFORT / REPLACEABLE. CRT render notices via a client-side call that
    is not publicly documented, so we cannot reliably parse them server-side
    yet. Until that endpoint is pinned down this returns [] (a valid, empty
    feed), and the app shows "0 notices". Wire the real source in here.
    """
    try:
        resp = requests.get(CRT_NOTICES_URL, headers=UA, timeout=30)
        resp.raise_for_status()
        # The page exposes filter config (types/reasons/waterways) but not the
        # notice list itself; the list arrives via a separate client request.
        # TODO: capture that request (browser devtools → Network) and call it
        # here, mapping each notice to the dict shape documented above.
        return []
    except requests.RequestException as exc:
        print(f"warning: could not reach CRT notices: {exc}", file=sys.stderr)
        return []


def build(iso_now):
    coords = load_waterway_coords()
    raw = fetch_crt_notices()

    stoppages = []
    skipped = 0
    for n in raw:
        c = geocode(n.get("waterway"), coords)
        if not c:
            skipped += 1
            continue  # can't place it on the map → omit (logged below)
        lat, lon = c
        stoppages.append({
            "id": n.get("id", ""),
            "title": n.get("title", "Notice"),
            "type": n.get("type", ""),
            "reason": n.get("reason", ""),
            "waterway": n.get("waterway", ""),
            "state": classify_state(n.get("type")),
            "start": n.get("start", ""),
            "end": n.get("end", ""),
            "lat": round(lat, 6),
            "lon": round(lon, 6),
            "url": n.get("url", CRT_NOTICES_URL),
        })

    doc = {
        "updated": iso_now,
        "source": "Canal & River Trust notices",
        "stoppages": stoppages,
    }
    with open(OUT_PATH, "w", encoding="utf-8") as fh:
        json.dump(doc, fh, indent=2)
    print(f"wrote {OUT_PATH}: {len(stoppages)} stoppages "
          f"({skipped} skipped for no coordinate)")


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--iso", help="ISO-8601 UTC timestamp to stamp as 'updated'")
    args = ap.parse_args()
    iso = args.iso
    if not iso:
        import datetime
        iso = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    build(iso)
