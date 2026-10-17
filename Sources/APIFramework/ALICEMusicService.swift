// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import Foundation
import Logging
import MCPFramework

/// Adapter bridging ALICEProvider to MCPFramework's AudioGenerationService protocol.
/// This avoids circular dependency between APIFramework and MCPFramework.
public final class ALICEMusicService: AudioGenerationService, @unchecked Sendable {
    private let logger = Logger(label: "com.sam.alice.music")

    public init() {}

    @MainActor
    public func isAvailable() async -> Bool {
        guard let provider = ALICEProvider.shared else { return false }
        return provider.isHealthy
    }

    @MainActor
    public func listModels() async throws -> [(id: String, displayName: String, type: String)] {
        guard let provider = ALICEProvider.shared else {
            throw ALICEError.invalidConfiguration("ALICE provider not configured")
        }

        let models = try await provider.fetchAudioModels()
        return models.map { (id: $0.id, displayName: $0.displayName, type: $0.type) }
    }

    @MainActor
    public func generate(
        prompt: String,
        model: String? = nil,
        seconds: Int? = nil,
        steps: Int? = nil,
        guidanceScale: Float? = nil,
        seed: Int? = nil,
        isInstrumental: Bool? = nil
    ) async throws -> AudioGenerationResult {
        guard let provider = ALICEProvider.shared, provider.isHealthy else {
            throw ALICEError.invalidConfiguration("ALICE server not available")
        }

        /// Resolve model: use provided model, or first available, or default.
        let resolvedModel: String
        if let model {
            resolvedModel = model
        } else if let firstModel = provider.availableModels.first?.id {
            resolvedModel = firstModel
        } else {
            resolvedModel = "stable-audio-open-1.0"
        }

        let result = try await provider.generateAudio(
            prompt: prompt,
            model: resolvedModel,
            seconds: seconds,
            steps: steps,
            guidanceScale: guidanceScale,
            seed: seed,
            isInstrumental: isInstrumental
        )

        /// Download the audio file to local temp directory.
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sam-audio", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let filename = "alice-\(UUID().uuidString.prefix(8))-audio.wav"
        let localPath = tempDir.appendingPathComponent(filename)

        try await provider.downloadAudio(from: result.url, to: localPath)

        logger.info("ALICE music generation complete: model=\(result.model), duration=\(result.durationSeconds)s")

        return AudioGenerationResult(
            localPaths: [localPath.path],
            model: result.model,
            durationSeconds: result.durationSeconds,
            sampleRate: result.sampleRate,
            seed: result.seed
        )
    }
}
