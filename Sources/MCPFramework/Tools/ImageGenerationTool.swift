// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import Foundation
import Logging
import ConfigurationSystem

/// Protocol for image generation service, injected from APIFramework to avoid circular dependency.
public protocol ImageGenerationService: Sendable {
    /// Check if the image generation server is available.
    @MainActor func isAvailable() async -> Bool

    /// Get available model IDs with display names and types.
    @MainActor func listModels() async throws -> [(id: String, displayName: String, type: String, defaultWidth: Int, defaultHeight: Int)]

    /// Generate an image and return local file paths.
    @MainActor func generate(
        prompt: String,
        negativePrompt: String?,
        model: String?,
        steps: Int,
        guidanceScale: Float,
        scheduler: String,
        seed: Int?,
        width: Int?,
        height: Int?
    ) async throws -> ImageGenerationResult
}

/// Result from image generation.
public struct ImageGenerationResult: Sendable {
    public let localPaths: [String]
    public let model: String
    public let width: Int
    public let height: Int
    public let steps: Int

    public init(localPaths: [String], model: String, width: Int, height: Int, steps: Int) {
        self.localPaths = localPaths
        self.model = model
        self.width = width
        self.height = height
        self.steps = steps
    }
}

/// MCP tool for AI image generation via remote server (ALICE).
/// Uses injected ImageGenerationService to avoid circular module dependency.
public class ImageGenerationTool: ConsolidatedMCP, @unchecked Sendable {
    public let name = "image_generation"
    public let supportedOperations = ["generate", "list_models"]

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
                description: "Text description of the image to generate (required for generate)",
                required: false
            ),
            "model": MCPToolParameter(
                type: .string,
                description: "Model ID to use (optional, uses first available)",
                required: false
            ),
            "negative_prompt": MCPToolParameter(
                type: .string,
                description: "What to avoid in the generated image",
                required: false
            ),
            "steps": MCPToolParameter(
                type: .integer,
                description: "Number of inference steps (default: 25)",
                required: false
            ),
            "guidance_scale": MCPToolParameter(
                type: .string,
                description: "Classifier-free guidance scale as number (default: 7.5)",
                required: false
            ),
            "scheduler": MCPToolParameter(
                type: .string,
                description: "Sampling scheduler (default: ddim)",
                required: false
            ),
            "seed": MCPToolParameter(
                type: .integer,
                description: "Random seed for reproducibility",
                required: false
            ),
            "width": MCPToolParameter(
                type: .integer,
                description: "Image width in pixels",
                required: false
            ),
            "height": MCPToolParameter(
                type: .integer,
                description: "Image height in pixels",
                required: false
            )
        ]
    }

    private let logger = Logger(label: "com.sam.mcp.ImageGeneration")
    private var service: ImageGenerationService?

    public var description: String {
        return """
        Generate images using a remote Stable Diffusion server.

        OPERATIONS:
        • generate - Generate an image from a text prompt
        • list_models - List available image generation models

        EXAMPLES:
        {"operation": "generate", "prompt": "A serene mountain landscape at sunset"}
        {"operation": "generate", "prompt": "A cat in a tiny hat", "steps": 30, "width": 1024, "height": 1024}
        {"operation": "list_models"}
        """
    }

    /// Inject the image generation service at runtime.
    public func setService(_ service: ImageGenerationService) {
        self.service = service
    }

    public func initialize() async throws {
        logger.debug("ImageGenerationTool initializing")
        guard let service = service else {
            logger.info("ImageGenerationTool: No image generation service configured - tool will not be available")
            throw NSError(domain: "ImageGenerationTool", code: 2, userInfo: [NSLocalizedDescriptionKey: "Image generation service not configured"])
        }
        let available = await service.isAvailable()
        if !available {
            logger.info("ImageGenerationTool: ALICE server not reachable - tool will not be available")
            throw NSError(domain: "ImageGenerationTool", code: 3, userInfo: [NSLocalizedDescriptionKey: "Image generation server not available"])
        }
        logger.info("ImageGenerationTool initialized - ALICE server is available")
    }

    public func validateParameters(_ parameters: [String: Any]) throws -> Bool {
        guard parameters["operation"] is String else {
            throw NSError(domain: "ImageGenerationTool", code: 1, userInfo: [NSLocalizedDescriptionKey: "Missing 'operation' parameter"])
        }
        return true
    }

    @MainActor
    public func routeOperation(
        _ operation: String,
        parameters: [String: Any],
        context: MCPExecutionContext
    ) async -> MCPToolResult {
        guard let service = service else {
            return errorResult("Image generation is not configured. Set up ALICE server in Preferences -> Image Generation.")
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
    private func executeGenerate(service: ImageGenerationService, parameters: [String: Any]) async -> MCPToolResult {
        guard await service.isAvailable() else {
            return errorResult("Image generation server is not available. Check Preferences -> Image Generation.")
        }

        guard let prompt = parameters["prompt"] as? String, !prompt.isEmpty else {
            return errorResult("'prompt' parameter is required.")
        }

        let model = parameters["model"] as? String
        let steps = parameters["steps"] as? Int ?? 25
        let guidanceScale = (parameters["guidance_scale"] as? NSNumber)?.floatValue ?? 7.5
        let scheduler = parameters["scheduler"] as? String ?? "ddim"
        let seed = parameters["seed"] as? Int
        let negativePrompt = parameters["negative_prompt"] as? String
        let width = parameters["width"] as? Int
        let height = parameters["height"] as? Int

        logger.info("Generating image: prompt=\(prompt.prefix(50))...")

        do {
            let result = try await service.generate(
                prompt: prompt,
                negativePrompt: negativePrompt,
                model: model,
                steps: steps,
                guidanceScale: guidanceScale,
                scheduler: scheduler,
                seed: seed,
                width: width,
                height: height
            )

            let pathList = result.localPaths.map { "- \($0)" }.joined(separator: "\n")

            return successResult("""
            **Image generated successfully!**

            **Prompt:** \(prompt)
            **Model:** \(result.model)
            **Size:** \(result.width)x\(result.height)
            **Steps:** \(result.steps)

            **Saved to:**
            \(pathList)

            Images are saved locally and can be shared with the user.
            """)
        } catch {
            logger.error("Image generation failed: \(error.localizedDescription)")
            return errorResult("Image generation failed: \(error.localizedDescription)")
        }
    }

    // MARK: - List Models

    @MainActor
    private func executeListModels(service: ImageGenerationService) async -> MCPToolResult {
        guard await service.isAvailable() else {
            return errorResult("Image generation server is not available.")
        }

        do {
            let models = try await service.listModels()

            if models.isEmpty {
                return successResult("No image generation models available.")
            }

            let modelList = models.map { model in
                "- **\(model.displayName)** (`\(model.id)`) [\(model.type)] default: \(model.defaultWidth)x\(model.defaultHeight)"
            }.joined(separator: "\n")

            return successResult("""
            **Image Generation Models (\(models.count) available):**

            \(modelList)
            """)
        } catch {
            return errorResult("Failed to fetch models: \(error.localizedDescription)")
        }
    }
}
