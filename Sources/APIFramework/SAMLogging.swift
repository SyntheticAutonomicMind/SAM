// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import Logging
import Foundation

/// SAM Logging System - NO EMOJIS, standardized format matching SAM 1.0 patterns Format: [TIMESTAMP] [LEVEL] [COMPONENT] message.
extension Logging.Logger {
    /// Create a logger for SAM components with standardized category naming.
    static func sam(_ category: SAMLogCategory) -> Logging.Logger {
        return Logging.Logger(label: "com.sam.api.\(category.rawValue)")
    }
}

/// Standardized logging categories matching SAM 1.0 architecture.
enum SAMLogCategory: String {
    case api = "API"
    case chat = "Chat"
    case config = "Config"
    case endpoint = "Endpoint"
    case memory = "Memory"
    case performance = "Performance"
    case security = "Security"
    case ui = "UI"
    case app = "App"
    case provider = "Provider"
}

/// Standardized logging messages - no emojis, clear technical descriptions All methods now use Logging.Logger for consistency.
public struct SAMLog {
    // MARK: - Logging methods

    static func endpointManagerCall(method: String, logger: Logging.Logger) {
        logger.debug("EndpointManager.\(method) called")
    }

    static func providersAvailable(providers: [String], logger: Logging.Logger) {
        logger.debug("Available providers: \(providers.sorted().joined(separator: ", "))")
    }

    static func providerModelsRetrieved(provider: String, count: Int, logger: Logging.Logger) {
        logger.debug("Provider \(provider) returned \(count) models")
    }

    static func providerConfigLoaded(provider: String, modelCount: Int, logger: Logging.Logger) {
        logger.debug("Provider \(provider) loaded with \(modelCount) models")
    }

    static func providerConfigNotFound(provider: String, logger: Logging.Logger) {
        logger.error("No configuration found for provider: \(provider)")
    }

    static func configLookup(key: String, logger: Logging.Logger) {
        logger.debug("Looking for UserDefaults key: \(key)")
    }

    static func dataNotFound(key: String, logger: Logging.Logger) {
        logger.debug("No data found in UserDefaults for key: \(key)")
    }

    static func configDecodeFailed(key: String, error: Error, logger: Logging.Logger) {
        logger.error("Failed to decode config data for key \(key): \(error)")
    }

    static func apiServerStarted(port: Int, logger: Logging.Logger) {
        logger.debug("API server started on port \(port)")
    }

    static func apiRequest(method: String, path: String, logger: Logging.Logger) {
        logger.debug("API request: \(method) \(path)")
    }

    static func chatWidgetInitialized(logger: Logging.Logger) {
        logger.debug("ChatWidget initialized, starting model loading")
    }

    static func modelsLoaded(count: Int, models: [String], logger: Logging.Logger) {
        logger.debug("Loaded \(count) available models: \(models.prefix(5).joined(separator: ", "))\(models.count > 5 ? "..." : "")")
    }

    // MARK: - Convenience methods with default loggers
    private static let chatLogger = Logging.Logger.sam(.chat)
    private static let uiLogger = Logging.Logger.sam(.ui)
    private static let apiLogger = Logging.Logger.sam(.api)

    public static func chatViewAppear() {
        chatLogger.debug("ChatWidget onAppear called - starting model loading")
    }

    public static func chatProcessMessage(_ text: String) {
        chatLogger.debug("ChatWidget processMessage called with: '\(text.prefix(50))\(text.count > 50 ? "..." : "")'")
    }

    public static func chatStreamingStart(model: String, temperature: Double) {
        chatLogger.debug("Calling endpointManager.processStreamingChatCompletion with model: \(model), temp: \(temperature)")
    }

    public static func chatStreamingResponse() {
        chatLogger.debug("Starting to process streaming response")
    }

    public static func chatDeltaReceived(_ content: String) {
        chatLogger.debug("Received delta chunk: '\(content.prefix(20))\(content.count > 20 ? "..." : "")'")
    }

    public static func chatDeltaAppended(totalChars: Int) {
        chatLogger.debug("Appended delta (total: \(totalChars) chars)")
    }

    public static func modelLoadingSkipped() {
        chatLogger.debug("Model loading already in progress, skipping")
    }

    public static func modelLoadingStarted() {
        chatLogger.info("Starting model loading from EndpointManager")
    }

    public static func providerConfigReload() {
        chatLogger.debug("Reloading provider configurations (matching SAMAPIServer behavior)")
    }

    public static func endpointManagerCall() {
        chatLogger.debug("Calling endpointManager.getAvailableModels()")
    }

    public static func rawModelsReceived(_ models: [String]) {
        chatLogger.debug("Raw models from EndpointManager: \(models.prefix(3).joined(separator: ", "))\(models.count > 3 ? "..." : "")")
    }

    public static func modelsStateUpdated(_ models: [String]) {
        chatLogger.debug("Updated availableModels state: \(models.prefix(3).joined(separator: ", "))\(models.count > 3 ? "..." : "")")
    }

    public static func modelSwitched(from: String, to: String) {
        chatLogger.info("Switching default model from \(from) to \(to)")
    }

    public static func modelsLoadedSuccessfully(count: Int, models: [String]) {
        chatLogger.debug("Loaded \(count) available models: \(models.prefix(3).joined(separator: ", "))\(models.count > 3 ? "..." : "")")
    }

    public static func modelLoadingFailed(_ error: Error) {
        chatLogger.error("Failed to load models, using fallback: \(error)")
    }

    public static func modelLoadingErrorDetails(_ error: Error) {
        chatLogger.error("Error details: \(error.localizedDescription)")
    }
}
