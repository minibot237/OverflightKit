import SwiftUI
import OverflightCore

/// Collector health, derived entirely from the poll table: total polls, gap
/// count, longest gap, current source, and how stale the newest poll is.
struct StatusStrip: View {
	@Environment(ViewerModel.self) private var model

	private enum Health {
		case live, stale, down, none

		var label: String {
			switch self {
			case .live: return "live"
			case .stale: return "stale"
			case .down: return "down"
			case .none: return "no data"
			}
		}

		@MainActor var color: Color {
			switch self {
			case .live: return Viz.statusGood
			case .stale: return Viz.statusWarning
			case .down, .none: return Viz.statusCritical
			}
		}
	}

	private var health: Health {
		if model.isRemote {
			guard let last = model.remoteHealth?.lastTs else { return .none }
			let age = Date().timeIntervalSince1970 - Double(last)
			// The sweep ticks at 60s, so give the server a little more slack
			// than a 10s local collector before calling it stale.
			if age < 90 { return .live }
			if age < 300 { return .stale }
			return .down
		}
		guard let stats = model.pollStats else { return .none }
		let age = Date().timeIntervalSince1970 - Double(stats.lastTs)
		if age < 60 { return .live }
		if age < 300 { return .stale }
		return .down
	}

	var body: some View {
		@Bindable var model = model
		HStack(spacing: 14) {
			HStack(spacing: 5) {
				Circle()
					.fill(health.color)
					.frame(width: 7, height: 7)
				Text(model.isRemote ? "server \(health.label)" : "collector \(health.label)")
			}
			if model.isRemote, let h = model.remoteHealth {
				let erroring = h.collectors.filter { $0.errorsLastHour > 0 }.count
				Text("collectors \(h.collectors.count)" + (erroring > 0 ? " (\(erroring) with errors)" : ""))
				if let last = h.lastTs {
					Text("data \(relative(last))")
				}
				if let bytes = h.dbBytes {
					Text("db \(fmt(Int(bytes / 1_048_576))) MB")
				}
				if model.remoteTruncated {
					Text("truncated — zoom in or shorten the range")
						.foregroundStyle(Viz.statusWarning)
				}
			}
			if let stats = model.pollStats {
				Text("polls \(fmt(stats.totalPolls)) (\(fmt(stats.errorPolls)) err)")
				Text("coverage \(String(format: "%.1f%%", stats.coverageFraction * 100))")
				Text("gaps >5m: \(stats.gapCount)" + (stats.gapCount > 0 ? " (longest \(duration(stats.longestGapS)))" : ""))
				Text("source \(stats.currentSource)")
				Text("last poll \(relative(stats.lastTs))")
			}
			if let err = model.loadError {
				Label(err, systemImage: "exclamationmark.triangle.fill")
					.foregroundStyle(Viz.statusCritical)
					.lineLimit(1)
			}
			if model.dbMissing {
				Button("Start collector") { model.startCollector() }
					.controlSize(.small)
					.help("Install and start this site's background collector agent")
			}
			Spacer()
			if model.loading {
				ProgressView()
					.controlSize(.small)
			}
			Toggle("Auto", isOn: $model.autoRefresh)
				.toggleStyle(.checkbox)
				.controlSize(.small)
			Button {
				Task { await model.reload() }
			} label: {
				Image(systemName: "arrow.clockwise")
			}
			.controlSize(.small)
		}
		.font(.caption)
		.foregroundStyle(.secondary)
		.padding(.horizontal, 10)
		.padding(.vertical, 5)
	}

	private func fmt(_ n: Int) -> String {
		let f = NumberFormatter()
		f.numberStyle = .decimal
		return f.string(from: NSNumber(value: n)) ?? String(n)
	}

	private func duration(_ s: Int64) -> String {
		if s < 60 { return "\(s)s" }
		if s < 3600 { return "\(s / 60)m" }
		return "\(s / 3600)h \((s % 3600) / 60)m"
	}

	private func relative(_ ts: Int64) -> String {
		let age = Int64(Date().timeIntervalSince1970) - ts
		if age < 0 { return "just now" }
		if age < 60 { return "\(age)s ago" }
		if age < 3600 { return "\(age / 60)m ago" }
		return "\(age / 3600)h ago"
	}
}
