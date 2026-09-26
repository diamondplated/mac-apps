// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "DockPeek",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(
            name: "DockPeek",
            targets: ["DockPeek"]
        )
    ],
    dependencies: [],
    targets: [
        .executableTarget(
            name: "DockPeek",
            dependencies: [],
            path: "Sources/DockPeek"
        ),
        .testTarget(
            name: "DockPeekTests",
            dependencies: ["DockPeek"]
        )
    ]
)
