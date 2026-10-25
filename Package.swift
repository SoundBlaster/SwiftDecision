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
        .library(name: "SwiftDecisionOpenAI", targets: ["SwiftDecisionOpenAI"]),
        .library(name: "SwiftDecisionGLiNER", targets: ["SwiftDecisionGLiNER"]),
        .executable(name: "InboxTriageExample", targets: ["InboxTriageExample"]),
    ],
    traits: [
        .trait(name: "MLX", description: "Enable the native Apple MLX Laya backend."),
        .trait(name: "GLiNER", description: "Enable the optional GLiNER Core ML backend and tokenizer."),
    ],
    dependencies: [
        .package(
            url: "https://github.com/SoundBlaster/SpecificationCore.git",
            from: "2.1.0",
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
        .target(
            name: "SwiftDecisionOpenAI",
            dependencies: ["SwiftDecision"]
        ),
        .target(
            name: "SwiftDecisionGLiNER",
            dependencies: [
                "SwiftDecision",
            ],
            swiftSettings: [
                .define("SWIFTDECISION_GLINER", .when(platforms: [.iOS, .macOS], traits: ["GLiNER"])),
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
        .testTarget(
            name: "SwiftDecisionOpenAITests",
            dependencies: ["SwiftDecision", "SwiftDecisionOpenAI"]
        ),
        .testTarget(
            name: "SwiftDecisionGLiNERTests",
            dependencies: ["SwiftDecision", "SwiftDecisionGLiNER"],
            resources: [.copy("Fixtures")],
            swiftSettings: [
                .define("SWIFTDECISION_GLINER", .when(platforms: [.iOS, .macOS], traits: ["GLiNER"])),
            ]
        ),
    ]
)
