// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import Foundation
import SwiftUI

// MARK: - Provider Configuration Models

/// Configuration for AI provider instances.
public struct ProviderConfiguration: Codable, Identifiable {
    public var id: String { providerId }
    public let providerId: String
    public let providerType: ProviderType
    public var isEnabled: Bool
    public var apiKey: String?
    public var baseURL: String?
    public var models: [String]
    public var maxTokens: Int?
    public var temperature: Double?
    public var customHeaders: [String: String]?
    public var timeoutSeconds: Int?
    public var retryCount: Int?

    /// MLX-specific configuration.
    public var mlxConfig: MLXConfiguration?

    private enum CodingKeys: String, CodingKey {
        case providerId
        case providerType
        case isEnabled
        case apiKey
        case baseURL
        case models
        case maxTokens
        case temperature
        case customHeaders
        case timeoutSeconds
        case retryCount
        case mlxConfig
    }

    public init(
        providerId: String,
        providerType: ProviderType,
        isEnabled: Bool = true,
        apiKey: String? = nil,
        baseURL: String? = nil,
        models: [String] = [],
        maxTokens: Int? = nil,
        temperature: Double? = nil,
        customHeaders: [String: String]? = nil,
        timeoutSeconds: Int? = 300,
        retryCount: Int? = 2,
        mlxConfig: MLXConfiguration? = nil
    ) {
        self.providerId = providerId
        self.providerType = providerType
        self.isEnabled = isEnabled
        self.apiKey = apiKey
        self.baseURL = baseURL
        self.models = models
        self.maxTokens = maxTokens
        self.temperature = temperature
        self.customHeaders = customHeaders
        self.timeoutSeconds = timeoutSeconds ?? 300
        self.retryCount = retryCount ?? 2
        self.mlxConfig = mlxConfig
    }
}

/// MLX-specific configuration for local model optimization.
public struct MLXConfiguration: Codable, Equatable {
    /// Number of bits for KV cache quantization (nil = no quantization, 4 or 8 recommended for memory savings).
    public var kvBits: Int?

    /// Group size for KV cache quantization (default: 64).
    public var kvGroupSize: Int

    /// Step to begin using quantized KV cache (default: 0).
    public var quantizedKVStart: Int

    /// Maximum size of KV cache before rotation (nil = unlimited).
    public var maxKVSize: Int?

    /// Top-P sampling threshold (default: 0.95, matching LMStudio).
    public var topP: Double

    /// Temperature for sampling (default: 0.8, matching LMStudio).
    public var temperature: Double

    /// Repetition penalty factor (nil = disabled, 1.1 recommended).
    public var repetitionPenalty: Double?

    /// Number of tokens to consider for repetition penalty (default: 20).
    public var repetitionContextSize: Int

    /// Context window length.
    public var contextLength: Int

    /// Maximum tokens to generate per response.
    public var maxTokens: Int

    public init(
        kvBits: Int? = nil,
        kvGroupSize: Int = 64,
        quantizedKVStart: Int = 0,
        maxKVSize: Int? = nil,
        topP: Double = 0.95,
        temperature: Double = 0.8,
        repetitionPenalty: Double? = 1.1,
        repetitionContextSize: Int = 20,
        contextLength: Int = 8192,
        maxTokens: Int = 2048
    ) {
        self.kvBits = kvBits
        self.kvGroupSize = kvGroupSize
        self.quantizedKVStart = quantizedKVStart
        self.maxKVSize = maxKVSize
        self.topP = topP
        self.temperature = temperature
        self.repetitionPenalty = repetitionPenalty
        self.repetitionContextSize = repetitionContextSize
        self.contextLength = contextLength
        self.maxTokens = maxTokens
    }

    /// Optimized configuration for memory-constrained systems (8GB RAM) Uses 4-bit KV cache quantization to reduce memory usage by ~75%.
    public static var memoryOptimized: MLXConfiguration {
        MLXConfiguration(
            kvBits: 4,
            kvGroupSize: 64,
            quantizedKVStart: 0,
            maxKVSize: 4096,
            topP: 0.95,
            temperature: 0.8,
            repetitionPenalty: 1.1,
            repetitionContextSize: 20,
            contextLength: 4096,
            maxTokens: 512
        )
    }

    /// Balanced configuration for systems with adequate RAM (16GB-24GB) Uses 4-bit KV cache quantization for better quality with moderate memory savings.
    public static var balanced: MLXConfiguration {
        MLXConfiguration(
            kvBits: 4,
            kvGroupSize: 64,
            quantizedKVStart: 0,
            maxKVSize: 8192,
            topP: 0.95,
            temperature: 0.8,
            repetitionPenalty: 1.1,
            repetitionContextSize: 20,
            contextLength: 16384,
            maxTokens: 2048
        )
    }

    /// High quality configuration for systems with ample RAM (32GB+) No KV cache quantization for maximum quality.
    public static var highQuality: MLXConfiguration {
        MLXConfiguration(
            kvBits: nil,
            kvGroupSize: 64,
            quantizedKVStart: 0,
            maxKVSize: nil,
            topP: 0.95,
            temperature: 0.8,
            repetitionPenalty: 1.05,
            repetitionContextSize: 20,
            contextLength: 32768,
            maxTokens: 4096
        )
    }
}

/// Supported AI provider types.
public enum ProviderType: String, CaseIterable, Codable {
    case openai = "openai"
    case anthropic = "anthropic"
    case githubCopilot = "github-copilot"
    case deepseek = "deepseek"
    case gemini = "gemini"
    case openrouter = "openrouter"
    case localLlama = "local-llama"
    case localMLX = "local-mlx"
    case custom = "custom"

    public var displayName: String {
        switch self {
        case .openai: return "OpenAI"
        case .anthropic: return "Anthropic"
        case .githubCopilot: return "GitHub Copilot"
        case .deepseek: return "DeepSeek"
        case .gemini: return "Google Gemini"
        case .openrouter: return "OpenRouter"
        case .localLlama: return "Local Models (llama.cpp)"
        case .localMLX: return "Local Models (MLX)"
        case .custom: return "Custom"
        }
    }

    public var defaultIdentifier: String {
        return rawValue
    }

    /// Normalized provider name for user-facing model identifiers (lowercase, underscores) e.g., "GitHub Copilot" → "github_copilot".
    public var normalizedProviderName: String {
        switch self {
        case .openai: return "openai"
        case .anthropic: return "anthropic"
        case .githubCopilot: return "github_copilot"
        case .deepseek: return "deepseek"
        case .gemini: return "gemini"
        case .openrouter: return "openrouter"
        case .localLlama: return "llama"
        case .localMLX: return "mlx"
        case .custom: return "custom"
        }
    }

    public var requiresApiKey: Bool {
        switch self {
        case .localLlama, .localMLX: return false
        case .openai, .anthropic, .githubCopilot, .deepseek, .gemini, .openrouter, .custom: return true
        }
    }

    public var defaultBaseURL: String? {
        switch self {
        case .openai: return "https://api.openai.com/v1"
        case .anthropic: return "https://api.anthropic.com"
        case .githubCopilot: return "https://api.githubcopilot.com"
        case .deepseek: return "https://api.deepseek.com/v1"
        case .gemini: return "https://generativelanguage.googleapis.com/v1beta"
        case .openrouter: return "https://openrouter.ai/api/v1"
        case .localLlama, .localMLX, .custom: return nil
        }
    }

    public var defaultModels: [String] {
        switch self {
        case .openai:
            return ["gpt-4", "gpt-4-turbo", "gpt-3.5-turbo"]

        case .anthropic:
            return ["claude-3-opus", "claude-3-sonnet", "claude-3-haiku"]

        case .githubCopilot:
            return ["copilot-chat"]

        case .deepseek:
            return ["deepseek-chat", "deepseek-coder"]

        case .gemini:
            return []

        case .openrouter:
            return []

        case .localLlama:
            return []
        case .localMLX:
            return []
        case .custom:
            return []
        }
    }

    public var icon: String {
        switch self {
        case .openai:
            return "cpu"

        case .anthropic:
            return "a.circle.fill"

        case .githubCopilot:
            return "arrow.triangle.branch"
        case .deepseek:
            return "d.circle.fill"

        case .gemini:
            return "g.circle.fill"

        case .openrouter:
            return "arrow.triangle.merge"

        case .localLlama:
            return "laptopcomputer"
        case .localMLX:
            return "flame"
        case .custom:
            return "network"
        }
    }

    public var iconColor: Color {
        switch self {
        case .openai:
            return .green

        case .anthropic:
            return .orange

        case .githubCopilot:
            return .purple

        case .deepseek:
            return .red

        case .gemini:
            return .blue

        case .openrouter:
            return .teal

        case .localLlama:
            return .cyan

        case .localMLX:
            return .orange

        case .custom:
            return .secondary
        }
    }
}

// MARK: - Server Configuration

public struct ServerConfiguration: Codable {
    public let port: Int
    public let enableSSL: Bool
    public let logLevel: String

    public init(port: Int = 8080, enableSSL: Bool = false, logLevel: String = "info") {
        self.port = port
        self.enableSSL = enableSSL
        self.logLevel = logLevel
    }
}

// MARK: - User Configuration

/// General user preferences and identity information.
public struct UserConfiguration: Codable {
    /// User's name for git commits (optional, uses system git config if not set).
    public let userName: String?
    /// User's email for git commits (optional, uses system git config if not set).
    public let userEmail: String?

    public init(userName: String? = nil, userEmail: String? = nil) {
        self.userName = userName
        self.userEmail = userEmail
    }

    /// Default configuration with placeholder values.
    public static var `default`: UserConfiguration {
        UserConfiguration(
            userName: nil,
            userEmail: nil
        )
    }
}

// MARK: - Provider Defaults

public struct ProviderDefaults: Codable {
    public let baseURL: String?
    public let maxTokens: Int?
    public let temperature: Double?
    public let timeoutSeconds: Int?
    public let retryCount: Int?

    public init(baseURL: String? = nil,
               maxTokens: Int? = nil,
               temperature: Double? = nil,
               timeoutSeconds: Int? = nil,
               retryCount: Int? = nil) {
        self.baseURL = baseURL
        self.maxTokens = maxTokens
        self.temperature = temperature
        self.timeoutSeconds = timeoutSeconds
        self.retryCount = retryCount
    }
}
