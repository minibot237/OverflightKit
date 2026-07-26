import Foundation

/// Per-vehicle write gate for slow movers (ships, trains): admit a position
/// when the vehicle has actually gone somewhere, drop the rest, and stamp a
/// keepalive periodically so a parked vehicle stays present in any time
/// window instead of vanishing between its moves.
///
/// Rules, in order:
///  1. first sighting of a vid → admit
///  2. sooner than `floorS` since the last kept point → drop (spam guard;
///     this is what bounds a fast mover's cadence)
///  3. moved at least `minMoveM` since the last kept point → admit
///  4. `stampS` or longer since the last kept point → admit (keepalive)
///  5. otherwise → drop
///
/// State is bounded by the real vehicle count; `prune` evicts vids not heard
/// from in a while so a long-running collector doesn't remember every vessel
/// that ever crossed the bbox.
public struct MovementGate: Sendable {
	public var floorS: Int64
	public var minMoveM: Double
	public var stampS: Int64

	private var last: [String: (ts: Int64, lat: Double, lon: Double)] = [:]

	public init(floorS: Int64, minMoveM: Double, stampS: Int64) {
		self.floorS = floorS
		self.minMoveM = minMoveM
		self.stampS = stampS
	}

	public mutating func admit(vid: String, ts: Int64, lat: Double, lon: Double) -> Bool {
		guard let prev = last[vid] else {
			last[vid] = (ts, lat, lon)
			return true
		}
		let age = ts - prev.ts
		if age < floorS { return false }
		if age >= stampS || Geo.distanceM(lat1: prev.lat, lon1: prev.lon, lat2: lat, lon2: lon) >= minMoveM {
			last[vid] = (ts, lat, lon)
			return true
		}
		return false
	}

	/// Forget vids whose last kept point is older than `olderThanS`.
	public mutating func prune(now: Int64, olderThanS: Int64 = 6 * 3600) {
		last = last.filter { now - $0.value.ts < olderThanS }
	}

	public var trackedCount: Int { last.count }
}
