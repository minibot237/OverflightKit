import Foundation

/// Client for minibot's query API (OverflightServer on :9200). GET/JSON only,
/// no auth — Tailscale is the perimeter. The DTOs mirror Server.swift's
/// Encodable shapes; keep the two in sync by hand, they're small.

/// One configured site as served by /api/views.
public struct RemoteView: Codable, Sendable, Identifiable, Equatable {
	public var slug: String
	public var title: String
	public var lat: Double
	public var lon: Double
	public var radiusNm: Double

	public var id: String { slug }

	enum CodingKeys: String, CodingKey {
		case slug, title, lat, lon
		case radiusNm = "radius_nm"
	}

	public init(slug: String, title: String, lat: Double, lon: Double, radiusNm: Double) {
		self.slug = slug
		self.title = title
		self.lat = lat
		self.lon = lon
		self.radiusNm = radiusNm
	}
}

/// One decoded track point. The wire format is a bare array
/// [ts, lat, lon, altFt|null, speedKt|null, heading|null].
public struct RemotePoint: Sendable, Equatable {
	public var ts: Int64
	public var lat: Double
	public var lon: Double
	public var altFt: Double?
	public var speedKt: Double?
	public var headingDeg: Double?

	public init(ts: Int64, lat: Double, lon: Double, altFt: Double? = nil, speedKt: Double? = nil, headingDeg: Double? = nil) {
		self.ts = ts
		self.lat = lat
		self.lon = lon
		self.altFt = altFt
		self.speedKt = speedKt
		self.headingDeg = headingDeg
	}
}

/// One server-segmented track from /api/tracks. `kind` stays a string so a
/// future server kind doesn't fail the whole decode; unknown kinds surface
/// as `vehicleKind == nil` and callers skip them.
public struct RemoteTrack: Decodable, Sendable {
	public var kind: String
	public var vid: String
	public var callsign: String?
	public var points: [RemotePoint]

	public var vehicleKind: VehicleKind? { VehicleKind(rawValue: kind) }

	enum CodingKeys: String, CodingKey {
		case kind, vid, callsign, points
	}

	public init(kind: String, vid: String, callsign: String? = nil, points: [RemotePoint]) {
		self.kind = kind
		self.vid = vid
		self.callsign = callsign
		self.points = points
	}

	public init(from decoder: Decoder) throws {
		let c = try decoder.container(keyedBy: CodingKeys.self)
		kind = try c.decode(String.self, forKey: .kind)
		vid = try c.decode(String.self, forKey: .vid)
		callsign = try c.decodeIfPresent(String.self, forKey: .callsign)
		let raw = try c.decode([[Double?]].self, forKey: .points)
		points = raw.compactMap { a in
			guard a.count >= 3, let ts = a[0], let lat = a[1], let lon = a[2] else { return nil }
			func at(_ i: Int) -> Double? { i < a.count ? a[i] : nil }
			return RemotePoint(ts: Int64(ts), lat: lat, lon: lon, altFt: at(3), speedKt: at(4), headingDeg: at(5))
		}
	}
}

/// The /api/tracks envelope.
public struct RemoteWindow: Decodable, Sendable {
	public var from: Int64
	public var to: Int64
	public var count: Int
	public var truncated: Bool
	public var tracks: [RemoteTrack]
}

/// The /api/health envelope. CollectorHealth is the same Codable struct the
/// server encodes.
public struct RemoteHealth: Decodable, Sendable {
	public var now: Int64
	public var firstTs: Int64?
	public var lastTs: Int64?
	public var dbBytes: Int64?
	public var collectors: [CollectorHealth]
}

public struct RemoteAPI: Sendable, Equatable {
	public let baseURL: URL

	public init(baseURL: URL) {
		self.baseURL = baseURL
	}

	/// Accepts what a person types in a URL field: requires http(s) and a
	/// host, strips a trailing slash.
	public init?(urlString: String) {
		let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
		guard var comps = URLComponents(string: trimmed),
			let scheme = comps.scheme, scheme == "http" || scheme == "https",
			let host = comps.host, !host.isEmpty
		else { return nil }
		if comps.path.hasSuffix("/") {
			comps.path = String(comps.path.dropLast())
		}
		guard let url = comps.url else { return nil }
		self.init(baseURL: url)
	}

	public func views() async throws -> [RemoteView] {
		try await get(baseURL.appending(path: "api/views"))
	}

	public func health() async throws -> RemoteHealth {
		try await get(baseURL.appending(path: "api/health"))
	}

	public func tracks(
		latMin: Double, lonMin: Double, latMax: Double, lonMax: Double,
		from: Int64, to: Int64, kinds: [VehicleKind]? = nil,
		gapS: Int64 = 300, limit: Int = 200_000
	) async throws -> RemoteWindow {
		try await get(tracksURL(
			latMin: latMin, lonMin: lonMin, latMax: latMax, lonMax: lonMax,
			from: from, to: to, kinds: kinds, gapS: gapS, limit: limit))
	}

	/// Separate from tracks() so the query construction is testable.
	public func tracksURL(
		latMin: Double, lonMin: Double, latMax: Double, lonMax: Double,
		from: Int64, to: Int64, kinds: [VehicleKind]?,
		gapS: Int64, limit: Int
	) -> URL {
		var comps = URLComponents(url: baseURL.appending(path: "api/tracks"), resolvingAgainstBaseURL: false)!
		func f(_ v: Double) -> String { String(format: "%.6f", v) }
		var items = [
			URLQueryItem(name: "bbox", value: "\(f(latMin)),\(f(lonMin)),\(f(latMax)),\(f(lonMax))"),
			URLQueryItem(name: "from", value: String(from)),
			URLQueryItem(name: "to", value: String(to)),
			URLQueryItem(name: "gap", value: String(gapS)),
			URLQueryItem(name: "limit", value: String(limit)),
		]
		if let kinds, !kinds.isEmpty {
			items.append(URLQueryItem(name: "kinds", value: kinds.map(\.rawValue).sorted().joined(separator: ",")))
		}
		comps.queryItems = items
		return comps.url!
	}

	private func get<T: Decodable>(_ url: URL) async throws -> T {
		var req = URLRequest(url: url)
		req.timeoutInterval = 30
		let (data, resp) = try await URLSession.shared.data(for: req)
		guard let http = resp as? HTTPURLResponse else {
			throw OverflightError.badResponse("not an HTTP response from \(url.host() ?? "?")")
		}
		guard http.statusCode == 200 else {
			let msg = (try? JSONDecoder().decode(ServerErrorBody.self, from: data))?.error
				?? "HTTP \(http.statusCode)"
			throw OverflightError.badResponse(msg)
		}
		return try JSONDecoder().decode(T.self, from: data)
	}
}

private struct ServerErrorBody: Decodable {
	var error: String
}
