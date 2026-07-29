// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import Foundation
import Logging
import ConfigurationSystem

/// Type alias for backwards compatibility with callers that still reference
/// `Message` (the historical YaRNContextProcessor signature). ConversationEngine
/// uses ConfigurationSystem.EnhancedMessage as the unified message type.
public typealias Message = ConfigurationSystem.EnhancedMessage

/// YaRN context statistics returned to the UI for telemetry.
///
/// After the context-management refactor (commit 118cda5, MessageValidator
/// became the sole context manager), YaRN's compression/scaling code was no
/// longer invoked from the request path. This struct is now a UI telemetry
/// payload: it tracks context-window sizing (used to drive UI warnings about
/// approaching the model's limit) and reports configuration state.
///
/// Compression/scaling/attention-pattern logic was removed in this commit
/// because nothing reads it - getContextStatistics() was the only public API
/// that survived, and the values it returned were always zero or static.
public struct ContextStatistics: Sendable {
    public let cacheSize: Int
    public let currentTokenCount: Int
    public let contextWindowSize: Int
    public let compressionRatio: Double
    public let attentionScalingFactor: Double
    public let isCompressionActive: Bool

    public init(
        cacheSize: Int = 0,
        currentTokenCount: Int = 0,
        contextWindowSize: Int = 0,
        compressionRatio: Double = 1.0,
        attentionScalingFactor: Double = 1.0,
        isCompressionActive: Bool = false
    ) {
        self.cacheSize = cacheSize
        self.currentTokenCount = currentTokenCount
        self.contextWindowSize = contextWindowSize
        self.compressionRatio = compressionRatio
        self.attentionScalingFactor = attentionScalingFactor
        self.isCompressionActive = isCompressionActive
    }
}

/// Lightweight context processor that owns the configured context window size
/// (used by getContextSize on TokenCounter to look up the right value for the
/// active model) and exposes getContextStatistics() for UI telemetry.
///
/// All historical compression / scaling / attention-pattern logic was removed
/// when MessageValidator became the sole context manager - nothing invokes it.
@MainActor
public class YaRNContextProcessor: ObservableObject {
    private let logger = Logger(label: "com.sam.yarn")

    @Published public var isInitialized: Bool = false
    @Published public var contextWindowSize: Int = 0

    private let memoryManager: MemoryManager
    private let tokenEstimator: (String) async -> Int

    public init(memoryManager: MemoryManager, tokenEstimator: @escaping (String) async -> Int, config: YaRNConfig = .default) {
        self.memoryManager = memoryManager
        self.tokenEstimator = tokenEstimator
        self.contextWindowSize = config.baseContextLength
    }

    public func initialize() async throws {
        isInitialized = true
        logger.debug("SUCCESS: YaRN context processor initialized (telemetry-only)")
    }

    /// Get current context statistics. With the removal of the compression/scaling
    /// pipeline this returns mostly default values - the context window size is
    /// the only meaningful field, used by the UI to display the model's budget.
    public func getContextStatistics() -> ContextStatistics {
        return ContextStatistics(
            cacheSize: 0,
            currentTokenCount: 0,
            contextWindowSize: contextWindowSize,
            compressionRatio: 1.0,
            attentionScalingFactor: 1.0,
            isCompressionActive: false
        )
    }
}

/// YaRN configuration. Kept for API compatibility (ConversationManager and
/// callers still reference it) but the historical `mega`/`universal`/scaling
/// profiles are collapsed into a single default profile - YaRN no longer
/// drives context decisions.
public struct YaRNConfig: Sendable {
    public let baseContextLength: Int

    public init(baseContextLength: Int) {
        self.baseContextLength = baseContextLength
    }

    /// Default profile - matches the model's reported context size.
    public static let `default` = YaRNConfig(baseContextLength: 32_768)
}
