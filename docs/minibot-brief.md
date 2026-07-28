# Minibot Brief: Traffic Time Machine

Written 2026-07-25. This file is the working brief for the Claude agent operating
on minibot. Read it start to finish before building anything. It captures what
exists today, what is decided, what must be verified live before it is built
against, and what is still Eric's call. Treat the "Verified facts" section as
hard-won knowledge - do not re-derive it, and extend it when you verify more.

## Mission

Turn OverflightKit from a single-purpose parcel sampler into a traffic time
machine. minibot (always-on Mac; ~1TB SSD mostly free; spinning-disk archive to
be added) continuously collects moving-vehicle observations - aircraft first,
ships next, trains where feasible - into one unified archive, and serves a query
API so any Tailscale-connected device (Mac, iPad, anything) can pan a map across
the covered region, scrub a time window, and watch what moved there.

The differentiator is the archive. Live-anywhere views already exist on the
aggregators' own sites; nobody gives away "what flew over Denver last Tuesday
between 6 and 9am." We build that. A thin "now" view rides on top later.

## What exists today (2026-07-23 build, running on Eric's desktop)

- OverflightCore: SQLite (WAL, C API) append-only store - poll, observation,
  metar tables; track segmentation at >300s gaps; point-in-cylinder overflight
  test; hour/altitude-band histograms; coverage diagnostic; METAR-corrected AGL
  with per-observation altitude-source labels.
- OverflightCollector: 10s +/-1s poller, one LaunchAgent + one DB per site,
  adsb.lol primary -> airplanes.live failover with primary re-probe, backoff cap
  5m, per-slug phase stagger, Retry-After honored.
- OverflightViewer: native macOS SwiftUI/MapKit - satellite map, band-colored
  track lines, identity-colored course arrows, Active-now panel, parcel +
  histograms, per-site remembered view state.
- Three sites collecting since 07-23: kgmj (Grove OK - the original parcel
  study), toledowa (KTDO), seatacwa (KSEA - the stress test, ~50 aircraft/poll,
  ~30MB/day raw). 23 tests green.

Observed load reality (~48h, ~14k polls/site): ~72% answered by adsb.lol
directly, ~20% served by the airplanes.live failover, ~4-5% of adsb.lol attempts
bounced 429/420 in bursts. Zero data loss, but the polite per-IP ceiling on
adsb.lol is near at 0.3 req/s. Scaling means fewer, bigger requests - never more
small ones.

## Decided architecture

### Storage: two tiers, one schema, no per-site DBs

Per-site DBs are retired. Wide-area collection is not site-shaped.

- Ingest tier (SSD): one SQLite store all collectors append to. The existing
  append-only observation schema, generalized: kind (aircraft/vessel/train),
  id (icao hex / MMSI / train id), ts, lat, lon, alt + alt source (null for
  surface movers), speed, heading, source, geohash. Poll/health table stays -
  it is the uptime and backpressure evidence. Holds a hot window (~30 days,
  Eric to confirm).
- Archive tier (spinning disk): nightly compaction to Parquet, partitioned by
  date + geo bucket, compressed (zstd). DuckDB queries the files in place.
  Ballpark: a CONUS sweep at 60s cadence lands around a few hundred MB/day in
  Parquet, order 100GB/year. Ships add more; multi-TB spinning covers years.
- Sites become bookmarks, not storage. A "site" is a saved view/analysis
  (point + radius + optional parcel cylinder + labels) executed as a query over
  the archive. KGMJ's parcel analytics become a saved query runnable against
  any location and any time window. Migrate the three existing site DBs into
  the unified store; nothing is thrown away.

### Collection: two resolution layers

- Wide sweep (coarse): large-radius circles tiling the target region, polled at
  30-60s. CONUS tiles into roughly 15-25 circles at ~250nm radius; at 60s that
  is about the same request rate as today's three sites at 10s. This is the
  surfable archive. Cruise-flight tracks interpolate fine at 60s; what coarse
  cadence loses is terminal-area maneuvering shape - which is what the next
  layer is for.
- Focus lens (fine): the current 10s small-radius collector, pointed at a
  curated list of interesting places - the top-X busy airports (Eric picks the
  list; SeaTac proved the fun, East Coast majors are wanted - think KJFK, KLGA,
  KEWR, KBOS, KPHL, KDCA, KATL as candidates) plus study parcels like KGMJ.
  Budget focus sites against the same politeness ceiling; they are the
  request-rate spenders.

Resolution follows purpose. Do not chase one global number.

### Access: minibot serves, everything else browses

- A small query API on minibot, Tailscale-only: tracks/observations for a bbox
  + time window + kind filters, plus saved-view (site) queries.
- A web UI served by minibot: map, time-window scrubber, kind/altitude filters.
  Web because iPad is a requirement - the SwiftUI viewer cannot go there. The
  native macOS viewer keeps working for parcel-study work until the web UI
  earns its keep.
- Basemap for the web UI needs its own decision (tile licensing / self-hosted
  tiles, e.g. Protomaps on the spinning disk) - resolve during Phase 4.

## Verified facts (live-wire, 2026-07-23/25) - extend, do not re-derive

- adsb.lol: ADSBExchange-v2 envelope {ac, msg, now(ms), total, ctime, ptime}.
  No key, no documented cap; throttles per-IP dynamically (429 and 420,
  sometimes with Retry-After). alt_baro is a number (ft) OR the literal string
  "ground". flight is space-padded, often absent on GA; squawk is a string with
  leading zeros; seen_pos is seconds since last position.
- airplanes.live: same envelope plus enrichment (desc, ownOp, year). Hard limit
  1 req/s per IP - documented. This is the failover budget ceiling.
- aviationweather.gov METAR JSON: altim is hPa (not inHg), obsTime is epoch
  seconds, elev is meters. bbox= search finds nearest reporting station.
  Station catalog presence is NOT reporting (KTDO is cataloged, silent) -
  always verify with a real metar query. inHg = hPa * 0.0295300.
- OurAirports CSV is the coordinate/elevation fallback for non-reporting
  fields.
- N collectors on one IP polling in phase stampede the aggregator -
  deterministic per-slug phase offset (stable hash, never String.hashValue)
  spreads them.
- adsb.lol /v2/point radius is NOT capped at 250nm (2026-07-25, exercised
  live): 250nm -> 329 ac / 168KB / 1.1s; 500 -> 1468 / 747KB / 1.4s;
  1000 -> 4313 / 2.2MB / 1.8s; 1300 (covers CONUS from 39.5,-98.35) ->
  6324 ac / 3.2MB / 1.9s. No truncation at any size (total == len(ac)),
  msg "No error". One CONUS request per 60s tick is the whole sweep.
- airplanes.live /v2/point hard-caps radius: 250nm OK (334 ac / 192KB),
  500nm+ -> HTTP 403 openresty HTML (2026-07-25). Failover sweep must tile
  at 250nm (~20 tiles for CONUS) under the documented 1 req/s.
- OpenSky (2026-07-25, exercised): anonymous CONUS bbox in one request -
  5929 states / 790KB / 1.4s. Anonymous = 400 credits/day, >400 sq-deg
  bbox costs 4 credits -> 100 CONUS snapshots/day (~15min cadence).
  Registered = OAuth2 client-credentials ONLY (no basic auth), 30-min
  tokens, 4000 credits/day. Good supplement, not primary.
- Amtrak via api-v3.amtraker.com/v3/trains (2026-07-25, exercised): no key,
  190 trains, 1.2MB, 375ms. Dict keyed by trainNum -> ARRAY of runs; fields
  lat, lon, heading (compass string like "N"), velocity, trainID, routeName,
  lastValTS. Attribution requested. /v3/stale reports feed freshness.
- AISStream.io (docs fetched 2026-07-25): wss://stream.aisstream.io/v0/stream,
  free API key (signup required - Eric), subscription JSON must be sent
  within 3s of connect: {APIKey, BoundingBoxes: [[[lat,lon],[lat,lon]]],
  FilterMessageTypes: ["PositionReport"]}. Beta, no SLA. Keys server-side.
- NOAA MarineCadastre (2026-07-25, header-verified live): 2025+ files at
  coast.noaa.gov/htdata/CMSP/AISDataHandler/2025/ais-2025-MM-DD.csv.zst
  (~220MB/day, zstd). Columns (lon BEFORE lat, lowercase): mmsi,
  base_date_time, longitude, latitude, sog, cog, heading, vessel_name, imo,
  call_sign, vessel_type, status, length, width, draft, cargo, transceiver.
  2024-and-earlier era: AIS_YYYY_MM_DD.zip (~324MB/day), Capitalized
  columns, LAT before LON, T-separated timestamps. No auth either era.
- GTFS-RT keyless VehiclePositions verified reachable: MBTA
  cdn.mbta.com/realtime/VehiclePositions.pb (incl. commuter rail); MTA LIRR
  api-endpoint.mta.info/Dataservice/mtagtfsfeeds/lirr%2Fgtfs-lirr (keep the
  %2F encoded). NYC subway feeds carry stop-relative positions, not GPS.

## Must verify before building (Verify First - probe the live wire, then code)

1. adsb.lol maximum radius per request (believed ~250nm) and behavior with
   1,000+ aircraft responses: payload size, latency, truncation, throttle
   response. Run a one-day probe at candidate sweep geometry before committing
   to the tiling.
2. OpenSky Network as an alternative/supplemental wide-area source: current
   API terms, anonymous vs registered rate limits, bbox snapshot cost. It may
   be the sanctioned way to sweep CONUS in one request.
3. AISStream.io: free API key, websocket subscription model, bbox filters,
   sustained-connection behavior. NOAA MarineCadastre historical AIS format and
   volumes for backfill.
4. Rail feeds: Amtrak tracker JSON, GTFS-RT agencies worth adapting, UK Network
   Rail feeds. US freight is essentially invisible - do not chase it.

Record every verified fact back into this file (or the memory scope) with date.

## Phases

- Phase 0 - Move current collection to minibot as-is. Install the three
  existing site agents (or the surviving set; seatacwa becomes a focus site
  anyway) on minibot from this repo. Proves the ops story. Desktop collectors
  get retired once minibot's are confirmed healthy.
  STATUS 2026-07-25: running on minibot. Three agents installed (kgmj,
  toledowa, seatacwa), fresh DBs, first polls healthy - seatacwa at ~50
  aircraft/poll as expected, kgmj quiet. toledowa METAR = KKLS (verified
  live: only reporting station in the bbox, even KCLS silent). KGMJ verified
  reporting. Desktop retirement pending Eric's confirmation after soak.
- Phase 1 - Unified store + ingest. New schema, collectors write to it,
  migrate the three site DBs in, sites become saved views. Query API skeleton
  (Tailscale-only) with bbox + window queries against the ingest tier.
  STATUS 2026-07-25: DONE. UnifiedStore (kind/vid/geohash schema) in core,
  site collectors dual-write (site DBs stay for the native viewer), all
  three site DBs migrated, OverflightServer on :9200 with /api/health,
  /api/views, /api/tracks, /api/observations.
- Phase 2 - Wide-area sweep. Run the source probes (above), pick adsb.lol
  tiling and/or OpenSky, implement the coarse layer, start archiving CONUS.
  Nightly Parquet compaction to spinning disk; DuckDB query path in the API.
  STATUS 2026-07-25: DONE and running. Probes found adsb.lol has NO radius
  cap - the sweep is ONE 1300nm request/60s (~6.3k aircraft/tick), tiling
  only exists as the airplanes.live failover (250nm hard cap there).
  Compaction nightly 03:30 Pacific to zstd Parquet (date + 2-char geohash
  partitions), verify-then-prune, archive on SSD until spinning disk.
  API transparently merges archive rows via duckdb.
- Phase 3 - Focus lens fleet. Top-X airport list at 10s, budgeted politely
  alongside the sweep.
  STATUS 2026-07-25: DONE. Per-site source/interval overrides; the 7 East
  Coast candidates (KJFK KLGA KEWR KBOS KPHL KDCA KATL) run at 12s against
  airplanes.live's documented 1 req/s budget (0.58 req/s), leaving adsb.lol
  load unchanged. List is still Eric's to trim.
- Phase 4 - Web time machine UI. Map + scrubber + filters, served by minibot,
  reachable over Tailscale from iPad/Mac. Basemap decision here.
  STATUS 2026-07-25: DONE (v1). Single-file web/index.html at /: Leaflet +
  OSM raster (basemap decision still open - Protomaps self-host is the
  candidate), date/time pickers, presets, play/scrub with interpolated
  dots + 30min comet trails, altitude-band colors, kind filters, health
  footer. Tailscale not yet on minibot, so the server binds loopback.
- Phase 5 - Ships. AISStream live collector (kind=vessel) + NOAA historical
  backfill loader. Same store, same viewer.
  STATUS 2026-07-25: LIVE. Eric supplied the aisstream key; ais agent
  running across the CONUS-coasts bbox. Per Eric (beta service, ship
  speeds): MovementGate per vessel — floor 30s between kept points (fast
  movers get fine cadence), keep on >=100m of movement, 10min keepalive
  stamp for anchored ships so they stay present in windows. All knobs in
  config: ais.min_interval_s / min_move_m / stamp_interval_s. Reconnects
  back off to 5m. NOAA backfill proven and in use: 2025-01-01 plus
  2025-12-25..31 loaded (~59M rows, Eric's Algiers Point request —
  aisstream's NOLA volunteer receiver only feeds ~3-8am CT, NOAA-era
  archive fills the gap). NOAA publishes ~7 months behind; no 2026 files
  yet as of 2026-07-28. Marine queries want &gap=1800+; a full day of a
  busy riverfront bbox hits the 200k row cap — shorter windows for full
  fidelity.
- Phase 6 - Rail, opportunistic. Amtrak + GTFS-RT adapters where feeds exist.
  STATUS 2026-07-25: Amtrak DONE and running (Amtraker, 60s, kind=train,
  ~57 trains/poll incl. VIA). MovementGate on writes (rail.min_move_m 25m,
  stamp_interval_s 600) kills station-dwell and stale-fix duplicates — the
  feed repeats a train's last position until its tracker updates. Known
  limit: track-shape "triangles" on curvy lines are source resolution
  (fixes arrive ~1/min), not poll cadence; map-matching to rail lines is
  the someday fix. GTFS-RT adapters not built; MBTA and MTA LIRR verified
  keyless if ever wanted.

Phases land in order but need not be fully sequential - e.g. ship probes can
run during Phase 2. Keep commits small and pushed; Eric and desktop sessions
follow along by pulling.

## Operating rules on minibot

- Politeness first: honor Retry-After, keep phase stagger, prefer fewer bigger
  requests, back off on sustained throttling. Never scrape aggregator map
  front-ends. If rate limits genuinely bind, the escape valve is a tiny cloud
  relay with its own IP that batches and compresses for minibot to pull -
  designed, not improvised; Eric approves first.
- Verify First: read the live wire before coding against any surface; label
  every "verified" claim with what was actually exercised.
- Storage discipline: SSD is ingest + hot window; spinning disk is archive.
  Nothing irreplaceable lives only on SSD after compaction runs exist.
- Repo conventions: minibot's house style now that minibot owns the repo -
  casual commit messages, Co-Authored-By trailers fine. Keep tab indentation
  in existing Swift sources for diff hygiene.
- This is Eric's data hobby, not production SaaS. Bias to simple, observable,
  restartable processes (LaunchAgents, SQLite, files) over infrastructure.

## Open decisions (Eric's - ask, do not assume)

1. RESOLVED 2026-07-25: minibot owns the repo (github.com/minibot237/OverflightKit).
2. The top-X focus airport list, and X. (East Coast 7 running as placeholder.)
3. Hot-window size on SSD (30d placeholder); spinning-disk hardware and mount.
4. Sweep region scope: CONUS, CONUS + coastal waters, world-someday.
5. DONE 2026-07-25: the native viewer has a remote (query-API) mode. Mode
   picker in the site picker (Local DBs / Remote (minibot), URL remembered),
   remote sites from /api/views, tracks from /api/tracks following the map
   viewport + time window, vessel/train kinds render in the web UI's colors,
   status strip shows server health. Parcel analytics stay local-mode.
   Verified live against :9200 (SeaTac tracks + Amtrak Cascades). 39 tests.
   `swift run OverflightViewer --remote [slug]` jumps straight in.

## Placeholders awaiting Eric (as of 2026-07-25 free-run)

- Tailscale on minibot (server binds loopback until then)
- Spinning disk -> archive_dir + ARCHIVE_DIR for install-compact.sh
- kgmj parcel still repo-example coords (airport center, 400m)
- Basemap licensing (OSM raster placeholder, Protomaps candidate)
- Desktop collector retirement after soak
