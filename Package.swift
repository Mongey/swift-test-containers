// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "swift-test-containers",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(
            name: "TestContainers",
            targets: ["TestContainers"]
        )
    ],
    targets: [
        .target(
            name: "TestContainers"
        ),
        .testTarget(
            name: "TestContainersTests",
            dependencies: ["TestContainers"]
        )
    ]
)

