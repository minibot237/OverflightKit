import XCTest
@testable import OverflightCore

/// Decoding the query API's wire shapes — samples lifted from live responses
/// on minibot (2026-07-25).
final class RemoteAPITests: XCTestCase {
	func testDecodeViews() throws {
		let json = #"""
		[{"radius_nm":15,"lat":47.4479,"lon":-122.3103,"slug":"seatacwa","title":"KSEA — Seattle-Tacoma Intl"},
		 {"radius_nm":15,"lat":36.6067,"lon":-94.7386,"slug":"kgmj","title":"KGMJ — Grove Muni, OK"}]
		"""#
		let views = try JSONDecoder().decode([RemoteView].self, from: Data(json.utf8))
		XCTAssertEqual(views.count, 2)
		XCTAssertEqual(views[0].slug, "seatacwa")
		XCTAssertEqual(views[0].radiusNm, 15)
		XCTAssertEqual(views[1].title, "KGMJ — Grove Muni, OK")
	}

	func testDecodeTracksWindow() throws {
		let json = #"""
		{"from":1785021000,"to":1785022000,"count":5,"truncated":false,"tracks":[
			{"kind":"aircraft","vid":"06a2b3","callsign":"QTR68T","points":[
				[1785021900,47.439395,-122.303696,null,2.2,null],
				[1785021910,47.439465,-122.303801,12000,410.5,271.3]]},
			{"kind":"vessel","vid":"366123456","points":[
				[1785021500,47.6,-122.35,null,8.1,180]]}
		]}
		"""#
		let window = try JSONDecoder().decode(RemoteWindow.self, from: Data(json.utf8))
		XCTAssertEqual(window.count, 5)
		XCTAssertFalse(window.truncated)
		XCTAssertEqual(window.tracks.count, 2)

		let ac = window.tracks[0]
		XCTAssertEqual(ac.vehicleKind, .aircraft)
		XCTAssertEqual(ac.callsign, "QTR68T")
		XCTAssertEqual(ac.points.count, 2)
		XCTAssertEqual(ac.points[0].ts, 1785021900)
		XCTAssertNil(ac.points[0].altFt)
		XCTAssertEqual(ac.points[1].altFt, 12000)
		XCTAssertEqual(ac.points[1].headingDeg ?? 0, 271.3, accuracy: 0.001)

		let ship = window.tracks[1]
		XCTAssertEqual(ship.vehicleKind, .vessel)
		XCTAssertNil(ship.callsign)
		XCTAssertNil(ship.points[0].altFt)
		XCTAssertEqual(ship.points[0].speedKt ?? 0, 8.1, accuracy: 0.001)
	}

	func testUnknownKindDecodesButHasNoVehicleKind() throws {
		let json = #"""
		{"from":0,"to":1,"count":1,"truncated":false,"tracks":[
			{"kind":"submarine","vid":"x1","points":[[1,47.0,-122.0,null,null,null]]}
		]}
		"""#
		let window = try JSONDecoder().decode(RemoteWindow.self, from: Data(json.utf8))
		XCTAssertEqual(window.tracks.count, 1)
		XCTAssertNil(window.tracks[0].vehicleKind)
	}

	func testPointRowsWithMissingCoordinatesAreDropped() throws {
		let json = #"""
		{"kind":"aircraft","vid":"abc123","points":[
			[1785021900,null,-122.3,null,null,null],
			[1785021910,47.44,-122.3,500,null,null]]}
		"""#
		let track = try JSONDecoder().decode(RemoteTrack.self, from: Data(json.utf8))
		XCTAssertEqual(track.points.count, 1)
		XCTAssertEqual(track.points[0].altFt, 500)
	}

	func testDecodeHealth() throws {
		let json = #"""
		{"firstTs":1785015211,"dbBytes":90664960,"now":1785022137,"lastTs":1785022136,
		 "collectors":[{"errorsLastHour":0,"lastPollTs":1785022125,"currentSource":"adsb.lol",
			"collector":"seatacwa","pollsLastHour":345,"vehiclesLastPoll":39}]}
		"""#
		let health = try JSONDecoder().decode(RemoteHealth.self, from: Data(json.utf8))
		XCTAssertEqual(health.lastTs, 1785022136)
		XCTAssertEqual(health.collectors.count, 1)
		XCTAssertEqual(health.collectors[0].collector, "seatacwa")
		XCTAssertEqual(health.collectors[0].vehiclesLastPoll, 39)
	}

	func testURLStringInitValidation() {
		XCTAssertEqual(RemoteAPI(urlString: "http://127.0.0.1:9200")?.baseURL.absoluteString, "http://127.0.0.1:9200")
		XCTAssertEqual(RemoteAPI(urlString: " http://100.64.1.2:9200/ \n")?.baseURL.absoluteString, "http://100.64.1.2:9200")
		XCTAssertNil(RemoteAPI(urlString: "127.0.0.1:9200"))
		XCTAssertNil(RemoteAPI(urlString: "ftp://example.com"))
		XCTAssertNil(RemoteAPI(urlString: ""))
	}

	func testTracksURLQuery() throws {
		let api = RemoteAPI(urlString: "http://127.0.0.1:9200")!
		let url = api.tracksURL(
			latMin: 47.3, lonMin: -122.5, latMax: 47.6, lonMax: -122.1,
			from: 1785021000, to: 1785022000, kinds: [.train, .aircraft],
			gapS: 300, limit: 200_000)
		let comps = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
		XCTAssertEqual(comps.path, "/api/tracks")
		var query: [String: String] = [:]
		for item in comps.queryItems ?? [] { query[item.name] = item.value }
		XCTAssertEqual(query["bbox"], "47.300000,-122.500000,47.600000,-122.100000")
		XCTAssertEqual(query["from"], "1785021000")
		XCTAssertEqual(query["to"], "1785022000")
		XCTAssertEqual(query["gap"], "300")
		XCTAssertEqual(query["limit"], "200000")
		XCTAssertEqual(query["kinds"], "aircraft,train")
	}
}
