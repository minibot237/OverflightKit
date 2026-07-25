import XCTest
@testable import OverflightCore

final class GeohashTests: XCTestCase {
	func testKnownVector() {
		// Canonical example from the geohash spec writeups.
		XCTAssertEqual(Geohash.encode(lat: 57.64911, lon: 10.40744, precision: 11), "u4pruydqqvj")
	}

	func testDefaultPrecisionAndBounds() {
		let h = Geohash.encode(lat: 47.4479, lon: -122.3103)
		XCTAssertEqual(h.count, 5)
		let b = Geohash.bounds(h)!
		XCTAssertTrue(b.latMin <= 47.4479 && 47.4479 <= b.latMax)
		XCTAssertTrue(b.lonMin <= -122.3103 && -122.3103 <= b.lonMax)
	}

	func testBoundsRejectsGarbage() {
		XCTAssertNil(Geohash.bounds("ai"))  // 'a' and 'i' are not geohash base32
	}
}

final class UnifiedStoreTests: XCTestCase {
	func tempPath(_ name: String) -> String {
		NSTemporaryDirectory() + "unified-test-\(name)-\(UUID().uuidString).db"
	}

	func testRoundTripAndBboxQuery() async throws {
		let store = try UnifiedStore(path: tempPath("roundtrip"))
		let poll = PollRecord(ts: 1000, source: "adsb.lol", httpStatus: 200, error: nil, aircraftCount: 2, latencyMs: 50)
		let inSeattle = UnifiedObservation(
			kind: .aircraft, vid: "a1b2c3", ts: 1000, lat: 47.45, lon: -122.31,
			altFt: 3500, altSrc: "baro", speedKt: 140, headingDeg: 90,
			callsign: "ASA123", source: "adsb.lol")
		let inOklahoma = UnifiedObservation(
			kind: .aircraft, vid: "d4e5f6", ts: 1000, lat: 36.6, lon: -94.7,
			altFt: nil, altSrc: "ground", source: "adsb.lol")
		try await store.record(poll: poll, collector: "test", observations: [inSeattle, inOklahoma])

		let seattleOnly = try await store.observations(
			latMin: 47, latMax: 48, lonMin: -123, lonMax: -122, from: 0, to: 2000)
		XCTAssertEqual(seattleOnly.count, 1)
		XCTAssertEqual(seattleOnly[0].vid, "a1b2c3")
		XCTAssertEqual(seattleOnly[0].callsign, "ASA123")
		XCTAssertEqual(seattleOnly[0].geohash, Geohash.encode(lat: 47.45, lon: -122.31))

		let vesselsOnly = try await store.observations(
			latMin: -90, latMax: 90, lonMin: -180, lonMax: 180,
			from: 0, to: 2000, kinds: [.vessel])
		XCTAssertTrue(vesselsOnly.isEmpty)
		await store.close()
	}

	func testAircraftMapping() {
		let ground = Aircraft(hex: "abc", lat: 1, lon: 2, altBaro: .ground)
		let g = UnifiedObservation(aircraft: ground, ts: 5, source: "s")
		XCTAssertNil(g.altFt)
		XCTAssertEqual(g.altSrc, "ground")

		let flying = Aircraft(hex: "def", flight: "UAL1", lat: 1, lon: 2, altBaro: .feet(30000))
		let f = UnifiedObservation(aircraft: flying, ts: 5, source: "s")
		XCTAssertEqual(f.altFt, 30000)
		XCTAssertEqual(f.altSrc, "baro")
		XCTAssertEqual(f.callsign, "UAL1")

		let geomOnly = Aircraft(hex: "geo", registration: "N123", lat: 1, lon: 2, altGeomFt: 4500)
		let ge = UnifiedObservation(aircraft: geomOnly, ts: 5, source: "s")
		XCTAssertEqual(ge.altFt, 4500)
		XCTAssertEqual(ge.altSrc, "geom")
		XCTAssertEqual(ge.callsign, "N123")
	}

	func testMigrateSiteDB() async throws {
		// Build a small legacy site DB with the real Store, then migrate it.
		let sitePath = tempPath("legacy-site")
		let site = try Store(path: sitePath)
		let aircraft = [
			Aircraft(hex: "aaa111", flight: "TEST1", lat: 36.61, lon: -94.74, altBaro: .feet(2500), groundSpeedKt: 100, trackDeg: 180),
			Aircraft(hex: "bbb222", lat: 36.62, lon: -94.75, altBaro: .ground),
		]
		try await site.record(
			poll: PollRecord(ts: 500, source: "adsb.lol", httpStatus: 200, error: nil, aircraftCount: 2, latencyMs: 40),
			aircraft: aircraft)
		try await site.record(metarTs: 490, station: "KGMJ", altimHpa: 1014.6, raw: "KGMJ ...")
		await site.close()

		let unified = try UnifiedStore(path: tempPath("migrated"))
		let (polls, obs) = try await unified.migrateSiteDB(path: sitePath, collector: "kgmj")
		XCTAssertEqual(polls, 1)
		XCTAssertEqual(obs, 2)

		let rows = try await unified.observations(
			latMin: 36, latMax: 37, lonMin: -95, lonMax: -94, from: 0, to: 1000)
		XCTAssertEqual(rows.count, 2)
		let flying = rows.first { $0.vid == "aaa111" }!
		XCTAssertEqual(flying.altFt, 2500)
		XCTAssertEqual(flying.altSrc, "baro")
		XCTAssertEqual(flying.callsign, "TEST1")
		XCTAssertEqual(flying.kind, .aircraft)
		let grounded = rows.first { $0.vid == "bbb222" }!
		XCTAssertNil(grounded.altFt)
		XCTAssertEqual(grounded.altSrc, "ground")
		let metarTs = try await unified.latestMetarTs(station: "KGMJ")
		XCTAssertEqual(metarTs, 490)

		let health = try await unified.health(now: 600)
		XCTAssertEqual(health.count, 1)
		XCTAssertEqual(health[0].collector, "kgmj")
		XCTAssertEqual(health[0].vehiclesLastPoll, 2)
		await unified.close()
	}

	func testPruneBefore() async throws {
		let store = try UnifiedStore(path: tempPath("prune"))
		for ts in [Int64(100), 200, 300] {
			try await store.record(
				poll: PollRecord(ts: ts, source: "s", httpStatus: 200, error: nil, aircraftCount: 1, latencyMs: 1),
				collector: "c",
				observations: [UnifiedObservation(kind: .train, vid: "t\(ts)", ts: ts, lat: 40, lon: -100, source: "s")])
		}
		let removed = try await store.pruneBefore(ts: 250)
		XCTAssertEqual(removed, 2)
		let left = try await store.observations(
			latMin: -90, latMax: 90, lonMin: -180, lonMax: 180, from: 0, to: 1000)
		XCTAssertEqual(left.count, 1)
		XCTAssertEqual(left[0].ts, 300)
		await store.close()
	}
}
