// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import SwiftUI
import ConfigurationSystem
import Logging

private let logger = Logger(label: "com.sam.performance")

public struct PerformanceMetricsView: View {
    @ObservedObject private var performanceMonitor: PerformanceMonitor
    @State private var showDetailedMetrics = false
    @Binding private var isVisible: Bool

    public init(performanceMonitor: PerformanceMonitor, isVisible: Binding<Bool>) {
        self.performanceMonitor = performanceMonitor
        self._isVisible = isVisible
    }

    public init(performanceMonitor: PerformanceMonitor) {
        self.performanceMonitor = performanceMonitor
        self._isVisible = .constant(true)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            /// Header.
            HStack {
                Text("Performance Metrics")
                    .font(.headline)

                Spacer()

                Button(showDetailedMetrics ? "Compact" : "Detailed") {
                    showDetailedMetrics.toggle()
                }
                .buttonStyle(.bordered)

                Button("Export") {
                    exportMetrics()
                }
                .buttonStyle(.bordered)

                /// Close button.
                Button(action: { isVisible = false }) {
                    Image(systemName: "xmark")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help("Close Performance Metrics")
            }

            if performanceMonitor.isEnabled {
                if showDetailedMetrics {
                    detailedMetricsView
                } else {
                    compactMetricsView
                }
            } else {
                disabledMetricsView
            }
        }
        .padding()
        .background(Color.secondary.opacity(0.1))
        .cornerRadius(8)
    }

    private var compactMetricsView: some View {
        HStack(spacing: 16) {
            if let current = performanceMonitor.currentMetrics {
                metricCard("Latency", formatLatency(current.totalLatency))
                metricCard("TTFT", formatLatency(current.timeToFirstToken))
                metricCard("Tokens/sec", String(format: "%.1f", current.tokensPerSecond))
            } else {
                Text("No recent requests")
                    .foregroundColor(.secondary)
            }
        }
    }

    private var detailedMetricsView: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let current = performanceMonitor.currentMetrics {
                currentRequestView(current)
            }

            if let stats = performanceMonitor.generateStatistics() {
                statisticalOverviewView(stats)
            }

            /// PHASE 2-4 METRICS: Workflow metrics.
            if !performanceMonitor.recentWorkflows.isEmpty {
                workflowMetricsView
            }

            /// PHASE 4 METRICS: Loop detection.
            if !performanceMonitor.recentLoopDetections.isEmpty {
                loopDetectionMetricsView
            }

            /// PHASE 3 METRICS: Context filtering.
            if !performanceMonitor.recentContextFiltering.isEmpty {
                contextFilteringMetricsView
            }

            recentRequestsView
        }
    }

    private func currentRequestView(_ metrics: APIPerformanceMetrics) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Current Request")
                .font(.subheadline)
                .fontWeight(.semibold)

            LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 3), spacing: 12) {
                detailedMetricCard("Total Latency", formatLatency(metrics.totalLatency))
                detailedMetricCard("Time to First Token", formatLatency(metrics.timeToFirstToken))
                detailedMetricCard("Tokens per Second", String(format: "%.1f", metrics.tokensPerSecond))
                detailedMetricCard("Request Tokens", String(metrics.requestTokens))
                detailedMetricCard("Response Tokens", String(metrics.responseTokens))
                detailedMetricCard("Total Tokens", String(metrics.totalTokens))
            }
        }
        .padding()
        .background(Color.blue.opacity(0.1))
        .cornerRadius(8)
    }

    private func statisticalOverviewView(_ stats: PerformanceStatistics) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Statistical Overview")
                .font(.subheadline)
                .fontWeight(.semibold)

            LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 2), spacing: 12) {
                detailedMetricCard("Total Requests", String(stats.totalRequests))
                detailedMetricCard("Success Rate", String(format: "%.1f%%", (1.0 - stats.errorRate) * 100))
                detailedMetricCard("Avg Latency", formatLatency(stats.averageLatency))
                detailedMetricCard("Avg TTFT", formatLatency(stats.averageTTFT))
                detailedMetricCard("Avg Tokens/sec", String(format: "%.1f", stats.averageTokensPerSecond))
            }
        }
        .padding()
        .background(Color.green.opacity(0.1))
        .cornerRadius(8)
    }

    private var recentRequestsView: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Recent Requests")
                .font(.subheadline)
                .fontWeight(.semibold)

            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(performanceMonitor.recentMetrics.prefix(10), id: \.id) { metrics in
                        recentRequestRow(metrics)
                    }
                }
            }
            .frame(maxHeight: 200)
        }
        .padding()
        .background(Color.orange.opacity(0.1))
        .cornerRadius(8)
    }

    private func recentRequestRow(_ metrics: APIPerformanceMetrics) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(metrics.success ? Color.green : Color.red)
                .frame(width: 8, height: 8)

            Text(metrics.model)
                .font(.caption)
                .foregroundColor(.primary)

            Spacer()

            Text(formatLatency(metrics.totalLatency))
                .font(.caption)
                .foregroundColor(.secondary)

            Text(String(format: "%.1f t/s", metrics.tokensPerSecond))
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(.vertical, 2)
    }

    // MARK: - UI Setup

    private var workflowMetricsView: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Workflow Metrics (Last 10)")
                .font(.subheadline)
                .fontWeight(.semibold)

            if let latest = performanceMonitor.recentWorkflows.first {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 3), spacing: 12) {
                    detailedMetricCard("Iterations", String(latest.totalIterations))
                    detailedMetricCard("Duration", formatLatency(latest.totalDuration))
                    detailedMetricCard("Tool Calls", String(latest.totalToolCalls))
                    detailedMetricCard("Success Rate", String(format: "%.0f%%", latest.toolSuccessRate * 100))
                    detailedMetricCard("Thinking Rounds", String(latest.thinkingRounds))
                    detailedMetricCard("Error Rounds", String(latest.errorRounds))
                }
            }

            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(performanceMonitor.recentWorkflows.prefix(10), id: \.id) { workflow in
                        workflowRow(workflow)
                    }
                }
            }
            .frame(maxHeight: 150)
        }
        .padding()
        .background(Color.purple.opacity(0.1))
        .cornerRadius(8)
    }

    private func workflowRow(_ workflow: WorkflowMetrics) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(workflow.errorRounds > 0 ? Color.orange : Color.green)
                .frame(width: 8, height: 8)

            Text("\(workflow.totalIterations) iterations")
                .font(.caption)
                .foregroundColor(.primary)

            Spacer()

            Text("\(workflow.totalToolCalls) tools")
                .font(.caption)
                .foregroundColor(.secondary)

            Text(String(format: "%.0f%% success", workflow.toolSuccessRate * 100))
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(.vertical, 2)
    }

    private var loopDetectionMetricsView: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Loop Detection Events (Last 10)")
                .font(.subheadline)
                .fontWeight(.semibold)

            if let latest = performanceMonitor.recentLoopDetections.first {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 3), spacing: 12) {
                    detailedMetricCard("Tool", latest.toolName)
                    detailedMetricCard("Loop Score", String(format: "%.2f", latest.compositeScore))
                    detailedMetricCard("Action", latest.actionTaken)
                }
            }

            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(performanceMonitor.recentLoopDetections.prefix(10), id: \.id) { detection in
                        loopDetectionRow(detection)
                    }
                }
            }
            .frame(maxHeight: 150)
        }
        .padding()
        .background(Color.red.opacity(0.1))
        .cornerRadius(8)
    }

    private func loopDetectionRow(_ detection: LoopDetectionMetrics) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(severityColor(for: detection.interventionLevel))
                .frame(width: 8, height: 8)

            Text(detection.toolName)
                .font(.caption)
                .foregroundColor(.primary)

            Spacer()

            Text("\(detection.callCount) calls")
                .font(.caption)
                .foregroundColor(.secondary)

            Text(String(format: "%.2f score", detection.compositeScore))
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(.vertical, 2)
    }

    private var contextFilteringMetricsView: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Context Filtering (Last 10)")
                .font(.subheadline)
                .fontWeight(.semibold)

            if let latest = performanceMonitor.recentContextFiltering.first {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 3), spacing: 12) {
                    detailedMetricCard("Filtered", "\(latest.roundsFiltered) rounds")
                    detailedMetricCard("Tokens Saved", "~\(latest.estimatedTokensSaved)")
                    detailedMetricCard("Effectiveness", String(format: "%.0f%%", latest.filterEffectiveness * 100))
                }
            }

            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(performanceMonitor.recentContextFiltering.prefix(10), id: \.id) { filtering in
                        contextFilteringRow(filtering)
                    }
                }
            }
            .frame(maxHeight: 150)
        }
        .padding()
        .background(Color.cyan.opacity(0.1))
        .cornerRadius(8)
    }

    private func contextFilteringRow(_ filtering: ContextFilteringMetrics) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(filtering.roundsFiltered > 0 ? Color.green : Color.gray)
                .frame(width: 8, height: 8)

            Text("Filtered \(filtering.roundsFiltered) rounds")
                .font(.caption)
                .foregroundColor(.primary)

            Spacer()

            Text("~\(filtering.estimatedTokensSaved) tokens")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(.vertical, 2)
    }

    private func severityColor(for level: String) -> Color {
        switch level {
        case "none": return .gray
        case "warning": return .yellow
        case "suggestion": return .orange
        case "blocking": return .red
        case "termination": return .purple
        default: return .gray
        }
    }

    private var disabledMetricsView: some View {
        VStack(spacing: 8) {
            Text("Performance monitoring is disabled")
                .foregroundColor(.secondary)

            Button("Enable Monitoring") {
                performanceMonitor.isEnabled = true
            }
            .buttonStyle(.bordered)
        }
    }

    private func metricCard(_ title: String, _ value: String) -> some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.headline)
                .fontWeight(.medium)
            Text(title)
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .frame(minWidth: 60)
    }

    private func detailedMetricCard(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundColor(.secondary)
            Text(value)
                .font(.subheadline)
                .fontWeight(.medium)
        }
        .padding(8)
        .background(Color.secondary.opacity(0.1))
        .cornerRadius(4)
    }

    private func formatLatency(_ latency: TimeInterval) -> String {
        if latency < 1.0 {
            return String(format: "%.0fms", latency * 1000)
        } else {
            return String(format: "%.2fs", latency)
        }
    }

    private func exportMetrics() {
        guard let fileURL = performanceMonitor.saveMetricsToFile() else {
            logger.error("Failed to export metrics")
            return
        }

        /// Open in Finder.
        NSWorkspace.shared.selectFile(fileURL.path, inFileViewerRootedAtPath: fileURL.deletingLastPathComponent().path)

        logger.info("Metrics exported to: \(fileURL.path)")
    }
}

#if DEBUG
struct PerformanceMetricsView_Previews: PreviewProvider {
    static var previews: some View {
        let monitor = PerformanceMonitor()

        /// Add sample data for preview.
        let sampleMetrics = APIPerformanceMetrics(
            model: "gpt-4",
            provider: "GitHub Copilot",
            requestTokens: 150,
            responseTokens: 300,
            timeToFirstToken: 0.8,
            totalLatency: 2.5,
            success: true
        )

        Task { @MainActor in
            monitor.recordMetrics(sampleMetrics)
        }

        return PerformanceMetricsView(performanceMonitor: monitor)
            .padding()
    }
}
#endif
