// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import Foundation
import Logging
import MCPFramework

/// Adapter bridging ALICEProvider to MCPFramework's ImageGenerationService protocol.
/// This avoids circular dependency between APIFramework and MCPFramework.
public final class ALICEImageGenerationService: ImageGenerationService, @unchecked Sendable {
    private let logger = Logger(label: "com.sam.alice.service")

    public init() {}

    @MainActor
    public func isAvailable() async -> Bool {
        guard let provider = ALICEProvider.shared else { return false }
        return provider.isHealthy
    }

    @MainActor
    public func listModels() async throws -> [(id: String, displayName: String, type: String, defaultWidth: Int, defaultHeight: Int)] {
        guard let provider = ALICEProvider.shared else {
            throw ALICEError.invalidConfiguration("ALICE provider not configured")
        }

        let models = try await provider.fetchAvailableModels()
        return models.map { model in
            let type = model.isSDXL ? "SDXL" : "SD1.5"
            let dims = model.defaultDimensions
            return (id: model.id, displayName: model.displayName, type: type, defaultWidth: dims.width, defaultHeight: dims.height)
        }
    }

    @MainActor
    public func generate(
        prompt: String,
        negativePrompt: String?,
        model: String?,
        steps: Int,
        guidanceScale: Float,
        scheduler: String,
        seed: Int?,
        width: Int?,
        height: Int?
    ) async throws -> ImageGenerationResult {
        guard let provider = ALICEProvider.shared, provider.isHealthy else {
            throw ALICEError.invalidConfiguration("ALICE server not available")
        }

        // Resolve model
        let resolvedModel = model ?? provider.availableModels.first?.id ?? ""
        guard !resolvedModel.isEmpty else {
            throw ALICEError.generationFailed("No model available")
        }

        // Detect defaults from model type
        let modelLower = resolvedModel.lowercased()
        let isSDXL = modelLower.contains("xl") || modelLower.contains("sdxl")
        let defaultSize = isSDXL ? 1024 : 512
        let resolvedWidth = width ?? defaultSize
        let resolvedHeight = height ?? defaultSize

        let result = try await provider.generateImages(
            prompt: prompt,
            negativePrompt: negativePrompt,
            model: resolvedModel,
            steps: steps,
            guidanceScale: guidanceScale,
            scheduler: scheduler,
            seed: seed,
            width: resolvedWidth,
            height: resolvedHeight
        )

        // Download images to local temp directory
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sam-images", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        var localPaths: [String] = []
        for (index, imageUrl) in result.imageUrls.enumerated() {
            let filename = "alice-\(UUID().uuidString.prefix(8))-\(index).png"
            let localPath = tempDir.appendingPathComponent(filename)
            try await provider.downloadImage(from: imageUrl, to: localPath)
            localPaths.append(localPath.path)
        }

        return ImageGenerationResult(
            localPaths: localPaths,
            model: result.model,
            width: resolvedWidth,
            height: resolvedHeight,
            steps: steps
        )
    }
}
