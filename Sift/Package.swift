// swift-tools-version: 6.0
import PackageDescription
import Foundation

// The dylib's install name is @rpath/libduckdb.dylib, so both `swift test` and any
// executable need an rpath pointing at Vendor/duckdb. An absolute path computed from
// the manifest's own location is the only form that works for every build product
// without per-invocation flags. build-app.sh rewrites this for the shipped bundle.
let vendorPath = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .appendingPathComponent("Vendor/duckdb")
    .path

let duckdbLink: [LinkerSetting] = [
    .unsafeFlags(["-L\(vendorPath)", "-Xlinker", "-rpath", "-Xlinker", vendorPath])
]

let package = Package(
    name: "Sift",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "DuckDBKit", targets: ["DuckDBKit"]),
        .library(name: "SiftCore", targets: ["SiftCore"]),
        .library(name: "SiftEngine", targets: ["SiftEngine"]),
        .library(name: "SiftUI", targets: ["SiftUI"]),
        .library(name: "SiftVerify", targets: ["SiftVerify"]),
        .library(name: "SiftPreview", targets: ["SiftPreview"]),
        .executable(name: "sift", targets: ["sift"]),
    ],
    targets: [
        .systemLibrary(name: "CDuckDB", path: "Sources/CDuckDB"),
        // Test-only, and deliberately NOT a test target: SwiftPM test targets cannot import one
        // another (the reason Tests/SiftEngineTests/Fixtures.swift is a second copy of
        // Tests/SiftCoreTests/Fixtures.swift), and all three of them need the same temp-directory
        // root. Lives under Tests/ so it cannot be mistaken for shipping code, and is depended on
        // by nothing else, so it never reaches Sift.app.
        .target(name: "TestSupport", dependencies: ["SiftEngine"], path: "Tests/TestSupport"),
        .target(
            name: "DuckDBKit",
            dependencies: ["CDuckDB"],
            linkerSettings: duckdbLink
        ),
        .testTarget(
            name: "DuckDBKitTests",
            dependencies: ["DuckDBKit", "TestSupport"]
        ),
        // Pure value types only — no dependencies, imports Foundation and nothing else.
        .target(name: "SiftCore"),
        .testTarget(
            name: "SiftCoreTests",
            dependencies: ["SiftCore", "DuckDBKit", "TestSupport"],
            resources: [.copy("Fixtures")]
        ),
        // The connection-needing half of core/source.py (and, later in this plan, session.py).
        // No linkerSettings here: DuckDBKit's rpath flags already propagate transitively through
        // this target's dependency on it, and a duplicate `-Xlinker -rpath` emits
        // `ld: warning: duplicate -rpath`.
        //
        // CDuckDB is listed explicitly because GuardStatements.swift calls
        // duckdb_extract_statements directly: it needs a raw duckdb_connection, and
        // DuckDBKit.Connection.handle is internal to that module by design (Task 3 must not touch
        // Sources/DuckDBKit/**). MEASURED: this edge is not strictly required today — SwiftPM
        // puts a `.systemLibrary` target's module map on the whole graph's Clang-importer search
        // path, so `import CDuckDB` here compiles even with this line removed, because DuckDBKit
        // already imports it. That is undocumented SwiftPM behavior, not a contract; declared
        // explicitly so this target's build does not depend on it staying true.
        .target(
            name: "SiftEngine",
            dependencies: ["SiftCore", "DuckDBKit", "CDuckDB"]
        ),
        // CDuckDB for the same reason SiftEngine itself lists it: GuardStatementsTests reaches the
        // gate's raw scratch connection (`withGuardScratchConnection`) to prove it is hardened, and
        // that connection is a `duckdb_connection`, not a `DuckDBKit.Connection`.
        .testTarget(
            name: "SiftEngineTests",
            dependencies: ["SiftEngine", "SiftVerify", "SiftCore", "DuckDBKit", "CDuckDB", "TestSupport"]
        ),
        // The whole view layer, and every decision in it. No linkerSettings, for the same reason
        // SiftEngine has none: DuckDBKit's rpath flags propagate transitively, and repeating them
        // emits `ld: warning: duplicate -rpath`.
        .target(
            name: "SiftUI",
            dependencies: ["SiftEngine", "SiftCore", "DuckDBKit"]
        ),
        .testTarget(
            name: "SiftUITests",
            dependencies: ["SiftUI", "SiftEngine", "SiftCore", "DuckDBKit", "TestSupport"]
        ),
        // Thin by construction: a test target cannot import an executableTarget, so this holds
        // @main, the menu bar, the toolbar and LaunchServices plumbing — nothing with a decision
        // in it. Everything else is in SiftUI.
        .executableTarget(
            name: "SiftApp",
            dependencies: ["SiftUI", "SiftEngine", "SiftCore"]
        ),
        // The headless verification surface and its loopback HTTP oracle. A separate library so
        // the app never links ~2,500 lines it cannot run: only the CLI and the tests depend on
        // it. No linkerSettings, for the same reason SiftEngine has none.
        .target(
            name: "SiftVerify",
            dependencies: ["SiftEngine", "SiftCore", "DuckDBKit"]
        ),
        // The Quick Look preview's logic: open one file read-only, sample rows, format cells,
        // render the page. A library so the tests and `sift --preview` run the extension's own
        // code; it depends on the engine and never on SiftVerify, so the extension cannot carry
        // the verifier or the loopback server (sift.yml checks the symbols).
        .target(
            name: "SiftPreview",
            dependencies: ["SiftEngine", "SiftCore", "DuckDBKit"]
        ),
        .testTarget(
            name: "SiftPreviewTests",
            dependencies: ["SiftPreview", "SiftEngine", "SiftCore", "DuckDBKit", "TestSupport"]
        ),
        // The thin shell of the Quick Look extension. An app extension's entry point is
        // `NSExtensionMain`, not `main`, so the linker is told to start there; build-app.sh wraps
        // the binary in a .appex. `-application-extension` keeps it to extension-safe API.
        // (SwiftPM, not an Xcode project like Latent's: this package links libduckdb through
        // unsafeFlags, and an Xcode project would have to repeat that wiring.)
        .executableTarget(
            name: "SiftPreviewExtension",
            dependencies: ["SiftPreview"],
            swiftSettings: [.unsafeFlags(["-application-extension"])],
            linkerSettings: [.unsafeFlags(["-Xlinker", "-e", "-Xlinker", "_NSExtensionMain", "-application-extension"])]
        ),
        // The headless CLI, and the reason browser mode could be deleted. Kept deliberately
        // thin: a test target cannot import an `executableTarget`, so everything it does lives
        // in SiftVerify/Verification.swift instead.
        .executableTarget(
            name: "sift",
            dependencies: ["SiftEngine", "SiftVerify", "SiftPreview"]
        ),
    ]
)
