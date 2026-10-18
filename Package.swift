// swift-tools-version: 6.0
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "SAM",
    platforms: [
        .macOS("14.0")
    ],
    products: [
        .executable(
            name: "SAM",
            targets: ["SAM"]
        ),
        .library(
            name: "ConversationEngine",
            targets: ["ConversationEngine"]
        ),
        .library(
            name: "MLXIntegration",
            targets: ["MLXIntegration"]
        ),
        .library(
            name: "UserInterface",
            targets: ["UserInterface"]
        ),
        .library(
            name: "ConfigurationSystem",
            targets: ["ConfigurationSystem"]
        ),
        .library(
            name: "APIFramework",
            targets: ["APIFramework"]
        ),
        .library(
            name: "MCPFramework",
            targets: ["MCPFramework"]
        ),
        .library(
            name: "SharedData",
            targets: ["SharedData"]
        ),
        .library(
            name: "SecurityFramework",
            targets: ["SecurityFramework"]
        ),
        .library(
            name: "VoiceFramework",
            targets: ["VoiceFramework"]
        )
    ],
    dependencies: [
        // MLX Swift for Apple Silicon AI acceleration
        .package(url: "https://github.com/ml-explore/mlx-swift", from: "0.32.3"),

        // MLX Swift LM - LLMs and VLMs with MLX Swift (split from mlx-swift-examples)
        .package(url: "https://github.com/ml-explore/mlx-swift-lm", from: "3.32.3"),

        // Transformers and tokenization support
        .package(url: "https://github.com/huggingface/swift-transformers", from: "1.3.5"),

        // Swift Crypto for security operations
        .package(url: "https://github.com/apple/swift-crypto", from: "4.5.2"),

        // Swift Log for structured logging
        .package(url: "https://github.com/apple/swift-log", from: "1.16.1"),

        // SQLite for memory database storage
        .package(url: "https://github.com/stephencelis/SQLite.swift", from: "0.16.0"),

        // Apple's swift-markdown for AST-based markdown parsing (PDF generation)
        .package(url: "https://github.com/apple/swift-markdown", from: "0.9.0"),

        // ZIPFoundation for Office document extraction (DOCX, XLSX are ZIP archives)
        .package(url: "https://github.com/weichsel/ZIPFoundation", from: "0.9.0"),

        // Sparkle for automatic updates
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.9.0")
    ],
    targets: [
        // Binary target for llama.cpp XCFramework (built by Makefile)
        .binaryTarget(
            name: "llama",
            path: "external/llama.cpp/build-apple/llama.xcframework"
        ),

        // Main executable target
        .executableTarget(
            name: "SAM",
            dependencies: [
                "ConversationEngine",
                "MLXIntegration",
                "UserInterface",
                "ConfigurationSystem",
                "APIFramework",
                "MCPFramework",
                "VoiceFramework",
                .product(name: "Sparkle", package: "Sparkle")
            ],
            path: "Sources/SAM"
        ),

        // Core conversation system
        .target(
            name: "ConversationEngine",
            dependencies: [
                "ConfigurationSystem",
                "MCPFramework",
                .product(name: "SQLite", package: "SQLite.swift"),
                .product(name: "Logging", package: "swift-log")
            ],
            path: "Sources/ConversationEngine"
        ),

        // MLX and model management
        .target(
            name: "MLXIntegration",
            dependencies: [
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "MLXNN", package: "mlx-swift"),
                .product(name: "MLXRandom", package: "mlx-swift"),
                .product(name: "MLXFFT", package: "mlx-swift"),
                .product(name: "MLXOptimizers", package: "mlx-swift"),
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "Transformers", package: "swift-transformers"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "Crypto", package: "swift-crypto"),
                "ConfigurationSystem"
            ],
            path: "Sources/MLXIntegration"
        ),

        // SwiftUI user interface (NO multi-pane navigation)
        .target(
            name: "UserInterface",
            dependencies: [
                "ConversationEngine",
                "ConfigurationSystem",
                "APIFramework",
                "SharedData",
                "MCPFramework",
                "VoiceFramework",
                .product(name: "Markdown", package: "swift-markdown"),
                .product(name: "ZIPFoundation", package: "ZIPFoundation")
            ],
            path: "Sources/UserInterface"
        ),

        // Shared data support for topics, storage and locking
        .target(
            name: "SharedData",
            dependencies: [
                "ConversationEngine",
                "ConfigurationSystem",
                .product(name: "SQLite", package: "SQLite.swift"),
                .product(name: "Logging", package: "swift-log")
            ],
            path: "Sources/SharedData"
        ),

        // Configuration management system
        .target(
            name: "ConfigurationSystem",
            dependencies: [
                .product(name: "Logging", package: "swift-log")
            ],
            path: "Sources/ConfigurationSystem"
        ),

        // API Framework for provider integration and orchestration
        .target(
            name: "APIFramework",
            dependencies: [
                "llama",
                "ConversationEngine",
                "ConfigurationSystem",
                "MLXIntegration",
                "SharedData",
                "SecurityFramework",
                .product(name: "Logging", package: "swift-log"),
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "ZIPFoundation", package: "ZIPFoundation")
            ],
            path: "Sources/APIFramework"
        ),

        // MCP Framework for agent-tool communication
        .target(
            name: "MCPFramework",
            dependencies: [
                "ConfigurationSystem",
                "SecurityFramework",
                .product(name: "Logging", package: "swift-log")
            ],
            path: "Sources/MCPFramework"
        ),

        // Security Framework for input sanitization, secret redaction, and command analysis
        .target(
            name: "SecurityFramework",
            dependencies: [
                .product(name: "Logging", package: "swift-log")
            ],
            path: "Sources/SecurityFramework"
        ),

        // Voice Framework for speech input/output
        .target(
            name: "VoiceFramework",
            dependencies: [
                .product(name: "Logging", package: "swift-log")
            ],
            path: "Sources/VoiceFramework"
        ),

        // Test targets
        .testTarget(
            name: "ConversationEngineTests",
            dependencies: ["ConversationEngine"],
            path: "Tests/ConversationEngineTests"
        ),
        .testTarget(
            name: "UserInterfaceTests",
            dependencies: ["UserInterface"],
            path: "Tests/UserInterfaceTests"
        ),
        .testTarget(
            name: "ConfigurationSystemTests",
            dependencies: ["ConfigurationSystem"],
            path: "Tests/ConfigurationSystemTests"
        ),
        .testTarget(
            name: "APIFrameworkTests",
            dependencies: ["APIFramework"],
            path: "Tests/APIFrameworkTests"
        ),
        .testTarget(
            name: "MCPFrameworkTests",
            dependencies: ["MCPFramework", "ConfigurationSystem", "APIFramework"],
            path: "Tests/MCPFrameworkTests"
        ),
        .testTarget(
            name: "SecurityFrameworkTests",
            dependencies: ["SecurityFramework"],
            path: "Tests/SecurityFrameworkTests"
        )
    ]
)
