import Foundation
import OverflightCore

func log(_ msg: String) {
	let fmt = ISO8601DateFormatter()
	fmt.formatOptions = [.withInternetDateTime]
	fputs("\(fmt.string(from: Date())) \(msg)\n", stdout)
	fflush(stdout)
}

func makeSignalSource(_ sig: Int32, cancelling task: Task<Void, Never>) -> DispatchSourceSignal {
	signal(sig, SIG_IGN)
	let src = DispatchSource.makeSignalSource(signal: sig, queue: .global())
	src.setEventHandler { task.cancel() }
	src.resume()
	return src
}

struct PollOutcome: Sendable {
	var record: PollRecord
	var aircraft: [Aircraft]
	var retryAfterS: Double?
}

struct CollectorLoop: Sendable {
	let config: Config
	let site: SiteConfig
	let store: Store
	let unified: UnifiedStore?
	let session: URLSession

	init(config: Config, site: SiteConfig, store: Store, unified: UnifiedStore? = nil) {
		self.config = config
		self.site = site
		self.store = store
		self.unified = unified
		let sc = URLSessionConfiguration.ephemeral
		sc.timeoutIntervalForRequest = 8
		sc.httpAdditionalHeaders = ["User-Agent": "OverflightKit/1.0 (+https://github.com/brewmium/OverflightKit)"]
		session = URLSession(configuration: sc)
	}

	func pollSource(named name: String) async -> PollOutcome {
		let ts = Int64(Date().timeIntervalSince1970)
		func failed(_ status: Int?, _ error: String, _ ms: Int?, retryAfterS: Double? = nil) -> PollOutcome {
			PollOutcome(
				record: PollRecord(ts: ts, source: name, httpStatus: status, error: error, aircraftCount: 0, latencyMs: ms),
				aircraft: [],
				retryAfterS: retryAfterS
			)
		}
		guard let base = Config.baseURL(forSource: name),
			let url = URL(string: "\(base)/v2/point/\(site.lat)/\(site.lon)/\(Int(site.radiusNm.rounded()))")
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

	func pollOnce() async throws {
		let outcome = await pollSource(named: config.primarySource)
		try await store.record(poll: outcome.record, aircraft: outcome.aircraft)
		if let err = outcome.record.error {
			log("\(config.primarySource): ERROR \(err)")
		} else {
			log("\(config.primarySource): \(outcome.record.aircraftCount) aircraft, \(outcome.record.latencyMs ?? 0)ms")
			for a in outcome.aircraft {
				let alt: String
				switch a.altBaro {
				case .ground: alt = "ground"
				case .feet(let f): alt = "\(f) ft"
				case nil: alt = a.altGeomFt.map { "\($0) ft geom" } ?? "alt?"
				}
				log("  \(a.hex) \(a.flight ?? a.registration ?? "") \(alt)")
			}
		}
	}

	func run() async {
		var activePrimary = true
		var failStreak = 0
		var backoffS = 0.0
		var pollsUntilPrimaryProbe = 0
		var pollCount = 0
		var okSinceLastSummary = 0
		var acSinceLastSummary = 0
		var lastMetarAttempt: Int64 = 0
		if let ts = try? await store.latestMetarTs(station: site.metarStation) {
			lastMetarAttempt = ts
		}

		// Multiple site collectors share this machine's IP; a deterministic
		// per-slug phase offset keeps them interleaved instead of stampeding
		// the aggregator together (which is what draws 429s at startup).
		let stableHash = site.slug.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0x7fff_ffff }
		let phaseS = Double(stableHash % 1000) / 1000 * config.pollIntervalS
		try? await Task.sleep(for: .seconds(phaseS))

		while !Task.isCancelled {
			let probing = !activePrimary && pollsUntilPrimaryProbe <= 0
			let sourceName = (activePrimary || probing) ? config.primarySource : config.fallbackSource

			let outcome = await pollSource(named: sourceName)
			do {
				try await store.record(poll: outcome.record, aircraft: outcome.aircraft)
			} catch {
				log("db write failed: \(error)")
			}
			if let unified {
				do {
					let obs = outcome.aircraft
						.filter { $0.lat != nil && $0.lon != nil }
						.map { UnifiedObservation(aircraft: $0, ts: outcome.record.ts, source: outcome.record.source) }
					try await unified.record(poll: outcome.record, collector: site.slug, observations: obs)
				} catch {
					log("unified db write failed: \(error)")
				}
			}

			pollCount += 1
			if outcome.record.error == nil {
				okSinceLastSummary += 1
				acSinceLastSummary += outcome.record.aircraftCount
				failStreak = 0
				backoffS = 0
				if probing {
					activePrimary = true
					log("primary \(config.primarySource) recovered — switching back")
				}
			} else {
				log("\(sourceName): \(outcome.record.error ?? "?")")
				if probing {
					// Primary still down; keep riding the fallback and try again later.
					pollsUntilPrimaryProbe = 30
				} else {
					failStreak += 1
					backoffS = min(backoffS == 0 ? config.pollIntervalS * 2 : backoffS * 2, 300)
					if let ra = outcome.retryAfterS {
						// The server told us when to come back; believe it.
						backoffS = min(max(ra, backoffS), 300)
					}
					if activePrimary, failStreak >= 3 {
						activePrimary = false
						pollsUntilPrimaryProbe = 30
						failStreak = 0
						backoffS = 0
						log("switching to fallback \(config.fallbackSource)")
					}
				}
			}
			if !activePrimary, !probing {
				pollsUntilPrimaryProbe -= 1
			}

			if pollCount % 60 == 0 {
				log("\(pollCount) polls, last 60: \(okSinceLastSummary) ok, \(acSinceLastSummary) aircraft rows, source \(sourceName)")
				okSinceLastSummary = 0
				acSinceLastSummary = 0
			}

			let now = Int64(Date().timeIntervalSince1970)
			if !site.metarStation.isEmpty, now - lastMetarAttempt >= 3600 {
				do {
					let (sample, raw) = try await MetarClient.fetchLatest(station: site.metarStation, session: session)
					try await store.record(metarTs: sample.ts, station: site.metarStation, altimHpa: sample.altimHpa, raw: raw)
					if let unified {
						try? await unified.record(metarTs: sample.ts, station: site.metarStation, altimHpa: sample.altimHpa, raw: raw)
					}
					lastMetarAttempt = now
					log("metar \(site.metarStation): altim \(sample.altimHpa) hPa")
				} catch {
					// Retry in 5 minutes rather than a full hour.
					lastMetarAttempt = now - 3600 + 300
					log("metar fetch failed: \(error)")
				}
			}

			let base = backoffS > 0 ? backoffS : config.pollIntervalS
			// Jitter so requests don't land on a fixed phase; never below 1s
			// (airplanes.live hard limit is 1 request/second).
			let delay = max(1.0, base + Double.random(in: -1...1))
			do {
				try await Task.sleep(for: .seconds(delay))
			} catch {
				break
			}
		}
	}
}

@main
struct OverflightCollectorMain {
	static func main() async {
		do {
			try await run()
		} catch {
			log("fatal: \(error)")
			exit(1)
		}
	}

	static func usage() -> String {
		"""
		OverflightCollector — ADS-B overflight sampler

		usage:
		  OverflightCollector [--site SLUG] [--config PATH]   run the collector loop
		  OverflightCollector --once [--site SLUG]            single poll, print aircraft, exit
		  OverflightCollector --report [--days N] [--site SLUG]
		                                                      print histograms + coverage diagnostic
		  OverflightCollector --list-sites                    print configured sites
		  OverflightCollector --migrate SLUG                  copy a site DB into the unified store

		--site defaults to the first configured site; config defaults to
		\(Config.defaultPath) and is created with KGMJ defaults if missing.
		The collector loop appends to the unified store (unified_db_path)
		alongside the per-site DB while the native viewer still reads site DBs.
		"""
	}

	static func run() async throws {
		var configPath: String?
		var report = false
		var once = false
		var listSites = false
		var days: Int?
		var siteSlug: String?
		var migrateSlug: String?

		var args = ArraySlice(CommandLine.arguments.dropFirst())
		while let arg = args.popFirst() {
			switch arg {
			case "--config":
				guard let v = args.popFirst() else { throw OverflightError.usage("--config requires a path") }
				configPath = v
			case "--site":
				guard let v = args.popFirst() else { throw OverflightError.usage("--site requires a slug") }
				siteSlug = v
			case "--migrate":
				guard let v = args.popFirst() else { throw OverflightError.usage("--migrate requires a site slug") }
				migrateSlug = v
			case "--report":
				report = true
			case "--once":
				once = true
			case "--list-sites":
				listSites = true
			case "--days":
				guard let v = args.popFirst(), let n = Int(v), n > 0 else {
					throw OverflightError.usage("--days requires a positive integer")
				}
				days = n
			case "--help", "-h":
				print(usage())
				return
			default:
				throw OverflightError.usage("unknown argument '\(arg)'\n\n\(usage())")
			}
		}

		let config = try Config.loadOrCreate(path: configPath)

		if listSites {
			for s in config.sites {
				print("\(s.slug)\t\(s.title)\t\(s.expandedDbPath)")
			}
			return
		}

		if let migrateSlug {
			guard let site = config.site(slug: migrateSlug) else {
				let known = config.sites.map(\.slug).joined(separator: ", ")
				throw OverflightError.usage("unknown site '\(migrateSlug)' — configured: \(known)")
			}
			let unified = try UnifiedStore(path: config.expandedUnifiedDbPath)
			let (polls, obs) = try await unified.migrateSiteDB(path: site.expandedDbPath, collector: site.slug)
			await unified.close()
			print("migrated \(site.slug): \(polls) polls, \(obs) observations -> \(config.expandedUnifiedDbPath)")
			return
		}

		guard let site = config.site(slug: siteSlug) else {
			let known = config.sites.map(\.slug).joined(separator: ", ")
			throw OverflightError.usage("unknown site '\(siteSlug ?? "")' — configured: \(known)")
		}

		if report {
			let store = try Store(path: site.expandedDbPath, readOnly: true)
			let text = try await Report.generate(store: store, config: config, site: site, sinceDays: days)
			await store.close()
			print(text)
			return
		}

		let store = try Store(path: site.expandedDbPath, readOnly: false)
		let unified = try UnifiedStore(path: config.expandedUnifiedDbPath)
		let loop = CollectorLoop(config: config, site: site, store: store, unified: unified)

		if once {
			try await loop.pollOnce()
			await store.close()
			await unified.close()
			return
		}

		log("collector starting [\(site.slug)]: \(site.lat),\(site.lon) r=\(Int(site.radiusNm))nm every \(Int(config.pollIntervalS))s -> \(site.expandedDbPath)")
		let task = Task { await loop.run() }
		let sigint = makeSignalSource(SIGINT, cancelling: task)
		let sigterm = makeSignalSource(SIGTERM, cancelling: task)
		defer {
			sigint.cancel()
			sigterm.cancel()
		}
		await task.value
		await store.close()
		await unified.close()
		log("collector stopped")
	}
}
