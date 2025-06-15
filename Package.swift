// swift-tools-version: 5.7
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "SimplePing",
    platforms: [
        .iOS(.v13),
        .macOS(.v10_15),
        .watchOS(.v6),
        .tvOS(.v13)
    ],
    products: [
        .library(
            name: "SimplePing",
            targets: ["SimplePing"]
        ),
    ],
    dependencies: [
        // No external dependencies
    ],
    targets: [
        .target(
            name: "SimplePing",
            dependencies: []
        ),
        .testTarget(
            name: "SimplePingTests",
            dependencies: ["SimplePing"]
        ),
    ]
)