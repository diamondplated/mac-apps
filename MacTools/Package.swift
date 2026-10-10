// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "MacTools",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "MacTools", targets: ["MacTools"])],
    dependencies: [.package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0")],
    targets: [
        .target(name: "MacToolsCore"),
        .executableTarget(name: "MacTools", dependencies: ["MacToolsCore", .product(name: "Sparkle", package: "Sparkle")],
                          linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]),
        .testTarget(name: "MacToolsCoreTests", dependencies: ["MacToolsCore"]),
        .testTarget(name: "MacToolsUpdaterTests", dependencies: ["MacTools"]),
    ]
)
