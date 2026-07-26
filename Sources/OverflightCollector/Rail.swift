import Foundation
import OverflightCore

/// Trains via the Amtraker community API (kind=train). No key; the
/// maintainer asks for attribution, which the README carries. One request
/// per interval for every active train in the country — the politest feed
/// we have. Verified live 2026-07-25: dict keyed by train number, each value
/// an ARRAY of concurrent runs; heading is a compass string; velocity mph.
struct RailLoop: Sendable {
	let config: Config
	let rail: RailConfig
	let unified: UnifiedStore
	let session: URLSession

	init(config: Config, rail: RailConfig, unified: UnifiedStore) {
		self.config = config
		self.rail = rail
		self.unified = unified
		let sc = URLSessionConfiguration.ephemeral
		sc.timeoutIntervalForRequest = 20
		sc.httpAdditionalHeaders = ["User-Agent": "OverflightKit/1.0 (+https://github.com/minibot237/OverflightKit)"]
		session = URLSession(configuration: sc)
	}

	struct Train: Decodable {
		var trainID: String?
		var trainNum: String?
		var routeName: String?
		var lat: Double?
		var lon: Double?
		var heading: String?
		var velocity: Double?
	}

	static let compassDeg: [String: Double] = [
		"N": 0, "NNE": 22.5, "NE": 45, "ENE": 67.5,
		"E": 90, "ESE": 112.5, "SE": 135, "SSE": 157.5,
		"S": 180, "SSW": 202.5, "SW": 225, "WSW": 247.5,
		"W": 270, "WNW": 292.5, "NW": 315, "NNW": 337.5,
	]
	static let mphToKt = 0.868976

	static func observation(from t: Train, ts: Int64) -> UnifiedObservation? {
		guard let lat = t.lat, let lon = t.lon, lat != 0 || lon != 0,
			abs(lat) <= 90, abs(lon) <= 180 else { return nil }
		let vid = t.trainID ?? t.trainNum ?? "?"
		var callsign = t.routeName ?? ""
		if let num = t.trainNum { callsign = callsign.isEmpty ? num : "\(callsign) \(num)" }
		return UnifiedObservation(
			kind: .train, vid: vid, ts: ts, lat: lat, lon: lon,
			speedKt: t.velocity.map { $0 * mphToKt },
			headingDeg: t.heading.flatMap { compassDeg[$0] },
			callsign: callsign.isEmpty ? nil : callsign,
			source: "amtraker")
	}

	func pollOnce() async -> (PollRecord, [UnifiedObservation]) {
		let ts = Int64(Date().timeIntervalSince1970)
		guard let url = URL(string: "https://api-v3.amtraker.com/v3/trains") else {
			return (PollRecord(ts: ts, source: "amtraker", httpStatus: nil, error: "bad url", aircraftCount: 0, latencyMs: nil), [])
		}
		let start = Date()
		do {
			let (data, resp) = try await session.data(from: url)
			let ms = Int(Date().timeIntervalSince(start) * 1000)
			let status = (resp as? HTTPURLResponse)?.statusCode
			guard status == 200 else {
				return (PollRecord(ts: ts, source: "amtraker", httpStatus: status, error: "http \(status.map(String.init) ?? "?")", aircraftCount: 0, latencyMs: ms), [])
			}
			let decoded = try JSONDecoder().decode([String: [Train]].self, from: data)
			let obs = decoded.values.flatMap { $0 }.compactMap { Self.observation(from: $0, ts: ts) }
			return (PollRecord(ts: ts, source: "amtraker", httpStatus: 200, error: nil, aircraftCount: obs.count, latencyMs: ms), obs)
		} catch {
			let ms = Int(Date().timeIntervalSince(start) * 1000)
			return (PollRecord(ts: ts, source: "amtraker", httpStatus: nil, error: "\(error.localizedDescription)", aircraftCount: 0, latencyMs: ms), [])
		}
	}

	func run() async {
		var pollCount = 0
		// Amtraker repeats a train's last fix until its tracker updates, and
		// station dwell would otherwise write the same spot every poll — the
		// gate keeps movement and stamps parked trains periodically. No floor:
		// the poll interval already bounds cadence.
		var gate = MovementGate(
			floorS: 0,
			minMoveM: rail.minMoveM,
			stampS: Int64(rail.stampIntervalS))
		while !Task.isCancelled {
			let (record, obs) = await pollOnce()
			let kept = obs.filter { gate.admit(vid: $0.vid, ts: $0.ts, lat: $0.lat, lon: $0.lon) }
			do {
				try await unified.record(poll: record, collector: "rail", observations: kept)
			} catch {
				log("rail db write failed: \(error)")
			}
			pollCount += 1
			if pollCount % 60 == 0 {
				gate.prune(now: Int64(Date().timeIntervalSince1970))
			}
			if let err = record.error {
				log("rail: \(err)")
			} else if pollCount % 30 == 1 {
				log("rail: \(record.aircraftCount) trains seen, \(kept.count) kept, \(record.latencyMs ?? 0)ms")
			}
			let delay = max(30, rail.intervalS + Double.random(in: -2...2))
			do {
				try await Task.sleep(for: .seconds(delay))
			} catch {
				break
			}
		}
	}
}
