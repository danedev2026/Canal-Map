"""
v1.1 routing: build a compact routable graph from the OSM network.

The effort spike here is DATA, not runtime. Pipeline:
  1. node        — split lines at every true crossing (shapely unary_union)
  2. connect     — bridge dangling endpoints to the nearest waterway within a
                   tolerance (canal/river joins that don't share a node)
  3. snap        — join any remaining near endpoints
  4. mark locks  — flag the graph node nearest each lock
  5. serialise   — a compact binary (node coords + edges + lock flags) the app
                   bundles and routes over on-device (A*)

We keep the FULL vertex graph (no contraction) so a route follows the real
canal geometry when drawn. ~166k nodes routes in well under a second on-device.

Known limitation (the plan flagged this as the unpredictable part): a few
branches (Kennet & Avon, Manchester ring, some rivers) stay in separate
components from junction gaps, so cross-component routes return "no through
route". The main connected network (~3,700 km) routes correctly.

Deps: shapely.
"""

import json
import math
import struct
from collections import defaultdict

from shapely.geometry import shape, Point, LineString
from shapely.ops import unary_union
from shapely import STRtree

COORD_PRECISION = 6
GAP_CONNECT_METRES = 35.0
GAP_SNAP_METRES = 20.0
LOCK_SNAP_METRES = 40.0
R_EARTH = 6371000.0
GRAPH_MAGIC = b"CMRG"
GRAPH_VERSION = 1


def _haversine(a, b):
    lon1, lat1 = a
    lon2, lat2 = b
    p1, p2 = math.radians(lat1), math.radians(lat2)
    dp = math.radians(lat2 - lat1)
    dl = math.radians(lon2 - lon1)
    h = math.sin(dp / 2) ** 2 + math.cos(p1) * math.cos(p2) * math.sin(dl / 2) ** 2
    return R_EARTH * 2 * math.asin(min(1, math.sqrt(h)))


def _key(lon, lat):
    return (round(lon, COORD_PRECISION), round(lat, COORD_PRECISION))


def build_vertex_graph(lines_coords):
    """List of coord-lists -> (adjacency dict, key->[lon,lat])."""
    adj = defaultdict(dict)
    coord = {}
    for cs in lines_coords:
        for i in range(len(cs) - 1):
            a, b = _key(*cs[i]), _key(*cs[i + 1])
            if a == b:
                continue
            coord[a], coord[b] = cs[i], cs[i + 1]
            L = _haversine(cs[i], cs[i + 1])
            if b not in adj[a] or L < adj[a][b]:
                adj[a][b] = L
                adj[b][a] = L
    return adj, coord


def _connectors(lines, tol_m):
    """Short bridges from dangling endpoints to the nearest other waterway."""
    tree = STRtree(lines)
    tol_deg = tol_m / 60000.0
    conns = []
    for i, l in enumerate(lines):
        cs = list(l.coords)
        for endp in (cs[0], cs[-1]):
            pt = Point(endp)
            best, best_d = None, tol_m
            for j in tree.query(pt.buffer(tol_deg)):
                j = int(j)
                if j == i:
                    continue
                proj = lines[j].interpolate(lines[j].project(pt))
                dm = _haversine(endp, (proj.x, proj.y))
                if 0.01 < dm < best_d:
                    best, best_d = (proj.x, proj.y), dm
            if best:
                conns.append(LineString([endp, best]))
    return conns


def snap_gaps(adj, coord, tol_m):
    keys = list(adj.keys())
    pts = [Point(*coord[k]) for k in keys]
    tree = STRtree(pts)
    tol_deg = tol_m / 60000.0
    added = 0
    for idx, k in enumerate(keys):
        if len(adj[k]) != 1:
            continue
        best, best_d = None, tol_m
        for i in tree.query(pts[idx].buffer(tol_deg)):
            k2 = keys[int(i)]
            if k2 == k or k2 in adj[k]:
                continue
            d = _haversine(coord[k], coord[k2])
            if d < best_d:
                best, best_d = k2, d
        if best is not None:
            adj[k][best] = best_d
            adj[best][k] = best_d
            added += 1
    return added


def connected_components(adj):
    seen, comps = set(), []
    for start in adj:
        if start in seen:
            continue
        stack, comp = [start], []
        seen.add(start)
        while stack:
            n = stack.pop()
            comp.append(n)
            for m in adj[n]:
                if m not in seen:
                    seen.add(m)
                    stack.append(m)
        comps.append(comp)
    comps.sort(key=len, reverse=True)
    return comps


def build(network, locks):
    lines = [shape(f["geometry"]) for f in network]
    merged = unary_union(lines + _connectors(lines, GAP_CONNECT_METRES))
    geoms = merged.geoms if merged.geom_type == "MultiLineString" else [merged]
    adj, coord = build_vertex_graph([list(g.coords) for g in geoms])
    snap_gaps(adj, coord, GAP_SNAP_METRES)

    # Mark lock nodes.
    keys = list(adj.keys())
    tree = STRtree([Point(*coord[k]) for k in keys])
    lock_keys = set()
    for lk in locks:
        lon, lat = lk["geometry"]["coordinates"]
        res = tree.query_nearest(Point(lon, lat))
        i = int(res[0]) if hasattr(res, "__len__") else int(res)
        if _haversine((lon, lat), coord[keys[i]]) <= LOCK_SNAP_METRES:
            lock_keys.add(keys[i])
    return adj, coord, lock_keys


def serialize(adj, coord, lock_keys, path):
    keys = list(adj.keys())
    index = {k: i for i, k in enumerate(keys)}
    # dedup undirected edges
    edges = set()
    for a in adj:
        for b in adj[a]:
            ia, ib = index[a], index[b]
            edges.add((ia, ib) if ia < ib else (ib, ia))
    edges = sorted(edges)
    lock_idx = sorted(index[k] for k in lock_keys)

    with open(path, "wb") as f:
        f.write(GRAPH_MAGIC)
        f.write(struct.pack("<B", GRAPH_VERSION))
        f.write(struct.pack("<I", len(keys)))
        for k in keys:
            lon, lat = coord[k]
            f.write(struct.pack("<ff", lon, lat))
        f.write(struct.pack("<I", len(lock_idx)))
        for i in lock_idx:
            f.write(struct.pack("<I", i))
        f.write(struct.pack("<I", len(edges)))
        for a, b in edges:
            f.write(struct.pack("<II", a, b))
    return len(keys), len(edges), len(lock_idx)


if __name__ == "__main__":
    network = json.load(open("data/network.geojson", encoding="utf-8"))["features"]
    features = json.load(open("data/features.geojson", encoding="utf-8"))["features"]
    locks = [f for f in features if (f["properties"] or {}).get("type") == "lock"]
    print(f"building routing graph from {len(network)} ways, {len(locks)} locks...")

    adj, coord, lock_keys = build(network, locks)
    comps = connected_components(adj)
    n, e, lk = serialize(adj, coord, lock_keys, "data/routing.graph")
    import os
    print(f"nodes={n} edges={e} locks={lk}")
    print(f"components={len(comps)} largest={100*len(comps[0])/n:.1f}%")
    print(f"routing.graph: {os.path.getsize('data/routing.graph')/1e6:.2f} MB")
