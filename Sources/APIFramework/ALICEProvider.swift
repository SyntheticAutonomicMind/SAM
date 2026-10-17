// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import Foundation
import Logging

// MARK: - Notification Names

extension Notification.Name {
    public static let aliceModelsLoaded = Notification.Name("com.sam.alice.modelsLoaded")
}

/// ALICE - Remote image generation API provider.
/// Connects to a remote ALICE server for GPU-accelerated Stable Diffusion image generation.
@MainActor
public class ALICEProvider: ObservableObject {
    private let logger = Logger(label: "com.sam.provider.alice")

    /// Shared instance, populated when connection is tested in Settings.
    nonisolated(unsafe) public static var shared: ALICEProvider?

    public let baseURL: String
    public let apiKey: String?

    @Published public var isHealthy: Bool = false
    @Published public var availableModels: [ALICEModel] = []
    @Published public var isChecking: Bool = false

    public init(baseURL: String, apiKey: String? = nil) {
        self.baseURL = baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        self.apiKey = apiKey
        logger.debug("ALICE Provider initialized with URL: \(self.baseURL)")
    }

    /// Initialize shared instance from user defaults at app startup.
    public static func initializeFromDefaults() {
        guard let baseURL = UserDefaults.standard.string(forKey: "alice_base_url"),
              !baseURL.isEmpty else {
            return
        }

        let apiKey = UserDefaults.standard.string(forKey: "alice_api_key")
        let provider = ALICEProvider(baseURL: baseURL, apiKey: apiKey?.isEmpty == true ? nil : apiKey)
        shared = provider

        Task {
            do {
                _ = try await provider.checkHealth()
                _ = try await provider.fetchAvailableModels()
                await MainActor.run {
                    NotificationCenter.default.post(name: .aliceModelsLoaded, object: nil)
                }
            } catch {
                Logger(label: "com.sam.provider.alice").warning("Failed to initialize ALICE from defaults: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Health Check

    public func checkHealth() async throws -> ALICEHealthResponse {
        let healthURL = baseURL.replacingOccurrences(of: "/v1", with: "") + "/health"

        guard let url = URL(string: healthURL) else {
            throw ALICEError.invalidConfiguration("Invalid ALICE health URL: \(healthURL)")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 10.0

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
            logger.info("ALICE server healthy: version=\(healthResponse.version), gpu=\(healthResponse.gpuAvailable), audioEnabled=\(healthResponse.audioEnabled ?? false)")

            self.isHealthy = true
            return healthResponse
        } catch let error as ALICEError {
            self.isHealthy = false
            throw error
        } catch {
            self.isHealthy = false
            throw ALICEError.networkError("Health check failed: \(error.localizedDescription)")
        }
    }

    /// Quick health check returning boolean.
    public func isServerHealthy() async -> Bool {
        do {
            _ = try await checkHealth()
            return true
        } catch {
            return false
        }
    }

    // MARK: - Model Discovery

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

        self.availableModels = modelsResponse.data
        return modelsResponse.data
    }

    // MARK: - Image Generation

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

        let modelId = model.hasPrefix("sd/") ? model : "sd/\(model)"

        let requestBody: [String: Any] = [
            "model": modelId,
            "messages": [
                ["role": "user", "content": prompt]
            ],
            "metadata": metadata
        ]

        request.httpBody = try deterministicJSONData(from: requestBody)
        request.timeoutInterval = 600.0

        logger.info("Generating image via ALICE: model=\(modelId), steps=\(steps), size=\(width)x\(height)")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw ALICEError.networkError("Invalid response type")
        }

        guard 200...299 ~= httpResponse.statusCode else {
            let errorText = String(data: data, encoding: .utf8) ?? "Unknown error"
            switch httpResponse.statusCode {
            case 401: throw ALICEError.authenticationFailed("Invalid or missing API key")
            case 400: throw ALICEError.invalidRequest("Bad request: \(errorText)")
            case 503: throw ALICEError.serverBusy("Server is busy, try again later")
            default: throw ALICEError.networkError("Generation failed (\(httpResponse.statusCode)): \(errorText)")
            }
        }

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

    public func downloadImage(from urlString: String, to localPath: URL) async throws {
        guard let imageURL = URL(string: urlString) else {
            throw ALICEError.invalidConfiguration("Invalid image URL: \(urlString)")
        }

        let (data, response) = try await URLSession.shared.data(from: imageURL)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw ALICEError.downloadFailed("Failed to download image from ALICE")
        }

        try FileManager.default.createDirectory(
            at: localPath.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        try data.write(to: localPath)
        logger.debug("Downloaded image to: \(localPath.path)")
    }

    // MARK: - Audio Model Discovery

    public func fetchAudioModels() async throws -> [ALICEAudioModel] {
        let audioModelsURL = "\(baseURL)/audio/models"

        guard let url = URL(string: audioModelsURL) else {
            throw ALICEError.invalidConfiguration("Invalid ALICE audio models URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        if let apiKey = apiKey, !apiKey.isEmpty {
            request.setValue(apiKey, forHTTPHeaderField: "X-Api-Key")
        }

        request.timeoutInterval = 30.0

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw ALICEError.networkError("Invalid response type")
        }

        guard httpResponse.statusCode == 200 else {
            let errorText = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw ALICEError.networkError("Failed to fetch audio models (\(httpResponse.statusCode)): \(errorText)")
        }

        let modelsResponse = try JSONDecoder().decode(ALICEAudioModelsResponse.self, from: data)
        logger.info("Fetched \(modelsResponse.models.count) audio models from ALICE")

        return modelsResponse.models
    }

    // MARK: - Audio Generation

    public func generateAudio(
        prompt: String,
        model: String? = nil,
        seconds: Int? = nil,
        steps: Int? = nil,
        guidanceScale: Float? = nil,
        seed: Int? = nil,
        isInstrumental: Bool? = nil
    ) async throws -> ALICEAudioResult {
        let audioGenerationsURL = "\(baseURL)/audio/generations"

        guard let url = URL(string: audioGenerationsURL) else {
            throw ALICEError.invalidConfiguration("Invalid ALICE audio generations URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        if let apiKey = apiKey, !apiKey.isEmpty {
            request.setValue(apiKey, forHTTPHeaderField: "X-Api-Key")
        }

        /// Build request body — only include fields that have values.
        var requestBody: [String: Any] = [
            "prompt": prompt
        ]

        if let model {
            requestBody["model"] = model
        }
        if let seconds {
            requestBody["seconds"] = seconds
        }
        if let steps {
            requestBody["steps"] = steps
        }
        if let guidanceScale {
            requestBody["cfg_scale"] = guidanceScale
        }
        if let seed {
            requestBody["seed"] = seed
        }
        if let isInstrumental {
            requestBody["is_instrumental"] = isInstrumental
        }

        request.httpBody = try deterministicJSONData(from: requestBody)
        request.timeoutInterval = 600.0

        logger.info("Generating audio via ALICE: model=\(model ?? "default"), prompt=\(prompt.prefix(50))")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw ALICEError.networkError("Invalid response type")
        }

        guard 200...299 ~= httpResponse.statusCode else {
            let errorText = String(data: data, encoding: .utf8) ?? "Unknown error"
            switch httpResponse.statusCode {
            case 401: throw ALICEError.authenticationFailed("Invalid or missing API key")
            case 400: throw ALICEError.invalidRequest("Bad request: \(errorText)")
            case 503: throw ALICEError.serverBusy("Server is busy, try again later")
            default: throw ALICEError.networkError("Audio generation failed (\(httpResponse.statusCode)): \(errorText)")
            }
        }

        let audioResponse = try JSONDecoder().decode(ALICEAudioGenerationResponse.self, from: data)

        logger.info("ALICE generated audio: duration=\(audioResponse.durationSeconds)s, model=\(audioResponse.model)")

        return ALICEAudioResult(
            url: audioResponse.url,
            model: audioResponse.model,
            durationSeconds: audioResponse.durationSeconds,
            sampleRate: audioResponse.sampleRate,
            seed: audioResponse.seed,
            steps: audioResponse.steps,
            guidanceScale: audioResponse.cfgScale,
            generationTimeSeconds: audioResponse.generationTimeSeconds,
            sizeBytes: audioResponse.sizeBytes,
            retries: audioResponse.retries,
            prompt: audioResponse.prompt
        )
    }

    // MARK: - Audio Download

    public func downloadAudio(from urlString: String, to localPath: URL) async throws {
        /// The ALICE audio response gives a relative path like /v1/audio/alice_12345678_seed42.wav.
        /// We need to construct the full URL.
        let fullURLString: String
        if urlString.hasPrefix("http") {
            fullURLString = urlString
        } else {
            /// Relative path — strip the /v1 prefix if present (ALICE serves at both /v1/audio/ and /audio/).
            let cleanPath = urlString.hasPrefix("/v1") ? String(urlString.dropFirst(3)) : urlString
            fullURLString = baseURL.replacingOccurrences(of: "/v1", with: "") + cleanPath
        }

        guard let audioURL = URL(string: fullURLString) else {
            throw ALICEError.invalidConfiguration("Invalid audio URL: \(fullURLString)")
        }

        var request = URLRequest(url: audioURL)
        if let apiKey = apiKey, !apiKey.isEmpty {
            request.setValue(apiKey, forHTTPHeaderField: "X-Api-Key")
        }
        request.timeoutInterval = 300.0

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw ALICEError.audioDownloadFailed("Failed to download audio from ALICE")
        }

        try FileManager.default.createDirectory(
            at: localPath.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        try data.write(to: localPath)
        logger.debug("Downloaded audio to: \(localPath.path)")
    }
}

// MARK: - Error Types

public enum ALICEError: LocalizedError {
    case invalidConfiguration(String)
    case networkError(String)
    case authenticationFailed(String)
    case invalidRequest(String)
    case generationFailed(String)
    case downloadFailed(String)
    case serverBusy(String)
    case audioGenerationFailed(String)
    case audioDownloadFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidConfiguration(let msg): return "ALICE config error: \(msg)"
        case .networkError(let msg): return "ALICE network error: \(msg)"
        case .authenticationFailed(let msg): return "ALICE auth failed: \(msg)"
        case .invalidRequest(let msg): return "ALICE invalid request: \(msg)"
        case .generationFailed(let msg): return "ALICE generation failed: \(msg)"
        case .downloadFailed(let msg): return "ALICE download failed: \(msg)"
        case .serverBusy(let msg): return "ALICE server busy: \(msg)"
        case .audioGenerationFailed(let msg): return "ALICE audio generation failed: \(msg)"
        case .audioDownloadFailed(let msg): return "ALICE audio download failed: \(msg)"
        }
    }
}

// MARK: - Response Models

public struct ALICEHealthResponse: Codable {
    public let status: String
    public let version: String
    public let gpuAvailable: Bool
    public let modelsLoaded: Int
    public let audioEnabled: Bool?
    public let audioModelId: String?
    public let audioModelLoaded: Bool?

    enum CodingKeys: String, CodingKey {
        case status, version, gpuAvailable, modelsLoaded
        case audioEnabled = "audioEnabled"
        case audioModelId = "audioModelId"
        case audioModelLoaded = "audioModelLoaded"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        status = try container.decode(String.self, forKey: .status)
        version = try container.decode(String.self, forKey: .version)

        if let gpu = try? container.decode(Bool.self, forKey: .gpuAvailable) {
            gpuAvailable = gpu
        } else {
            let alt = try decoder.container(keyedBy: AltKeys.self)
            gpuAvailable = try alt.decode(Bool.self, forKey: .gpuAvailable)
        }

        if let models = try? container.decode(Int.self, forKey: .modelsLoaded) {
            modelsLoaded = models
        } else {
            let alt = try decoder.container(keyedBy: AltKeys.self)
            modelsLoaded = try alt.decode(Int.self, forKey: .modelsLoaded)
        }

        audioEnabled = try? container.decode(Bool.self, forKey: .audioEnabled)
        audioModelId = try? container.decode(String.self, forKey: .audioModelId)
        audioModelLoaded = try? container.decode(Bool.self, forKey: .audioModelLoaded)
    }

    private enum AltKeys: String, CodingKey {
        case gpuAvailable = "gpu_available"
        case modelsLoaded = "models_loaded"
    }

    public init(status: String, version: String, gpuAvailable: Bool, modelsLoaded: Int, audioEnabled: Bool? = nil, audioModelId: String? = nil, audioModelLoaded: Bool? = nil) {
        self.status = status
        self.version = version
        self.gpuAvailable = gpuAvailable
        self.modelsLoaded = modelsLoaded
        self.audioEnabled = audioEnabled
        self.audioModelId = audioModelId
        self.audioModelLoaded = audioModelLoaded
    }
}

public struct ALICEModelsResponse: Codable, Sendable {
    public let object: String
    public let data: [ALICEModel]
}

public struct ALICEModel: Codable, Identifiable, Sendable {
    public let id: String
    public let object: String
    public let created: Int
    public let ownedBy: String

    enum CodingKeys: String, CodingKey {
        case id, object, created, ownedBy
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        object = try container.decode(String.self, forKey: .object)
        created = try container.decode(Int.self, forKey: .created)

        if let owned = try? container.decode(String.self, forKey: .ownedBy) {
            ownedBy = owned
        } else {
            let alt = try decoder.container(keyedBy: AltKeys.self)
            ownedBy = try alt.decode(String.self, forKey: .ownedBy)
        }
    }

    private enum AltKeys: String, CodingKey {
        case ownedBy = "owned_by"
    }

    public var displayName: String {
        if id.hasPrefix("sd/") {
            return String(id.dropFirst(3))
                .replacingOccurrences(of: "-", with: " ")
                .capitalized
        }
        return id
    }

    public var isSDXL: Bool {
        let lower = id.lowercased()
        return lower.contains("xl") || lower.contains("sdxl")
    }

    public var defaultDimensions: (width: Int, height: Int) {
        isSDXL ? (1024, 1024) : (512, 512)
    }
}

public struct ALICEGenerationResult: @unchecked Sendable {
    public let imageUrls: [String]
    public let metadata: [String: Any]
    public let model: String
}

public struct ALICEChatResponse: Codable {
    public let id: String
    public let object: String
    public let created: Int
    public let model: String
    public let choices: [ALICEChoice]
    public let usage: ALICEUsage?
}

public struct ALICEChoice: Codable {
    public let index: Int
    public let message: ALICEMessage
    public let finishReason: String?
}

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
    }
}

public struct ALICEUsage: Codable {
    public let promptTokens: Int
    public let completionTokens: Int
    public let totalTokens: Int
}

/// Helper for decoding Any values from JSON.
private struct ALICEAnyCodable: Codable {
    let value: Any

    init(_ value: Any) { self.value = value }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let bool = try? container.decode(Bool.self) { value = bool }
        else if let int = try? container.decode(Int.self) { value = int }
        else if let double = try? container.decode(Double.self) { value = double }
        else if let string = try? container.decode(String.self) { value = string }
        else if let array = try? container.decode([ALICEAnyCodable].self) { value = array.map { $0.value } }
        else if let dict = try? container.decode([String: ALICEAnyCodable].self) { value = dict.mapValues { $0.value } }
        else { value = NSNull() }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch value {
        case let bool as Bool: try container.encode(bool)
        case let int as Int: try container.encode(int)
        case let double as Double: try container.encode(double)
        case let string as String: try container.encode(string)
        case let array as [Any]: try container.encode(array.map { ALICEAnyCodable($0) })
        case let dict as [String: Any]: try container.encode(dict.mapValues { ALICEAnyCodable($0) })
        default: try container.encodeNil()
        }
    }
}

// MARK: - Audio Response Models

public struct ALICEAudioModelsResponse: Codable, Sendable {
    public let models: [ALICEAudioModel]
    public let backend: String?
    public let available: Bool?
}

public struct ALICEAudioModel: Codable, Identifiable, Sendable {
    public let id: String
    public let name: String?
    public let repo: String?
    public let description: String?
    public let engine: String?
    public let maxSeconds: Int?
    public let defaultSeconds: Int?
    public let sampleRate: Int?
    public let supportsLyrics: Bool?
    public let license: String?

    enum CodingKeys: String, CodingKey {
        case id, name, repo, description, engine, license
        case maxSeconds = "max_seconds"
        case defaultSeconds = "default_seconds"
        case sampleRate = "sample_rate"
        case supportsLyrics = "supports_lyrics"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        repo = try container.decodeIfPresent(String.self, forKey: .repo)
        description = try container.decodeIfPresent(String.self, forKey: .description)
        engine = try container.decodeIfPresent(String.self, forKey: .engine)
        maxSeconds = try container.decodeIfPresent(Int.self, forKey: .maxSeconds)
        defaultSeconds = try container.decodeIfPresent(Int.self, forKey: .defaultSeconds)
        sampleRate = try container.decodeIfPresent(Int.self, forKey: .sampleRate)
        supportsLyrics = try container.decodeIfPresent(Bool.self, forKey: .supportsLyrics)
        license = try container.decodeIfPresent(String.self, forKey: .license)
    }

    public var displayName: String {
        name ?? id
    }

    public var type: String {
        engine ?? "unknown"
    }

    public init(id: String, name: String? = nil, repo: String? = nil, description: String? = nil, engine: String? = nil, maxSeconds: Int? = nil, defaultSeconds: Int? = nil, sampleRate: Int? = nil, supportsLyrics: Bool? = nil, license: String? = nil) {
        self.id = id
        self.name = name
        self.repo = repo
        self.description = description
        self.engine = engine
        self.maxSeconds = maxSeconds
        self.defaultSeconds = defaultSeconds
        self.sampleRate = sampleRate
        self.supportsLyrics = supportsLyrics
        self.license = license
    }
}

public struct ALICEAudioGenerationResponse: Codable, Sendable {
    public let url: String
    public let model: String
    public let durationSeconds: Double
    public let sampleRate: Int
    public let seed: Int?
    public let steps: Int?
    public let cfgScale: Float?
    public let generationTimeSeconds: Double
    public let sizeBytes: Int
    public let retries: Int?
    public let prompt: String?

    enum CodingKeys: String, CodingKey {
        case url, model, seed, steps, prompt, retries
        case durationSeconds = "duration_seconds"
        case sampleRate = "sample_rate"
        case cfgScale = "cfg_scale"
        case generationTimeSeconds = "generation_time_seconds"
        case sizeBytes = "size_bytes"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        url = try container.decode(String.self, forKey: .url)
        model = try container.decode(String.self, forKey: .model)
        durationSeconds = try container.decode(Double.self, forKey: .durationSeconds)
        sampleRate = try container.decode(Int.self, forKey: .sampleRate)
        seed = try container.decodeIfPresent(Int.self, forKey: .seed)
        steps = try container.decodeIfPresent(Int.self, forKey: .steps)
        cfgScale = try container.decodeIfPresent(Float.self, forKey: .cfgScale)
        generationTimeSeconds = try container.decode(Double.self, forKey: .generationTimeSeconds)
        sizeBytes = try container.decode(Int.self, forKey: .sizeBytes)
        retries = try container.decodeIfPresent(Int.self, forKey: .retries)
        prompt = try container.decodeIfPresent(String.self, forKey: .prompt)
    }
}

public struct ALICEAudioResult: @unchecked Sendable {
    public let url: String
    public let model: String
    public let durationSeconds: Double
    public let sampleRate: Int
    public let seed: Int?
    public let steps: Int?
    public let guidanceScale: Float?
    public let generationTimeSeconds: Double
    public let sizeBytes: Int
    public let retries: Int?
    public let prompt: String?

    public init(url: String, model: String, durationSeconds: Double, sampleRate: Int, seed: Int?, steps: Int?, guidanceScale: Float?, generationTimeSeconds: Double, sizeBytes: Int, retries: Int?, prompt: String?) {
        self.url = url
        self.model = model
        self.durationSeconds = durationSeconds
        self.sampleRate = sampleRate
        self.seed = seed
        self.steps = steps
        self.guidanceScale = guidanceScale
        self.generationTimeSeconds = generationTimeSeconds
        self.sizeBytes = sizeBytes
        self.retries = retries
        self.prompt = prompt
    }
}
