import SwiftUI
import CoreLocation
import OverflightCore

/// Landing view for a new (or re-targeted) window: pick a local site —
/// including one already open elsewhere, which gives you a clone — add a new
/// one, or flip to Remote and browse minibot's query API instead. Lookup
/// accepts an ICAO identifier or a place name ("Toledo, WA"); places are
/// geocoded and paired with the nearest METAR-reporting station.
struct SitePickerView: View {
	enum BrowseMode: String {
		case local, remote
	}

	let onPick: (ViewerSelection) -> Void

	@State private var config: Config = (try? Config.loadOrCreate()) ?? .kgmjDefault
	@State private var showingAdd = false

	// Remote mode: server URL + the views it serves, both remembered.
	@State private var mode: BrowseMode
	@State private var serverURL: String
	@State private var remoteViews: [RemoteView] = []
	@State private var remoteBusy = false
	@State private var remoteError: String?

	init(onPick: @escaping (ViewerSelection) -> Void) {
		self.onPick = onPick
		let saved = BrowseModeState.load()
		_mode = State(initialValue: BrowseMode(rawValue: saved.mode ?? "") ?? .local)
		_serverURL = State(initialValue: saved.serverURL ?? BrowseModeState.defaultServerURL)
	}

	// Add-site form fields (strings so partial input never fights a formatter)
	@State private var query = ""
	@State private var resolvedIcao: String?
	@State private var displayName = ""
	@State private var latText = ""
	@State private var lonText = ""
	@State private var elevText = ""
	@State private var radiusText = "15"
	@State private var metarStation = ""
	@State private var timezone = TimeZone.current.identifier
	@State private var lookupBusy = false
	@State private var lookupNote: String?
	@State private var formError: String?

	var body: some View {
		Group {
			if showingAdd {
				addFormView
			} else {
				pickerView
			}
		}
		.frame(minWidth: 500, minHeight: 440)
		.navigationTitle(showingAdd ? "Overflight — add site" : "Overflight — pick a site")
	}

	// MARK: - Mode picker

	private var pickerView: some View {
		VStack(spacing: 0) {
			Picker("Mode", selection: $mode) {
				Text("Local DBs").tag(BrowseMode.local)
				Text("Remote (minibot)").tag(BrowseMode.remote)
			}
			.pickerStyle(.segmented)
			.labelsHidden()
			.padding(10)
			.onChange(of: mode) {
				persistBrowseMode()
				if mode == .remote, remoteViews.isEmpty {
					connect()
				}
			}
			Divider()
			if mode == .local {
				siteListView
			} else {
				remoteListView
			}
		}
		.task {
			if mode == .remote {
				connect()
			}
		}
	}

	private func persistBrowseMode() {
		var state = BrowseModeState.load()
		state.mode = mode.rawValue
		state.serverURL = serverURL
		state.save()
	}

	// MARK: - Remote list

	private var remoteListView: some View {
		VStack(spacing: 0) {
			HStack {
				TextField("Server URL", text: $serverURL, prompt: Text(BrowseModeState.defaultServerURL))
					.textFieldStyle(.roundedBorder)
					.onSubmit { connect() }
				Button(remoteBusy ? "Connecting..." : "Connect") { connect() }
					.disabled(remoteBusy)
			}
			.padding(10)
			if let remoteError {
				Label(remoteError, systemImage: "exclamationmark.triangle.fill")
					.font(.caption)
					.foregroundStyle(Viz.statusCritical)
					.padding(.horizontal, 10)
					.padding(.bottom, 6)
			}
			List {
				Section("Open a view") {
					ForEach(remoteViews) { view in
						Button {
							guard let api = RemoteAPI(urlString: serverURL) else { return }
							onPick(.remote(api: api, view: view, all: remoteViews))
						} label: {
							VStack(alignment: .leading, spacing: 2) {
								Text(view.title)
									.font(.headline)
								Text("\(String(format: "%.4f, %.4f", view.lat, view.lon)) - \(Int(view.radiusNm)) nm - \(view.slug)")
									.font(.caption)
									.foregroundStyle(.secondary)
							}
							.contentShape(Rectangle())
						}
						.buttonStyle(.plain)
					}
				}
			}
			Divider()
			HStack {
				Text("Sites are configured on the server; analytics stay local-mode.")
					.font(.caption2)
					.foregroundStyle(.secondary)
				Spacer()
			}
			.padding(10)
		}
	}

	private func connect() {
		guard let api = RemoteAPI(urlString: serverURL) else {
			remoteError = "server URL must look like \(BrowseModeState.defaultServerURL)"
			return
		}
		remoteBusy = true
		remoteError = nil
		persistBrowseMode()
		Task {
			defer { remoteBusy = false }
			do {
				remoteViews = try await api.views()
				if remoteViews.isEmpty {
					remoteError = "server answered, but serves no views"
				}
			} catch {
				remoteViews = []
				remoteError = "\(error)"
			}
		}
	}

	// MARK: - Site list

	private var siteListView: some View {
		VStack(spacing: 0) {
			List {
				Section("Open a site") {
					ForEach(config.sites) { site in
						Button {
							onPick(.local(site: site, config: config))
						} label: {
							VStack(alignment: .leading, spacing: 2) {
								Text(site.title)
									.font(.headline)
								Text("\(String(format: "%.4f, %.4f", site.lat, site.lon)) - \(Int(site.radiusNm)) nm - \(site.slug)")
									.font(.caption)
									.foregroundStyle(.secondary)
							}
							.contentShape(Rectangle())
						}
						.buttonStyle(.plain)
					}
				}
			}
			Divider()
			HStack {
				Spacer()
				Button("Add Site...") {
					formError = nil
					lookupNote = nil
					showingAdd = true
				}
			}
			.padding(10)
		}
	}

	// MARK: - Add form

	private var addFormView: some View {
		VStack(spacing: 0) {
			Form {
				Section("Look up") {
					HStack {
						TextField("ICAO or place", text: $query, prompt: Text("KTOL or Toledo, WA"))
							.onSubmit { lookUp() }
						Button(lookupBusy ? "Looking up..." : "Look up") { lookUp() }
							.disabled(lookupBusy || query.trimmingCharacters(in: .whitespaces).isEmpty)
					}
					Text("A station ID fills everything from its METAR; a place name is geocoded and paired with the nearest reporting station.")
						.font(.caption2)
						.foregroundStyle(.secondary)
					if let lookupNote {
						Text(lookupNote)
							.font(.caption)
							.foregroundStyle(.secondary)
					}
				}
				Section("Site") {
					TextField("Display name", text: $displayName)
					HStack {
						TextField("Latitude", text: $latText)
						TextField("Longitude", text: $lonText)
					}
					HStack {
						TextField("Field elevation (ft)", text: $elevText)
						TextField("Collection radius (nm)", text: $radiusText)
					}
					HStack {
						TextField("METAR station", text: $metarStation)
						TextField("Timezone", text: $timezone)
					}
				}
				if let formError {
					Label(formError, systemImage: "exclamationmark.triangle.fill")
						.font(.caption)
						.foregroundStyle(Viz.statusCritical)
				}
			}
			.formStyle(.grouped)
			Divider()
			HStack {
				Text("New sites start collecting once their agent is installed:  scripts/install-agent.sh <slug>")
					.font(.caption2)
					.foregroundStyle(.secondary)
				Spacer()
				Button("Cancel") { showingAdd = false }
					.keyboardShortcut(.cancelAction)
				Button("Create Site") { create() }
					.keyboardShortcut(.defaultAction)
					.disabled(latText.isEmpty || lonText.isEmpty || displayName.isEmpty)
			}
			.padding(10)
		}
	}

	// MARK: - Lookup

	private func looksLikeStationId(_ s: String) -> Bool {
		(3...4).contains(s.count) && s.allSatisfy { $0.isLetter || $0.isNumber }
	}

	private func lookUp() {
		let q = query.trimmingCharacters(in: .whitespaces)
		guard !q.isEmpty else { return }
		lookupBusy = true
		formError = nil
		lookupNote = nil
		Task {
			defer { lookupBusy = false }
			do {
				if looksLikeStationId(q) {
					let info = try await MetarClient.stationInfo(icao: q.uppercased())
					query = info.icao
					resolvedIcao = info.icao
					displayName = info.name
					latText = String(format: "%.4f", info.lat)
					lonText = String(format: "%.4f", info.lon)
					elevText = String(Int(info.elevFt.rounded()))
					metarStation = info.icao
				} else {
					try await lookUpPlace(q)
				}
			} catch {
				formError = "\(error)"
			}
		}
	}

	private func lookUpPlace(_ q: String) async throws {
		let placemarks = try await CLGeocoder().geocodeAddressString(q)
		guard let pm = placemarks.first, let loc = pm.location else {
			throw OverflightError.badResponse("no place found for '\(q)'")
		}
		let lat = loc.coordinate.latitude
		let lon = loc.coordinate.longitude
		resolvedIcao = nil
		displayName = [pm.locality ?? pm.name, pm.administrativeArea]
			.compactMap { $0 }
			.joined(separator: ", ")
		latText = String(format: "%.4f", lat)
		lonText = String(format: "%.4f", lon)
		if let tzId = pm.timeZone?.identifier {
			timezone = tzId
		}
		if let station = try await MetarClient.nearestStation(lat: lat, lon: lon) {
			metarStation = station.icao
			let distanceKm = Geo.distanceM(lat1: lat, lon1: lon, lat2: station.lat, lon2: station.lon) / 1000
			// The station's elevation only stands in for the site's when it's
			// actually nearby.
			if distanceKm <= 30 {
				elevText = String(Int(station.elevFt.rounded()))
			}
			lookupNote = String(
				format: "Found %@. Altimeter from %@ (%@), %.0f km away.",
				displayName, station.icao, station.name, distanceKm
			)
		} else {
			lookupNote = "Found \(displayName), but no METAR station reports within ~80 km — baro altitudes will go uncorrected."
		}
	}

	// MARK: - Create

	private func create() {
		guard let lat = Double(latText), let lon = Double(lonText) else {
			formError = "latitude/longitude must be numbers"
			return
		}
		guard TimeZone(identifier: timezone) != nil else {
			formError = "unknown timezone identifier '\(timezone)'"
			return
		}
		let slugBase = resolvedIcao?.lowercased()
			?? displayName.lowercased().filter { $0.isLetter || $0.isNumber }
		var slug = slugBase.isEmpty ? "site" : slugBase
		var n = 2
		while config.sites.contains(where: { $0.slug == slug }) {
			slug = "\(slugBase)\(n)"
			n += 1
		}
		let site = SiteConfig(
			slug: slug,
			icao: resolvedIcao,
			displayName: displayName,
			lat: lat, lon: lon,
			fieldElevationFt: Double(elevText) ?? 0,
			radiusNm: Double(radiusText) ?? 15,
			metarStation: metarStation.isEmpty ? nil : metarStation,
			timezone: timezone
		)
		var updated = config
		updated.upsert(site: site)
		do {
			try updated.save()
			config = updated
			// Start collecting immediately; if this can't (collector binary not
			// installed yet), the new window's Start collector button covers it.
			Task {
				try? await AgentInstaller.startCollector(site: site)
			}
			onPick(.local(site: site, config: updated))
		} catch {
			formError = "saving config: \(error)"
		}
	}
}
