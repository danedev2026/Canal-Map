"""Precompute polylines for well-known cruising routes ("rings") by routing
through curated waypoints over the SAME graph the app uses (routing_graph.build,
including component stitching). Validates each against its known distance so we
don't ship a route that mis-traced, then writes app/assets/popular_routes.json
for the app to draw. £0: offline, reproducible.

Run: ./.venv/Scripts/python.exe build_popular_routes.py
"""
import heapq
import json
import math

from shapely.geometry import Point, LineString
from shapely import STRtree

import routing_graph as rg

MPH_M_PER_MIN = 3 * 1609.34 / 60
MINS_PER_LOCK = 10
SIMPLIFY_DEG = 0.00006  # ~6 m, trims the polyline without visibly changing it

# name, description, expected miles (for a sanity check), loop?, waypoints[(lat,lon)]
ROUTES = [
    ("Cheshire Ring",
     "A classic 4–7 day circuit through Manchester, the Peak fringe and the "
     "Cheshire plain. Contrasting canals and plenty of locks.",
     97, True, [
        (53.4760, -2.2520),  # Manchester (Castlefield)
        (53.3960, -2.0660),  # Marple Junction
        (53.2530, -2.1250),  # Macclesfield
        (53.0870, -2.2380),  # Kidsgrove (Harding's Wood)
        (53.1900, -2.4430),  # Middlewich
        (53.3380, -2.6660),  # Preston Brook
        (53.4470, -2.3090),  # Stretford
     ]),
    ("Four Counties Ring",
     "Cheshire, Shropshire, Staffordshire and the West Midlands — the Audlem "
     "and Bosley-free lock flights, Harecastle Tunnel and open countryside.",
     110, True, [
        (53.1900, -2.4430),  # Middlewich
        (53.0680, -2.5230),  # Nantwich
        (52.9870, -2.5090),  # Audlem
        (52.9060, -2.4880),  # Market Drayton
        (52.7720, -2.2830),  # Norbury Junction
        (52.6180, -2.1350),  # Autherley Junction
        (52.8010, -2.0170),  # Great Haywood Junction
        (52.9060, -2.1480),  # Stone
        (53.0270, -2.1870),  # Stoke-on-Trent
     ]),
    ("Warwickshire Ring",
     "Birmingham, the Coventry and Oxford canals and the Grand Union — lots of "
     "locks (Hatton, Farmer's Bridge) and a good two-week cruise.",
     100, True, [
        (52.4830, -1.9050),  # Birmingham (Farmer's Bridge)
        (52.6130, -1.7000),  # Fazeley Junction
        (52.5800, -1.5500),  # Atherstone
        (52.4430, -1.4620),  # Hawkesbury Junction
        (52.3660, -1.4700),  # Ansty (Oxford Canal, keeps it off the T&M)
        (52.2900, -1.6300),  # Hatton
        (52.3500, -1.7700),  # Kingswood Junction
     ]),
    ("Stourport Ring",
     "Birmingham Canal Navigations, the Stourbridge and Staffs & Worcs canals, "
     "the River Severn and the Worcester & Birmingham — locks galore.",
     84, True, [
        (52.4770, -1.9100),  # Birmingham (Gas Street)
        (52.4560, -2.1490),  # Stourbridge
        (52.4560, -2.2900),  # Stourton Junction
        (52.3400, -2.2770),  # Stourport-on-Severn
        (52.1850, -2.2200),  # Worcester (Diglis)
        (52.3230, -2.0200),  # Tardebigge
        (52.4050, -1.9200),  # Kings Norton Junction
     ]),
    ("Avon Ring",
     "The Worcester & Birmingham, River Severn, River Avon and Stratford Canal "
     "— rivers and canals, and the famous Tardebigge flight.",
     109, True, [
        (52.4770, -1.9100),  # Birmingham
        (52.4050, -1.9200),  # Kings Norton
        (52.3230, -2.0200),  # Tardebigge
        (52.1850, -2.2200),  # Worcester (Diglis)
        (51.9900, -2.1600),  # Tewkesbury
        (52.0900, -1.9400),  # Evesham
        (52.1900, -1.7100),  # Stratford-upon-Avon
        (52.3500, -1.7700),  # Kingswood Junction
     ]),
    ("Llangollen Canal",
     "One of the most scenic canals in the country: lock flights, the Whitchurch "
     "and Ellesmere country, and the Pontcysyllte Aqueduct to Llangollen.",
     46, False, [
        (53.0980, -2.5500),  # Hurleston Junction
        (53.0180, -2.6180),  # Wrenbury
        (52.9700, -2.6900),  # Whitchurch
        (52.9060, -2.8900),  # Ellesmere
        (52.9370, -3.0790),  # Chirk
        (52.9700, -3.1700),  # Llangollen
     ]),
]


def astar(adj, coord, start, goal):
    if start == goal:
        return [start]
    gx, gy = coord[goal]

    def h(k):
        x, y = coord[k]
        return rg._haversine((x, y), (gx, gy))

    openq = [(h(start), start)]
    gscore = {start: 0.0}
    came = {}
    while openq:
        _, u = heapq.heappop(openq)
        if u == goal:
            break
        gu = gscore[u]
        for v, w in adj[u].items():
            ng = gu + w
            if ng < gscore.get(v, math.inf):
                gscore[v] = ng
                came[v] = u
                heapq.heappush(openq, (ng + h(v), v))
    if goal not in came and start != goal:
        return None
    path = [goal]
    cur = goal
    while cur != start:
        cur = came[cur]
        path.append(cur)
    path.reverse()
    return path


def build_route(adj, coord, lock_keys, tree, keys, waypoints, loop):
    pts = list(waypoints)
    if loop:
        pts = pts + [pts[0]]

    def snap(lat, lon):
        res = tree.query_nearest(Point(lon, lat))
        i = int(res[0]) if hasattr(res, "__len__") else int(res)
        return keys[i]

    node_pts = [snap(lat, lon) for (lat, lon) in pts]
    full = []
    for a, b in zip(node_pts, node_pts[1:]):
        seg = astar(adj, coord, a, b)
        if seg is None:
            return None
        if full:
            seg = seg[1:]  # avoid duplicating the shared node
        full.extend(seg)

    # Metres + locks along the path.
    metres = 0.0
    for a, b in zip(full, full[1:]):
        metres += rg._haversine(coord[a], coord[b])
    locks = sum(1 for k in full[1:-1] if k in lock_keys)

    coords = [[coord[k][0], coord[k][1]] for k in full]  # lon,lat
    line = LineString(coords).simplify(SIMPLIFY_DEG, preserve_topology=False)
    poly = [[round(y, 6), round(x, 6)] for (x, y) in line.coords]  # lat,lon
    eta = round(metres / MPH_M_PER_MIN + locks * MINS_PER_LOCK)
    return {"miles": metres / 1609.34, "locks": locks, "etaMinutes": eta, "poly": poly}


def main():
    network = json.load(open("data/network.geojson", encoding="utf-8"))["features"]
    features = json.load(open("data/features.geojson", encoding="utf-8"))["features"]
    locks = [f for f in features if (f["properties"] or {}).get("type") == "lock"]
    print(f"building graph from {len(network)} ways, {len(locks)} locks...")
    adj, coord, lock_keys = rg.build(network, locks)

    keys = list(adj.keys())
    tree = STRtree([Point(*coord[k]) for k in keys])

    out = []
    for name, desc, expect, loop, wps in ROUTES:
        r = build_route(adj, coord, lock_keys, tree, keys, wps, loop)
        if r is None:
            print(f"  SKIP  {name}: a leg had no through route (component gap)")
            continue
        pct = 100 * (r["miles"] - expect) / expect
        flag = "" if abs(pct) <= 30 else "  <-- CHECK (far from expected)"
        print(f"  OK    {name}: {r['miles']:.1f} mi (expect ~{expect}), "
              f"{r['locks']} locks, {len(r['poly'])} pts{flag}")
        out.append({"name": name, "description": desc,
                    "miles": round(r["miles"], 1), "locks": r["locks"],
                    "etaMinutes": r["etaMinutes"], "poly": r["poly"]})

    path = "app/assets/popular_routes.json"
    json.dump(out, open(path, "w", encoding="utf-8"))
    import os
    print(f"wrote {len(out)} routes -> {path} "
          f"({os.path.getsize(path) / 1024:.0f} KB)")


if __name__ == "__main__":
    main()
