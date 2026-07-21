# Canal Map — Build Plan

## Goal
A beautiful, offline-first map of the UK's connected navigable network
— canals AND the navigable rivers narrowboats actually cruise (Thames,
Wey, Nene, Great Ouse, Trent, Severn, Avon, etc.).
Android first (Google Play), iOS + web later. Personal project.

## Hard constraints (do not violate)
- **£0 to run.** No always-on server, no paid APIs, no rented database.
- **No ads. Fully free to users.**
- **Offline-first.** Must fully work with zero signal for days.
- Keep the app bundle well under Google Play limits.

## Stack
- **Flutter** (single codebase → Android now, iOS + web later)
- **MapLibre GL** for rendering (free, no API key)
- **PMTiles** for vector tiles (single static file, no tile server)
- **Python** for the offline data pipeline (Shapely, pyproj, tippecanoe)
- Static hosting on Cloudflare Pages/R2 or GitHub for the one live file

## Data sources (all free; attribution required for each)
- **OpenStreetMap (ODbL) — PRIMARY network geometry.** Canals + navigable
  rivers in one already-connected dataset. Backbone for the basemap now
  and the routing graph later. Avoids stitching multiple agency datasets.
- **Canal & River Trust Open Data** (ArcGIS portal) — authoritative
  facilities/locks on CRT waters, plus the official **Notices** feed for
  stoppages/closures.
- **Environment Agency Open Data (OGL)** — river locks/facilities on
  EA-managed navigations (e.g. non-tidal Thames).
- Include an in-app **Attribution** screen crediting OSM, CRT and EA.

### River scope rules
- Rivers = a **curated whitelist** of navigable rivers, NOT every blue
  line OSM contains (canoe-only/size-limited waters are excluded).
- **Flag tidal sections** (tidal Thames, tidal Trent, Severn estuary) as
  hazardous — navigable but need prep/licences/timing; don't render them
  as an ordinary cut.

## Architecture — the two-bucket model
- **Bucket 1 — bundled in the app, never fetched at runtime:**
  `basemap.pmtiles`, `features.geojson`, (later) `routing.graph`.
  Lives in app storage; the OS will not evict it. Updated via app
  releases (a few times a year).
- **Bucket 2 — cached with fallback, the only networked data:**
  `stoppages.json`. On launch, try to fetch; on success overwrite the
  local copy; on failure use the last saved copy. The map ALWAYS renders
  from local files — network is only ever a background top-up and never
  blocks the UI. Show a "notices updated N days ago" indicator.

## Build order

### Phase 1 — Data pipeline (Python, offline)
Start with a SMALL slice (e.g. Thames + one canal region) to get the
whole pipeline working end-to-end, then widen to nationwide.
1. Pull network geometry from **OSM** (Overpass): all canals + the
   whitelisted navigable rivers. This is the backbone.
2. Pull feature points from OSM (locks, water points, sanitary, moorings,
   pubs) — unified across canals and rivers.
3. Enrich facilities with **CRT open data** (and **EA** for rivers) where
   available — better attributes/status than OSM alone.
4. Clip everything to a buffer (~150 m) around the network.
5. Build `basemap.pmtiles` with tippecanoe (vector, max zoom ~z16).
6. Emit `features.geojson` (typed points: lock, bridge, water_point,
   elsan, pumpout, mooring, boatyard, pub, tidal_warning, ...).
Deliverable: the static asset files.

### Phase 2 — App scaffold + offline map
1. Flutter skeleton, MapLibre integrated.
2. On first run, copy `basemap.pmtiles` from assets into the app
   documents dir (PMTiles needs byte-range reads; path via
   path_provider), then point MapLibre at the local file.
3. Verify pan/zoom in airplane mode.
Deliverable: a pannable, fully-offline map of the network.

### Phase 3 — POI layer
1. Load `features.geojson`, render points styled by type with clear icons.
2. Tap a feature → info sheet (name, type, details).
Deliverable: map with all boater features, tappable.

### Phase 4 — Location
GPS dot, follow-me, permissions. Must work offline.

### Phase 5 — Search + near-me
Client-side only: search waterways/places; "near me" = distance filter
over the in-memory features. No database.

### Phase 6 — Live stoppages
1. GitHub Action (cron, daily) fetches CRT Notices → writes
   `stoppages.json` to static hosting.
2. App fetch-with-fallback per the two-bucket model; overlay closures;
   show freshness indicator.
Deliverable: shippable v1.

### Phase 7 — Polish + release
Cartography pass, icon set, offline/empty states, tidal-hazard styling,
attribution screen. Release to Google Play via internal testing first.

## Explicitly NOT in v1 (do not build yet)
- Route planning / journey-time estimates (this is v1.1).
- Crowdsourced / user-submitted data (needs a writable backend — breaks £0).
- Accounts, boat profile, logbook.
- iOS build, web build (Flutter supports both later; not now).
- Full Broads / obscure disconnected waterways (curated whitelist only).

## v1.1 — Routing (fast-follow, still £0, all on-device)
The effort spike is DATA, not runtime.
1. Build a routable graph from the OSM network (already node-connected):
   nodes at junctions, edges carrying length.
2. "Node" the network — snap near-but-unconnected endpoints, split lines
   at crossings, so junctions are truly shared nodes. The unpredictable
   part; river/canal joins need checking.
3. Snap each lock onto its edge and split there → locks become nodes so
   routes can count them.
4. Serialise a compact graph; bundle it in the app.
5. On-device Dijkstra/A*. Time estimate via the lockmile heuristic:
   minutes ≈ miles × (60 / ~3mph) + locks × mins-per-lock (tunable).
   Add extra time weighting for tidal sections.