// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "RightHere", platforms: [.macOS(.v14)], products: [
    .executable(name: "RightHere", targets: ["RightHere"]),
    .executable(name: "RightHereFinder", targets: ["RightHereFinder"])
], targets: [
    .target(name: "RightHereCore"),
    .executableTarget(name: "RightHere", dependencies: ["RightHereCore"]),
    // The Finder Sync extension. An app extension starts at `NSExtensionMain`, not `main`, so the
    // linker is told to; build-app.sh wraps the binary in a .appex. `-application-extension`
    // keeps it to extension-safe API.
    .executableTarget(name: "RightHereFinder", dependencies: ["RightHereCore"],
                      swiftSettings: [.unsafeFlags(["-application-extension"])],
                      linkerSettings: [.unsafeFlags(["-Xlinker", "-e", "-Xlinker", "_NSExtensionMain", "-application-extension"])]),
    .testTarget(name: "RightHereCoreTests", dependencies: ["RightHereCore"])
])
