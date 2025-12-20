// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import Foundation
import Logging

/// ALICE - Remote Stable Diffusion API provider
/// Enables image generation on remote AMD GPU servers (Steam Deck, Linux servers)
@MainActor
public class ALICEProvider: ObservableObject {
    private let logger = Logger(label: "com.sam.provider.alice")

    /// Shared instance for global access to ALICE state
    /// This is populated when connection is tested in Settings
    nonisolated(unsafe) public static var shared: ALICEProvider?

    public let baseURL: String
    public let apiKey: String?

    /// Published state for UI binding
    @Published public var isHealthy: Bool = false
    @Published public var availableModels: [ALICEModel] = []
    @Published public var isChecking: Bool = false

    public init(baseURL: String, apiKey: String? = nil) {
        self.baseURL = baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        self.apiKey = apiKey
        logger.debug("ALICE Provider initialized with URL: \(self.baseURL)")
    }

    /// Initialize shared instance from user defaults
    /// Called at app startup to restore ALICE connection
    public static func initializeFromDefaults() {
        guard let baseURL = UserDefaults.standard.string(forKey: "alice_base_url"),
              !baseURL.isEmpty else {
            return
        }

        let apiKey = UserDefaults.standard.string(forKey: "alice_api_key")
        let provider = ALICEProvider(baseURL: baseURL, apiKey: apiKey?.isEmpty == true ? nil : apiKey)
        shared = provider

        /// Check health and load models in background
        Task {
            do {
                _ = try await provider.checkHealth()
                _ = try await provider.fetchAvailableModels()

                /// Post notification that ALICE models are available
                /// This allows ChatWidget to refresh the model list
                await MainActor.run {
                    NotificationCenter.default.post(name: .aliceModelsLoaded, object: nil)
                }
            } catch {
                Logger(label: "com.sam.provider.alice").warning("Failed to initialize ALICE from defaults: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Health Check

    /// Check if ALICE server is reachable and healthy
    public func checkHealth() async throws -> ALICEHealthResponse {
        /// Health endpoint is at /health (not /v1/health)
        let healthURL = baseURL.replacingOccurrences(of: "/v1", with: "") + "/health"

        guard let url = URL(string: healthURL) else {
            throw ALICEError.invalidConfiguration("Invalid ALICE health URL: \(healthURL)")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 10.0

        logger.debug("Checking ALICE health at: \(healthURL)")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                throw ALICEError.networkError("Invalid response type")
            }

            guard httpResponse.statusCode == 200 else {
                let errorText = String(data: data, encoding: .utf8) ?? "Unknown error"
                throw ALICEError.networkError("Health check failed (\(httpResponse.statusCode)): \(errorText)")
            }

            let healthResponse = try JSONDecoder().decode(ALICEHealthResponse.self, from: data)
            logger.info("ALICE server healthy: version=\(healthResponse.version), gpu=\(healthResponse.gpuAvailable)")

            await MainActor.run {
                self.isHealthy = true
            }

            return healthResponse
        } catch let error as ALICEError {
            await MainActor.run {
                self.isHealthy = false
            }
            throw error
        } catch {
            await MainActor.run {
                self.isHealthy = false
            }
            throw ALICEError.networkError("Health check failed: \(error.localizedDescription)")
        }
    }

    /// Quick health check returning boolean
    public func isServerHealthy() async -> Bool {
        do {
            _ = try await checkHealth()
            return true
        } catch {
            return false
        }
    }

    // MARK: - Model Discovery

    /// Fetch available models from ALICE server
    public func fetchAvailableModels() async throws -> [ALICEModel] {
        let modelsURL = "\(baseURL)/models"

        guard let url = URL(string: modelsURL) else {
            throw ALICEError.invalidConfiguration("Invalid ALICE models URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        if let apiKey = apiKey, !apiKey.isEmpty {
            request.setValue(apiKey, forHTTPHeaderField: "X-Api-Key")
        }

        request.timeoutInterval = 30.0

        logger.debug("Fetching ALICE models from: \(modelsURL)")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw ALICEError.networkError("Invalid response type")
        }

        guard httpResponse.statusCode == 200 else {
            let errorText = String(data: data, encoding: .utf8) ?? "Unknown error"
            if httpResponse.statusCode == 401 {
                throw ALICEError.authenticationFailed("Invalid or missing API key")
            }
            throw ALICEError.networkError("Failed to fetch models (\(httpResponse.statusCode)): \(errorText)")
        }

        let modelsResponse = try JSONDecoder().decode(ALICEModelsResponse.self, from: data)
        logger.info("Fetched \(modelsResponse.data.count) models from ALICE")

        await MainActor.run {
            self.availableModels = modelsResponse.data
        }

        return modelsResponse.data
    }

    // MARK: - Image Generation

    /// Generate images via ALICE API
    public func generateImages(
        prompt: String,
        negativePrompt: String? = nil,
        model: String,
        steps: Int = 25,
        guidanceScale: Float = 7.5,
        scheduler: String = "ddim",
        seed: Int? = nil,
        width: Int = 512,
        height: Int = 512
    ) async throws -> ALICEGenerationResult {
        let completionsURL = "\(baseURL)/chat/completions"

        guard let url = URL(string: completionsURL) else {
            throw ALICEError.invalidConfiguration("Invalid ALICE completions URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        if let apiKey = apiKey, !apiKey.isEmpty {
            request.setValue(apiKey, forHTTPHeaderField: "X-Api-Key")
        }

        /// Build metadata
        var metadata: [String: Any] = [
            "steps": steps,
            "guidance_scale": guidanceScale,
            "scheduler": scheduler,
            "width": width,
            "height": height
        ]

        if let negativePrompt = negativePrompt, !negativePrompt.isEmpty {
            metadata["negative_prompt"] = negativePrompt
        }

        if let seed = seed, seed >= 0 {
            metadata["seed"] = seed
        }

        /// Ensure model has sd/ prefix
        let modelId = model.hasPrefix("sd/") ? model : "sd/\(model)"

        let requestBody: [String: Any] = [
            "model": modelId,
            "messages": [
                ["role": "user", "content": prompt]
            ],
            "metadata": metadata
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)

        /// Long timeout for image generation (10 minutes)
        request.timeoutInterval = 600.0

        logger.info("Generating image via ALICE", metadata: [
            "model": .string(modelId),
            "steps": .stringConvertible(steps),
            "scheduler": .string(scheduler),
            "size": .string("\(width)x\(height)")
        ])

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw ALICEError.networkError("Invalid response type")
        }

        guard 200...299 ~= httpResponse.statusCode else {
            let errorText = String(data: data, encoding: .utf8) ?? "Unknown error"
            logger.error("ALICE generation error: \(errorText)")

            switch httpResponse.statusCode {
            case 401:
                throw ALICEError.authenticationFailed("Invalid or missing API key")
            case 400:
                throw ALICEError.invalidRequest("Bad request: \(errorText)")
            case 503:
                throw ALICEError.serverBusy("Server is busy, try again later")
            default:
                throw ALICEError.networkError("Generation failed (\(httpResponse.statusCode)): \(errorText)")
            }
        }

        /// Parse response
        let chatResponse = try JSONDecoder().decode(ALICEChatResponse.self, from: data)

        guard let choice = chatResponse.choices.first,
              let imageUrls = choice.message.imageUrls,
              !imageUrls.isEmpty else {
            throw ALICEError.generationFailed("No images returned from ALICE")
        }

        logger.info("ALICE generated \(imageUrls.count) image(s)")

        return ALICEGenerationResult(
            imageUrls: imageUrls,
            metadata: choice.message.metadata ?? [:],
            model: chatResponse.model
        )
    }

    // MARK: - Image Download

    /// Download generated image to local path
    public func downloadImage(from urlString: String, to localPath: URL) async throws {
        guard let imageURL = URL(string: urlString) else {
            throw ALICEError.invalidConfiguration("Invalid image URL: \(urlString)")
        }

        logger.debug("Downloading image from ALICE: \(urlString)")

        let (data, response) = try await URLSession.shared.data(from: imageURL)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw ALICEError.downloadFailed("Failed to download image from ALICE")
        }

        /// Create parent directory if needed
        try FileManager.default.createDirectory(
            at: localPath.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        try data.write(to: localPath)
        logger.debug("Downloaded image to: \(localPath.path)")
    }
}

// MARK: - ALICE Error Types

public enum ALICEError: LocalizedError {
    case invalidConfiguration(String)
    case networkError(String)
    case authenticationFailed(String)
    case invalidRequest(String)
    case generationFailed(String)
    case downloadFailed(String)
    case serverBusy(String)

    public var errorDescription: String? {
        switch self {
        case .invalidConfiguration(let message):
            return "ALICE configuration error: \(message)"
        case .networkError(let message):
            return "ALICE network error: \(message)"
        case .authenticationFailed(let message):
            return "ALICE authentication failed: \(message)"
        case .invalidRequest(let message):
            return "ALICE invalid request: \(message)"
        case .generationFailed(let message):
            return "ALICE generation failed: \(message)"
        case .downloadFailed(let message):
            return "ALICE download failed: \(message)"
        case .serverBusy(let message):
            return "ALICE server busy: \(message)"
        }
    }
}

// MARK: - ALICE Response Models

/// Health check response
public struct ALICEHealthResponse: Codable {
    public let status: String
    public let version: String
    public let gpuAvailable: Bool
    public let modelsLoaded: Int

    /// Support both camelCase (server default) and snake_case (alternative) responses
    enum CodingKeys: String, CodingKey {
        case status, version, gpuAvailable, modelsLoaded
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        status = try container.decode(String.self, forKey: .status)
        version = try container.decode(String.self, forKey: .version)

        /// Try camelCase first, fallback to snake_case
        if let gpu = try? container.decode(Bool.self, forKey: .gpuAvailable) {
            gpuAvailable = gpu
        } else {
            /// Try with alternate container for snake_case
            let altContainer = try decoder.container(keyedBy: AlternateCodingKeys.self)
            gpuAvailable = try altContainer.decode(Bool.self, forKey: .gpuAvailable)
        }

        if let models = try? container.decode(Int.self, forKey: .modelsLoaded) {
            modelsLoaded = models
        } else {
            let altContainer = try decoder.container(keyedBy: AlternateCodingKeys.self)
            modelsLoaded = try altContainer.decode(Int.self, forKey: .modelsLoaded)
        }
    }

    /// Alternate keys for snake_case responses
    private enum AlternateCodingKeys: String, CodingKey {
        case gpuAvailable = "gpu_available"
        case modelsLoaded = "models_loaded"
    }

    public init(status: String, version: String, gpuAvailable: Bool, modelsLoaded: Int) {
        self.status = status
        self.version = version
        self.gpuAvailable = gpuAvailable
        self.modelsLoaded = modelsLoaded
    }
}

/// Models list response
public struct ALICEModelsResponse: Codable, Sendable {
    public let object: String
    public let data: [ALICEModel]
}

/// Individual model info
public struct ALICEModel: Codable, Identifiable, Sendable {
    public let id: String
    public let object: String
    public let created: Int
    public let ownedBy: String

    /// Support both camelCase (server default) and snake_case responses
    enum CodingKeys: String, CodingKey {
        case id, object, created, ownedBy
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        object = try container.decode(String.self, forKey: .object)
        created = try container.decode(Int.self, forKey: .created)

        /// Try camelCase first, fallback to snake_case
        if let owned = try? container.decode(String.self, forKey: .ownedBy) {
            ownedBy = owned
        } else {
            let altContainer = try decoder.container(keyedBy: AlternateCodingKeys.self)
            ownedBy = try altContainer.decode(String.self, forKey: .ownedBy)
        }
    }

    /// Alternate keys for snake_case responses
    private enum AlternateCodingKeys: String, CodingKey {
        case ownedBy = "owned_by"
    }

    /// Display name (strips sd/ prefix)
    public var displayName: String {
        if id.hasPrefix("sd/") {
            return String(id.dropFirst(3))
                .replacingOccurrences(of: "-", with: " ")
                .capitalized
        }
        return id
    }

    /// Detect if this is an SDXL model
    public var isSDXL: Bool {
        let lower = id.lowercased()
        return lower.contains("xl") || lower.contains("sdxl")
    }

    /// Default dimensions for this model
    public var defaultDimensions: (width: Int, height: Int) {
        isSDXL ? (1024, 1024) : (512, 512)
    }
}

/// Generation result
public struct ALICEGenerationResult: @unchecked Sendable {
    public let imageUrls: [String]
    public let metadata: [String: Any]
    public let model: String

    public init(imageUrls: [String], metadata: [String: Any], model: String) {
        self.imageUrls = imageUrls
        self.metadata = metadata
        self.model = model
    }
}

/// Chat completion response
public struct ALICEChatResponse: Codable {
    public let id: String
    public let object: String
    public let created: Int
    public let model: String
    public let choices: [ALICEChoice]
    public let usage: ALICEUsage?
}

/// Chat choice
public struct ALICEChoice: Codable {
    public let index: Int
    public let message: ALICEMessage
    public let finishReason: String?

    /// No CodingKeys needed - server returns camelCase which matches property names
}

/// Chat message with image URLs
public struct ALICEMessage: Codable {
    public let role: String
    public let content: String?
    public let imageUrls: [String]?
    public let metadata: [String: Any]?

    enum CodingKeys: String, CodingKey {
        case role, content
        case imageUrls = "image_urls"
        case metadata
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        role = try container.decode(String.self, forKey: .role)
        content = try container.decodeIfPresent(String.self, forKey: .content)
        imageUrls = try container.decodeIfPresent([String].self, forKey: .imageUrls)

        /// Decode metadata as dictionary using AnyCodable helper
        if let metadataContainer = try? container.decode([String: ALICEAnyCodable].self, forKey: .metadata) {
            metadata = metadataContainer.mapValues { $0.value }
        } else {
            metadata = nil
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(role, forKey: .role)
        try container.encodeIfPresent(content, forKey: .content)
        try container.encodeIfPresent(imageUrls, forKey: .imageUrls)
        /// Skip encoding metadata (not needed for requests)
    }
}

/// Usage statistics
public struct ALICEUsage: Codable {
    public let promptTokens: Int
    public let completionTokens: Int
    public let totalTokens: Int

    /// No CodingKeys needed - server returns camelCase which matches property names
}

/// Helper for decoding Any values from JSON
private struct ALICEAnyCodable: Codable {
    let value: Any

    init(_ value: Any) {
        self.value = value
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        if let bool = try? container.decode(Bool.self) {
            value = bool
        } else if let int = try? container.decode(Int.self) {
            value = int
        } else if let double = try? container.decode(Double.self) {
            value = double
        } else if let string = try? container.decode(String.self) {
            value = string
        } else if let array = try? container.decode([ALICEAnyCodable].self) {
            value = array.map { $0.value }
        } else if let dict = try? container.decode([String: ALICEAnyCodable].self) {
            value = dict.mapValues { $0.value }
        } else {
            value = NSNull()
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()

        switch value {
        case let bool as Bool:
            try container.encode(bool)
        case let int as Int:
            try container.encode(int)
        case let double as Double:
            try container.encode(double)
        case let string as String:
            try container.encode(string)
        case let array as [Any]:
            try container.encode(array.map { ALICEAnyCodable($0) })
        case let dict as [String: Any]:
            try container.encode(dict.mapValues { ALICEAnyCodable($0) })
        default:
            try container.encodeNil()
        }
    }
}
