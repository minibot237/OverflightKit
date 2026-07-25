import Foundation
import Observation
import CoreLocation
import OverflightCore

enum SegmentClass: Hashable, Sendable {
	case band(Int)
	case ground
	case unknownAlt
	case vessel
	case train
}

enum RangePreset: Hashable {
	case hour, sixHours, day, week, month, all, custom
}

/// The leading tip of a still-active track: where the aircraft is right now,
/// and which way it's pointed.
struct TrackHead: Identifiable, Sendable {
	let id: String
	let lat: Double
	let lon: Double
	let headingDeg: Double?
	let cls: SegmentClass
	let colorIndex: Int
}

/// One currently-active aircraft (heard within the last two minutes),
/// for the "Active now" panel.
struct ActiveFlight: Identifiable, Sendable {
	let id: String
	let kind: VehicleKind
	let name: String
	let typeCode: String?
	let aglFt: Double?
	let altSource: AltitudeSource
	let onGround: Bool
	let gsKt: Double?
	let lastTs: Int64
	let colorIndex: Int
}

/// A one-shot "find this aircraft on the map" request from the Active-now
/// list; the sequence number distinguishes repeat clicks on the same row.
struct FocusRequest: Equatable {
	let trackId: String
	let seq: Int
}

@MainActor
@Observable
final class ViewerModel {
	let site: SiteConfig
	/// Non-nil in remote mode: the window browses minibot's query API instead
	/// of a local site database. `site` is then synthesized from the remote
	/// view (slug/title/center/radius) so the map plumbing works unchanged.
	let remote: RemoteAPI?
	private(set) var config: Config?
	private(set) var store: Store?
	private(set) var loadError: String?
	private(set) var loading = false
	/// True when the site's database doesn't exist yet — no collector has run.
	private(set) var dbMissing = false

	var isRemote: Bool { remote != nil }

	/// UserDefaults key for remembered view state. Remote gets its own
	/// namespace so a remote "seatacwa" doesn't clobber the local one.
	var viewStateSlug: String { Self.viewStateSlug(slug: site.slug, remote: isRemote) }

	static func viewStateSlug(slug: String, remote: Bool) -> String {
		remote ? "remote.\(slug)" : slug
	}

	// Filters
	var rangeStart: Date
	var rangeEnd: Date
	var rangePreset: RangePreset = .week
	var enabledBands: Set<AltitudeBand> = Set(AltitudeBand.allCases)
	var showGround = false

	// Parcel (persisted back to the site's config entry automatically)
	var parcelLat: Double
	var parcelLon: Double
	var parcelRadiusM: Double

	// Remote data: server-segmented tracks for the current window + viewport,
	// plus which kinds the query asks for and the latest health snapshot.
	private(set) var remoteTracks: [RemoteTrack] = []
	private(set) var remoteHealth: RemoteHealth?
	private(set) var remoteTruncated = false
	var enabledKinds: Set<VehicleKind> = Set(VehicleKind.allCases)
	/// The map viewport (slightly inflated), which remote queries follow.
	private var queryBbox: (latMin: Double, lonMin: Double, latMax: Double, lonMax: Double)

	// Data
	private(set) var tracks: [Track] = []
	private(set) var overflights: [Overflight] = []
	private(set) var hourHist: [Int] = Array(repeating: 0, count: 24)
	private(set) var bandHist = BandHistogram()
	private(set) var coverage: CoverageDiagnostic?
	private(set) var pollStats: PollStats?
	private(set) var segmentsByClass: [SegmentClass: [[CLLocationCoordinate2D]]] = [:]
	private(set) var trackHeads: [TrackHead] = []
	private(set) var activeFlights: [ActiveFlight] = []
	private(set) var mapRevision = 0
	private(set) var lastLoaded: Date?
	private(set) var focusRequest: FocusRequest?
	private(set) var recenterSeq = 0

	var autoRefresh = true
	private var refreshTask: Task<Void, Never>?
	private var altimeters: AltimeterHistory?
	/// Sticky identity-color slot per aircraft hex, held while it stays active.
	private var identitySlots: [String: Int] = [:]
	private var focusSeq = 0

	// Incremental refresh state. Rows older than `settledTs` are final in the
	// buffer; the tail (rows newer than that) is re-fetched every cycle because
	// a poll's rows commit a moment after its timestamp.
	private var settledObservations: [AircraftObservation] = []
	private var tailObservations: [AircraftObservation] = []
	private var settledTs: Int64 = 0
	private static let settleMarginS: Int64 = 20

	var windowTitle: String { isRemote ? "\(site.title) — remote" : site.title }

	init(site: SiteConfig, config: Config) {
		self.site = site
		self.config = config
		remote = nil
		parcelLat = site.parcel.lat
		parcelLon = site.parcel.lon
		parcelRadiusM = site.parcel.radiusM
		queryBbox = Self.defaultBbox(site: site)
		let now = Date()
		rangeEnd = now
		rangeStart = now.addingTimeInterval(-7 * 86_400)
		let saved = SiteViewState.load(slug: site.slug)
		if let bands = saved.enabledBands {
			enabledBands = Set(bands.compactMap(AltitudeBand.init(rawValue:)))
		}
		if let ground = saved.showGround {
			showGround = ground
		}
	}

	init(remote: RemoteAPI, view: RemoteView) {
		let site = SiteConfig(
			slug: view.slug, icao: nil, displayName: view.title,
			lat: view.lat, lon: view.lon, fieldElevationFt: 0,
			radiusNm: view.radiusNm, timezone: TimeZone.current.identifier
		)
		self.site = site
		self.remote = remote
		config = nil
		parcelLat = site.parcel.lat
		parcelLon = site.parcel.lon
		parcelRadiusM = site.parcel.radiusM
		// Short default window: remote queries re-fetch whole windows, and the
		// busy sites push six figures of rows per day.
		rangePreset = .hour
		let now = Date()
		rangeEnd = now
		rangeStart = now.addingTimeInterval(-3600)
		let saved = SiteViewState.load(slug: Self.viewStateSlug(slug: view.slug, remote: true))
		if let lat = saved.centerLat, let lon = saved.centerLon,
			let dLat = saved.spanLatDeg, let dLon = saved.spanLonDeg {
			queryBbox = Self.clampBbox(
				latMin: lat - dLat / 2, lonMin: lon - dLon / 2,
				latMax: lat + dLat / 2, lonMax: lon + dLon / 2)
		} else {
			queryBbox = Self.defaultBbox(site: site)
		}
		if let bands = saved.enabledBands {
			enabledBands = Set(bands.compactMap(AltitudeBand.init(rawValue:)))
		}
		if let kinds = saved.enabledKinds {
			let parsed = Set(kinds.compactMap(VehicleKind.init(rawValue:)))
			if !parsed.isEmpty { enabledKinds = parsed }
		}
	}

	private static func defaultBbox(site: SiteConfig) -> (latMin: Double, lonMin: Double, latMax: Double, lonMax: Double) {
		let dLat = site.radiusNm * 1.2 / 60
		let dLon = site.radiusNm * 1.2 / (60 * max(0.1, cos(site.lat * .pi / 180)))
		return clampBbox(
			latMin: site.lat - dLat, lonMin: site.lon - dLon,
			latMax: site.lat + dLat, lonMax: site.lon + dLon)
	}

	/// The server rejects out-of-range bboxes, and a zoomed-out MapKit span
	/// happily exceeds the globe.
	private static func clampBbox(latMin: Double, lonMin: Double, latMax: Double, lonMax: Double) -> (latMin: Double, lonMin: Double, latMax: Double, lonMax: Double) {
		(
			latMin: max(-90, min(89.9, latMin)),
			lonMin: max(-180, min(179.9, lonMin)),
			latMax: max(-89.9, min(90, latMax)),
			lonMax: max(-179.9, min(180, lonMax))
		)
	}

	private func persistBandSelection() {
		SiteViewState.update(slug: viewStateSlug) {
			$0.enabledBands = enabledBands.map(\.rawValue).sorted()
			$0.showGround = showGround
			$0.enabledKinds = enabledKinds.map(\.rawValue).sorted()
		}
	}

	func start() {
		guard refreshTask == nil else { return }
		refreshTask = Task { [weak self] in
			var first = true
			while !Task.isCancelled {
				guard let self else { return }
				if first {
					first = false
					await self.reload()
				} else if self.autoRefresh {
					await self.refreshTick()
				}
				try? await Task.sleep(for: .seconds(10))
			}
		}
	}

	/// Full reload: used at start and whenever the window itself changes
	/// (preset, custom dates). Auto-refresh uses the incremental path.
	func reload() async {
		if isRemote {
			await remoteReload()
			return
		}
		guard !loading else { return }
		loading = true
		defer { loading = false }
		do {
			let store = try openStoreIfNeeded()

			if rangePreset != .custom {
				rangeEnd = Date()
				switch rangePreset {
				case .hour: rangeStart = rangeEnd.addingTimeInterval(-3600)
				case .sixHours: rangeStart = rangeEnd.addingTimeInterval(-6 * 3600)
				case .day: rangeStart = rangeEnd.addingTimeInterval(-86_400)
				case .week: rangeStart = rangeEnd.addingTimeInterval(-7 * 86_400)
				case .month: rangeStart = rangeEnd.addingTimeInterval(-30 * 86_400)
				case .all:
					if let bounds = try await store.observationTimeBounds() {
						rangeStart = Date(timeIntervalSince1970: Double(bounds.first))
					}
				case .custom: break
				}
			}

			let from = Int64(rangeStart.timeIntervalSince1970)
			let to = Int64(rangeEnd.timeIntervalSince1970)
			let obs = try await store.observations(from: from, to: to)
			settledTs = to - Self.settleMarginS
			settledObservations = obs.filter { $0.ts <= settledTs }
			tailObservations = obs.filter { $0.ts > settledTs }

			try await finishRebuild(store: store, from: from, to: to)
			loadError = nil
			lastLoaded = Date()
		} catch {
			if case OverflightError.notFound = error {
				dbMissing = true
				loadError = "no data yet — the collector for this site isn't running"
			} else {
				loadError = "\(error)"
			}
			store = nil
		}
	}

	/// Incremental refresh: slide the window forward and fetch only rows newer
	/// than the settled boundary, so a 10s cadence stays cheap over a
	/// weeks-deep database.
	private func refreshTick() async {
		if isRemote {
			guard rangePreset != .custom else {
				// Fixed historical window: only the health readout moves.
				if let remote {
					remoteHealth = try? await remote.health()
				}
				return
			}
			await remoteReload()
			return
		}
		guard !loading else { return }
		guard rangePreset != .custom else {
			// Fixed historical window: only the status strip needs refreshing.
			if let store {
				pollStats = try? await store.pollStats(gapThresholdS: 300, expectedIntervalS: config?.pollIntervalS ?? 10)
				rebuildTrackHeads()
			}
			return
		}
		loading = true
		defer { loading = false }
		do {
			let store = try openStoreIfNeeded()
			rangeEnd = Date()
			switch rangePreset {
			case .hour: rangeStart = rangeEnd.addingTimeInterval(-3600)
			case .sixHours: rangeStart = rangeEnd.addingTimeInterval(-6 * 3600)
			case .day: rangeStart = rangeEnd.addingTimeInterval(-86_400)
			case .week: rangeStart = rangeEnd.addingTimeInterval(-7 * 86_400)
			case .month: rangeStart = rangeEnd.addingTimeInterval(-30 * 86_400)
			case .all, .custom: break
			}
			let from = Int64(rangeStart.timeIntervalSince1970)
			let to = Int64(rangeEnd.timeIntervalSince1970)

			let fresh = try await store.observations(from: settledTs + 1, to: to)
			let newSettled = to - Self.settleMarginS
			settledObservations.append(contentsOf: fresh.filter { $0.ts <= newSettled })
			tailObservations = fresh.filter { $0.ts > newSettled }
			settledTs = newSettled
			if let firstKept = settledObservations.first, firstKept.ts < from {
				settledObservations.removeAll { $0.ts < from }
			}

			try await finishRebuild(store: store, from: from, to: to)
			loadError = nil
			lastLoaded = Date()
		} catch {
			if case OverflightError.notFound = error {
				dbMissing = true
				loadError = "no data yet — the collector for this site isn't running"
			} else {
				loadError = "\(error)"
			}
			store = nil
		}
	}

	// MARK: - Remote mode

	/// Remote windows re-fetch whole windows — no incremental path. The server
	/// segments tracks (same 300s rule); we only classify and render.
	private func remoteReload() async {
		guard let remote, !loading else { return }
		loading = true
		defer { loading = false }
		if rangePreset != .custom {
			rangeEnd = Date()
			switch rangePreset {
			case .hour: rangeStart = rangeEnd.addingTimeInterval(-3600)
			case .sixHours: rangeStart = rangeEnd.addingTimeInterval(-6 * 3600)
			case .day: rangeStart = rangeEnd.addingTimeInterval(-86_400)
			case .week: rangeStart = rangeEnd.addingTimeInterval(-7 * 86_400)
			case .month: rangeStart = rangeEnd.addingTimeInterval(-30 * 86_400)
			// The server caps windows at 31 days; "all" means the whole cap.
			case .all: rangeStart = rangeEnd.addingTimeInterval(-31 * 86_400)
			case .custom: break
			}
		}
		let from = Int64(rangeStart.timeIntervalSince1970)
		let to = Int64(rangeEnd.timeIntervalSince1970)
		let bbox = queryBbox
		// Anchored ships report sporadically; widen the stitch gap when
		// vessels are in the query so they don't shatter into dots.
		let gap: Int64 = enabledKinds.contains(.vessel) ? 1800 : 300
		do {
			async let healthFetch = remote.health()
			let window = try await remote.tracks(
				latMin: bbox.latMin, lonMin: bbox.lonMin,
				latMax: bbox.latMax, lonMax: bbox.lonMax,
				from: from, to: to,
				kinds: enabledKinds.count == VehicleKind.allCases.count ? nil : Array(enabledKinds),
				gapS: gap)
			remoteHealth = try? await healthFetch
			remoteTracks = window.tracks
			remoteTruncated = window.truncated
			rebuildRemoteSegments()
			loadError = nil
			lastLoaded = Date()
		} catch {
			loadError = "\(error)"
		}
	}

	/// The map viewport settled somewhere new — remote queries follow it.
	func mapRegionChanged(centerLat: Double, centerLon: Double, spanLat: Double, spanLon: Double) {
		guard isRemote else { return }
		// Inflate a bit so tracks clipped at the edges still draw past them.
		let bbox = Self.clampBbox(
			latMin: centerLat - spanLat * 0.575, lonMin: centerLon - spanLon * 0.575,
			latMax: centerLat + spanLat * 0.575, lonMax: centerLon + spanLon * 0.575)
		guard bbox != queryBbox else { return }
		queryBbox = bbox
		Task { await remoteReload() }
	}

	func kindFilterChanged() {
		persistBandSelection()
		Task { await remoteReload() }
	}

	private static func remoteClass(kind: VehicleKind, altFt: Double?) -> SegmentClass {
		switch kind {
		case .vessel: return .vessel
		case .train: return .train
		case .aircraft:
			// The API serves raw altitude (ft MSL-ish), not AGL — close enough
			// for band colors at browsing zoom.
			guard let altFt else { return .unknownAlt }
			return .band(AltitudeBand.classify(aglFt: altFt).rawValue)
		}
	}

	/// Remote flavor of rebuildSegments: same run-splitting, classes from
	/// kind + raw altitude.
	private func rebuildRemoteSegments() {
		var out: [SegmentClass: [[CLLocationCoordinate2D]]] = [:]
		for t in remoteTracks {
			guard let kind = t.vehicleKind, enabledKinds.contains(kind) else { continue }
			var runClass: SegmentClass?
			var run: [CLLocationCoordinate2D] = []

			func flush() {
				if run.count >= 2, let rc = runClass, isEnabled(rc) {
					out[rc, default: []].append(run)
				}
			}

			for p in t.points {
				let cls = Self.remoteClass(kind: kind, altFt: p.altFt)
				let coord = CLLocationCoordinate2D(latitude: p.lat, longitude: p.lon)
				if cls != runClass {
					flush()
					var newRun: [CLLocationCoordinate2D] = []
					if let lastCoord = run.last { newRun.append(lastCoord) }
					newRun.append(coord)
					run = newRun
					runClass = cls
				} else {
					run.append(coord)
				}
			}
			flush()
		}
		segmentsByClass = out
		rebuildRemoteHeads()
		mapRevision += 1
	}

	private func remoteTrackId(_ t: RemoteTrack) -> String {
		"\(t.kind)-\(t.vid)-\(t.points.first?.ts ?? 0)"
	}

	/// Head markers + Active-now list from remote tracks. "Now" is the newest
	/// point in the response, not the wall clock, so a paused feed doesn't
	/// silently empty the panel.
	private func rebuildRemoteHeads() {
		let visible = remoteTracks.filter { t in
			t.vehicleKind.map { enabledKinds.contains($0) } ?? false
		}
		guard let nowTs = visible.compactMap({ $0.points.last?.ts }).max() else {
			trackHeads = []
			activeFlights = []
			return
		}
		let cutoff = nowTs - 120
		let activeTracks = visible.filter { ($0.points.last?.ts ?? 0) >= cutoff }

		let activeIds = Set(activeTracks.map { "\($0.kind):\($0.vid)" })
		identitySlots = identitySlots.filter { activeIds.contains($0.key) }
		for t in activeTracks where identitySlots["\(t.kind):\(t.vid)"] == nil {
			let used = Set(identitySlots.values)
			identitySlots["\(t.kind):\(t.vid)"] = (0..<8).first { !used.contains($0) } ?? identitySlots.count % 8
		}

		var heads: [TrackHead] = []
		var active: [ActiveFlight] = []
		for t in activeTracks {
			guard let kind = t.vehicleKind, let last = t.points.last else { continue }
			let colorIndex = identitySlots["\(t.kind):\(t.vid)"] ?? 0
			active.append(ActiveFlight(
				id: remoteTrackId(t), kind: kind,
				name: t.callsign ?? t.vid,
				typeCode: kind == .aircraft ? nil : kind.rawValue,
				aglFt: last.altFt, altSource: .unknown, onGround: false,
				gsKt: last.speedKt, lastTs: last.ts, colorIndex: colorIndex
			))
			let cls = Self.remoteClass(kind: kind, altFt: last.altFt)
			guard isEnabled(cls) else { continue }
			var heading = last.headingDeg
			if heading == nil, t.points.count >= 2 {
				let prev = t.points[t.points.count - 2]
				heading = Geo.bearingDeg(lat1: prev.lat, lon1: prev.lon, lat2: last.lat, lon2: last.lon)
			}
			heads.append(TrackHead(
				id: remoteTrackId(t), lat: last.lat, lon: last.lon, headingDeg: heading,
				cls: cls, colorIndex: colorIndex
			))
		}
		trackHeads = heads
		activeFlights = active.sorted { a, b in
			let ka = a.onGround ? 2.0e9 : (a.aglFt ?? 1.0e9)
			let kb = b.onGround ? 2.0e9 : (b.aglFt ?? 1.0e9)
			return ka < kb
		}
	}

	private func openStoreIfNeeded() throws -> Store {
		if let store { return store }
		let s = try Store(path: site.expandedDbPath, readOnly: true)
		store = s
		dbMissing = false
		return s
	}

	/// Install and start this site's LaunchAgent from the viewer; the regular
	/// 10s refresh picks up the database once the first polls land.
	func startCollector() {
		dbMissing = false
		loadError = "starting collector..."
		Task {
			do {
				try await AgentInstaller.startCollector(site: site)
				loadError = "collector starting — first polls land within a few seconds"
			} catch {
				dbMissing = true
				loadError = "\(error)"
			}
		}
	}

	private func finishRebuild(store: Store, from: Int64, to: Int64) async throws {
		let metars = try await store.metarSamples(from: from - 10_800, to: to + 10_800)
		pollStats = try await store.pollStats(gapThresholdS: 300, expectedIntervalS: config?.pollIntervalS ?? 10)

		let siteCfg = site
		let alts = AltimeterHistory(samples: metars)
		altimeters = alts
		let obs = settledObservations + tailObservations
		let built = await Task.detached {
			let t = Analysis.tracks(from: obs, fieldElevationFt: siteCfg.fieldElevationFt, altimeters: alts)
			let c = Analysis.coverage(
				observations: obs, siteLat: siteCfg.lat, siteLon: siteCfg.lon,
				fieldElevationFt: siteCfg.fieldElevationFt, altimeters: alts
			)
			return (t, c)
		}.value

		tracks = built.0
		coverage = built.1
		recomputeStats()
		rebuildSegments()
	}

	/// Overflights + histograms. Cheap enough to run on every parcel move.
	func recomputeStats() {
		let ofs = Analysis.overflights(
			tracks: tracks, parcelLat: parcelLat, parcelLon: parcelLon, radiusM: parcelRadiusM
		)
		overflights = ofs
		hourHist = Analysis.hourHistogram(ofs, timeZone: site.timeZone)
		bandHist = Analysis.bandHistogram(ofs)
	}

	/// Map polyline geometry, split wherever the altitude band changes so each
	/// run can wear its band color; disabled bands are dropped here.
	func rebuildSegments() {
		if isRemote {
			rebuildRemoteSegments()
			return
		}
		var out: [SegmentClass: [[CLLocationCoordinate2D]]] = [:]
		for t in tracks {
			var runClass: SegmentClass?
			var run: [CLLocationCoordinate2D] = []

			func flush() {
				if run.count >= 2, let rc = runClass, isEnabled(rc) {
					out[rc, default: []].append(run)
				}
			}

			for p in t.points {
				let cls: SegmentClass
				if p.onGround {
					cls = .ground
				} else if let agl = p.aglFt {
					cls = .band(AltitudeBand.classify(aglFt: agl).rawValue)
				} else {
					cls = .unknownAlt
				}
				let coord = CLLocationCoordinate2D(latitude: p.lat, longitude: p.lon)
				if cls != runClass {
					flush()
					// Carry the previous point over so the polyline stays continuous
					// across a band change.
					var newRun: [CLLocationCoordinate2D] = []
					if let lastCoord = run.last { newRun.append(lastCoord) }
					newRun.append(coord)
					run = newRun
					runClass = cls
				} else {
					run.append(coord)
				}
			}
			flush()
		}
		segmentsByClass = out
		rebuildTrackHeads()
		mapRevision += 1
	}

	/// Head markers and the "Active now" list for tracks still receiving
	/// observations — last point within two minutes of the newest poll.
	/// Historical tracks end without a head so weeks of accumulated lines
	/// don't sprout hundreds of triangles. Heads respect the band filters;
	/// the active list deliberately does not, so it always answers "what's
	/// up there right now."
	private func rebuildTrackHeads() {
		guard let nowTs = pollStats?.lastTs else {
			trackHeads = []
			activeFlights = []
			return
		}
		let cutoff = nowTs - 120
		let activeTracks = tracks.filter { ($0.points.last?.ts ?? 0) >= cutoff }

		// Color slots follow the aircraft (hex), not its list position: keep
		// existing assignments, release ones that went quiet, give newcomers
		// the lowest free slot. Past 8 live aircraft, hues repeat.
		let activeHexes = Set(activeTracks.map(\.hex))
		identitySlots = identitySlots.filter { activeHexes.contains($0.key) }
		for t in activeTracks where identitySlots[t.hex] == nil {
			let used = Set(identitySlots.values)
			identitySlots[t.hex] = (0..<8).first { !used.contains($0) } ?? identitySlots.count % 8
		}

		var heads: [TrackHead] = []
		var active: [ActiveFlight] = []
		for t in activeTracks {
			guard let last = t.points.last else { continue }
			let colorIndex = identitySlots[t.hex] ?? 0
			active.append(ActiveFlight(
				id: t.id, kind: .aircraft, name: t.displayName, typeCode: t.typeCode,
				aglFt: last.aglFt, altSource: last.altSource, onGround: last.onGround,
				gsKt: last.gsKt, lastTs: last.ts, colorIndex: colorIndex
			))
			let cls: SegmentClass
			if last.onGround {
				cls = .ground
			} else if let agl = last.aglFt {
				cls = .band(AltitudeBand.classify(aglFt: agl).rawValue)
			} else {
				cls = .unknownAlt
			}
			guard isEnabled(cls) else { continue }
			var heading = last.trackDeg
			if heading == nil, t.points.count >= 2 {
				let prev = t.points[t.points.count - 2]
				heading = Geo.bearingDeg(lat1: prev.lat, lon1: prev.lon, lat2: last.lat, lon2: last.lon)
			}
			heads.append(TrackHead(
				id: t.id, lat: last.lat, lon: last.lon, headingDeg: heading,
				cls: cls, colorIndex: colorIndex
			))
		}
		trackHeads = heads
		// Lowest traffic first — that's the interesting end; ground and
		// unknown-altitude at the bottom.
		activeFlights = active.sorted { a, b in
			let ka = a.onGround ? 2.0e9 : (a.aglFt ?? 1.0e9)
			let kb = b.onGround ? 2.0e9 : (b.aglFt ?? 1.0e9)
			return ka < kb
		}
	}

	private func isEnabled(_ cls: SegmentClass) -> Bool {
		switch cls {
		case .band(let i):
			guard let band = AltitudeBand(rawValue: i) else { return false }
			return enabledBands.contains(band)
		case .ground:
			return showGround
		case .unknownAlt:
			return true
		case .vessel:
			return enabledKinds.contains(.vessel)
		case .train:
			return enabledKinds.contains(.train)
		}
	}

	/// Overflight list filtered by the enabled-band toggles (closest-approach band).
	var visibleOverflights: [Overflight] {
		overflights.filter { of in
			guard let agl = of.closestPoint.aglFt else { return true }
			return enabledBands.contains(AltitudeBand.classify(aglFt: agl))
		}
	}

	func bandFilterChanged() {
		rebuildSegments()
		persistBandSelection()
	}

	func requestFocus(trackId: String) {
		focusSeq += 1
		focusRequest = FocusRequest(trackId: trackId, seq: focusSeq)
	}

	func requestRecenter() {
		recenterSeq += 1
	}

	// MARK: - Parcel (auto-saved)

	func parcelMoved(lat: Double, lon: Double) {
		parcelLat = lat
		parcelLon = lon
		recomputeStats()
		persistParcel()
	}

	func parcelRadiusChanged() {
		recomputeStats()
		persistParcel()
	}

	func resetParcelToDefaults() {
		parcelLat = site.lat
		parcelLon = site.lon
		parcelRadiusM = 400
		recomputeStats()
		persistParcel()
	}

	/// Read-modify-write against the on-disk config so edits from other
	/// windows (other sites) aren't clobbered.
	private func persistParcel() {
		do {
			var disk = try Config.load()
			guard var target = disk.site(slug: site.slug) else { return }
			target.parcel = SiteConfig.Parcel(lat: parcelLat, lon: parcelLon, radiusM: parcelRadiusM)
			disk.upsert(site: target)
			try disk.save()
			config = disk
		} catch {
			loadError = "saving config: \(error)"
		}
	}

	// MARK: - Date range

	func setPreset(_ p: RangePreset) {
		rangePreset = p
		Task { await reload() }
	}

	/// Called only from the date pickers' binding setters, so programmatic
	/// writes during reload never masquerade as a user edit.
	func setCustomRange(start: Date? = nil, end: Date? = nil) {
		if let start { rangeStart = start }
		if let end { rangeEnd = end }
		rangePreset = .custom
		Task { await reload() }
	}
}
