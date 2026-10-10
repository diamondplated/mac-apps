// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "ScrollSplit", platforms: [.macOS(.v14)], products: [.executable(name: "ScrollSplit", targets: ["ScrollSplit"])], targets: [
    .target(name: "ScrollSplitCore"),
    .executableTarget(name: "ScrollSplit", dependencies: ["ScrollSplitCore"]),
    .testTarget(name: "ScrollSplitCoreTests", dependencies: ["ScrollSplitCore"])
])
