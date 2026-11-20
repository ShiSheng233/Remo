// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "RemoEngine",
    platforms: [.macOS(.v12), .iOS(.v15)],
    products: [
        .library(name: "RemoEngine", targets: ["RemoEngine"]),
        .executable(name: "remo-engine", targets: ["RemoEngineCLI"]),
    ],
    dependencies: [.package(path: "../RemoCodec"), .package(path: "../RemoTransport")],
    targets: [
        .target(name: "RemoEngine", dependencies: ["RemoCodec", "RemoTransport"]),
        .executableTarget(
            name: "RemoEngineCLI", dependencies: ["RemoEngine", "RemoTransport", "RemoCodec"]),
        .testTarget(
            name: "RemoEngineTests", dependencies: ["RemoEngine", "RemoCodec", "RemoTransport"]),
    ]
)
