// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "LinkRoutes", platforms: [.macOS(.v14)], products: [.executable(name: "LinkRoutes", targets: ["LinkRoutes"])], targets: [.executableTarget(name: "LinkRoutes"), .testTarget(name: "LinkRoutesTests", dependencies: ["LinkRoutes"])])
