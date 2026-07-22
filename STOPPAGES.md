# Live stoppages (Bucket 2) — setup

The only networked file in the whole app. Everything else is bundled and never
fetched at runtime. If this fetch fails, the map still works — the app falls
back to the last saved copy, then to the bundled `assets/stoppages.json`.

## How it flows

```
GitHub Action (daily cron)
  └─ build_stoppages.py  →  data/stoppages.json  (committed)
       served as a static file (raw GitHub URL or GitHub Pages)
          └─ app fetches on launch, caches, falls back offline
```

## One-time setup

1. **Create a GitHub repo** and push this project to it.
2. The workflow [.github/workflows/update-stoppages.yml](.github/workflows/update-stoppages.yml)
   runs daily at 06:00 UTC (and on-demand from the **Actions** tab via
   *Run workflow*). It rebuilds `data/stoppages.json` and commits it.
   - It needs write permission: repo **Settings → Actions → General →
     Workflow permissions → Read and write permissions**.
3. **Point the app at the file** — already wired in [app/lib/main.dart](app/lib/main.dart):
   ```dart
   static const String _stoppagesUrl =
       'https://raw.githubusercontent.com/danedev2026/Canal-Map/main/data/stoppages.json';
   ```

**Ordering matters:** run the Action **once** (Actions tab → Run workflow) so
the hosted `data/stoppages.json` holds real notices *before* you ship a build
with the URL set. An empty hosted file is a valid 200 and would show "0
notices" until the Action populates it. The bundled snapshot covers offline.

That's it — £0, no server, no database.

## The CRT source (done)

`fetch_crt_notices()` in [build_stoppages.py](build_stoppages.py) calls CRT's
own notices API, reverse-engineered from their React app:

```
GET /api/stoppage/notices?geometry=point&consult=false&start=<today>&end=<+120d>&fields=...
Header: X-Requested-With: XMLHttpRequest   # required, else HTTP 500
```

It returns a **GeoJSON FeatureCollection** — notices already carry coordinates
(no geocoding needed). We keep `state == "Published"` notices, map `typeId` →
marker state (closed / restricted / advisory), drop towpath-only types, and
name `typeId`/`reasonId` via CRT's lookup tables. Typically ~340 nationwide
navigation notices. The bundled `assets/stoppages.json` is a real snapshot for
offline first-run.
