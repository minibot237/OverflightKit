import Foundation
import OverflightCore

/// The coarse layer: one big-radius request per tick against the primary
/// (verified: adsb.lol serves 1300nm — all of CONUS — in one ~3MB response),
/// falling back to a 250nm tile ring on the fallback source, which hard-caps
/// radius at 250nm. Writes only to the unified store; there is no site DB
/// and no parcel here. Resolution follows purpose: this layer is the archive,
/// terminal-area shape belongs to the focus sites.
struct SweepLoop: Sendable {
	let config: Config
	let sweep: SweepConfig
	let unified: UnifiedStore
	let session: URLSession

	init(config: Config, sweep: SweepConfig, unified: UnifiedStore) {
		self.config = config
		self.sweep = sweep
		self.unified = unified
		let sc = URLSessionConfiguration.ephemeral
		sc.timeoutIntervalForRequest = 30
		sc.httpAdditionalHeaders = ["User-Agent": "OverflightKit/1.0 (+https://github.com/minibot237/OverflightKit)"]
		session = URLSession(configuration: sc)
	}

	func pollPoint(source name: String, lat: Double, lon: Double, radiusNm: Double) async -> PollOutcome {
		let ts = Int64(Date().timeIntervalSince1970)
		func failed(_ status: Int?, _ error: String, _ ms: Int?, retryAfterS: Double? = nil) -> PollOutcome {
			PollOutcome(
				record: PollRecord(ts: ts, source: name, httpStatus: status, error: error, aircraftCount: 0, latencyMs: ms),
				aircraft: [],
				retryAfterS: retryAfterS
			)
		}
		guard let base = Config.baseURL(forSource: name),
			let url = URL(string: "\(base)/v2/point/\(lat)/\(lon)/\(Int(radiusNm.rounded()))")
		else {
			return failed(nil, "unknown source '\(name)'", nil)
		}
		let start = Date()
		do {
			let (data, resp) = try await session.data(from: url)
			let ms = Int(Date().timeIntervalSince(start) * 1000)
			let http = resp as? HTTPURLResponse
			let status = http?.statusCode
			guard status == 200 else {
				let retryAfter = http?.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init)
				return failed(status, "http \(status.map(String.init) ?? "?")", ms, retryAfterS: retryAfter)
			}
			do {
				let decoded = try JSONDecoder().decode(PointResponse.self, from: data)
				return PollOutcome(
					record: PollRecord(ts: ts, source: name, httpStatus: 200, error: nil, aircraftCount: decoded.ac.count, latencyMs: ms),
					aircraft: decoded.ac
				)
			} catch {
				return failed(200, "decode: \(error)", ms)
			}
		} catch {
			let ms = Int(Date().timeIntervalSince(start) * 1000)
			return failed(nil, "transport: \(error.localizedDescription)", ms)
		}
	}

	/// One fallback cycle: walk the tile ring politely (fallback source is a
	/// documented 1 req/s), dedupe aircraft seen in overlapping tiles, and
	/// record the whole cycle as a single poll row.
	func pollFallbackTiles() async -> PollOutcome {
		let ts = Int64(Date().timeIntervalSince1970)
		let tiles = sweep.fallbackTiles()
		let start = Date()
		var byHex: [String: Aircraft] = [:]
		var okTiles = 0
		var lastError: String?
		var retryAfterMax: Double?
		for (i, tile) in tiles.enumerated() {
			let outcome = await pollPoint(source: config.fallbackSource, lat: tile.lat, lon: tile.lon, radiusNm: 250)
			if outcome.record.error == nil {
				okTiles += 1
				for a in outcome.aircraft where byHex[a.hex] == nil {
					byHex[a.hex] = a
				}
			} else {
				lastError = outcome.record.error
				if let ra = outcome.retryAfterS {
					retryAfterMax = max(retryAfterMax ?? 0, ra)
				}
			}
			if i < tiles.count - 1 {
				try? await Task.sleep(for: .seconds(1.3))
			}
		}
		let ms = Int(Date().timeIntervalSince(start) * 1000)
		let aircraft = Array(byHex.values)
		let error = okTiles == 0 ? (lastError ?? "all tiles failed") : nil
		if okTiles < tiles.count {
			log("sweep fallback: \(okTiles)/\(tiles.count) tiles ok")
		}
		return PollOutcome(
			record: PollRecord(ts: ts, source: config.fallbackSource, httpStatus: nil, error: error, aircraftCount: aircraft.count, latencyMs: ms),
			aircraft: aircraft,
			retryAfterS: retryAfterMax
		)
	}

	func run() async {
		var activePrimary = true
		var failStreak = 0
		var backoffS = 0.0
		var pollsUntilPrimaryProbe = 0
		var pollCount = 0
		var okSinceLastSummary = 0
		var acSinceLastSummary = 0
		let label = sweep.collectorLabel

		while !Task.isCancelled {
			let cycleStart = Date()
			let probing = !activePrimary && pollsUntilPrimaryProbe <= 0
			let usePrimary = activePrimary || probing

			let outcome: PollOutcome
			if usePrimary {
				outcome = await pollPoint(source: config.primarySource, lat: sweep.lat, lon: sweep.lon, radiusNm: sweep.radiusNm)
			} else {
				outcome = await pollFallbackTiles()
			}

			do {
				let obs = outcome.aircraft
					.filter { $0.lat != nil && $0.lon != nil }
					.map { UnifiedObservation(aircraft: $0, ts: outcome.record.ts, source: outcome.record.source) }
				try await unified.record(poll: outcome.record, collector: label, observations: obs)
			} catch {
				log("unified db write failed: \(error)")
			}

			pollCount += 1
			if outcome.record.error == nil {
				okSinceLastSummary += 1
				acSinceLastSummary += outcome.record.aircraftCount
				failStreak = 0
				backoffS = 0
				if probing {
					activePrimary = true
					log("primary \(config.primarySource) recovered — back to single-request sweep")
				}
			} else {
				log("sweep \(outcome.record.source): \(outcome.record.error ?? "?")")
				if probing {
					pollsUntilPrimaryProbe = 10
				} else {
					failStreak += 1
					backoffS = min(backoffS == 0 ? sweep.intervalS * 2 : backoffS * 2, 600)
					if let ra = outcome.retryAfterS {
						backoffS = min(max(ra, backoffS), 600)
					}
					if activePrimary, failStreak >= 3 {
						activePrimary = false
						pollsUntilPrimaryProbe = 10
						failStreak = 0
						backoffS = 0
						log("sweep switching to \(config.fallbackSource) tile ring (\(sweep.fallbackTiles().count) tiles)")
					}
				}
			}
			if !activePrimary, !probing {
				pollsUntilPrimaryProbe -= 1
			}

			if pollCount % 30 == 0 {
				log("sweep \(pollCount) cycles, last 30: \(okSinceLastSummary) ok, \(acSinceLastSummary) aircraft rows")
				okSinceLastSummary = 0
				acSinceLastSummary = 0
			}

			// Hold the cadence: sleep whatever remains of the tick after the
			// request (a fallback tile walk can eat most of it).
			let elapsed = Date().timeIntervalSince(cycleStart)
			let base = backoffS > 0 ? backoffS : max(1, sweep.intervalS - elapsed)
			let delay = max(1.0, base + Double.random(in: -2...2))
			do {
				try await Task.sleep(for: .seconds(delay))
			} catch {
				break
			}
		}
	}
}
