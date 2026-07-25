# Session prompt: give OverflightViewer a remote (query-API) mode

STATUS 2026-07-25: DONE. RemoteAPI client in OverflightCore (decode-tested),
mode picker in the site picker, remote windows follow the map viewport +
time window, vessel/train render in the web UI's colors, server health in
the status strip, parcel analytics local-only as specced. Verified live:
SeaTac tracks rendering from :9200. 39 tests green. Kept for reference.

Copy everything below the line into a fresh Claude session running in
`~/workshop/OverflightKit`.

---

Read `docs/minibot-brief.md` start to finish first — it is the working brief
for this repo and explains the whole system. Then do this task:

## Task

Give the native macOS SwiftUI viewer (`Sources/OverflightViewer/`) a
**remote mode** that browses minibot's query API instead of local SQLite
files, per decided open-decision 5 in the brief. Local mode must keep
working exactly as it does today — parcel-study analytics stay local-DB.

## Context you'd otherwise have to rediscover

- The viewer today reads per-site SQLite directly:
  `ViewerModel.swift:241` does `Store(path: site.expandedDbPath, readOnly: true)`.
  There is no HTTP anywhere in the viewer.
- The query API (`Sources/OverflightServer/Server.swift`) runs on minibot at
  `http://127.0.0.1:9200` (binds the Tailscale IP once Tailscale is
  installed; loopback until then). GET-only endpoints:
  - `/api/health` → `{now, firstTs, lastTs, dbBytes, collectors:[{collector,
    lastPollTs, lastError, pollsLastHour, errorsLastHour, vehiclesLastPoll,
    currentSource}]}`
  - `/api/views` → `[{slug, title, lat, lon, radius_nm}]` (the configured sites)
  - `/api/tracks?bbox=latMin,lonMin,latMax,lonMax&from=EPOCH&to=EPOCH`
    `&kinds=aircraft,vessel,train&gap=300&limit=200000` →
    `{from, to, count, truncated, tracks:[{kind, vid, callsign,
    points:[[ts, lat, lon, altFt|null, speedKt|null, heading|null], ...]}]}`
    Window cap 31 days. Marine data wants `gap=1800+` (anchored ships
    report sporadically).
  - `/api/observations` — same params, raw rows, only if you need them.
- The unified store behind the API holds kinds aircraft/vessel/train from:
  3 original sites, 7 East Coast focus airports, a CONUS-wide 60s sweep,
  Amtrak trains, and (once Eric adds an aisstream key) live ships. The
  archive tier (Parquet) is merged in transparently by the server.
- `segmentTracks` in `Sources/OverflightCore/UnifiedStore.swift` is the
  server-side segmentation the API already applies — don't re-segment.

## Shape of the change (guidance, not gospel)

- Introduce a small protocol for what `ViewerModel` needs (sites list +
  observations/tracks for a window), with the existing local `Store` path
  and a new `RemoteAPI` implementation behind it.
- Add a mode picker in the UI: "Local DBs" / "Remote (minibot)" with a
  server URL field, default `http://127.0.0.1:9200`, persisted in
  `ViewState` like the other remembered settings.
- Remote sites come from `/api/views`; tracks from `/api/tracks` with the
  map's bbox and the viewer's time window. New kinds (vessel/train) should
  at minimum not break rendering; distinct colors are a nice-to-have.
- Parcel analytics/histograms (`Analysis`, `Report`, `Charts`) stay
  local-mode-only for now — grey them out or hide them in remote mode.
- The API is GET/JSON only, no auth (Tailscale is the perimeter).

## House rules (from the brief + CLAUDE.md)

- Casual commit messages, small commits, push to main freely.
- Tab indentation in Swift sources; match existing code style.
- Timestamps shown to the user: US Pacific, never UTC.
- Verify First: exercise the real API on this machine before/after coding
  (`curl http://127.0.0.1:9200/api/health` etc. — the server is running).
- `swift test` must stay green (32 tests). Add tests for anything testable
  without a GUI (e.g. JSON decoding of the API shapes).
- NEVER `cp` over a running binary — install scripts `rm` first; if you
  touch install scripts keep that pattern.
- The 12 collector LaunchAgents and the server are live on this machine —
  don't break the running system; `scripts/install-server.sh` restarts the
  server safely if you change it.

## Done means

`swift run OverflightViewer`, flip to Remote mode, and watch SeaTac (or the
CONUS sweep area) render tracks fetched from `http://127.0.0.1:9200` — then
update the brief's decision-5 line and this file's status, commit, push.
