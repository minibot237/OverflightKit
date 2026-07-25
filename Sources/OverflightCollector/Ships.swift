import Foundation
import OverflightCore

/// Live AIS via aisstream.io websocket (kind=vessel). Free key, beta service,
/// no SLA — the loop reconnects with backoff forever. Position reports are
/// buffered and flushed to the unified store as one poll row per interval,
/// so poll-table health math works the same as the HTTP collectors.
///
/// Protocol (docs fetched 2026-07-25): connect wss://stream.aisstream.io/v0/stream,
/// send the subscription JSON within 3 seconds or be dropped.
struct AisLoop: Sendable {
	let config: Config
	let ais: AisConfig
	let unified: UnifiedStore

	static let flushIntervalS: Double = 15

	struct Subscription: Encodable {
		var APIKey: String
		var BoundingBoxes: [[[Double]]]
		var FilterMessageTypes: [String]
	}

	/// One incoming frame. Only PositionReport is subscribed; everything else
	/// decodes to nil fields and is dropped.
	struct Frame: Decodable {
		struct Meta: Decodable {
			var MMSI: Int64?
			var ShipName: String?
			var latitude: Double?
			var longitude: Double?
		}
		struct PositionReport: Decodable {
			var Latitude: Double?
			var Longitude: Double?
			var Sog: Double?
			var Cog: Double?
			var TrueHeading: Double?
		}
		struct Message: Decodable {
			var PositionReport: PositionReport?
		}
		var MessageType: String?
		var MetaData: Meta?
		var Message: Message?
	}

	func observation(from frame: Frame, ts: Int64) -> UnifiedObservation? {
		guard frame.MessageType == "PositionReport",
			let meta = frame.MetaData, let mmsi = meta.MMSI else { return nil }
		let pr = frame.Message?.PositionReport
		guard let lat = pr?.Latitude ?? meta.latitude,
			let lon = pr?.Longitude ?? meta.longitude,
			abs(lat) <= 90, abs(lon) <= 180 else { return nil }
		// TrueHeading 511 means unavailable; fall back to course over ground.
		var heading = pr?.TrueHeading
		if let h = heading, h >= 360 { heading = nil }
		heading = heading ?? pr?.Cog
		let name = meta.ShipName?.trimmingCharacters(in: .whitespaces)
		return UnifiedObservation(
			kind: .vessel, vid: String(mmsi), ts: ts,
			lat: lat, lon: lon,
			speedKt: pr?.Sog, headingDeg: heading,
			callsign: (name?.isEmpty ?? true) ? nil : name,
			source: "aisstream")
	}

	func run() async {
		guard let key = ais.apiKey, !key.isEmpty else {
			log("ais: no api_key configured — nothing to do")
			return
		}
		var backoffS = 2.0
		while !Task.isCancelled {
			do {
				try await streamOnce(key: key)
				backoffS = 2
			} catch {
				log("ais stream dropped: \(error)")
			}
			if Task.isCancelled { break }
			log("ais reconnecting in \(Int(backoffS))s")
			try? await Task.sleep(for: .seconds(backoffS))
			backoffS = min(backoffS * 2, 300)
		}
	}

	func streamOnce(key: String) async throws {
		let session = URLSession(configuration: .ephemeral)
		guard let url = URL(string: "wss://stream.aisstream.io/v0/stream") else { return }
		let ws = session.webSocketTask(with: url)
		ws.resume()
		defer { ws.cancel(with: .normalClosure, reason: nil) }

		let sub = Subscription(
			APIKey: key,
			BoundingBoxes: [[[ais.bbox[0], ais.bbox[1]], [ais.bbox[2], ais.bbox[3]]]],
			FilterMessageTypes: ["PositionReport"])
		let subData = try JSONEncoder().encode(sub)
		try await ws.send(.string(String(decoding: subData, as: UTF8.self)))
		log("ais subscribed: bbox \(ais.bbox)")

		var buffer: [UnifiedObservation] = []
		var lastFlush = Date()
		let decoder = JSONDecoder()
		while !Task.isCancelled {
			let msg = try await ws.receive()
			let data: Data
			switch msg {
			case .string(let s): data = Data(s.utf8)
			case .data(let d): data = d
			@unknown default: continue
			}
			let ts = Int64(Date().timeIntervalSince1970)
			if let frame = try? decoder.decode(Frame.self, from: data),
				let obs = observation(from: frame, ts: ts) {
				buffer.append(obs)
			}
			if Date().timeIntervalSince(lastFlush) >= Self.flushIntervalS {
				let batch = buffer
				buffer.removeAll(keepingCapacity: true)
				lastFlush = Date()
				let poll = PollRecord(
					ts: ts, source: "aisstream", httpStatus: nil, error: nil,
					aircraftCount: batch.count, latencyMs: nil)
				do {
					try await unified.record(poll: poll, collector: "ais", observations: batch)
				} catch {
					log("ais db write failed: \(error)")
				}
			}
		}
	}
}
