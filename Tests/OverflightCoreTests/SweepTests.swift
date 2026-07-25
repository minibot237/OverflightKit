import XCTest
@testable import OverflightCore

final class SweepTests: XCTestCase {
	func testFallbackTilesCoverSweepCircle() {
		let sweep = SweepConfig(slug: "conus", lat: 39.5, lon: -98.35, radiusNm: 1300)
		let tiles = sweep.fallbackTiles()
		// Sanity: a CONUS ring should be tens of tiles, not hundreds.
		XCTAssertGreaterThan(tiles.count, 10)
		XCTAssertLessThan(tiles.count, 120)

		// Every probe point inside the sweep circle must land within 250nm
		// of some tile center.
		var worstNm = 0.0
		for latOff in stride(from: -1300.0, through: 1300.0, by: 100) {
			for lonOff in stride(from: -1300.0, through: 1300.0, by: 100) {
				let plat = 39.5 + latOff / 60
				let plon = -98.35 + lonOff / (60 * cos(39.5 * .pi / 180))
				let fromCenter = Geo.distanceM(lat1: 39.5, lon1: -98.35, lat2: plat, lon2: plon) / Geo.metersPerNm
				guard fromCenter <= 1300 else { continue }
				let nearest = tiles.map {
					Geo.distanceM(lat1: $0.lat, lon1: $0.lon, lat2: plat, lon2: plon) / Geo.metersPerNm
				}.min() ?? .infinity
				worstNm = max(worstNm, nearest)
			}
		}
		XCTAssertLessThanOrEqual(worstNm, 250, "coverage hole: a point is \(worstNm)nm from the nearest tile")
	}

	func testSweepDecodesFromJSON() throws {
		let json = """
		{"sites": [{"lat": 1, "lon": 2, "icao": "KTST"}],
		 "sweep": {"lat": 39.5, "lon": -98.35}}
		"""
		let config = try JSONDecoder().decode(Config.self, from: Data(json.utf8))
		XCTAssertEqual(config.sweep?.slug, "conus")
		XCTAssertEqual(config.sweep?.radiusNm, 1300)
		XCTAssertEqual(config.sweep?.intervalS, 60)
		XCTAssertEqual(config.sweep?.enabled, true)
		XCTAssertEqual(config.sweep?.collectorLabel, "sweep-conus")
	}
}
