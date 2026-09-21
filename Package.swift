// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "SwiftDecision",
    platforms: [
        .iOS(.v13),
        .macOS(.v10_15),
        .tvOS(.v13),
        .watchOS(.v6)
    ],
    products: [
        .library(name: "SwiftDecision", targets: ["SwiftDecision"])
    ],
    dependencies: [
        .package(url: "https://github.com/SoundBlaster/SpecificationCore.git", exact: "1.1.0")
    ],
    targets: [
        .target(
            name: "SwiftDecision",
            dependencies: [.product(name: "SpecificationCore", package: "SpecificationCore")]
        ),
        .testTarget(
            name: "SwiftDecisionTests",
            dependencies: [
                "SwiftDecision",
                .product(name: "SpecificationCore", package: "SpecificationCore")
            ]
        )
    ]
)
