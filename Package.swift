// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "AIMeter",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "AIMeter", targets: ["AIMeter"]),
        .executable(name: "AIMeterSnapshot", targets: ["AIMeterSnapshot"])
    ],
    dependencies: [
        .package(
            url: "https://github.com/sparkle-project/Sparkle",
            from: "2.9.0"
        )
    ],
    targets: [
        .target(
            name: "AIMeterCore",
            path: "Sources/AIMeterCore"
        ),
        .target(
            name: "AIMeterUI",
            dependencies: ["AIMeterCore"],
            path: "Sources/AIMeterUI",
            resources: [
                .process("Resources")
            ]
        ),
        .executableTarget(
            name: "AIMeter",
            dependencies: [
                "AIMeterUI",
                .product(name: "Sparkle", package: "Sparkle")
            ],
            path: "Sources/AIMeter"
        ),
        .executableTarget(
            name: "AIMeterSnapshot",
            dependencies: ["AIMeterCore", "AIMeterUI"],
            path: "Sources/AIMeterSnapshot"
        ),
        .testTarget(
            name: "AIMeterTests",
            dependencies: ["AIMeterCore", "AIMeterUI"],
            path: "Tests/AIMeterTests"
        )
    ]
)
