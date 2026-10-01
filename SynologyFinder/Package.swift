// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SynologyFinder",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "SynologyDiscovery"),
        .executableTarget(name: "SynologyFinder", dependencies: ["SynologyDiscovery"]),
        .testTarget(name: "SynologyDiscoveryTests", dependencies: ["SynologyDiscovery"]),
    ]
)
