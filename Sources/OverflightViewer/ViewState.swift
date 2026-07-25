import Foundation
import OverflightCore

/// Per-site viewer state remembered across launches: where the map was left
/// (center + zoom span) and which altitude bands were enabled. Stored in
/// UserDefaults — it's UI state, not collection config. Map fields and band
/// fields are written by different owners, so updates load-modify-write.
struct SiteViewState: Codable {
	var centerLat: Double?
	var centerLon: Double?
	var spanLatDeg: Double?
	var spanLonDeg: Double?
	var enabledBands: [Int]?
	var showGround: Bool?
	var enabledKinds: [String]?

	static func load(slug: String) -> SiteViewState {
		guard let data = UserDefaults.standard.data(forKey: key(slug)),
			let state = try? JSONDecoder().decode(SiteViewState.self, from: data)
		else {
			return SiteViewState()
		}
		return state
	}

	func save(slug: String) {
		if let data = try? JSONEncoder().encode(self) {
			UserDefaults.standard.set(data, forKey: Self.key(slug))
		}
	}

	static func update(slug: String, _ mutate: (inout SiteViewState) -> Void) {
		var state = load(slug: slug)
		mutate(&state)
		state.save(slug: slug)
	}

	private static func key(_ slug: String) -> String {
		"siteState.\(slug)"
	}
}

/// Which browsing mode the picker was left in and where the remote server
/// lives. Same UserDefaults treatment as the per-site state.
struct BrowseModeState: Codable {
	var mode: String?
	var serverURL: String?

	static let defaultServerURL = "http://127.0.0.1:9200"
	private static let key = "browseMode"

	static func load() -> BrowseModeState {
		guard let data = UserDefaults.standard.data(forKey: key),
			let state = try? JSONDecoder().decode(BrowseModeState.self, from: data)
		else {
			return BrowseModeState()
		}
		return state
	}

	func save() {
		if let data = try? JSONEncoder().encode(self) {
			UserDefaults.standard.set(data, forKey: Self.key)
		}
	}
}
