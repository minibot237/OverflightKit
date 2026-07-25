import Foundation

/// Standard geohash (base32, Gustavo Niemeyer's scheme). Used to tag every
/// unified observation so the archive can partition by area and queries can
/// prefilter by prefix before exact bbox math.
public enum Geohash {
	static let base32 = Array("0123456789bcdefghjkmnpqrstuvwxyz")

	/// Encode to `precision` characters. 5 chars ≈ 4.9 x 4.9 km cell —
	/// the unified store's default tag.
	public static func encode(lat: Double, lon: Double, precision: Int = 5) -> String {
		var latRange = (-90.0, 90.0)
		var lonRange = (-180.0, 180.0)
		var hash = ""
		var bits = 0
		var value = 0
		var evenBit = true
		while hash.count < precision {
			if evenBit {
				let mid = (lonRange.0 + lonRange.1) / 2
				if lon >= mid {
					value = (value << 1) | 1
					lonRange.0 = mid
				} else {
					value <<= 1
					lonRange.1 = mid
				}
			} else {
				let mid = (latRange.0 + latRange.1) / 2
				if lat >= mid {
					value = (value << 1) | 1
					latRange.0 = mid
				} else {
					value <<= 1
					latRange.1 = mid
				}
			}
			evenBit.toggle()
			bits += 1
			if bits == 5 {
				hash.append(base32[value])
				bits = 0
				value = 0
			}
		}
		return hash
	}

	/// The bounding box a geohash string denotes: (latMin, latMax, lonMin, lonMax).
	public static func bounds(_ hash: String) -> (latMin: Double, latMax: Double, lonMin: Double, lonMax: Double)? {
		var latRange = (-90.0, 90.0)
		var lonRange = (-180.0, 180.0)
		var evenBit = true
		for ch in hash.lowercased() {
			guard let idx = base32.firstIndex(of: ch) else { return nil }
			for bit in stride(from: 4, through: 0, by: -1) {
				let set = (idx >> bit) & 1 == 1
				if evenBit {
					let mid = (lonRange.0 + lonRange.1) / 2
					if set { lonRange.0 = mid } else { lonRange.1 = mid }
				} else {
					let mid = (latRange.0 + latRange.1) / 2
					if set { latRange.0 = mid } else { latRange.1 = mid }
				}
				evenBit.toggle()
			}
		}
		return (latRange.0, latRange.1, lonRange.0, lonRange.1)
	}
}
