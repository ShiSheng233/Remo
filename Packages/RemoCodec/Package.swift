// swift-tools-version: 6.4

import PackageDescription

let package = Package(
    name: "RemoCodec",
    platforms: [.macOS(.v12), .iOS(.v15)],
    products: [.library(name: "RemoCodec", targets: ["RemoCodec"])],
    targets: [
        .target(name: "RemoCodec"),
        .testTarget(name: "RemoCodecTests", dependencies: ["RemoCodec"]),
    ]
)
