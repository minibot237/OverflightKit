// swift-tools-version: 6.0
import PackageDescription

let package = Package(
	name: "OverflightKit",
	platforms: [.macOS(.v14)],
	products: [
		.library(name: "OverflightCore", targets: ["OverflightCore"]),
		.executable(name: "OverflightCollector", targets: ["OverflightCollector"]),
		.executable(name: "OverflightViewer", targets: ["OverflightViewer"]),
		.executable(name: "OverflightServer", targets: ["OverflightServer"]),
	],
	targets: [
		.target(name: "OverflightCore"),
		.executableTarget(name: "OverflightCollector", dependencies: ["OverflightCore"]),
		.executableTarget(name: "OverflightViewer", dependencies: ["OverflightCore"]),
		.executableTarget(name: "OverflightServer", dependencies: ["OverflightCore"]),
		.testTarget(name: "OverflightCoreTests", dependencies: ["OverflightCore"]),
	]
)
