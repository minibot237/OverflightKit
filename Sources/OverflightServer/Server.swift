import Foundation
import Network
import OverflightCore

func log(_ msg: String) {
	let fmt = ISO8601DateFormatter()
	fmt.formatOptions = [.withInternetDateTime]
	fputs("\(fmt.string(from: Date())) \(msg)\n", stdout)
	fflush(stdout)
}

/// Find this machine's Tailscale IPv4 (CGNAT 100.64.0.0/10) so the API is
/// reachable from tailnet devices and nothing else. Falls back to loopback
/// when Tailscale is down — better dark than open.
func tailscaleIPv4() -> String? {
	var addrs: UnsafeMutablePointer<ifaddrs>?
	guard getifaddrs(&addrs) == 0 else { return nil }
	defer { freeifaddrs(addrs) }
	var cursor = addrs
	while let ifa = cursor?.pointee {
		defer { cursor = ifa.ifa_next }
		guard let sa = ifa.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET) else { continue }
		var addr = sockaddr_in()
		memcpy(&addr, sa, MemoryLayout<sockaddr_in>.size)
		let ip = UInt32(bigEndian: addr.sin_addr.s_addr)
		// 100.64.0.0/10
		if ip >> 22 == (UInt32(100) << 2) | 1 {
			var buf = [UInt8](repeating: 0, count: Int(INET_ADDRSTRLEN))
			var sin = addr.sin_addr
			let ptr = buf.withUnsafeMutableBytes { raw in
				inet_ntop(AF_INET, &sin, raw.baseAddress?.assumingMemoryBound(to: CChar.self), socklen_t(INET_ADDRSTRLEN))
			}
			if ptr != nil, let end = buf.firstIndex(of: 0) {
				return String(decoding: buf[..<end], as: UTF8.self)
			}
			return nil
		}
	}
	return nil
}

struct HTTPRequest {
	var path: String
	var query: [String: String]
}

enum HTTPResponse {
	case ok(Data, contentType: String)
	case badRequest(String)
	case notFound

	var data: Data {
		let (status, body, type): (String, Data, String)
		switch self {
		case .ok(let d, let t): (status, body, type) = ("200 OK", d, t)
		case .badRequest(let msg): (status, body, type) = ("400 Bad Request", Data("{\"error\":\(JSONString(msg))}".utf8), "application/json")
		case .notFound: (status, body, type) = ("404 Not Found", Data("{\"error\":\"not found\"}".utf8), "application/json")
		}
		var head = "HTTP/1.1 \(status)\r\n"
		head += "Content-Type: \(type)\r\n"
		head += "Content-Length: \(body.count)\r\n"
		head += "Cache-Control: no-store\r\n"
		head += "Connection: close\r\n\r\n"
		return Data(head.utf8) + body
	}
}

func JSONString(_ s: String) -> String {
	let d = try? JSONEncoder().encode([s])
	let arr = d.flatMap { String(data: $0, encoding: .utf8) } ?? "[\"?\"]"
	return String(arr.dropFirst().dropLast())
}

/// Reads Parquet partitions the nightly compactor wrote, via the duckdb CLI.
/// Every value interpolated into the SQL is a Swift Double/Int64 or a
/// VehicleKind rawValue — nothing user-typed reaches the string.
struct ArchiveQuery {
	let archiveDir: String
	let duckdbPath: String?

	init(archiveDir: String) {
		self.archiveDir = archiveDir
		let candidates = ["/opt/homebrew/bin/duckdb", "/usr/local/bin/duckdb"]
		duckdbPath = candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
	}

	var available: Bool {
		duckdbPath != nil && FileManager.default.fileExists(atPath: archiveDir)
	}

	func observations(
		latMin: Double, latMax: Double, lonMin: Double, lonMax: Double,
		from: Int64, to: Int64, kinds: [VehicleKind], limit: Int
	) throws -> [UnifiedObservation] {
		guard let duckdbPath, available else { return [] }
		let kindList = kinds.map { "'\($0.rawValue)'" }.joined(separator: ",")
		let sql = """
			SELECT kind, vid, ts, lat, lon, alt_ft, alt_src, speed_kt, heading, callsign, source, geohash
			FROM read_parquet('\(archiveDir)/date=*/geo=*/*.parquet', hive_partitioning=1)
			WHERE ts >= \(from) AND ts <= \(to)
				AND lat >= \(latMin) AND lat <= \(latMax)
				AND lon >= \(lonMin) AND lon <= \(lonMax)
				AND kind IN (\(kindList))
			ORDER BY kind, vid, ts
			LIMIT \(limit);
			"""
		let proc = Process()
		proc.executableURL = URL(fileURLWithPath: duckdbPath)
		proc.arguments = ["-json", "-c", sql]
		let out = Pipe()
		proc.standardOutput = out
		proc.standardError = Pipe()
		try proc.run()
		let data = out.fileHandleForReading.readDataToEndOfFile()
		proc.waitUntilExit()
		guard proc.terminationStatus == 0, !data.isEmpty else { return [] }

		struct Row: Decodable {
			var kind: String
			var vid: String
			var ts: Int64
			var lat: Double
			var lon: Double
			var alt_ft: Double?
			var alt_src: String?
			var speed_kt: Double?
			var heading: Double?
			var callsign: String?
			var source: String
			var geohash: String
		}
		let rows = try JSONDecoder().decode([Row].self, from: data)
		return rows.compactMap { r in
			guard let kind = VehicleKind(rawValue: r.kind) else { return nil }
			return UnifiedObservation(
				kind: kind, vid: r.vid, ts: r.ts, lat: r.lat, lon: r.lon,
				altFt: r.alt_ft, altSrc: r.alt_src, speedKt: r.speed_kt,
				headingDeg: r.heading, callsign: r.callsign,
				source: r.source, geohash: r.geohash)
		}
	}
}

/// Query API over the unified store. Read-only; every parameter is parsed
/// into a number or a known enum before it goes anywhere near SQL.
actor QueryAPI {
	let config: Config
	let store: UnifiedStore
	let webRoot: String
	let archive: ArchiveQuery
	let encoder: JSONEncoder

	init(config: Config, store: UnifiedStore, webRoot: String) {
		self.config = config
		self.store = store
		self.webRoot = webRoot
		archive = ArchiveQuery(archiveDir: config.expandedArchiveDir)
		encoder = JSONEncoder()
	}

	struct TrackJSON: Encodable {
		var kind: String
		var vid: String
		var callsign: String?
		/// [ts, lat, lon, alt_ft?, speed_kt?, heading?]
		var points: [[Double?]]
	}

	struct HealthJSON: Encodable {
		var now: Int64
		var collectors: [CollectorHealth]
		var firstTs: Int64?
		var lastTs: Int64?
		var dbBytes: Int64?
	}

	struct ViewJSON: Encodable {
		var slug: String
		var title: String
		var lat: Double
		var lon: Double
		var radiusNm: Double

		enum CodingKeys: String, CodingKey {
			case slug, title, lat, lon
			case radiusNm = "radius_nm"
		}
	}

	struct WindowJSON: Encodable {
		var from: Int64
		var to: Int64
		var count: Int
		var truncated: Bool
		var tracks: [TrackJSON]
	}

	func handle(_ req: HTTPRequest) async -> HTTPResponse {
		switch req.path {
		case "/", "/index.html":
			let path = webRoot + "/index.html"
			if let data = FileManager.default.contents(atPath: path) {
				return .ok(data, contentType: "text/html; charset=utf-8")
			}
			return .ok(Data("<html><body><h1>OverflightKit</h1><p>Web UI not installed; API lives at /api/*.</p></body></html>".utf8), contentType: "text/html")
		case "/api/health":
			return await health()
		case "/api/views":
			let views = config.sites.map {
				ViewJSON(slug: $0.slug, title: $0.title, lat: $0.lat, lon: $0.lon, radiusNm: $0.radiusNm)
			}
			return encode(views)
		case "/api/tracks", "/api/observations":
			return await tracks(req, raw: req.path == "/api/observations")
		default:
			return .notFound
		}
	}

	func health() async -> HTTPResponse {
		do {
			let now = Int64(Date().timeIntervalSince1970)
			let collectors = try await store.health(now: now)
			let bounds = try await store.observationTimeBounds()
			let attrs = try? FileManager.default.attributesOfItem(atPath: config.expandedUnifiedDbPath)
			return encode(HealthJSON(
				now: now,
				collectors: collectors,
				firstTs: bounds?.first,
				lastTs: bounds?.last,
				dbBytes: (attrs?[.size] as? NSNumber)?.int64Value
			))
		} catch {
			return .badRequest("health query failed: \(error)")
		}
	}

	func tracks(_ req: HTTPRequest, raw: Bool) async -> HTTPResponse {
		// bbox=latMin,lonMin,latMax,lonMax — matches OpenSky's lamin/lomin order.
		guard let bboxStr = req.query["bbox"] else { return .badRequest("bbox=latMin,lonMin,latMax,lonMax required") }
		let parts = bboxStr.split(separator: ",").compactMap { Double($0) }
		guard parts.count == 4 else { return .badRequest("bbox needs 4 numbers") }
		let (latMin, lonMin, latMax, lonMax) = (parts[0], parts[1], parts[2], parts[3])
		guard latMin < latMax, lonMin < lonMax,
			latMin >= -90, latMax <= 90, lonMin >= -180, lonMax <= 180 else {
			return .badRequest("bbox out of range")
		}
		let now = Int64(Date().timeIntervalSince1970)
		let from = req.query["from"].flatMap { Int64($0) } ?? now - 3600
		let to = req.query["to"].flatMap { Int64($0) } ?? now
		guard from <= to, to - from <= 31 * 86400 else {
			return .badRequest("window must be positive and at most 31 days")
		}
		var kinds: [VehicleKind]?
		if let k = req.query["kinds"] {
			let parsed = k.split(separator: ",").compactMap { VehicleKind(rawValue: String($0)) }
			guard !parsed.isEmpty else { return .badRequest("kinds must be aircraft,vessel,train") }
			kinds = parsed
		}
		let limit = min(max(req.query["limit"].flatMap { Int($0) } ?? 200_000, 1), 500_000)
		let gap = min(max(req.query["gap"].flatMap { Int64($0) } ?? 300, 30), 3600)

		do {
			var obs = try await store.observations(
				latMin: latMin, latMax: latMax, lonMin: lonMin, lonMax: lonMax,
				from: from, to: to, kinds: kinds, limit: limit)
			// Anything older than the hot tier lives in Parquet. The compactor
			// prunes only verified days, so the two tiers never overlap.
			let hotFirst = try await store.observationTimeBounds()?.first ?? now
			if from < hotFirst, archive.available {
				let cold = try archive.observations(
					latMin: latMin, latMax: latMax, lonMin: lonMin, lonMax: lonMax,
					from: from, to: min(to, hotFirst - 1),
					kinds: kinds ?? VehicleKind.allCases, limit: limit)
				if !cold.isEmpty {
					obs = (cold + obs).sorted {
						($0.kind.rawValue, $0.vid, $0.ts) < ($1.kind.rawValue, $1.vid, $1.ts)
					}
				}
			}
			let truncated = obs.count >= limit
			if raw {
				struct Row: Encodable {
					var kind: String
					var vid: String
					var ts: Int64
					var lat: Double
					var lon: Double
					var altFt: Double?
					var speedKt: Double?
					var heading: Double?
					var callsign: String?
					var source: String
				}
				let rows = obs.map {
					Row(kind: $0.kind.rawValue, vid: $0.vid, ts: $0.ts, lat: $0.lat, lon: $0.lon,
						altFt: $0.altFt, speedKt: $0.speedKt, heading: $0.headingDeg,
						callsign: $0.callsign, source: $0.source)
				}
				return encode(["count": AnyEncodable(rows.count), "truncated": AnyEncodable(truncated), "observations": AnyEncodable(rows)])
			}
			let tracks = segmentTracks(obs, gapS: gap).map { t in
				TrackJSON(
					kind: t.kind.rawValue, vid: t.vid, callsign: t.callsign,
					points: t.points.map { [Double($0.ts), $0.lat, $0.lon, $0.altFt, $0.speedKt, $0.headingDeg] })
			}
			return encode(WindowJSON(from: from, to: to, count: obs.count, truncated: truncated, tracks: tracks))
		} catch {
			return .badRequest("query failed: \(error)")
		}
	}

	func encode<T: Encodable>(_ value: T) -> HTTPResponse {
		do {
			return .ok(try encoder.encode(value), contentType: "application/json")
		} catch {
			return .badRequest("encode failed: \(error)")
		}
	}
}

struct AnyEncodable: Encodable {
	let value: Encodable
	init(_ value: Encodable) { self.value = value }
	func encode(to encoder: Encoder) throws {
		try value.encode(to: encoder)
	}
}

final class HTTPServer: @unchecked Sendable {
	let api: QueryAPI
	let listener: NWListener
	let host: String
	let port: UInt16

	init(api: QueryAPI, host: String, port: UInt16) throws {
		self.api = api
		self.host = host
		self.port = port
		let params = NWParameters.tcp
		params.requiredLocalEndpoint = NWEndpoint.hostPort(
			host: NWEndpoint.Host(host),
			port: NWEndpoint.Port(rawValue: port)!)
		listener = try NWListener(using: params)
	}

	func run() {
		listener.newConnectionHandler = { [api] conn in
			conn.start(queue: .global())
			self.receiveRequest(conn, buffer: Data()) { request in
				Task {
					let response: HTTPResponse
					if let request {
						response = await api.handle(request)
					} else {
						response = .badRequest("only GET is served here")
					}
					conn.send(content: response.data, completion: .contentProcessed { _ in
						conn.cancel()
					})
				}
			}
		}
		listener.start(queue: .global())
	}

	private func receiveRequest(_ conn: NWConnection, buffer: Data, completion: @escaping @Sendable (HTTPRequest?) -> Void) {
		conn.receive(minimumIncompleteLength: 1, maximumLength: 16384) { data, _, done, error in
			var buf = buffer
			if let data { buf.append(data) }
			if buf.count > 65536 || error != nil {
				completion(nil)
				return
			}
			if let range = buf.range(of: Data("\r\n\r\n".utf8)) {
				let head = String(data: buf[..<range.lowerBound], encoding: .utf8) ?? ""
				completion(Self.parse(head))
				return
			}
			if done {
				completion(nil)
				return
			}
			self.receiveRequest(conn, buffer: buf, completion: completion)
		}
	}

	static func parse(_ head: String) -> HTTPRequest? {
		guard let requestLine = head.split(separator: "\r\n").first else { return nil }
		let parts = requestLine.split(separator: " ")
		guard parts.count >= 2, parts[0] == "GET" else { return nil }
		let target = String(parts[1])
		let pieces = target.split(separator: "?", maxSplits: 1)
		let path = String(pieces[0])
		var query: [String: String] = [:]
		if pieces.count == 2 {
			for pair in pieces[1].split(separator: "&") {
				let kv = pair.split(separator: "=", maxSplits: 1)
				guard kv.count == 2 else { continue }
				let key = String(kv[0]).removingPercentEncoding ?? String(kv[0])
				let val = String(kv[1]).removingPercentEncoding ?? String(kv[1])
				query[key] = val
			}
		}
		return HTTPRequest(path: path, query: query)
	}
}

@main
struct OverflightServerMain {
	static func main() async throws {
		var configPath: String?
		var args = ArraySlice(CommandLine.arguments.dropFirst())
		while let arg = args.popFirst() {
			switch arg {
			case "--config":
				configPath = args.popFirst()
			default:
				print("usage: OverflightServer [--config PATH]")
				return
			}
		}
		let config = try Config.loadOrCreate(path: configPath)
		let store = try UnifiedStore(path: config.expandedUnifiedDbPath, readOnly: true)
		let webRoot = ("~/.overflight/web" as NSString).expandingTildeInPath
		let api = QueryAPI(config: config, store: store, webRoot: webRoot)

		let host = tailscaleIPv4() ?? "127.0.0.1"
		let port: UInt16 = 9200
		let server = try HTTPServer(api: api, host: host, port: port)
		server.run()
		log("query api listening on http://\(host):\(port) (tailscale-only bind), web root \(webRoot)")

		// LaunchAgent keeps us alive; park forever.
		while true {
			try await Task.sleep(for: .seconds(3600))
		}
	}
}
