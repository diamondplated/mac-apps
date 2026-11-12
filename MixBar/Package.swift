// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "MixBar", platforms: [.macOS(.v14)], products: [.executable(name: "MixBar", targets: ["MixBar"])], targets: [
    // The real-time render path, in C so the IO callback has no reference counting, allocation or locks.
    .target(name: "MixBarDSP"),
    .target(name: "MixBarCore", dependencies: ["MixBarDSP"]),
    .executableTarget(name: "MixBar", dependencies: ["MixBarCore", "MixBarDSP"]),
    .testTarget(name: "MixBarCoreTests", dependencies: ["MixBarCore", "MixBarDSP"])
])
