// swift-tools-version: 6.1

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
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-subprocess.git", branch: "main"),
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.0.0"),
    ],
    targets: [
        .target(
            name: "TestContainers",
            dependencies: [
                .product(name: "Subprocess", package: "swift-subprocess"),
                .product(name: "Crypto", package: "swift-crypto", condition: .when(platforms: [.linux, .windows])),
            ]
        ),
        .testTarget(
            name: "TestContainersTests",
            dependencies: ["TestContainers"]
        )
    ]
)
