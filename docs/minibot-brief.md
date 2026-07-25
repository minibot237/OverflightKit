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
- Phase 1 - Unified store + ingest. New schema, collectors write to it,
  migrate the three site DBs in, sites become saved views. Query API skeleton
  (Tailscale-only) with bbox + window queries against the ingest tier.
- Phase 2 - Wide-area sweep. Run the source probes (above), pick adsb.lol
  tiling and/or OpenSky, implement the coarse layer, start archiving CONUS.
  Nightly Parquet compaction to spinning disk; DuckDB query path in the API.
- Phase 3 - Focus lens fleet. Top-X airport list at 10s, budgeted politely
  alongside the sweep.
- Phase 4 - Web time machine UI. Map + scrubber + filters, served by minibot,
  reachable over Tailscale from iPad/Mac. Basemap decision here.
- Phase 5 - Ships. AISStream live collector (kind=vessel) + NOAA historical
  backfill loader. Same store, same viewer.
- Phase 6 - Rail, opportunistic. Amtrak + GTFS-RT adapters where feeds exist.

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

1. Repo access model for minibot: r/w deploy key to brewmium/OverflightKit vs
   minibot owning the repo. (Eric is mulling.)
2. The top-X focus airport list, and X.
3. Hot-window size on SSD; spinning-disk hardware and mount layout.
4. Sweep region scope: CONUS, CONUS + coastal waters, world-someday.
5. Whether the native macOS viewer gains a remote (query-API) mode or stays
   local-DB only until the web UI replaces it for browsing.
