# Canal Map — Project Context

**Canal Map: UK Waterways** — a free, offline map of the UK's connected
navigable network (canals + navigable rivers) for narrowboaters. Personal
project. Android first (in Google Play closed testing); iOS + web possible later.
Package `uk.canalmap.canal_map`.

## Hard constraints (never violate)
- £0 to run: no always-on server, no paid APIs, no rented database.
- No ads, fully free to users. No accounts, no tracking, no analytics.
- Offline-first: must fully work with zero signal for days.
- Keep the app bundle reasonable (well under Play limits).

## Stack
- Flutter (one codebase → Android now, iOS + web later). App in `app/`.
  Flutter SDK is at `~/flutter` (not on PATH) — run `~/flutter/bin/flutter`.
- MapLibre GL (`maplibre_gl`, no API key) + PMTiles (offline vector tiles).
- Python data pipeline in `.venv` (`~/flutter/bin/flutter` aside, use
  `./.venv/Scripts/python.exe`). Deps: requests, shapely, pyproj, geojson,
  mapbox-vector-tile, pmtiles.

## Data (all free; attribution required — see the in-app About screen)
- OpenStreetMap (ODbL) — PRIMARY network geometry (canals + navigable rivers),
  facilities, bridges, place names.
- Canal & River Trust Open Data — authoritative facilities + the live
  stoppages/notices feed (`/api/stoppage/notices`, needs X-Requested-With).
- Environment Agency Open Data (OGL) — river facilities where used.
- **River scope is data-driven:** navigable rivers = OSM `motorboat=yes` (plus
  boat=yes rivers named "* Navigation"). NOT a hand-typed name list (pulled in
  non-navigable same-named rivers) and NOT bare boat=yes (includes canoe rivers
  like the Wye). Tidal sections (OSM `tidal=yes`) are flagged as hazardous.

## Architecture rule
Static/serverless. The app BUNDLES everything and renders from local files:
`basemap.pmtiles` (network + features + places layers), `routing.graph`,
`search_index.json`, font glyphs, and a fallback `stoppages.json`. The ONLY
runtime fetch is the daily `stoppages.json` (served as a static file from the
GitHub repo, refreshed by a GitHub Action), with offline fallback. Never add
anything needing a writable backend (breaks £0).

## Status — through v1.5 COMPLETE (in closed testing)
All of PLAN.md plus many refinements, built and verified on a real S10+ and the
emulator: nationwide offline map, POIs with icons, search + near-me,
GPS/follow-me, live CRT stoppages, tidal hazards, place/bridge/POI labels, and
on-device route planning with lockmile ETAs. Later releases added:
- v1.3 moorings, "Route here", boat log + export, planned-stoppages toggle.
- v1.4 optional online satellite (Esri), detailed journey plan, CSV export.
- v1.5 (current, versionCode 7): light/dark mode + colour themes; save routes
  in-app; descriptive boat log (nearest-place label + editable note) with
  single-entry delete; "Save to device" (SAF) export so files land in Files;
  route GPX now embeds along-route stoppages + a date; component-stitching in
  the routing graph (70.4%→74.3% connected — recovers real <80 m junction gaps
  without inventing water links between genuinely separate navigations);
  Safety & canal-use guide + Terms of use in-app; rate-app + external privacy
  link; interactive desktop map viewer on the GitHub Pages site (docs/map.html).
Signed release bundle builds; released to Play closed testing. See the
auto-memory (MEMORY.md) for detailed state, the signing keystore, and gotchas.

## Working style
- Verify changes on the emulator or the user's S10+ (screenshots) — don't just
  compile. The user tests real builds.
- Data changes go through the pipeline (`phase1_pipeline.py`) so they're
  reproducible; a full nationwide run takes several minutes, so for iteration
  reprocess existing `data/*.geojson` where possible instead of re-fetching.
- After a data change, re-bundle assets into `app/assets/`, rebuild the routing
  graph if the network changed, and bump `version:` in pubspec before any Play
  upload (versionCode must strictly increase).
