// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PhotoViewer",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "PipelineCore", targets: ["PipelineCore"]),
        .library(name: "EnhancementStages", targets: ["EnhancementStages"]),
        .library(name: "PhotoIO", targets: ["PhotoIO"]),
        .library(name: "PhotoML", targets: ["PhotoML"]),
        .library(name: "PhotoSearch", targets: ["PhotoSearch"]),
        .library(name: "PhotoViewerCore", targets: ["PhotoViewerCore"]),
        .library(name: "PhotoGeo", targets: ["PhotoGeo"]),
        .library(name: "PhotoQuickLook", targets: ["PhotoQuickLook"]),
        .library(name: "PhotoServe", targets: ["PhotoServe"]),
        .library(name: "PhotoContainers", targets: ["PhotoContainers"]),
        .executable(name: "pv-pipeline", targets: ["PipelineCLI"]),
        .executable(name: "Latent", targets: ["PhotoViewerApp"]),
    ],
    targets: [
        .target(
            name: "PipelineCore",
            path: "Sources/PipelineCore"
        ),
        .target(
            name: "EnhancementStages",
            dependencies: ["PipelineCore", "PhotoML"],
            path: "Sources/EnhancementStages"
        ),
        .target(
            name: "PhotoIO",
            dependencies: ["PipelineCore"],
            path: "Sources/PhotoIO"
        ),
        .target(
            name: "PhotoML",
            dependencies: ["PipelineCore"],
            path: "Sources/PhotoML"
        ),
        .target(
            name: "PhotoSearch",
            dependencies: ["PipelineCore", "PhotoIO", "PhotoML"],
            path: "Sources/PhotoSearch"
        ),
        .target(
            name: "PhotoViewerCore",
            dependencies: [],
            path: "Sources/PhotoViewerCore"
        ),
        .target(
            name: "PhotoGeo",
            dependencies: ["PipelineCore", "PhotoIO"],
            path: "Sources/PhotoGeo"
        ),
        .target(
            name: "PhotoQuickLook",
            dependencies: ["PipelineCore", "PhotoIO"],
            path: "Sources/PhotoQuickLook"
        ),
        .target(
            name: "PhotoServe",
            dependencies: ["PhotoViewerCore"],
            path: "Sources/PhotoServe",
            resources: [.embedInCode("Resources/client.html")]
        ),
        .target(
            name: "PhotoContainers",
            dependencies: [],
            path: "Sources/PhotoContainers"
        ),
        .target(
            name: "VerificationSupport",
            dependencies: ["PipelineCore", "PhotoIO", "PhotoContainers"],
            path: "VerificationSupport",
            resources: [.copy("Resources/oversized-20000.png"), .copy("Resources/Matroska"), .copy("Resources/AVI")]
        ),
        .executableTarget(
            name: "PipelineCLI",
            dependencies: ["PipelineCore", "EnhancementStages", "PhotoIO", "PhotoML", "PhotoSearch", "PhotoViewerCore", "PhotoGeo", "PhotoQuickLook", "PhotoServe", "VerificationSupport"],
            path: "Sources/PipelineCLI"
        ),
        .executableTarget(
            name: "PhotoViewerApp",
            dependencies: ["PipelineCore", "EnhancementStages", "PhotoIO", "PhotoML", "PhotoSearch", "PhotoViewerCore", "PhotoGeo", "PhotoServe", "PhotoContainers"],
            path: "Sources/PhotoViewerApp"
        ),
        .testTarget(
            name: "PipelineCoreTests",
            dependencies: ["PipelineCore", "EnhancementStages", "PhotoIO", "PhotoML", "PhotoSearch", "PhotoQuickLook", "VerificationSupport"],
            path: "Tests/PipelineCoreTests"
        ),
        .testTarget(
            name: "PhotoViewerCoreTests",
            dependencies: ["PhotoViewerCore"],
            path: "Tests/PhotoViewerCoreTests"
        ),
        .testTarget(
            name: "PhotoServeTests",
            dependencies: ["PhotoServe"],
            path: "Tests/PhotoServeTests"
        ),
    ]
)
