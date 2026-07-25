import SwiftUI
import AppKit
import OverflightCore

/// What a window is looking at: a local site database, or a saved view
/// browsed through minibot's query API.
enum ViewerSelection {
	case local(site: SiteConfig, config: Config)
	case remote(api: RemoteAPI, view: RemoteView, all: [RemoteView])

	/// Stable identity for `.id()` — switching selection rebuilds the model.
	var id: String {
		switch self {
		case .local(let site, _): return "local.\(site.slug)"
		case .remote(let api, let view, _): return "remote.\(api.baseURL.absoluteString).\(view.slug)"
		}
	}
}

struct ContentView: View {
	@Environment(ViewerModel.self) private var model

	var body: some View {
		VStack(spacing: 0) {
			HSplitView {
				MapPane()
					.frame(minWidth: 460, maxWidth: .infinity, maxHeight: .infinity)
				SidePanel()
					.frame(minWidth: 320, idealWidth: 350, maxWidth: 420)
			}
			Divider()
			StatusStrip()
		}
		.frame(minWidth: 940, minHeight: 640)
		.task { model.start() }
	}
}

/// One window bound to one selection. `.id(selection.id)` upstream guarantees
/// a fresh model whenever the selection changes, and picking the already-open
/// one from another window simply yields a clone.
struct SiteWindow: View {
	let selection: ViewerSelection
	let onSwitch: (ViewerSelection) -> Void
	@State private var model: ViewerModel

	init(selection: ViewerSelection, onSwitch: @escaping (ViewerSelection) -> Void) {
		self.selection = selection
		self.onSwitch = onSwitch
		switch selection {
		case .local(let site, let config):
			_model = State(initialValue: ViewerModel(site: site, config: config))
		case .remote(let api, let view, _):
			_model = State(initialValue: ViewerModel(remote: api, view: view))
		}
	}

	var body: some View {
		ContentView()
			.environment(model)
			.navigationTitle(model.windowTitle)
			.toolbar {
				ToolbarItem {
					switchMenu
				}
			}
	}

	@ViewBuilder
	private var switchMenu: some View {
		switch selection {
		case .local(let site, let config):
			Menu {
				ForEach(config.sites) { s in
					Button {
						onSwitch(.local(site: s, config: config))
					} label: {
						if s.slug == site.slug {
							Label(s.title, systemImage: "checkmark")
						} else {
							Text(s.title)
						}
					}
				}
				Divider()
				Button("Other site...") {
					onSwitch(selection)
					// Handled by WindowRoot: re-picking the same selection reopens the picker.
				}
			} label: {
				Label(site.icao ?? site.slug.uppercased(), systemImage: "airplane.circle")
			}
			.help("Switch this window to another site")
		case .remote(let api, let view, let all):
			Menu {
				ForEach(all) { v in
					Button {
						onSwitch(.remote(api: api, view: v, all: all))
					} label: {
						if v.slug == view.slug {
							Label(v.title, systemImage: "checkmark")
						} else {
							Text(v.title)
						}
					}
				}
				Divider()
				Button("Other site...") {
					onSwitch(selection)
				}
			} label: {
				Label(view.slug.uppercased(), systemImage: "antenna.radiowaves.left.and.right")
			}
			.help("Switch this window to another remote view")
		}
	}
}

struct WindowRoot: View {
	@State private var selection: ViewerSelection?
	@State private var showPicker = false
	@State private var autoOpened = false

	var body: some View {
		Group {
			if let selection, !showPicker {
				SiteWindow(selection: selection) { next in
					if next.id == selection.id {
						showPicker = true
					} else {
						self.selection = next
					}
				}
				.id(selection.id)
			} else {
				SitePickerView { picked in
					selection = picked
					showPicker = false
				}
			}
		}
		.task { await autoOpenFromArguments() }
	}

	/// `swift run OverflightViewer --remote [slug] [--server URL]` jumps
	/// straight into remote mode — handy for demos and for verifying against
	/// the live API without clicking through the picker.
	private func autoOpenFromArguments() async {
		guard !autoOpened, selection == nil else { return }
		autoOpened = true
		let args = CommandLine.arguments
		guard let flagIdx = args.firstIndex(of: "--remote") else { return }
		let slug = args.indices.contains(flagIdx + 1) && !args[flagIdx + 1].hasPrefix("--")
			? args[flagIdx + 1] : nil
		var urlString = BrowseModeState.load().serverURL ?? BrowseModeState.defaultServerURL
		if let serverIdx = args.firstIndex(of: "--server"), args.indices.contains(serverIdx + 1) {
			urlString = args[serverIdx + 1]
		}
		guard let api = RemoteAPI(urlString: urlString) else { return }
		guard let views = try? await api.views(), !views.isEmpty else { return }
		guard let view = slug.map({ s in views.first { $0.slug == s } }) ?? views.first else { return }
		selection = .remote(api: api, view: view, all: views)
	}
}

@main
struct OverflightViewerApp: App {
	init() {
		// Running from `swift run` there is no app bundle; promote to a
		// regular app so the window fronts and gets a menu bar.
		NSApplication.shared.setActivationPolicy(.regular)
	}

	var body: some Scene {
		WindowGroup {
			WindowRoot()
				.onAppear {
					NSApp.activate(ignoringOtherApps: true)
				}
		}
	}
}
