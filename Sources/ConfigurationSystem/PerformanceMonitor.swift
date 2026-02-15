// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import Foundation
import Combine

// MARK: - Performance Metrics Models

public struct APIPerformanceMetrics: Identifiable, Codable {
    public let id: UUID
    public let timestamp: Date
    public let model: String
    public let provider: String
    public let requestTokens: Int
    public let responseTokens: Int
    public let timeToFirstToken: TimeInterval
    public let totalLatency: TimeInterval
    public let success: Bool
    public let errorMessage: String?

    public var totalTokens: Int { requestTokens + responseTokens }
    public var tokensPerSecond: Double {
        guard totalLatency > 0 else { return 0 }
        return Double(responseTokens) / totalLatency
    }

    public init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        model: String,
        provider: String,
        requestTokens: Int,
        responseTokens: Int,
        timeToFirstToken: TimeInterval,
        totalLatency: TimeInterval,
        success: Bool,
        errorMessage: String? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.model = model
        self.provider = provider
        self.requestTokens = requestTokens
        self.responseTokens = responseTokens
        self.timeToFirstToken = timeToFirstToken
        self.totalLatency = totalLatency
        self.success = success
        self.errorMessage = errorMessage
    }
}

// MARK: - Billing/Cost Tracking Models

/// Session cost summary by model
public struct SessionCostSummary: Identifiable, Sendable {
    public let id = UUID()
    public let model: String
    public let requestCount: Int
    public let totalInputTokens: Int
    public let totalOutputTokens: Int
    public let totalTokens: Int
    public let premiumMultiplier: Double?
    public let isPremium: Bool
    
    /// Estimated premium requests used (for GitHub Copilot)
    public var premiumRequestsUsed: Int {
        guard let multiplier = premiumMultiplier, multiplier > 0 else {
            return isPremium ? requestCount : 0
        }
        return Int(ceil(Double(requestCount) * multiplier))
    }
    
    public init(
        model: String,
        requestCount: Int,
        totalInputTokens: Int,
        totalOutputTokens: Int,
        totalTokens: Int,
        premiumMultiplier: Double?,
        isPremium: Bool
    ) {
        self.model = model
        self.requestCount = requestCount
        self.totalInputTokens = totalInputTokens
        self.totalOutputTokens = totalOutputTokens
        self.totalTokens = totalTokens
        self.premiumMultiplier = premiumMultiplier
        self.isPremium = isPremium
    }
}

/// Aggregate session cost statistics
public struct SessionCostStatistics: Sendable {
    public let totalRequests: Int
    public let totalInputTokens: Int
    public let totalOutputTokens: Int
    public let totalTokens: Int
    public let premiumRequestsUsed: Int
    public let freeRequestsUsed: Int
    public let modelBreakdown: [SessionCostSummary]
    public let sessionStartTime: Date
    
    public init(
        totalRequests: Int,
        totalInputTokens: Int,
        totalOutputTokens: Int,
        totalTokens: Int,
        premiumRequestsUsed: Int,
        freeRequestsUsed: Int,
        modelBreakdown: [SessionCostSummary],
        sessionStartTime: Date
    ) {
        self.totalRequests = totalRequests
        self.totalInputTokens = totalInputTokens
        self.totalOutputTokens = totalOutputTokens
        self.totalTokens = totalTokens
        self.premiumRequestsUsed = premiumRequestsUsed
        self.freeRequestsUsed = freeRequestsUsed
        self.modelBreakdown = modelBreakdown
        self.sessionStartTime = sessionStartTime
    }
}

public struct PerformanceStatistics: Codable {
    public let totalRequests: Int
    public let successfulRequests: Int
    public let errorRate: Double
    public let averageLatency: TimeInterval
    public let averageTTFT: TimeInterval
    public let averageTokensPerSecond: Double

    public init(
        totalRequests: Int,
        successfulRequests: Int,
        errorRate: Double,
        averageLatency: TimeInterval,
        averageTTFT: TimeInterval,
        averageTokensPerSecond: Double
    ) {
        self.totalRequests = totalRequests
        self.successfulRequests = successfulRequests
        self.errorRate = errorRate
        self.averageLatency = averageLatency
        self.averageTTFT = averageTTFT
        self.averageTokensPerSecond = averageTokensPerSecond
    }
}

// MARK: - Workflow Metrics (Phase 2-4 enhancements)

public struct WorkflowMetrics: Identifiable, Codable {
    public let id: UUID
    public let timestamp: Date
    public let conversationId: UUID?
    public let totalIterations: Int
    public let totalDuration: TimeInterval
    public let totalToolCalls: Int
    public let successfulToolCalls: Int
    public let failedToolCalls: Int
    public let thinkingRounds: Int
    public let errorRounds: Int
    public let completionReason: String

    public var toolSuccessRate: Double {
        guard totalToolCalls > 0 else { return 0 }
        return Double(successfulToolCalls) / Double(totalToolCalls)
    }

    public var averageIterationDuration: TimeInterval {
        guard totalIterations > 0 else { return 0 }
        return totalDuration / Double(totalIterations)
    }

    public init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        conversationId: UUID?,
        totalIterations: Int,
        totalDuration: TimeInterval,
        totalToolCalls: Int,
        successfulToolCalls: Int,
        failedToolCalls: Int,
        thinkingRounds: Int,
        errorRounds: Int,
        completionReason: String
    ) {
        self.id = id
        self.timestamp = timestamp
        self.conversationId = conversationId
        self.totalIterations = totalIterations
        self.totalDuration = totalDuration
        self.totalToolCalls = totalToolCalls
        self.successfulToolCalls = successfulToolCalls
        self.failedToolCalls = failedToolCalls
        self.thinkingRounds = thinkingRounds
        self.errorRounds = errorRounds
        self.completionReason = completionReason
    }
}

public struct LoopDetectionMetrics: Identifiable, Codable {
    public let id: UUID
    public let timestamp: Date
    public let conversationId: UUID?
    public let toolName: String
    public let callCount: Int
    public let compositeScore: Double
    public let interventionLevel: String
    public let actionTaken: String

    public init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        conversationId: UUID?,
        toolName: String,
        callCount: Int,
        compositeScore: Double,
        interventionLevel: String,
        actionTaken: String
    ) {
        self.id = id
        self.timestamp = timestamp
        self.conversationId = conversationId
        self.toolName = toolName
        self.callCount = callCount
        self.compositeScore = compositeScore
        self.interventionLevel = interventionLevel
        self.actionTaken = actionTaken
    }
}

public struct ContextFilteringMetrics: Identifiable, Codable {
    public let id: UUID
    public let timestamp: Date
    public let conversationId: UUID?
    public let originalMessageCount: Int
    public let filteredMessageCount: Int
    public let roundsFiltered: Int
    public let roundsKept: Int
    public let estimatedTokensSaved: Int

    public var filterEffectiveness: Double {
        guard originalMessageCount > 0 else { return 0 }
        return Double(originalMessageCount - filteredMessageCount) / Double(originalMessageCount)
    }

    public init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        conversationId: UUID?,
        originalMessageCount: Int,
        filteredMessageCount: Int,
        roundsFiltered: Int,
        roundsKept: Int,
        estimatedTokensSaved: Int
    ) {
        self.id = id
        self.timestamp = timestamp
        self.conversationId = conversationId
        self.originalMessageCount = originalMessageCount
        self.filteredMessageCount = filteredMessageCount
        self.roundsFiltered = roundsFiltered
        self.roundsKept = roundsKept
        self.estimatedTokensSaved = estimatedTokensSaved
    }
}

@MainActor
public class PerformanceMonitor: ObservableObject {
    @Published public var currentMetrics: APIPerformanceMetrics?
    @Published public var recentMetrics: [APIPerformanceMetrics] = []
    @Published public var isEnabled: Bool = true

    /// PHASE 2-4 ENHANCEMENTS: Workflow tracking.
    @Published public var recentWorkflows: [WorkflowMetrics] = []
    @Published public var recentLoopDetections: [LoopDetectionMetrics] = []
    @Published public var recentContextFiltering: [ContextFilteringMetrics] = []

    public init() {}

    public func startRequest(model: String, provider: String, requestTokens: Int) -> RequestTracker {
        RequestTracker(
            model: model,
            provider: provider,
            requestTokens: requestTokens,
            performanceMonitor: self
        )
    }

    public func recordMetrics(_ metrics: APIPerformanceMetrics) {
        guard isEnabled else { return }

        currentMetrics = metrics
        recentMetrics.insert(metrics, at: 0)

        if recentMetrics.count > 100 {
            recentMetrics = Array(recentMetrics.prefix(100))
        }
    }

    /// PHASE 2-4 ENHANCEMENTS: Record workflow metrics.
    public func recordWorkflow(_ metrics: WorkflowMetrics) {
        guard isEnabled else { return }

        recentWorkflows.insert(metrics, at: 0)

        if recentWorkflows.count > 50 {
            recentWorkflows = Array(recentWorkflows.prefix(50))
        }
    }

    /// Record loop detection event.
    public func recordLoopDetection(_ metrics: LoopDetectionMetrics) {
        guard isEnabled else { return }

        recentLoopDetections.insert(metrics, at: 0)

        if recentLoopDetections.count > 50 {
            recentLoopDetections = Array(recentLoopDetections.prefix(50))
        }
    }

    /// Record context filtering event.
    public func recordContextFiltering(_ metrics: ContextFilteringMetrics) {
        guard isEnabled else { return }

        recentContextFiltering.insert(metrics, at: 0)

        if recentContextFiltering.count > 50 {
            recentContextFiltering = Array(recentContextFiltering.prefix(50))
        }
    }

    public func generateStatistics() -> PerformanceStatistics? {
        guard !recentMetrics.isEmpty else { return nil }

        let totalRequests = recentMetrics.count
        let successfulRequests = recentMetrics.filter(\.success).count
        let errorRate = Double(totalRequests - successfulRequests) / Double(totalRequests)

        let latencies = recentMetrics.map(\.totalLatency)
        let ttfts = recentMetrics.map(\.timeToFirstToken)
        let tokensPerSec = recentMetrics.map(\.tokensPerSecond).filter { $0 > 0 }

        let avgLatency = latencies.reduce(0, +) / Double(latencies.count)
        let avgTTFT = ttfts.reduce(0, +) / Double(ttfts.count)
        let avgTokensPerSec = tokensPerSec.isEmpty ? 0 : tokensPerSec.reduce(0, +) / Double(tokensPerSec.count)

        return PerformanceStatistics(
            totalRequests: totalRequests,
            successfulRequests: successfulRequests,
            errorRate: errorRate,
            averageLatency: avgLatency,
            averageTTFT: avgTTFT,
            averageTokensPerSecond: avgTokensPerSec
        )
    }
    
    // MARK: - Session Cost Tracking
    
    /// Generate session cost statistics with per-model breakdown
    /// - Parameter billingLookup: Closure to get billing info for a model (isPremium, multiplier)
    /// - Returns: SessionCostStatistics with complete cost breakdown
    public func generateSessionCostStatistics(
        billingLookup: (String) -> (isPremium: Bool, multiplier: Double?)?
    ) -> SessionCostStatistics {
        // Group metrics by model
        var modelStats: [String: (requests: Int, inputTokens: Int, outputTokens: Int)] = [:]
        
        for metric in recentMetrics {
            var stats = modelStats[metric.model] ?? (requests: 0, inputTokens: 0, outputTokens: 0)
            stats.requests += 1
            stats.inputTokens += metric.requestTokens
            stats.outputTokens += metric.responseTokens
            modelStats[metric.model] = stats
        }
        
        // Build model breakdown with billing info
        var modelBreakdown: [SessionCostSummary] = []
        var totalPremium = 0
        var totalFree = 0
        var totalInput = 0
        var totalOutput = 0
        
        for (model, stats) in modelStats.sorted(by: { $0.value.requests > $1.value.requests }) {
            let billing = billingLookup(model)
            let isPremium = billing?.isPremium ?? false
            let multiplier = billing?.multiplier
            
            let summary = SessionCostSummary(
                model: model,
                requestCount: stats.requests,
                totalInputTokens: stats.inputTokens,
                totalOutputTokens: stats.outputTokens,
                totalTokens: stats.inputTokens + stats.outputTokens,
                premiumMultiplier: multiplier,
                isPremium: isPremium
            )
            
            modelBreakdown.append(summary)
            totalInput += stats.inputTokens
            totalOutput += stats.outputTokens
            
            if isPremium {
                totalPremium += summary.premiumRequestsUsed
            } else {
                totalFree += stats.requests
            }
        }
        
        // Determine session start time from oldest metric
        let sessionStart = recentMetrics.last?.timestamp ?? Date()
        
        return SessionCostStatistics(
            totalRequests: recentMetrics.count,
            totalInputTokens: totalInput,
            totalOutputTokens: totalOutput,
            totalTokens: totalInput + totalOutput,
            premiumRequestsUsed: totalPremium,
            freeRequestsUsed: totalFree,
            modelBreakdown: modelBreakdown,
            sessionStartTime: sessionStart
        )
    }

    // MARK: - Export Functionality

    /// Export all metrics as JSON.
    public func exportMetrics() -> String? {
        let exportData: [String: Any] = [
            "exportDate": ISO8601DateFormatter().string(from: Date()),
            "apiMetrics": exportAPIMetrics(),
            "workflowMetrics": exportWorkflowMetrics(),
            "loopDetectionMetrics": exportLoopDetectionMetrics(),
            "contextFilteringMetrics": exportContextFilteringMetrics(),
            "statistics": exportStatistics()
        ]

        guard let jsonData = try? JSONSerialization.data(withJSONObject: exportData, options: [.prettyPrinted, .sortedKeys]) else {
            return nil
        }

        return String(data: jsonData, encoding: .utf8)
    }

    private func exportAPIMetrics() -> [[String: Any]] {
        return recentMetrics.map { metrics in
            [
                "id": metrics.id.uuidString,
                "timestamp": ISO8601DateFormatter().string(from: metrics.timestamp),
                "model": metrics.model,
                "provider": metrics.provider,
                "requestTokens": metrics.requestTokens,
                "responseTokens": metrics.responseTokens,
                "totalTokens": metrics.totalTokens,
                "timeToFirstToken": metrics.timeToFirstToken,
                "totalLatency": metrics.totalLatency,
                "tokensPerSecond": metrics.tokensPerSecond,
                "success": metrics.success,
                "errorMessage": metrics.errorMessage ?? NSNull()
            ]
        }
    }

    private func exportWorkflowMetrics() -> [[String: Any]] {
        return recentWorkflows.map { workflow in
            [
                "id": workflow.id.uuidString,
                "timestamp": ISO8601DateFormatter().string(from: workflow.timestamp),
                "conversationId": workflow.conversationId?.uuidString ?? NSNull(),
                "totalIterations": workflow.totalIterations,
                "totalDuration": workflow.totalDuration,
                "totalToolCalls": workflow.totalToolCalls,
                "successfulToolCalls": workflow.successfulToolCalls,
                "failedToolCalls": workflow.failedToolCalls,
                "toolSuccessRate": workflow.toolSuccessRate,
                "thinkingRounds": workflow.thinkingRounds,
                "errorRounds": workflow.errorRounds,
                "completionReason": workflow.completionReason,
                "averageIterationDuration": workflow.averageIterationDuration
            ]
        }
    }

    private func exportLoopDetectionMetrics() -> [[String: Any]] {
        return recentLoopDetections.map { detection in
            [
                "id": detection.id.uuidString,
                "timestamp": ISO8601DateFormatter().string(from: detection.timestamp),
                "conversationId": detection.conversationId?.uuidString ?? NSNull(),
                "toolName": detection.toolName,
                "callCount": detection.callCount,
                "compositeScore": detection.compositeScore,
                "interventionLevel": detection.interventionLevel,
                "actionTaken": detection.actionTaken
            ]
        }
    }

    private func exportContextFilteringMetrics() -> [[String: Any]] {
        return recentContextFiltering.map { filtering in
            [
                "id": filtering.id.uuidString,
                "timestamp": ISO8601DateFormatter().string(from: filtering.timestamp),
                "conversationId": filtering.conversationId?.uuidString ?? NSNull(),
                "originalMessageCount": filtering.originalMessageCount,
                "filteredMessageCount": filtering.filteredMessageCount,
                "roundsFiltered": filtering.roundsFiltered,
                "roundsKept": filtering.roundsKept,
                "estimatedTokensSaved": filtering.estimatedTokensSaved,
                "filterEffectiveness": filtering.filterEffectiveness
            ]
        }
    }

    private func exportStatistics() -> [String: Any] {
        guard let stats = generateStatistics() else {
            return [:]
        }

        return [
            "totalRequests": stats.totalRequests,
            "successfulRequests": stats.successfulRequests,
            "errorRate": stats.errorRate,
            "successRate": 1.0 - stats.errorRate,
            "averageLatency": stats.averageLatency,
            "averageTTFT": stats.averageTTFT,
            "averageTokensPerSecond": stats.averageTokensPerSecond
        ]
    }

    /// Save exported metrics to file.
    public func saveMetricsToFile(filename: String? = nil) -> URL? {
        guard let jsonString = exportMetrics() else {
            return nil
        }

        let filename = filename ?? "sam_metrics_\(Date().timeIntervalSince1970).json"
        let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent(filename)

        do {
            try jsonString.write(to: fileURL, atomically: true, encoding: .utf8)
            return fileURL
        } catch {
            return nil
        }
    }
}

public class RequestTracker: @unchecked Sendable {
    private let model: String
    private let provider: String
    private let requestTokens: Int
    private let startTime: Date
    private var firstTokenTime: Date?
    private weak var performanceMonitor: PerformanceMonitor?

    init(model: String, provider: String, requestTokens: Int, performanceMonitor: PerformanceMonitor) {
        self.model = model
        self.provider = provider
        self.requestTokens = requestTokens
        self.startTime = Date()
        self.performanceMonitor = performanceMonitor
    }

    public func markFirstToken() {
        guard firstTokenTime == nil else { return }
        firstTokenTime = Date()
    }

    public func complete(responseTokens: Int, success: Bool = true, error: Error? = nil) {
        let endTime = Date()
        let totalLatency = endTime.timeIntervalSince(startTime)
        let timeToFirstToken = firstTokenTime?.timeIntervalSince(startTime) ?? totalLatency

        let metrics = APIPerformanceMetrics(
            timestamp: startTime,
            model: model,
            provider: provider,
            requestTokens: requestTokens,
            responseTokens: responseTokens,
            timeToFirstToken: timeToFirstToken,
            totalLatency: totalLatency,
            success: success,
            errorMessage: error?.localizedDescription
        )

        let monitor = performanceMonitor
        Task { @MainActor in
            monitor?.recordMetrics(metrics)
        }
    }
}
