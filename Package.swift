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
        .package(url: "https://github.com/swift-server/async-http-client.git", from: "1.21.0"),
    ],
    targets: [
        .target(
            name: "TestContainers",
            dependencies: [
                .product(name: "Subprocess", package: "swift-subprocess"),
                .product(name: "Crypto", package: "swift-crypto", condition: .when(platforms: [.linux, .windows])),
                .product(name: "AsyncHTTPClient", package: "async-http-client"),
            ]
        ),
        .testTarget(
            name: "TestContainersTests",
            dependencies: ["TestContainers"]
        )
    ]
)
