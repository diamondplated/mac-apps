// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "MacTools",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "MacTools", targets: ["MacTools"])],
    targets: [
        .target(name: "MacToolsCore"),
        .executableTarget(name: "MacTools", dependencies: ["MacToolsCore"]),
        .testTarget(name: "MacToolsCoreTests", dependencies: ["MacToolsCore"]),
    ]
)
