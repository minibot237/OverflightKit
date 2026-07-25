# OverflightKit

A macOS toolkit that answers one question about a specific parcel of land:

> **How often does aircraft traffic pass over it, at what altitude, and at what
> times of day?**

A headless collector samples free ADS-B aggregator APIs around a fixed point
every 10 seconds and appends every observation to SQLite. A SwiftUI viewer
opens the same database read-only and shows track polylines on a satellite map,
identity-colored arrows on currently-active aircraft, a draggable parcel marker
with a radius ring, and hour-of-day / altitude-band histograms that recompute
live. Multiple sites are supported — each gets its own collector agent and
database, and each viewer window binds to one site (new sites autofill from an
ICAO identifier via the station's METAR). The default configuration targets
Grove Regional Airport (KGMJ), Grove, Oklahoma.

No third-party dependencies: SQLite via the C API, URLSession, SwiftUI +
MapKit. Swift 6, macOS 14+, strict concurrency.

## Quick start

```sh
swift test                      # unit tests
swift run OverflightCollector --once     # single poll, prints what it saw
scripts/install-agent.sh        # build release + install a LaunchAgent per site
tail -f ~/.overflight/log/kgmj.log

swift run OverflightViewer      # the map + histograms viewer
scripts/make-viewer-app.sh      # or wrap the viewer in a proper .app bundle

~/.overflight/bin/OverflightCollector --list-sites
~/.overflight/bin/OverflightCollector --report --site kgmj            # all data
~/.overflight/bin/OverflightCollector --report --site kgmj --days 7   # last week
scripts/uninstall-agent.sh      # stop all agents (data stays)
```

The collector and viewer are independent; the database is opened in WAL mode
so both run concurrently. The viewer never writes the database.

## Configuration — `~/.overflight/config.json`

Created with KGMJ defaults on first run. Global keys plus a `sites` array
(see `config.example.json`); a legacy single-site file is migrated
automatically:

| Key | Default | Meaning |
|---|---|---|
| `poll_interval_s` | 10 | Poll cadence (±1 s jitter is added) |
| `primary_source` | `adsb.lol` | Primary aggregator |
| `fallback_source` | `airplanes.live` | Used after 3 consecutive primary failures |
| `sites[].slug` | — | Key for `--site`, agent label, default db filename |
| `sites[].icao`, `display_name` | — | Title-bar identity ("KGMJ — Grove Muni, OK") |
| `sites[].lat`, `lon` | — | Query center |
| `sites[].field_elevation_ft` | 0 | Field elevation MSL, for AGL math |
| `sites[].radius_nm` | 15 | Collection radius around the site |
| `sites[].parcel` | site center, 400 m | Overflight cylinder (centroid + radius_m) |
| `sites[].db_path` | `~/.overflight/<slug>.db` | Per-site SQLite database |
| `sites[].metar_station` | icao | Station for hourly altimeter fetches |
| `sites[].timezone` | `America/Chicago` | Local time for the hour histogram |

Source names can also be a full base URL of any ADSBExchange-v2-compatible API
(`https://host` serving `/v2/point/{lat}/{lon}/{radius_nm}`).

Each collector process serves one site (`--site <slug>`, defaulting to the
first), and `scripts/install-agent.sh` installs one LaunchAgent per site. In
the viewer, every window starts at a site picker — picking a site another
window already shows gives you a clone — and "Add site" autofills coordinates,
elevation, and name from an ICAO identifier. Parcel edits (drag, radius)
save back to the config automatically; "Reset to defaults" restores the site
center and a 400 m radius.

## Sampling behavior

- Poll every 10 s with ±1 s jitter (minute-level sampling aliases pattern
  traffic badly — a 100 kt aircraft covers ~1.7 nm/min).
- Exponential backoff on any failure, capped at 5 minutes. Intermittent 4xx
  from adsb.lol is dynamic rate limiting — treated as backpressure, not a bug.
- After 3 consecutive primary failures the collector switches to the fallback,
  then re-probes the primary every ~30 polls and switches back when it recovers.
- The delay never drops below 1 s (airplanes.live hard limit is 1 req/s).
- The KGMJ altimeter setting is fetched hourly from aviationweather.gov and
  stored, so barometric altitudes can be corrected with the pressure that was
  in effect at observation time.

## Schema

Append-only. Nothing is deduplicated, smoothed, or assembled into tracks at
ingest — segmentation happens at query time. Raw observations are cheap;
irreversible decisions are not.

```sql
-- one row per poll attempt, INCLUDING failures and zero-aircraft polls
CREATE TABLE poll (
  id            INTEGER PRIMARY KEY,
  ts            INTEGER NOT NULL,      -- unix epoch, UTC
  source        TEXT    NOT NULL,      -- 'adsb.lol' | 'airplanes.live'
  http_status   INTEGER,               -- NULL on transport failure
  error         TEXT,
  aircraft_count INTEGER NOT NULL DEFAULT 0,
  latency_ms    INTEGER
);

-- one row per aircraft per poll (aircraft without a position are counted in
-- aircraft_count but produce no observation row)
CREATE TABLE observation (
  id          INTEGER PRIMARY KEY,
  poll_id     INTEGER NOT NULL REFERENCES poll(id),
  ts          INTEGER NOT NULL,        -- poll ts, denormalized
  hex         TEXT    NOT NULL,        -- 24-bit ICAO address
  flight      TEXT,                    -- callsign, trimmed
  reg         TEXT,
  type_code   TEXT,
  lat         REAL    NOT NULL,
  lon         REAL    NOT NULL,
  alt_baro_ft INTEGER,                 -- NULL when on ground
  on_ground   INTEGER NOT NULL DEFAULT 0,
  alt_geom_ft INTEGER,                 -- GNSS altitude when broadcast
  gs_kt       REAL,
  track_deg   REAL,
  baro_rate   INTEGER,
  squawk      TEXT,                    -- leading zeros preserved
  seen_pos    REAL,                    -- position age at poll time, seconds
  rssi        REAL
);

-- altimeter settings for baro correction, fetched hourly
CREATE TABLE metar (
  id        INTEGER PRIMARY KEY,
  ts        INTEGER NOT NULL,          -- METAR obsTime, unix epoch
  station   TEXT    NOT NULL,
  altim_hpa REAL,
  raw       TEXT
);
```

**The `poll` table is the point.** A row exists for every attempt — including
empty and failed ones — so "no aircraft were overhead" is distinguishable from
"the collector was down" and "the API was refusing requests." The viewer's
status strip and the `--report` collector section are derived entirely from it.

## The altitude caveat

`alt_baro` is uncorrected pressure altitude referenced to 29.92 inHg. Actual
error runs to several hundred feet in non-standard pressure. OverflightKit
handles it explicitly:

1. **GNSS preferred.** When `alt_geom` is present:
   `AGL = alt_geom − field_elevation`.
2. **Corrected baro next.** Otherwise, if a stored altimeter setting exists
   within ±3 h of the observation:
   `AGL = alt_baro + (altim_inHg − 29.92) × 1000 − field_elevation`.
   The correction uses the METAR nearest the observation's own timestamp, not
   the current one.
3. **Uncorrected baro last**, labeled as such.

Every displayed altitude carries its source — `GNSS`, `baro, corrected`, or
`baro, uncorrected` — in the report, the coverage panel, and each overflight
row. A corrected and an uncorrected altitude are never presented as
equivalent.

## Coverage diagnostic

Rural ADS-B coverage at pattern altitude is not a given. The report and viewer
compute the fraction of airborne observations below 2,000 ft AGL and the
minimum observed AGL within 5 nm of the field. If nothing below 2,000 ft AGL
ever appears, both say so loudly: the dataset cannot answer the overflight
question at pattern altitudes, and no amount of histogram is going to fix that.

## Analysis definitions

- **Track**: observations for one `hex`, split wherever the gap between
  consecutive observations exceeds 300 s.
- **Overflight**: a track with ≥1 airborne observation inside the cylinder
  (parcel centroid + radius). Ground traffic never qualifies. Reported with
  closest-approach distance and the altitude + source at closest approach.
- **Histograms**: overflight counts by local hour of day (at closest approach)
  and by AGL band at closest approach: `<1000`, `1000–2000`, `2000–5000`,
  `5000–10000`, `>10000` ft.

## Data sources

- [adsb.lol](https://adsb.lol) — aircraft, primary. Open data, ODbL licensed,
  no key.
- [airplanes.live](https://airplanes.live) — aircraft, fallback + focus
  fleet. Personal, non-commercial use; hard limit 1 request/second.
- [aviationweather.gov](https://aviationweather.gov) — hourly METAR for the
  altimeter setting.
- [Amtraker](https://github.com/piemadd/amtrak) — train positions
  (Amtrak + VIA). Community API over Amtrak's own Track-a-Train data;
  attribution requested and hereby given. Polled once a minute.
- [aisstream.io](https://aisstream.io) — live ship positions (websocket,
  free key required; beta, no SLA).
- [NOAA MarineCadastre](https://hub.marinecadastre.gov) — historical ship
  traffic backfill, public bulk downloads.

This project only reads from these services, at a gentle rate, and feeds
nothing back. Aircraft-owner identification and route inference are
explicitly out of scope.

## License

Minibot License — free for personal, educational, and non-commercial
use; see [LICENSE.md](LICENSE.md).
