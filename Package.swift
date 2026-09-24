// swift-tools-version: 6.3

import PackageDescription

let package = Package(
    name: "SwiftDecision",
    platforms: [
        .iOS(.v15),
        .macOS(.v10_15),
        .tvOS(.v13),
        .watchOS(.v6),
    ],
    products: [
        .library(name: "SwiftDecision", targets: ["SwiftDecision"]),
        .executable(name: "InboxTriageExample", targets: ["InboxTriageExample"]),
    ],
    traits: [
        .trait(name: "MLX", description: "Enable the native Apple MLX Laya backend."),
    ],
    dependencies: [
        .package(
            url: "https://github.com/SoundBlaster/SpecificationCore.git",
            revision: "83cfea8ecc47513e6331b4ecd93189c5e6715636",
            traits: ["Tracing"]
        ),
        .package(url: "https://github.com/ml-explore/mlx-swift.git", exact: "0.31.6"),
        .package(url: "https://github.com/huggingface/swift-transformers.git", exact: "1.3.4"),
    ],
    targets: [
        .target(
            name: "SwiftDecision",
            dependencies: [
                .product(name: "SpecificationCore", package: "SpecificationCore"),
                .product(name: "MLX", package: "mlx-swift", condition: .when(platforms: [.iOS, .macOS], traits: ["MLX"])),
                .product(name: "MLXNN", package: "mlx-swift", condition: .when(platforms: [.iOS, .macOS], traits: ["MLX"])),
                .product(name: "Tokenizers", package: "swift-transformers", condition: .when(platforms: [.iOS, .macOS], traits: ["MLX"])),
            ],
            swiftSettings: [
                .define("SWIFTDECISION_MLX", .when(platforms: [.iOS, .macOS], traits: ["MLX"])),
            ]
        ),
        .executableTarget(
            name: "InboxTriageExample",
            dependencies: ["SwiftDecision"],
            path: "Examples/InboxTriage"
        ),
        .testTarget(
            name: "SwiftDecisionTests",
            dependencies: [
                "SwiftDecision",
                .product(name: "SpecificationCore", package: "SpecificationCore"),
            ],
            swiftSettings: [
                .define("SWIFTDECISION_MLX", .when(platforms: [.iOS, .macOS], traits: ["MLX"])),
            ]
        ),
    ]
)
