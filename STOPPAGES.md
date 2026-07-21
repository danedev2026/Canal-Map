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
3. **Point the app at the file.** In [app/lib/main.dart](app/lib/main.dart) set:
   ```dart
   static const String _stoppagesUrl =
       'https://raw.githubusercontent.com/<you>/<repo>/main/data/stoppages.json';
   ```
   (While this is empty, the app just uses the bundled/cached copy — still
   fully works, shown as "· offline".)

That's it — £0, no server, no database.

## The one unfinished piece

`fetch_crt_notices()` in [build_stoppages.py](build_stoppages.py) currently
returns an empty list. CRT have **no clean public notices API** — the notices
load via an undocumented client-side request, and give locations by *name*,
not coordinates. To finish it:

1. Open <https://canalrivertrust.org.uk/notices> with browser devtools →
   **Network**, and find the request that returns the notice list.
2. Reproduce that request in `fetch_crt_notices()`, mapping each notice to
   `{id, title, type, reason, waterway, start, end}`.
3. `build_stoppages.py` already geocodes by waterway name (via
   `app/assets/search_index.json`) and classifies `state` — no other change
   needed. The `stoppages.json` schema is the stable contract.

Until then, `data/stoppages.json` is seeded with a small **sample** (3 notices
on real in-slice waterways) so the overlay is demoable end-to-end.
