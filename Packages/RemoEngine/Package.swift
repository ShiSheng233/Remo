// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "RemoEngine",
    platforms: [.macOS(.v13), .iOS(.v16)],
    products: [
        .library(name: "RemoEngine", targets: ["RemoEngine"]),
        .executable(name: "remo-engine", targets: ["RemoEngineCLI"]),
    ],
    dependencies: [
        .package(path: "../RemoCodec"),
        .package(path: "../RemoShims"),
        .package(path: "../RemoTransport"),
    ],
    targets: [
        .target(
            name: "RemoEngine",
            dependencies: [
                "RemoCodec",
                "RemoTransport",
                .product(name: "CVirtualDisplay", package: "RemoShims", condition: .when(platforms: [.macOS])),
            ]),
        .executableTarget(name: "RemoEngineCLI", dependencies: ["RemoEngine"]),
        .testTarget(name: "RemoEngineCLITests", dependencies: ["RemoEngineCLI"]),
        .testTarget(
            name: "RemoEngineTests", dependencies: ["RemoEngine", "RemoCodec", "RemoTransport"]),
    ]
)
