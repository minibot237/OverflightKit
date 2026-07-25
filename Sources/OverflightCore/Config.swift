import Foundation

/// One monitored location: query center, parcel, its own database.
/// The slug keys everything — `--site` on the collector, the LaunchAgent
/// label suffix, the default database filename.
public struct SiteConfig: Codable, Sendable, Equatable, Identifiable {
	public var slug: String
	public var icao: String?
	public var displayName: String
	public var lat: Double
	public var lon: Double
	public var fieldElevationFt: Double
	public var radiusNm: Double
	public var parcel: Parcel
	public var dbPath: String
	public var metarStation: String
	public var timezone: String

	public var id: String { slug }

	public struct Parcel: Codable, Sendable, Equatable {
		public var lat: Double
		public var lon: Double
		public var radiusM: Double

		enum CodingKeys: String, CodingKey {
			case lat, lon
			case radiusM = "radius_m"
		}

		public init(lat: Double, lon: Double, radiusM: Double) {
			self.lat = lat
			self.lon = lon
			self.radiusM = radiusM
		}
	}

	enum CodingKeys: String, CodingKey {
		case slug, icao, lat, lon, parcel, timezone
		case displayName = "display_name"
		case fieldElevationFt = "field_elevation_ft"
		case radiusNm = "radius_nm"
		case dbPath = "db_path"
		case metarStation = "metar_station"
	}

	public init(
		slug: String, icao: String?, displayName: String,
		lat: Double, lon: Double, fieldElevationFt: Double,
		radiusNm: Double = 15, parcel: Parcel? = nil,
		dbPath: String? = nil, metarStation: String? = nil,
		timezone: String = "America/Chicago"
	) {
		self.slug = slug
		self.icao = icao
		self.displayName = displayName
		self.lat = lat
		self.lon = lon
		self.fieldElevationFt = fieldElevationFt
		self.radiusNm = radiusNm
		self.parcel = parcel ?? Parcel(lat: lat, lon: lon, radiusM: 400)
		self.dbPath = dbPath ?? "~/.overflight/\(slug).db"
		self.metarStation = metarStation ?? icao ?? ""
		self.timezone = timezone
	}

	public init(from decoder: Decoder) throws {
		let c = try decoder.container(keyedBy: CodingKeys.self)
		let icao = try c.decodeIfPresent(String.self, forKey: .icao)
		let slug = try c.decodeIfPresent(String.self, forKey: .slug) ?? icao?.lowercased() ?? "site"
		self.slug = slug
		self.icao = icao
		displayName = try c.decodeIfPresent(String.self, forKey: .displayName) ?? icao ?? slug
		lat = try c.decode(Double.self, forKey: .lat)
		lon = try c.decode(Double.self, forKey: .lon)
		fieldElevationFt = try c.decodeIfPresent(Double.self, forKey: .fieldElevationFt) ?? 0
		radiusNm = try c.decodeIfPresent(Double.self, forKey: .radiusNm) ?? 15
		parcel = try c.decodeIfPresent(Parcel.self, forKey: .parcel) ?? Parcel(lat: lat, lon: lon, radiusM: 400)
		dbPath = try c.decodeIfPresent(String.self, forKey: .dbPath) ?? "~/.overflight/\(slug).db"
		metarStation = try c.decodeIfPresent(String.self, forKey: .metarStation) ?? icao ?? ""
		timezone = try c.decodeIfPresent(String.self, forKey: .timezone) ?? "America/Chicago"
	}

	public var expandedDbPath: String {
		(dbPath as NSString).expandingTildeInPath
	}

	public var timeZone: TimeZone {
		TimeZone(identifier: timezone) ?? .current
	}

	/// "KGMJ — Grove Muni, OK" (or just the display name when no ICAO).
	public var title: String {
		if let icao, !icao.isEmpty, icao != displayName {
			return "\(icao) — \(displayName)"
		}
		return displayName
	}
}

/// The wide-area coarse layer: one big circle polled slowly, the surfable
/// archive under the focus sites. Verified 2026-07-25: adsb.lol serves a
/// 1300nm point query (all of CONUS) in one ~3MB response, so the default
/// sweep is a single request per tick. The fallback source caps radius at
/// 250nm, so on failover the sweep tiles the circle instead.
public struct SweepConfig: Codable, Sendable, Equatable {
	public var slug: String
	public var lat: Double
	public var lon: Double
	public var radiusNm: Double
	public var intervalS: Double
	public var enabled: Bool

	enum CodingKeys: String, CodingKey {
		case slug, lat, lon, enabled
		case radiusNm = "radius_nm"
		case intervalS = "interval_s"
	}

	public init(slug: String, lat: Double, lon: Double, radiusNm: Double, intervalS: Double = 60, enabled: Bool = true) {
		self.slug = slug
		self.lat = lat
		self.lon = lon
		self.radiusNm = radiusNm
		self.intervalS = intervalS
		self.enabled = enabled
	}

	public init(from decoder: Decoder) throws {
		let c = try decoder.container(keyedBy: CodingKeys.self)
		slug = try c.decodeIfPresent(String.self, forKey: .slug) ?? "conus"
		lat = try c.decode(Double.self, forKey: .lat)
		lon = try c.decode(Double.self, forKey: .lon)
		radiusNm = try c.decodeIfPresent(Double.self, forKey: .radiusNm) ?? 1300
		intervalS = try c.decodeIfPresent(Double.self, forKey: .intervalS) ?? 60
		enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
	}

	public var collectorLabel: String { "sweep-\(slug)" }

	/// Offset-lattice tile centers that cover this circle with `tileRadiusNm`
	/// circles. Cell 1.4r x 1.2r with alternate rows offset puts the worst
	/// gap point ~0.92r from a center — margin for lat/lon distortion.
	public func fallbackTiles(tileRadiusNm: Double = 250) -> [(lat: Double, lon: Double)] {
		let lonPitchNm = tileRadiusNm * 1.4
		let latStep = tileRadiusNm * 1.2 / 60
		var tiles: [(lat: Double, lon: Double)] = []
		var row = 0
		var tileLat = lat - radiusNm / 60
		while tileLat <= lat + radiusNm / 60 + latStep / 2 {
			let clampedLat = max(-85.0, min(85.0, tileLat))
			let lonStep = lonPitchNm / (60 * cos(clampedLat * .pi / 180))
			let offset = row % 2 == 0 ? 0 : lonStep / 2
			let halfWidth = radiusNm / (60 * cos(clampedLat * .pi / 180))
			var tileLon = lon - halfWidth + offset
			while tileLon <= lon + halfWidth + lonStep / 2 {
				let d = Geo.distanceM(lat1: lat, lon1: lon, lat2: clampedLat, lon2: tileLon) / Geo.metersPerNm
				if d <= radiusNm + tileRadiusNm {
					tiles.append((clampedLat, tileLon))
				}
				tileLon += lonStep
			}
			row += 1
			tileLat += latStep
		}
		return tiles
	}
}

/// Global settings plus the site list, at ~/.overflight/config.json.
/// A legacy single-site file (top-level `site`/`parcel`/`db_path` keys)
/// decodes into a one-element site list, preserving its database path.
public struct Config: Codable, Sendable, Equatable {
	public var pollIntervalS: Double
	public var primarySource: String
	public var fallbackSource: String
	public var sites: [SiteConfig]
	/// The unified two-tier ingest database every collector appends to.
	public var unifiedDbPath: String
	/// Optional wide-area coarse sweep.
	public var sweep: SweepConfig?

	public var expandedUnifiedDbPath: String {
		(unifiedDbPath as NSString).expandingTildeInPath
	}

	enum CodingKeys: String, CodingKey {
		case sites, sweep
		case pollIntervalS = "poll_interval_s"
		case primarySource = "primary_source"
		case fallbackSource = "fallback_source"
		case unifiedDbPath = "unified_db_path"
	}

	private enum LegacyKeys: String, CodingKey {
		case site, parcel, timezone
		case radiusNm = "radius_nm"
		case dbPath = "db_path"
		case metarStation = "metar_station"
	}

	private struct LegacySite: Decodable {
		let lat: Double
		let lon: Double
		let fieldElevationFt: Double?

		enum CodingKeys: String, CodingKey {
			case lat, lon
			case fieldElevationFt = "field_elevation_ft"
		}
	}

	public init(pollIntervalS: Double, primarySource: String, fallbackSource: String, sites: [SiteConfig], unifiedDbPath: String = UnifiedStore.defaultPath, sweep: SweepConfig? = nil) {
		self.pollIntervalS = pollIntervalS
		self.primarySource = primarySource
		self.fallbackSource = fallbackSource
		self.sites = sites
		self.unifiedDbPath = unifiedDbPath
		self.sweep = sweep
	}

	public init(from decoder: Decoder) throws {
		let d = Config.kgmjDefault
		let c = try decoder.container(keyedBy: CodingKeys.self)
		pollIntervalS = try c.decodeIfPresent(Double.self, forKey: .pollIntervalS) ?? d.pollIntervalS
		primarySource = try c.decodeIfPresent(String.self, forKey: .primarySource) ?? d.primarySource
		fallbackSource = try c.decodeIfPresent(String.self, forKey: .fallbackSource) ?? d.fallbackSource
		unifiedDbPath = try c.decodeIfPresent(String.self, forKey: .unifiedDbPath) ?? UnifiedStore.defaultPath
		sweep = try c.decodeIfPresent(SweepConfig.self, forKey: .sweep)
		if let decoded = try c.decodeIfPresent([SiteConfig].self, forKey: .sites), !decoded.isEmpty {
			sites = decoded
			return
		}
		// Legacy single-site layout.
		let legacy = try decoder.container(keyedBy: LegacyKeys.self)
		guard let ls = try legacy.decodeIfPresent(LegacySite.self, forKey: .site) else {
			sites = d.sites
			return
		}
		let station = try legacy.decodeIfPresent(String.self, forKey: .metarStation) ?? "KGMJ"
		var site = SiteConfig(
			slug: station.lowercased(),
			icao: station,
			displayName: station == "KGMJ" ? "Grove Muni, OK" : station,
			lat: ls.lat, lon: ls.lon,
			fieldElevationFt: ls.fieldElevationFt ?? 0,
			radiusNm: try legacy.decodeIfPresent(Double.self, forKey: .radiusNm) ?? 15,
			metarStation: station,
			timezone: try legacy.decodeIfPresent(String.self, forKey: .timezone) ?? "America/Chicago"
		)
		if let p = try legacy.decodeIfPresent(SiteConfig.Parcel.self, forKey: .parcel) {
			site.parcel = p
		}
		if let path = try legacy.decodeIfPresent(String.self, forKey: .dbPath) {
			site.dbPath = path
		}
		sites = [site]
	}

	public static let kgmjSite = SiteConfig(
		slug: "kgmj",
		icao: "KGMJ",
		displayName: "Grove Muni, OK",
		lat: 36.6067, lon: -94.7386,
		fieldElevationFt: 832,
		radiusNm: 15,
		dbPath: "~/.overflight/overflight.db",
		metarStation: "KGMJ",
		timezone: "America/Chicago"
	)

	public static let kgmjDefault = Config(
		pollIntervalS: 10,
		primarySource: "adsb.lol",
		fallbackSource: "airplanes.live",
		sites: [kgmjSite]
	)

	public static let defaultPath = "~/.overflight/config.json"

	public func site(slug: String?) -> SiteConfig? {
		guard let slug else { return sites.first }
		return sites.first { $0.slug == slug }
	}

	public mutating func upsert(site: SiteConfig) {
		if let i = sites.firstIndex(where: { $0.slug == site.slug }) {
			sites[i] = site
		} else {
			sites.append(site)
		}
	}

	/// Known aggregator hosts. A source name that is already a URL is used as-is,
	/// so a config can point at any ADSBExchange-v2-compatible endpoint.
	public static func baseURL(forSource name: String) -> String? {
		switch name {
		case "adsb.lol": return "https://api.adsb.lol"
		case "airplanes.live": return "https://api.airplanes.live"
		default:
			if name.hasPrefix("http://") || name.hasPrefix("https://") {
				return name.hasSuffix("/") ? String(name.dropLast()) : name
			}
			return nil
		}
	}

	public static func load(path: String? = nil) throws -> Config {
		let p = ((path ?? defaultPath) as NSString).expandingTildeInPath
		guard FileManager.default.fileExists(atPath: p) else {
			throw OverflightError.notFound("config not found at \(p)")
		}
		let data = try Data(contentsOf: URL(fileURLWithPath: p))
		return try JSONDecoder().decode(Config.self, from: data)
	}

	/// Load the config, writing the KGMJ defaults out first if no file exists.
	public static func loadOrCreate(path: String? = nil) throws -> Config {
		let p = ((path ?? defaultPath) as NSString).expandingTildeInPath
		if !FileManager.default.fileExists(atPath: p) {
			try kgmjDefault.save(path: p)
		}
		return try load(path: p)
	}

	public func save(path: String? = nil) throws {
		let p = ((path ?? Config.defaultPath) as NSString).expandingTildeInPath
		let dir = (p as NSString).deletingLastPathComponent
		try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
		let enc = JSONEncoder()
		enc.outputFormatting = [.prettyPrinted, .sortedKeys]
		try enc.encode(self).write(to: URL(fileURLWithPath: p), options: .atomic)
	}
}
