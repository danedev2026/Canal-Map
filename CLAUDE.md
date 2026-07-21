# Canal Map — Project Context

UK canal + navigable-river map for narrowboaters. Beautiful, offline,
free. Personal project. Android first (Google Play), iOS + web later.

## Hard constraints (never violate)
- £0 to run: no always-on server, no paid APIs, no rented database.
- No ads, fully free to users.
- Offline-first: must fully work with zero signal for days.
- Keep the app bundle small (well under Play limits).

## Stack
- Flutter (one codebase → Android now, iOS + web later)
- MapLibre GL (maps, no API key) + PMTiles (offline vector tiles, no server)
- Python for the offline data pipeline

## Data (all free; attribution required for each)
- OpenStreetMap (ODbL) — PRIMARY network geometry: canals + navigable
  rivers, already connected. Backbone for map now, routing later.
- Canal & River Trust Open Data — authoritative facilities/locks on CRT
  waters + official stoppage Notices.
- Environment Agency Open Data (OGL) — river locks/facilities (e.g. Thames).
- Scope of rivers = a curated whitelist of navigable rivers, NOT every
  blue line. Tidal sections flagged as hazardous.

## Architecture rule
Static/serverless. App BUNDLES basemap + features (+ routing graph later)
— these never fetch at runtime. ONLY stoppages.json is fetched (daily,
with offline fallback); the map always renders from local files.

## Working style
Work through PLAN.md in blocks, not all at once:
  - Block A: Phase 1 (data pipeline) alone — verify output before building on it
  - Block B: Phases 2-3 (scaffold + offline map + POIs)
  - Block C: Phases 4-6 (location, search, stoppages)
  - Block D: Phase 7 (polish + release)
Within a block, STOP and summarise after each phase before continuing.
Don't build ahead of the current block. Never add anything requiring a
writable backend (breaks £0).