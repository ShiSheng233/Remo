// swift-tools-version: 6.4

import PackageDescription

let package = Package(
    name: "RemoShims",
    platforms: [.macOS(.v13), .iOS(.v16)],
    products: [
        .library(name: "CVirtualDisplay", targets: ["CVirtualDisplay"]),
    ],
    targets: [
        .target(name: "CVirtualDisplay"),
    ]
)
