"""
Phase 1: build the static map assets for Canal Map.
Outputs: data/network.geojson, data/features.geojson, and basemap.pmtiles
Run offline on your own machine; ship the outputs inside the app.

Deps: requests, shapely, pyproj, geojson  (pip install)
Plus tippecanoe installed separately for the PMTiles step.
"""

import json
import os
import shutil
import subprocess
import time
import requests
from shapely.geometry import shape, mapping
from shapely.ops import unary_union, transform
from shapely.prepared import prep
from pyproj import Transformer

# --- Config -----------------------------------------------------------

# Overpass is rate-limited and load-shedding: it rejects the default
# python-requests UA (406) and returns 429/504 when busy. So: send a
# descriptive User-Agent, and retry across mirrors with backoff.
USER_AGENT = "CanalMap/0.1 (personal narrowboat map project; canal map)"
OVERPASS_ENDPOINTS = [
    "https://overpass-api.de/api/interpreter",
    "https://overpass.kumi.systems/api/interpreter",
    "https://maps.mail.ru/osm/tools/overpass/api/interpreter",
]
# Status codes worth retrying on another mirror (server-side/overload, not our fault)
_OVERPASS_RETRY_CODES = {429, 502, 503, 504}


def overpass_query(query, retries=4):
    """POST a query to Overpass, rotating mirrors and backing off on load."""
    headers = {"User-Agent": USER_AGENT}
    last_error = None
    for attempt in range(retries):
        for url in OVERPASS_ENDPOINTS:
            try:
                r = requests.post(url, data={"data": query}, headers=headers, timeout=300)
                if r.status_code in _OVERPASS_RETRY_CODES:
                    last_error = f"HTTP {r.status_code} from {url}"
                    continue
                r.raise_for_status()
                data = r.json()
                # A server-side timeout/runtime error comes back as HTTP 200
                # with a "remark" and no elements — retry it on another mirror.
                if not data.get("elements") and data.get("remark"):
                    last_error = f"remark from {url}: {data['remark'][:80]}"
                    continue
                return data
            except requests.RequestException as exc:
                last_error = f"{type(exc).__name__} from {url}: {exc}"
                continue
        wait = 5 * (2 ** attempt)  # 5, 10, 20, 40s
        print(f"  Overpass busy ({last_error}); retrying in {wait}s...")
        time.sleep(wait)
    raise RuntimeError(f"Overpass failed after {retries} rounds: {last_error}")

# Curated whitelist of navigable rivers (extend as needed).
# Start small to iterate fast, then widen.
NAVIGABLE_RIVERS = [
    "River Thames", "River Wey", "River Nene", "River Great Ouse",
    "River Trent", "River Severn", "River Avon",  # TODO: disambiguate Avons
]

BUFFER_METRES = 150  # clip everything to this distance from the water

# CRT "Customer service facilities" layer (ArcGIS open data). One point per
# facility, with Yes/No columns per service. We explode it into typed points.
CRT_FACILITIES_URL = (
    "https://services.arcgis.com/DknzyjEEie5tEW0u/ArcGIS/rest/services/"
    "Collaboration_17/FeatureServer/6/query"
)
# CRT boolean column -> our feature type (a facility can offer several).
CRT_SERVICE_TYPES = {
    "water_point": "water_point",
    "elsan_point": "sanitary",
    "pump_out_user_operated": "pumpout",
    "pump_out_staff_operated": "pumpout",
    "refuse_disposal": "refuse",
}

# Scope. None = nationwide (the shipped default). Set to a
# (south, west, north, east) WGS84 bbox to iterate fast on ONE region instead
# — e.g. West London (Grand Union + Thames): (51.30, -0.60, 51.75, 0.10).
SMALL_SLICE = None

# British National Grid for metric buffering, then back to WGS84
to_bng = Transformer.from_crs("EPSG:4326", "EPSG:27700", always_xy=True).transform
to_wgs = Transformer.from_crs("EPSG:27700", "EPSG:4326", always_xy=True).transform

DATA_DIR = "data"


def _region():
    """Return (preamble, selector) for the current scope.

    Small slice -> a bbox selector and no area preamble.
    Nationwide  -> the GB area definition plus an `(area.gb)` selector.
    """
    if SMALL_SLICE:
        s, w, n, e = SMALL_SLICE
        return "", f"({s},{w},{n},{e})"
    return 'area["ISO3166-1"="GB"][admin_level=2]->.gb;', "(area.gb)"


# --- OSM -> GeoJSON converters ----------------------------------------

def _feature(geometry, props):
    return {"type": "Feature", "geometry": geometry, "properties": props}


def classify_node(tags):
    """Map raw OSM tags to one of our typed feature categories."""
    ww = tags.get("waterway")
    if ww == "lock_gate":
        return "lock"
    if ww == "water_point":
        return "water_point"
    if ww == "sanitary_dump_station":
        return "sanitary"
    if tags.get("amenity") == "pub":
        return "pub"
    return "unknown"


def osm_ways_to_lines(overpass_json):
    """Overpass `out geom` ways -> LineString Features.

    Each way element carries a `geometry` list of {lat, lon} vertices.
    """
    features = []
    for el in overpass_json.get("elements", []):
        if el.get("type") != "way":
            continue
        geom = el.get("geometry") or []
        if len(geom) < 2:
            continue  # need at least two points to form a line
        coords = [[pt["lon"], pt["lat"]] for pt in geom]
        tags = el.get("tags", {})
        props = {
            "osm_id": el.get("id"),
            "name": tags.get("name"),
            "waterway": tags.get("waterway"),
        }
        features.append(_feature({"type": "LineString", "coordinates": coords}, props))
    return features


def osm_nodes_to_points(overpass_json):
    """Overpass elements -> typed Point Features.

    Handles bare nodes (lat/lon on the element) and ways/relations returned
    with `out center` (coords under `center`).
    """
    features = []
    for el in overpass_json.get("elements", []):
        if "lat" in el and "lon" in el:
            lon, lat = el["lon"], el["lat"]
        elif "center" in el:
            lon, lat = el["center"]["lon"], el["center"]["lat"]
        else:
            continue  # no usable coordinate
        tags = el.get("tags", {})
        props = {
            "osm_id": el.get("id"),
            "name": tags.get("name"),
            "type": classify_node(tags),
            "source": "osm",
        }
        features.append(_feature({"type": "Point", "coordinates": [lon, lat]}, props))
    return features


# --- 1. Network geometry from OSM (canals + whitelisted rivers) --------

def fetch_network():
    # Canals and the named navigable rivers are fetched as SEPARATE queries.
    # Nationwide, combining them (canals + 7 named-river lookups over all GB)
    # overruns Overpass's server timeout and returns an empty remark.
    preamble, sel = _region()

    canal_query = f"""
    [out:json][timeout:600];
    {preamble}
    (way["waterway"="canal"]{sel};);
    out geom;
    """
    canals = osm_ways_to_lines(overpass_query(canal_query))

    # Navigable rivers come primarily from OSM's own navigability tag
    # (boat=yes) — a data-driven curation that correctly excludes canoe-only /
    # unnavigable blue lines (boat=no). A hand-written name list alone missed
    # whole navigations (e.g. the River Stort). The names below are kept as a
    # belt-and-braces supplement for big rivers with patchy tagging.
    river_filter = "".join(
        f'way["waterway"="river"]["name"="{name}"]{sel};' for name in NAVIGABLE_RIVERS
    )
    river_query = f"""
    [out:json][timeout:600];
    {preamble}
    (
      way["waterway"="river"]["boat"="yes"]{sel};
      {river_filter}
    );
    out geom;
    """
    rivers = osm_ways_to_lines(overpass_query(river_query))

    print(f"  network: {len(canals)} canal ways + {len(rivers)} river ways")
    return canals + rivers


def fetch_tidal_ids():
    """OSM way ids tagged tidal=yes — used to flag hazardous tidal sections."""
    preamble, sel = _region()
    query = f"""
    [out:json][timeout:300];
    {preamble}
    (way["waterway"]["tidal"="yes"]{sel};);
    out ids;
    """
    data = overpass_query(query)
    return {el["id"] for el in data.get("elements", []) if el["type"] == "way"}


def mark_tidal(network, tidal_ids):
    """Flag network features whose OSM way is tidal (navigable but hazardous —
    need prep/licences/timing; the app styles them distinctly)."""
    n = 0
    for f in network:
        if f["properties"].get("osm_id") in tidal_ids:
            f["properties"]["tidal"] = 1
            n += 1
    return n


# --- 2. Feature points ------------------------------------------------
# Locks, water points, sanitary/Elsan, pump-out, moorings, boatyards, pubs.

def fetch_osm_features():
    # OSM covers locks/water points/pubs across BOTH canals and EA rivers,
    # so it's the unified base layer.
    preamble, sel = _region()
    query = f"""
    [out:json][timeout:600];
    {preamble}
    (
      node["waterway"="lock_gate"]{sel};
      node["waterway"="water_point"]{sel};
      node["waterway"="sanitary_dump_station"]{sel};
      node["amenity"="pub"]{sel};           // filtered to buffer below
    );
    out center;
    """
    return osm_nodes_to_points(overpass_query(query))


def fetch_crt_facilities():
    """CRT authoritative facilities -> typed service points.

    One CRT facility can offer several services (water + Elsan + refuse),
    so we emit one point per distinct service it flags "Yes". Paginated;
    server-side bbox filtered when running a small slice.
    """
    params = {
        "where": "1=1",
        "outFields": ",".join(["sap_description", "sap_func_loc", *CRT_SERVICE_TYPES]),
        "outSR": 4326,
        "f": "geojson",
        "resultRecordCount": 1000,
    }
    if SMALL_SLICE:
        s, w, n, e = SMALL_SLICE
        params.update({
            "geometry": f"{w},{s},{e},{n}",
            "geometryType": "esriGeometryEnvelope",
            "inSR": 4326,
            "spatialRel": "esriSpatialRelIntersects",
        })
    headers = {"User-Agent": USER_AGENT}
    out, offset = [], 0
    while True:
        params["resultOffset"] = offset
        gj = requests.get(CRT_FACILITIES_URL, params=params, headers=headers, timeout=120).json()
        feats = gj.get("features", [])
        for f in feats:
            props = f.get("properties", {})
            # distinct service types this facility offers
            types = {
                CRT_SERVICE_TYPES[col]
                for col in CRT_SERVICE_TYPES
                if str(props.get(col, "")).strip().lower() == "yes"
            }
            for ftype in types:
                out.append(_feature(f["geometry"], {
                    "type": ftype,
                    "name": props.get("sap_description"),
                    "source": "crt",
                    "crt_id": props.get("sap_func_loc"),
                }))
        if len(feats) < params["resultRecordCount"]:
            break  # last page
        offset += params["resultRecordCount"]
    return out
    # TODO (optional): fetch EA facility data the same way for Thames etc.


def fetch_bridges():
    """Numbered canal bridges. OSM puts the number on the crossing way as
    `bridge:ref` — boaters navigate by these ("moor above Bridge 42")."""
    preamble, sel = _region()
    query = f"""
    [out:json][timeout:600];
    {preamble}
    (way["bridge:ref"]{sel};);
    out center tags;
    """
    feats = []
    for el in overpass_query(query).get("elements", []):
        c = el.get("center")
        if not c:
            continue
        tags = el.get("tags", {})
        ref = (tags.get("bridge:ref") or "").strip()
        # Skip railway-style refs like "LSC2/06" — not canal bridge numbers.
        if not ref or "/" in ref or len(ref) > 6:
            continue
        feats.append(_feature(
            {"type": "Point", "coordinates": [c["lon"], c["lat"]]},
            {
                "type": "bridge",
                "ref": ref,  # the number the map labels
                # Only a real bridge name goes in `name`, so the search index
                # isn't flooded with thousands of generic "Bridge 41" entries.
                "name": tags.get("bridge:name"),
                "source": "osm",
            },
        ))
    return feats


def fetch_places():
    """Town/village names for map context labels."""
    preamble, sel = _region()
    query = f"""
    [out:json][timeout:600];
    {preamble}
    (node["place"~"^(city|town|village|suburb|hamlet)$"]["name"]{sel};);
    out;
    """
    feats = []
    for el in overpass_query(query).get("elements", []):
        if "lat" not in el:
            continue
        tags = el.get("tags", {})
        feats.append(_feature(
            {"type": "Point", "coordinates": [el["lon"], el["lat"]]},
            {"type": tags.get("place"), "name": tags.get("name")},
        ))
    return feats


# --- 3. Clip to buffer around the water -------------------------------

_net_union_cache = {}


def network_buffer(network_lines, metres):
    """Prepared polygon `metres` around the network — fast repeated contains().
    The unary_union is the expensive bit, so cache it across buffer sizes."""
    key = id(network_lines)
    net = _net_union_cache.get(key)
    if net is None:
        net = unary_union([shape(l["geometry"]) for l in network_lines])
        _net_union_cache[key] = net
    net_bng = transform(to_bng, net)
    return prep(transform(to_wgs, net_bng.buffer(metres)))


def clip_points(points, prepared):
    return [p for p in points if prepared.contains(shape(p["geometry"]))]


def clip_to_network(points, network_lines, metres=BUFFER_METRES):
    return clip_points(points, network_buffer(network_lines, metres))


# --- 4. Write outputs + build PMTiles ---------------------------------

def write_geojson(path, features):
    with open(path, "w") as f:
        json.dump({"type": "FeatureCollection", "features": features}, f)


def write_search_index(path, features, network):
    """Emit a small flat list the app loads into memory for search + near-me.

    Named POIs (locks, pubs, CRT facilities…) plus one entry per uniquely
    named waterway (with a representative point). No geometry, no database —
    just [{name, type, lat, lon}] the app filters client-side.
    """
    index = []

    for f in features:
        name = (f.get("properties", {}) or {}).get("name")
        if not name:
            continue
        lon, lat = f["geometry"]["coordinates"]
        index.append({
            "name": name,
            "type": f["properties"].get("type", "feature"),
            "lat": round(lat, 6),
            "lon": round(lon, 6),
        })

    # One entry per named waterway, anchored at the mid-vertex of its first line.
    seen = set()
    for line in network:
        name = (line.get("properties", {}) or {}).get("name")
        if not name or name in seen:
            continue
        seen.add(name)
        coords = line["geometry"]["coordinates"]
        lon, lat = coords[len(coords) // 2]
        index.append({
            "name": name,
            "type": "waterway",
            "lat": round(lat, 6),
            "lon": round(lon, 6),
        })

    with open(path, "w", encoding="utf-8") as fh:
        json.dump(index, fh)
    return len(index)


def _have_tippecanoe():
    return shutil.which("tippecanoe") is not None


def build_pmtiles():
    """Build basemap.pmtiles. Prefer tippecanoe; fall back to pure-Python.

    tippecanoe is the gold standard but is Unix-only. When it's not on PATH
    (e.g. Windows dev box) we use pmtiles_builder — slower and simpler, but
    keeps the pipeline runnable everywhere with no external binary.
    """
    layers = {
        "network": "data/network.geojson",
        "features": "data/features.geojson",
        "places": "data/places.geojson",
    }
    if _have_tippecanoe():
        print("build_pmtiles: using tippecanoe")
        subprocess.run([
            "tippecanoe", "-o", "basemap.pmtiles", "-z16", "-Z6",
            "--drop-densest-as-needed", "--force",
            *[a for name, path in layers.items() for a in ("-L", f"{name}:{path}")],
        ], check=True)
    else:
        print("build_pmtiles: tippecanoe not found — using pure-Python builder")
        import pmtiles_builder
        pmtiles_builder.build(layers, "basemap.pmtiles", minzoom=6, maxzoom=16)


if __name__ == "__main__":
    os.makedirs(DATA_DIR, exist_ok=True)

    network = fetch_network()
    n_tidal = mark_tidal(network, fetch_tidal_ids())
    print(f"  tidal ways flagged: {n_tidal}")
    write_geojson("data/network.geojson", network)

    # Bridges sit ON the water, so clip them tight; POIs use the normal buffer.
    tight = network_buffer(network, 40)
    bridges = clip_points(fetch_bridges(), tight)
    print(f"  numbered bridges: {len(bridges)}")

    features = fetch_osm_features() + fetch_crt_facilities()
    features = clip_to_network(features, network) + bridges
    write_geojson("data/features.geojson", features)

    # Place labels get a wider buffer so nearby towns give context.
    places = clip_points(fetch_places(), network_buffer(network, 2500))
    write_geojson("data/places.geojson", places)
    print(f"  place labels: {len(places)}")

    n = write_search_index("data/search_index.json", features, network)
    print(f"search index: {n} entries")

    build_pmtiles()
    print("Done: basemap.pmtiles + data/features.geojson + data/search_index.json")