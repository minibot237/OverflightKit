import SwiftUI
import OverflightCore

struct SidePanel: View {
	@Environment(ViewerModel.self) private var model

	var body: some View {
		@Bindable var model = model
		Form {
			Section {
				if model.activeFlights.isEmpty {
					Text("Nothing in the air right now")
						.font(.caption)
						.foregroundStyle(.secondary)
				} else if model.activeFlights.count <= 10 {
					ForEach(model.activeFlights) { flight in
						tappableActiveRow(flight)
					}
				} else {
					// Busy airspace: hold the section at ~10 rows and scroll.
					ScrollView {
						VStack(alignment: .leading, spacing: 8) {
							ForEach(model.activeFlights) { flight in
								tappableActiveRow(flight)
							}
						}
						.padding(.vertical, 2)
					}
					.frame(height: 320)
				}
			} header: {
				HStack {
					Text("Active now")
					if !model.activeFlights.isEmpty {
						Text("\(model.activeFlights.count)")
							.foregroundStyle(.secondary)
					}
					Spacer()
					Button {
						model.requestRecenter()
					} label: {
						Image(systemName: "location.viewfinder")
					}
					.buttonStyle(.borderless)
					.help("Recenter the map on the field")
				}
			}

			Section("Date range") {
				Picker("Preset", selection: Binding(
					get: { model.rangePreset },
					set: { model.setPreset($0) }
				)) {
					// Remote re-fetches whole windows from the API, so the
					// presets skew shorter there.
					if model.isRemote {
						Text("1h").tag(RangePreset.hour)
						Text("6h").tag(RangePreset.sixHours)
						Text("24h").tag(RangePreset.day)
						Text("7d").tag(RangePreset.week)
					} else {
						Text("24h").tag(RangePreset.day)
						Text("7d").tag(RangePreset.week)
						Text("30d").tag(RangePreset.month)
						Text("All").tag(RangePreset.all)
					}
					if model.rangePreset == .custom {
						Text("Custom").tag(RangePreset.custom)
					}
				}
				.pickerStyle(.segmented)
				.labelsHidden()
				DatePicker("From", selection: Binding(
					get: { model.rangeStart },
					set: { model.setCustomRange(start: $0) }
				))
				DatePicker("To", selection: Binding(
					get: { model.rangeEnd },
					set: { model.setCustomRange(end: $0) }
				))
			}

			// Remote tracks carry raw altitude, not AGL — label honestly.
			Section(model.isRemote ? "Altitude bands (ft)" : "Altitude bands (ft AGL)") {
				ForEach(AltitudeBand.allCases, id: \.self) { band in
					Toggle(isOn: Binding(
						get: { model.enabledBands.contains(band) },
						set: { on in
							if on {
								model.enabledBands.insert(band)
							} else {
								model.enabledBands.remove(band)
							}
							model.bandFilterChanged()
						}
					)) {
						HStack(spacing: 6) {
							RoundedRectangle(cornerRadius: 2)
								.fill(Viz.chartBand(band))
								.frame(width: 12, height: 12)
							Text(band.label)
						}
					}
				}
				// The API doesn't label ground observations; the toggle would lie.
				if !model.isRemote {
					Toggle(isOn: Binding(
						get: { model.showGround },
						set: { on in
							model.showGround = on
							model.bandFilterChanged()
						}
					)) {
						HStack(spacing: 6) {
							RoundedRectangle(cornerRadius: 2)
								.fill(Viz.ground)
								.frame(width: 12, height: 12)
							Text("Ground traffic")
						}
					}
				}
			}

			if model.isRemote {
				Section("Kinds") {
					kindToggle(.aircraft, label: "Aircraft", color: Viz.seriesBlue)
					kindToggle(.vessel, label: "Ships", color: Viz.vessel)
					kindToggle(.train, label: "Trains", color: Viz.train)
				}
			}

			if !model.isRemote {
				localSections
			}
		}
		.formStyle(.grouped)
	}

	private func kindToggle(_ kind: VehicleKind, label: String, color: Color) -> some View {
		Toggle(isOn: Binding(
			get: { model.enabledKinds.contains(kind) },
			set: { on in
				if on {
					model.enabledKinds.insert(kind)
				} else if model.enabledKinds.count > 1 {
					model.enabledKinds.remove(kind)
				}
				model.kindFilterChanged()
			}
		)) {
			HStack(spacing: 6) {
				RoundedRectangle(cornerRadius: 2)
					.fill(color)
					.frame(width: 12, height: 12)
				Text(label)
			}
		}
	}

	/// Parcel-study analytics — local databases only, per the brief; the
	/// remote API has no parcel, METAR, or poll-table context.
	@ViewBuilder
	private var localSections: some View {
			@Bindable var model = model
			Section("Parcel") {
				LabeledContent("Center") {
					Text(String(format: "%.5f, %.5f", model.parcelLat, model.parcelLon))
						.font(.caption.monospacedDigit())
				}
				Text("Drag the orange marker on the map to move it.")
					.font(.caption2)
					.foregroundStyle(.secondary)
				LabeledContent("Radius") {
					Text("\(Int(model.parcelRadiusM)) m")
						.font(.caption.monospacedDigit())
				}
				Slider(
					value: $model.parcelRadiusM,
					in: 50...3000,
					onEditingChanged: { editing in
						if !editing {
							model.parcelRadiusChanged()
						}
					}
				)
				HStack {
					Button("Reset to defaults") { model.resetParcelToDefaults() }
					Spacer()
					Text("changes save automatically")
						.font(.caption2)
						.foregroundStyle(.secondary)
				}
				.controlSize(.small)
			}

			Section("Overflights") {
				HStack(alignment: .firstTextBaseline, spacing: 8) {
					Text("\(model.visibleOverflights.count)")
						.font(.system(size: 28, weight: .semibold))
					Text("tracks through cylinder")
						.font(.caption)
						.foregroundStyle(.secondary)
				}
				BarChartView(title: "By hour of day (\(model.site.timezone))", data: hourData)
				BarChartView(title: "By altitude band at closest approach (ft AGL)", data: bandData)
				if model.bandHist.unknownCount > 0 {
					Text("\(model.bandHist.unknownCount) overflight(s) had no usable altitude at closest approach")
						.font(.caption2)
						.foregroundStyle(Viz.mutedInk)
				}
			}

			Section("Coverage") {
				if let cov = model.coverage {
					LabeledContent("Below 2,000 ft AGL") {
						Text("\(cov.below2000) obs (\(String(format: "%.1f%%", cov.fractionBelow2000 * 100)))")
							.font(.caption.monospacedDigit())
					}
					LabeledContent("Min AGL within 5 nm") {
						if let minAgl = cov.minAglWithin5nmFt {
							Text("\(Int(minAgl.rounded())) ft (\(cov.minAglSource?.label ?? "?"))")
								.font(.caption.monospacedDigit())
						} else {
							Text("none seen")
								.font(.caption)
						}
					}
					altitudeSourcesRow(cov)
					if !cov.patternVisible {
						Label(
							"No observations below 2,000 ft AGL in this window — the aggregator likely cannot see pattern traffic here, so this data cannot answer the overflight question at pattern altitudes.",
							systemImage: "exclamationmark.triangle.fill"
						)
						.font(.caption)
						.foregroundStyle(Viz.statusCritical)
					}
				} else {
					Text("No data loaded")
						.font(.caption)
						.foregroundStyle(.secondary)
				}
			}

			Section("Recent overflights") {
				if model.visibleOverflights.isEmpty {
					Text("None in range")
						.font(.caption)
						.foregroundStyle(.secondary)
				} else {
					ForEach(model.visibleOverflights.suffix(30).reversed()) { of in
						overflightRow(of)
					}
				}
			}
	}

	private var hourData: [BarChartView.BarDatum] {
		model.hourHist.enumerated().map { hour, count in
			BarChartView.BarDatum(
				id: hour,
				axisLabel: hour % 3 == 0 ? String(format: "%02d", hour) : nil,
				value: count,
				color: Viz.seriesBlue
			)
		}
	}

	private var bandData: [BarChartView.BarDatum] {
		AltitudeBand.allCases.map { band in
			BarChartView.BarDatum(
				id: band.rawValue,
				axisLabel: band.label,
				value: model.bandHist.counts[band.rawValue],
				color: Viz.chartBand(band)
			)
		}
	}

	private func altitudeSourcesRow(_ cov: CoverageDiagnostic) -> some View {
		let total = cov.sourceCounts.values.reduce(0, +)
		let order: [AltitudeSource] = [.geometric, .baroCorrected, .baroUncorrected, .unknown]
		let parts = order.compactMap { src -> String? in
			guard total > 0, let n = cov.sourceCounts[src], n > 0 else { return nil }
			return "\(src.label) \(String(format: "%.0f%%", Double(n) / Double(total) * 100))"
		}
		return LabeledContent("Altitude sources") {
			Text(parts.isEmpty ? "-" : parts.joined(separator: ", "))
				.font(.caption)
				.multilineTextAlignment(.trailing)
		}
	}

	private func tappableActiveRow(_ flight: ActiveFlight) -> some View {
		activeRow(flight)
			.frame(maxWidth: .infinity, alignment: .leading)
			.contentShape(Rectangle())
			.onTapGesture { model.requestFocus(trackId: flight.id) }
			.help("Show this aircraft on the map")
	}

	private func activeRow(_ flight: ActiveFlight) -> some View {
		let swatch = Viz.identity(flight.colorIndex)
		let alt: String?
		if flight.kind != .aircraft {
			// Surface movers: altitude would just be noise.
			alt = nil
		} else if flight.onGround {
			alt = "on ground"
		} else if let agl = flight.aglFt {
			alt = model.isRemote
				? "\(Int(agl.rounded())) ft"
				: "\(Int(agl.rounded())) ft AGL (\(flight.altSource.label))"
		} else {
			alt = "altitude unknown"
		}
		let age = max(0, Int64(Date().timeIntervalSince1970) - flight.lastTs)
		var parts: [String] = alt.map { [$0] } ?? []
		if let gs = flight.gsKt {
			parts.append("\(Int(gs.rounded())) kt")
		}
		parts.append("\(age < 60 ? "\(age)s" : "\(age / 60)m") ago")
		let detail = parts.joined(separator: " - ")
		return HStack(spacing: 6) {
			Circle()
				.fill(swatch)
				.frame(width: 8, height: 8)
			VStack(alignment: .leading, spacing: 1) {
				HStack {
					Text(flight.name)
						.font(.caption.bold())
					if let type = flight.typeCode {
						Text(type)
							.font(.caption2)
							.foregroundStyle(.secondary)
					}
				}
				Text(detail)
					.font(.caption2)
					.foregroundStyle(.secondary)
			}
		}
	}

	private func overflightRow(_ of: Overflight) -> some View {
		let fmt = DateFormatter()
		fmt.dateFormat = "MM-dd HH:mm"
		fmt.timeZone = model.site.timeZone
		let time = fmt.string(from: Date(timeIntervalSince1970: Double(of.closestPoint.ts)))
		let alt: String
		if let agl = of.closestPoint.aglFt {
			alt = "\(Int(agl.rounded())) ft AGL (\(of.closestPoint.altSource.label))"
		} else {
			alt = "altitude unknown"
		}
		return VStack(alignment: .leading, spacing: 1) {
			HStack {
				Text(of.track.displayName)
					.font(.caption.bold())
				if let type = of.track.typeCode {
					Text(type)
						.font(.caption2)
						.foregroundStyle(.secondary)
				}
				Spacer()
				Text(time)
					.font(.caption2.monospacedDigit())
					.foregroundStyle(.secondary)
			}
			Text("closest \(Int(of.closestDistanceM.rounded())) m - \(alt)")
				.font(.caption2)
				.foregroundStyle(.secondary)
		}
	}
}
