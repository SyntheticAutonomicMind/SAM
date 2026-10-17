// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import Foundation
import Logging
import ConfigurationSystem

/// MCP tool for AI music/audio generation via remote ALICE server.
/// Uses injected AudioGenerationService to avoid circular module dependency.
public class MusicGenerationTool: ConsolidatedMCP, @unchecked Sendable {
    public let name = "music_operations"
    public let supportedOperations = ["generate", "list_models"]

    /// Default to list_models when operation is omitted entirely — it's the
    /// only operation that can succeed without any parameters.
    public var defaultOperation: String { "list_models" }

    public var parameters: [String: MCPToolParameter] {
        [
            "operation": MCPToolParameter(
                type: .string,
                description: "Operation to perform: generate or list_models",
                required: true,
                enumValues: ["generate", "list_models"]
            ),
            "prompt": MCPToolParameter(
                type: .string,
                description: "Text description of the music/audio to generate (required for generate)",
                required: false
            ),
            "model": MCPToolParameter(
                type: .string,
                description: "Audio model ID to use (e.g. stable-audio-open-1.0, minimax-music-3; optional, uses default)",
                required: false
            ),
            "seconds": MCPToolParameter(
                type: .integer,
                description: "Duration in seconds (1-47 for Stable Audio, 1-360 for MiniMax Music)",
                required: false
            ),
            "steps": MCPToolParameter(
                type: .integer,
                description: "Number of diffusion/flow-matching steps (default: varies by model)",
                required: false
            ),
            "cfg_scale": MCPToolParameter(
                type: .string,
                description: "Guidance scale as number (default: 7.0; ignored by MiniMax Music 3)",
                required: false
            ),
            "seed": MCPToolParameter(
                type: .integer,
                description: "Random seed for reproducibility",
                required: false
            ),
            "is_instrumental": MCPToolParameter(
                type: .boolean,
                description: "For MiniMax Music 3: generate instrumental music with vocal leakage prevention (default: false)",
                required: false
            )
        ]
    }

    private let logger = Logger(label: "com.sam.mcp.MusicGeneration")
    private var service: AudioGenerationService?

    public var description: String {
        return """
        Generate music and audio using a remote ALICE server.

        OPERATIONS:
        • generate - Generate audio from a text prompt
        • list_models - List available audio generation models

        SUPPORTED MODELS:
        • stable-audio-open-1.0 — 47s stereo audio at 44.1 kHz from text prompts
        • minimax-music-3 — up to 6-minute songs with lyrics and structured music descriptions

        EXAMPLES:
        {"operation": "generate", "prompt": "A warm acoustic guitar loop, 90 BPM", "seconds": 30}
        {"operation": "generate", "prompt": "orchestral film score with dramatic strings", "model": "stable-audio-open-1.0", "steps": 100, "guidance_scale": 7.0}
        {"operation": "generate", "prompt": "instrumental jazz fusion with brushed drums", "model": "minimax-music-3", "seconds": 180, "is_instrumental": true}
        {"operation": "list_models"}
        """
    }

    /// Inject the audio generation service at runtime.
    public func setService(_ service: AudioGenerationService) {
        self.service = service
    }

    public func initialize() async throws {
        logger.debug("MusicGenerationTool initializing")
        guard let service = self.service else {
            logger.info("MusicGenerationTool: No audio generation service configured - tool will not be available")
            throw NSError(domain: "MusicGenerationTool", code: 2, userInfo: [NSLocalizedDescriptionKey: "Audio generation service not configured"])
        }
        let available = await service.isAvailable()
        if !available {
            logger.info("MusicGenerationTool: ALICE server not reachable - tool will not be available")
            throw NSError(domain: "MusicGenerationTool", code: 3, userInfo: [NSLocalizedDescriptionKey: "Audio generation server not available"])
        }
        logger.info("MusicGenerationTool initialized - ALICE server is available")
    }

    /// Infer operation from parameters when `operation` is omitted.
    public func inferOperation(from parameters: [String: Any]) -> String? {
        if parameters["operation"] as? String != nil { return nil }
        if parameters["prompt"] as? String != nil { return "generate" }
        return nil
    }

    @MainActor
    public func routeOperation(
        _ operation: String,
        parameters: [String: Any],
        context: MCPExecutionContext
    ) async -> MCPToolResult {
        guard let service = service else {
            return errorResult("Audio generation is not configured. Set up ALICE server in Preferences -> Image Generation.")
        }

        switch operation {
        case "generate":
            return await executeGenerate(service: service, parameters: parameters)
        case "list_models":
            return await executeListModels(service: service)
        default:
            return operationError(operation, message: "Unknown operation")
        }
    }

    // MARK: - Generate

    @MainActor
    private func executeGenerate(service: AudioGenerationService, parameters: [String: Any]) async -> MCPToolResult {
        guard await service.isAvailable() else {
            return errorResult("Audio generation server is not available. Check Preferences -> Image Generation (ALICE server).")
        }

        guard let prompt = parameters["prompt"] as? String, !prompt.isEmpty else {
            return errorResult("'prompt' parameter is required.")
        }

        let model = parameters["model"] as? String
        let seconds = parameters["seconds"] as? Int
        let steps = parameters["steps"] as? Int
        let guidanceScale = (parameters["cfg_scale"] as? NSNumber)?.floatValue
        let seed = parameters["seed"] as? Int
        let isInstrumental = parameters["is_instrumental"] as? Bool

        logger.info("Generating audio: prompt=\(prompt.prefix(50))...")

        do {
            let result = try await service.generate(
                prompt: prompt,
                model: model,
                seconds: seconds,
                steps: steps,
                guidanceScale: guidanceScale,
                seed: seed,
                isInstrumental: isInstrumental
            )

            let pathList = result.localPaths.map { "- \($0)" }.joined(separator: "\n")

            return successResult("""
            **Audio generated successfully!**

            **Prompt:** \(prompt)
            **Model:** \(result.model)
            **Duration:** \(String(format: "%.1f", result.durationSeconds))s
            **Sample Rate:** \(result.sampleRate) Hz
            **Seed:** \(result.seed?.description ?? "auto")

            **Saved to:**
            \(pathList)

            Audio files are saved locally and can be shared with the user.
            """)
        } catch {
            logger.error("Audio generation failed: \(error.localizedDescription)")
            return errorResult("Audio generation failed: \(error.localizedDescription)")
        }
    }

    // MARK: - List Models

    @MainActor
    private func executeListModels(service: AudioGenerationService) async -> MCPToolResult {
        guard await service.isAvailable() else {
            return errorResult("Audio generation server is not available.")
        }

        do {
            let models = try await service.listModels()

            if models.isEmpty {
                return successResult("No audio generation models available.")
            }

            let modelList = models.map { model in
                "- **\(model.displayName)** (`\(model.id)`) [\(model.type)]"
            }.joined(separator: "\n")

            return successResult("""
            **Audio Generation Models (\(models.count) available):**

            \(modelList)
            """)
        } catch {
            return errorResult("Failed to fetch audio models: \(error.localizedDescription)")
        }
    }
}
