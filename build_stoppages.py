"""
Bucket 2 producer: build stoppages.json from Canal & River Trust notices.

Run daily by GitHub Actions (see .github/workflows/update-stoppages.yml), which
commits the result so it is served as a static file. The app fetches it with
offline fallback — the map always renders from local files regardless.

Data source: CRT's own notices API, reverse-engineered from the React app on
canalrivertrust.org.uk/notices:
  GET /api/stoppage/notices?geometry=point&consult=false&start=..&end=..&fields=..
  (requires an X-Requested-With: XMLHttpRequest header, else 500).
It returns a GeoJSON FeatureCollection — notices already carry coordinates, so
no geocoding is needed. typeId/reasonId are mapped to names via CRT's lookups.

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
"""

import argparse
import datetime
import json
import sys

import requests

API_URL = "https://canalrivertrust.org.uk/api/stoppage/notices"
API_HEADERS = {
    "User-Agent": "CanalMap/0.1 (personal narrowboat map project; canal map)",
    "Accept": "application/json",
    "X-Requested-With": "XMLHttpRequest",  # required, else the API 500s
    "Referer": "https://canalrivertrust.org.uk/notices",
}
FIELDS = "title,region,waterways,path,typeId,reasonId,programmeId,start,end,state,image"
WINDOW_DAYS = 120  # current + upcoming notices
OUT_PATH = "data/stoppages.json"

# CRT typeId -> our marker state. Towpath-only types (3, 8) are dropped as they
# don't affect navigation.
TYPE_STATE = {
    1: "closed",       # Navigation Closure
    9: "closed",       # Navigation and Towpath Closure
    2: "restricted",   # Navigation Restriction
    11: "restricted",  # Navigation Restriction and Towpath Closure
    4: "advisory",     # Advice
    10: "advisory",    # Customer Service Facility
}
TYPES = {
    1: "Navigation Closure", 2: "Navigation Restriction", 3: "Towpath Closure",
    4: "Advice", 8: "Towpath Restriction", 9: "Navigation and Towpath Closure",
    10: "Customer Service Facility", 11: "Navigation Restriction and Towpath Closure",
}
REASONS = {
    2: "3rd Party Works", 5: "Inspections", 6: "Maintenance", 8: "Repair",
    9: "Suspected Vandalism", 10: "Vegetation", 12: "Information", 13: "Event",
    14: "Boating Incident", 15: "Emergency Services Incident",
    16: "Underwater Obstruction", 17: "Vehicle Incident", 18: "Low Water Levels",
    19: "High Water Levels", 20: "Pollution Incident",
}


def _first_point(geom):
    """A notice's geometry is a Point/MultiPoint/GeometryCollection of points;
    take the first point as its marker location. Returns (lon, lat) or None."""
    if not geom:
        return None
    t = geom.get("type")
    if t == "Point":
        return geom["coordinates"]
    if t == "MultiPoint" and geom.get("coordinates"):
        return geom["coordinates"][0]
    if t == "GeometryCollection":
        for g in geom.get("geometries", []):
            c = _first_point(g)
            if c:
                return c
    return None


def fetch_crt_notices():
    """Live navigation notices from CRT, mapped to our stoppage records."""
    today = datetime.date.today()
    params = {
        "geometry": "point",
        "consult": "false",
        "start": today.isoformat(),
        "end": (today + datetime.timedelta(days=WINDOW_DAYS)).isoformat(),
        "fields": FIELDS,
    }
    resp = requests.get(API_URL, params=params, headers=API_HEADERS, timeout=60)
    resp.raise_for_status()
    features = resp.json().get("features", [])

    out, skipped = [], 0
    for f in features:
        p = f.get("properties", {}) or {}
        if p.get("state") != "Published":  # skip Completed/Cancelled
            continue
        state = TYPE_STATE.get(p.get("typeId"))
        if state is None:  # towpath-only / not navigation-relevant
            skipped += 1
            continue
        coord = _first_point(f.get("geometry"))
        if not coord:
            skipped += 1
            continue
        lon, lat = coord
        out.append({
            "id": p.get("id", ""),
            "title": p.get("title", "Notice"),
            "type": TYPES.get(p.get("typeId"), ""),
            "reason": REASONS.get(p.get("reasonId"), ""),
            "waterway": p.get("waterways", ""),
            "state": state,
            "start": p.get("start", ""),
            "end": p.get("end", ""),
            "lat": round(lat, 6),
            "lon": round(lon, 6),
            "url": "https://canalrivertrust.org.uk" + p.get("path", "/notices"),
        })
    print(f"CRT notices: {len(out)} navigation stoppages "
          f"({skipped} skipped: towpath-only/no-coord)")
    return out


def build(iso_now):
    try:
        stoppages = fetch_crt_notices()
    except requests.RequestException as exc:
        # Never break the pipeline on a fetch failure — the app has offline
        # fallback. Emit an empty feed and let the next run recover.
        print(f"warning: CRT fetch failed ({exc}); writing empty feed", file=sys.stderr)
        stoppages = []

    doc = {
        "updated": iso_now,
        "source": "Canal & River Trust notices",
        "stoppages": stoppages,
    }
    with open(OUT_PATH, "w", encoding="utf-8") as fh:
        json.dump(doc, fh, indent=2)
    print(f"wrote {OUT_PATH}: {len(stoppages)} stoppages")


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--iso", help="ISO-8601 UTC timestamp to stamp as 'updated'")
    args = ap.parse_args()
    iso = args.iso or datetime.datetime.now(datetime.timezone.utc).strftime(
        "%Y-%m-%dT%H:%M:%SZ")
    build(iso)
