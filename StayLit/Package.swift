// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "StayLit", platforms: [.macOS(.v14)], products: [.executable(name: "StayLit", targets: ["StayLit"])], targets: [
    .target(name: "StayLitCore"),
    .executableTarget(name: "StayLit", dependencies: ["StayLitCore"]),
    .testTarget(name: "StayLitCoreTests", dependencies: ["StayLitCore"])
])
