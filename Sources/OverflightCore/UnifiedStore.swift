import Foundation

/// What kind of mover an observation describes. The string raw values are
/// what lands in the database and the query API.
public enum VehicleKind: String, Sendable, CaseIterable, Codable {
	case aircraft
	case vessel
	case train
}

/// One position report in the unified schema: any mover, any source.
/// `vid` is the vehicle identity — icao hex for aircraft, MMSI for vessels,
/// train id for trains. Altitude is nil for surface movers; `altSrc` labels
/// where a non-nil altitude came from ("baro"/"geom") or "ground".
public struct UnifiedObservation: Sendable, Equatable {
	public var id: Int64
	public var kind: VehicleKind
	public var vid: String
	public var ts: Int64
	public var lat: Double
	public var lon: Double
	public var altFt: Double?
	public var altSrc: String?
	public var speedKt: Double?
	public var headingDeg: Double?
	public var callsign: String?
	public var source: String
	public var geohash: String

	public init(
		id: Int64 = 0, kind: VehicleKind, vid: String, ts: Int64,
		lat: Double, lon: Double, altFt: Double? = nil, altSrc: String? = nil,
		speedKt: Double? = nil, headingDeg: Double? = nil, callsign: String? = nil,
		source: String, geohash: String? = nil
	) {
		self.id = id
		self.kind = kind
		self.vid = vid
		self.ts = ts
		self.lat = lat
		self.lon = lon
		self.altFt = altFt
		self.altSrc = altSrc
		self.speedKt = speedKt
		self.headingDeg = headingDeg
		self.callsign = callsign
		self.source = source
		self.geohash = geohash ?? Geohash.encode(lat: lat, lon: lon)
	}

	/// Map an ADSBExchange-v2 aircraft into the unified shape.
	public init(aircraft a: Aircraft, ts: Int64, source: String) {
		var altFt: Double?
		var altSrc: String?
		switch a.altBaro {
		case .ground:
			altSrc = "ground"
		case .feet(let ft):
			altFt = Double(ft)
			altSrc = "baro"
		case nil:
			if let geom = a.altGeomFt {
				altFt = Double(geom)
				altSrc = "geom"
			}
		}
		self.init(
			kind: .aircraft, vid: a.hex, ts: ts,
			lat: a.lat ?? 0, lon: a.lon ?? 0,
			altFt: altFt, altSrc: altSrc,
			speedKt: a.groundSpeedKt, headingDeg: a.trackDeg,
			callsign: a.flight ?? a.registration,
			source: source
		)
	}
}

/// A contiguous run of one vehicle's observations — the query API's unit of
/// answer. Split whenever the gap between consecutive points exceeds `gapS`
/// (same 300s rule the parcel analytics use).
public struct UnifiedTrack: Sendable {
	public var kind: VehicleKind
	public var vid: String
	public var callsign: String?
	public var points: [UnifiedObservation]
}

/// Group bbox-query results (already ordered kind, vid, ts) into tracks.
public func segmentTracks(_ observations: [UnifiedObservation], gapS: Int64 = 300) -> [UnifiedTrack] {
	var out: [UnifiedTrack] = []
	var current: [UnifiedObservation] = []
	func flush() {
		guard let first = current.first else { return }
		out.append(UnifiedTrack(
			kind: first.kind, vid: first.vid,
			callsign: current.compactMap(\.callsign).last,
			points: current))
		current = []
	}
	for o in observations {
		if let last = current.last,
			last.vid != o.vid || last.kind != o.kind || o.ts - last.ts > gapS {
			flush()
		}
		current.append(o)
	}
	flush()
	return out
}

/// Per-collector health, straight off the unified poll table.
public struct CollectorHealth: Sendable, Codable {
	public var collector: String
	public var lastPollTs: Int64
	public var lastError: String?
	public var pollsLastHour: Int
	public var errorsLastHour: Int
	public var vehiclesLastPoll: Int
	public var currentSource: String
}

/// The unified two-tier ingest store: every collector appends here, the
/// nightly compactor drains rows older than the hot window to Parquet.
/// Same append-only discipline as the per-site `Store`, generalized to
/// any mover kind. Sites become saved views over this data, not databases.
public actor UnifiedStore {
	private let db: Database
	public let path: String

	public static let defaultPath = "~/.overflight/unified.db"

	public init(path: String, readOnly: Bool = false) throws {
		self.path = path
		db = try Database(path: path, readOnly: readOnly)
		try db.exec("PRAGMA busy_timeout=10000;")
		if !readOnly {
			try db.exec("PRAGMA journal_mode=WAL;")
			try db.exec("PRAGMA synchronous=NORMAL;")
			try db.exec("PRAGMA foreign_keys=ON;")
			try UnifiedStore.migrate(db)
		}
	}

	public func close() {
		db.close()
	}

	private static func migrate(_ db: Database) throws {
		try db.exec("""
			CREATE TABLE IF NOT EXISTS poll (
				id            INTEGER PRIMARY KEY,
				ts            INTEGER NOT NULL,
				collector     TEXT    NOT NULL,
				source        TEXT    NOT NULL,
				http_status   INTEGER,
				error         TEXT,
				vehicle_count INTEGER NOT NULL DEFAULT 0,
				latency_ms    INTEGER
			);
			CREATE INDEX IF NOT EXISTS idx_upoll_collector_ts ON poll(collector, ts);
			CREATE TABLE IF NOT EXISTS observation (
				id       INTEGER PRIMARY KEY,
				poll_id  INTEGER NOT NULL REFERENCES poll(id),
				kind     TEXT    NOT NULL,
				vid      TEXT    NOT NULL,
				ts       INTEGER NOT NULL,
				lat      REAL    NOT NULL,
				lon      REAL    NOT NULL,
				alt_ft   REAL,
				alt_src  TEXT,
				speed_kt REAL,
				heading  REAL,
				callsign TEXT,
				source   TEXT    NOT NULL,
				geohash  TEXT    NOT NULL
			);
			CREATE INDEX IF NOT EXISTS idx_uobs_ts      ON observation(ts);
			CREATE INDEX IF NOT EXISTS idx_uobs_vid_ts  ON observation(kind, vid, ts);
			CREATE INDEX IF NOT EXISTS idx_uobs_geo_ts  ON observation(geohash, ts);
			CREATE TABLE IF NOT EXISTS metar (
				id        INTEGER PRIMARY KEY,
				ts        INTEGER NOT NULL,
				station   TEXT    NOT NULL,
				altim_hpa REAL,
				raw       TEXT
			);
			CREATE INDEX IF NOT EXISTS idx_umetar_station_ts ON metar(station, ts);
			PRAGMA user_version=1;
			""")
	}

	// MARK: - Writes

	/// One poll attempt and its observations, in a single transaction.
	@discardableResult
	public func record(poll: PollRecord, collector: String, observations: [UnifiedObservation]) throws -> Int64 {
		try db.exec("BEGIN IMMEDIATE;")
		do {
			let pollStmt = try db.prepare("""
				INSERT INTO poll (ts, collector, source, http_status, error, vehicle_count, latency_ms)
				VALUES (?,?,?,?,?,?,?);
				""")
			pollStmt.bind(1, poll.ts)
			pollStmt.bind(2, collector)
			pollStmt.bind(3, poll.source)
			pollStmt.bind(4, poll.httpStatus)
			pollStmt.bind(5, poll.error)
			pollStmt.bind(6, poll.aircraftCount)
			pollStmt.bind(7, poll.latencyMs)
			try pollStmt.step()
			let pollId = db.lastInsertRowID
			if !observations.isEmpty {
				let stmt = try db.prepare("""
					INSERT INTO observation (poll_id, kind, vid, ts, lat, lon, alt_ft, alt_src,
						speed_kt, heading, callsign, source, geohash)
					VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?);
					""")
				for o in observations {
					stmt.reset()
					stmt.bind(1, pollId)
					stmt.bind(2, o.kind.rawValue)
					stmt.bind(3, o.vid)
					stmt.bind(4, o.ts)
					stmt.bind(5, o.lat)
					stmt.bind(6, o.lon)
					stmt.bind(7, o.altFt)
					stmt.bind(8, o.altSrc)
					stmt.bind(9, o.speedKt)
					stmt.bind(10, o.headingDeg)
					stmt.bind(11, o.callsign)
					stmt.bind(12, o.source)
					stmt.bind(13, o.geohash)
					try stmt.step()
				}
			}
			try db.exec("COMMIT;")
			return pollId
		} catch {
			try? db.exec("ROLLBACK;")
			throw error
		}
	}

	public func record(metarTs: Int64, station: String, altimHpa: Double?, raw: String?) throws {
		let stmt = try db.prepare("INSERT INTO metar (ts, station, altim_hpa, raw) VALUES (?,?,?,?);")
		stmt.bind(1, metarTs)
		stmt.bind(2, station)
		stmt.bind(3, altimHpa)
		stmt.bind(4, raw)
		try stmt.step()
	}

	public func latestMetarTs(station: String) throws -> Int64? {
		let stmt = try db.prepare("SELECT ts FROM metar WHERE station = ? ORDER BY ts DESC LIMIT 1;")
		stmt.bind(1, station)
		return try stmt.step() ? stmt.int64(0) : nil
	}

	// MARK: - Reads

	/// Observations inside a bbox and time window, oldest first, grouped by
	/// vehicle so callers can segment into tracks in one pass. `limit` caps
	/// the result to keep API responses bounded; the caller learns it was
	/// truncated when exactly `limit` rows come back.
	public func observations(
		latMin: Double, latMax: Double, lonMin: Double, lonMax: Double,
		from: Int64, to: Int64, kinds: [VehicleKind]? = nil, limit: Int = 200_000
	) throws -> [UnifiedObservation] {
		let kindList = (kinds?.isEmpty ?? true) ? VehicleKind.allCases : kinds!
		let placeholders = kindList.map { _ in "?" }.joined(separator: ",")
		let stmt = try db.prepare("""
			SELECT id, kind, vid, ts, lat, lon, alt_ft, alt_src, speed_kt, heading,
				callsign, source, geohash
			FROM observation
			WHERE ts >= ? AND ts <= ?
				AND lat >= ? AND lat <= ? AND lon >= ? AND lon <= ?
				AND kind IN (\(placeholders))
			ORDER BY kind, vid, ts
			LIMIT ?;
			""")
		stmt.bind(1, from)
		stmt.bind(2, to)
		stmt.bind(3, latMin)
		stmt.bind(4, latMax)
		stmt.bind(5, lonMin)
		stmt.bind(6, lonMax)
		var i: Int32 = 7
		for k in kindList {
			stmt.bind(i, k.rawValue)
			i += 1
		}
		stmt.bind(i, limit)
		var out: [UnifiedObservation] = []
		while try stmt.step() {
			guard let kind = VehicleKind(rawValue: stmt.text(1) ?? "") else { continue }
			out.append(UnifiedObservation(
				id: stmt.int64(0),
				kind: kind,
				vid: stmt.text(2) ?? "",
				ts: stmt.int64(3),
				lat: stmt.double(4),
				lon: stmt.double(5),
				altFt: stmt.doubleOrNil(6),
				altSrc: stmt.text(7),
				speedKt: stmt.doubleOrNil(8),
				headingDeg: stmt.doubleOrNil(9),
				callsign: stmt.text(10),
				source: stmt.text(11) ?? "",
				geohash: stmt.text(12) ?? ""
			))
		}
		return out
	}

	public func observationTimeBounds() throws -> (first: Int64, last: Int64)? {
		let stmt = try db.prepare("SELECT MIN(ts), MAX(ts) FROM observation;")
		guard try stmt.step(), !stmt.isNull(0) else { return nil }
		return (stmt.int64(0), stmt.int64(1))
	}

	public func health(now: Int64 = Int64(Date().timeIntervalSince1970)) throws -> [CollectorHealth] {
		let stmt = try db.prepare("""
			SELECT collector,
				MAX(ts),
				COUNT(*) FILTER (WHERE ts >= ?),
				COUNT(*) FILTER (WHERE ts >= ? AND error IS NOT NULL)
			FROM poll GROUP BY collector ORDER BY collector;
			""")
		let hourAgo = now - 3600
		stmt.bind(1, hourAgo)
		stmt.bind(2, hourAgo)
		var out: [CollectorHealth] = []
		while try stmt.step() {
			out.append(CollectorHealth(
				collector: stmt.text(0) ?? "",
				lastPollTs: stmt.int64(1),
				lastError: nil,
				pollsLastHour: Int(stmt.int64(2)),
				errorsLastHour: Int(stmt.int64(3)),
				vehiclesLastPoll: 0,
				currentSource: ""
			))
		}
		for i in out.indices {
			let last = try db.prepare("""
				SELECT error, vehicle_count, source FROM poll
				WHERE collector = ? ORDER BY ts DESC LIMIT 1;
				""")
			last.bind(1, out[i].collector)
			if try last.step() {
				out[i].lastError = last.text(0)
				out[i].vehiclesLastPoll = Int(last.int64(1))
				out[i].currentSource = last.text(2) ?? ""
			}
		}
		return out
	}

	// MARK: - Compaction support

	/// Delete observations and polls strictly older than `ts`. Returns rows
	/// removed. The compactor calls this only after the Parquet write for the
	/// same span has been verified on disk.
	@discardableResult
	public func pruneBefore(ts: Int64) throws -> Int {
		try db.exec("BEGIN IMMEDIATE;")
		do {
			let obsStmt = try db.prepare("DELETE FROM observation WHERE ts < ?;")
			obsStmt.bind(1, ts)
			try obsStmt.step()
			let removed = Int(db.changes)
			let pollStmt = try db.prepare("DELETE FROM poll WHERE ts < ? AND id NOT IN (SELECT DISTINCT poll_id FROM observation);")
			pollStmt.bind(1, ts)
			try pollStmt.step()
			try db.exec("COMMIT;")
			return removed
		} catch {
			try? db.exec("ROLLBACK;")
			throw error
		}
	}

	// MARK: - Migration from per-site databases

	/// Pull every observation, poll, and metar row out of a legacy per-site
	/// database into the unified schema. Idempotence is the caller's problem —
	/// run it once per retired site DB. Returns (polls, observations) copied.
	public func migrateSiteDB(path: String, collector: String, source fallbackSource: String = "adsb.lol") throws -> (polls: Int, observations: Int) {
		let src = try Database(path: path, readOnly: true)
		defer { src.close() }
		var pollCount = 0
		var obsCount = 0
		try db.exec("BEGIN IMMEDIATE;")
		do {
			let pollIn = try src.prepare("SELECT id, ts, source, http_status, error, aircraft_count, latency_ms FROM poll ORDER BY id;")
			let pollOut = try db.prepare("""
				INSERT INTO poll (ts, collector, source, http_status, error, vehicle_count, latency_ms)
				VALUES (?,?,?,?,?,?,?);
				""")
			let obsIn = try src.prepare("""
				SELECT ts, hex, flight, reg, lat, lon, alt_baro_ft, on_ground, alt_geom_ft,
					gs_kt, track_deg
				FROM observation WHERE poll_id = ? ORDER BY id;
				""")
			let obsOut = try db.prepare("""
				INSERT INTO observation (poll_id, kind, vid, ts, lat, lon, alt_ft, alt_src,
					speed_kt, heading, callsign, source, geohash)
				VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?);
				""")
			while try pollIn.step() {
				let srcPollId = pollIn.int64(0)
				let pollSource = pollIn.text(2) ?? fallbackSource
				pollOut.reset()
				pollOut.bind(1, pollIn.int64(1))
				pollOut.bind(2, collector)
				pollOut.bind(3, pollSource)
				pollOut.bind(4, pollIn.int64OrNil(3))
				pollOut.bind(5, pollIn.text(4))
				pollOut.bind(6, pollIn.int64(5))
				pollOut.bind(7, pollIn.int64OrNil(6))
				try pollOut.step()
				let newPollId = db.lastInsertRowID
				pollCount += 1

				obsIn.reset()
				obsIn.bind(1, srcPollId)
				while try obsIn.step() {
					let lat = obsIn.double(4)
					let lon = obsIn.double(5)
					var altFt: Double?
					var altSrc: String?
					if obsIn.int64(7) != 0 {
						altSrc = "ground"
					} else if let baro = obsIn.doubleOrNil(6) {
						altFt = baro
						altSrc = "baro"
					} else if let geom = obsIn.doubleOrNil(8) {
						altFt = geom
						altSrc = "geom"
					}
					obsOut.reset()
					obsOut.bind(1, newPollId)
					obsOut.bind(2, VehicleKind.aircraft.rawValue)
					obsOut.bind(3, obsIn.text(1))
					obsOut.bind(4, obsIn.int64(0))
					obsOut.bind(5, lat)
					obsOut.bind(6, lon)
					obsOut.bind(7, altFt)
					obsOut.bind(8, altSrc)
					obsOut.bind(9, obsIn.doubleOrNil(9))
					obsOut.bind(10, obsIn.doubleOrNil(10))
					obsOut.bind(11, obsIn.text(2) ?? obsIn.text(3))
					obsOut.bind(12, pollSource)
					obsOut.bind(13, Geohash.encode(lat: lat, lon: lon))
					try obsOut.step()
					obsCount += 1
				}
			}
			let metarIn = try src.prepare("SELECT ts, station, altim_hpa, raw FROM metar ORDER BY id;")
			let metarOut = try db.prepare("INSERT INTO metar (ts, station, altim_hpa, raw) VALUES (?,?,?,?);")
			while try metarIn.step() {
				metarOut.reset()
				metarOut.bind(1, metarIn.int64(0))
				metarOut.bind(2, metarIn.text(1))
				metarOut.bind(3, metarIn.doubleOrNil(2))
				metarOut.bind(4, metarIn.text(3))
				try metarOut.step()
			}
			try db.exec("COMMIT;")
			return (pollCount, obsCount)
		} catch {
			try? db.exec("ROLLBACK;")
			throw error
		}
	}
}
