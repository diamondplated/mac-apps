// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "MacTools",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "MacTools", targets: ["MacTools"])],
    // Keep the exact pin: docs/RELEASING.md and scripts/release.sh name this
    // version for the signing tools, so a bump updates them too. One package
    // per line keeps Dependabot's Swift parser from reading past the `)`.
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.1"),
    ],
    targets: [
        .target(name: "MacToolsCore"),
        .executableTarget(name: "MacTools", dependencies: ["MacToolsCore", .product(name: "Sparkle", package: "Sparkle")],
                          linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]),
        .testTarget(name: "MacToolsCoreTests", dependencies: ["MacToolsCore"]),
        .testTarget(name: "MacToolsUpdaterTests", dependencies: ["MacTools"]),
    ]
)
