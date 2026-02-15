// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import SwiftUI
import ConfigurationSystem
import APIFramework
import Logging

private let logger = Logger(label: "com.sam.ui.costtracking")

/// Cost Tracking Panel for ChatWidget
/// Displays session cost statistics, token usage, and per-model breakdown
public struct CostTrackingView: View {
    @ObservedObject private var performanceMonitor: PerformanceMonitor
    @EnvironmentObject private var endpointManager: EndpointManager
    @Binding private var isVisible: Bool
    
    @State private var showDetailedBreakdown = false
    @State private var costStats: SessionCostStatistics?
    @State private var isRefreshingBilling = false
    
    public init(performanceMonitor: PerformanceMonitor, isVisible: Binding<Bool>) {
        self.performanceMonitor = performanceMonitor
        self._isVisible = isVisible
    }
    
    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header
            HStack {
                Image(systemName: "creditcard")
                    .foregroundColor(.accentColor)
                Text("Session Costs")
                    .font(.headline)
                
                Spacer()
                
                Button(showDetailedBreakdown ? "Compact" : "Detailed") {
                    showDetailedBreakdown.toggle()
                }
                .buttonStyle(.bordered)
                
                // Close button
                Button(action: { isVisible = false }) {
                    Image(systemName: "xmark")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help("Close Cost Tracking")
            }
            
            if let stats = costStats {
                if showDetailedBreakdown {
                    detailedCostView(stats)
                } else {
                    compactCostView(stats)
                }
            } else {
                noCostDataView
            }
        }
        .padding()
        .background(Color.secondary.opacity(0.1))
        .cornerRadius(8)
        .onAppear {
            // Fetch fresh billing data when panel appears
            Task {
                await ensureBillingDataLoaded()
                refreshCostStats()
            }
        }
        .onChange(of: performanceMonitor.recentMetrics.count) { _, _ in
            refreshCostStats()
        }
        .onChange(of: performanceMonitor.currentMetrics?.id) { _, _ in
            // Refresh when a new request completes
            refreshCostStats()
        }
        .onReceive(Timer.publish(every: 2.0, on: .main, in: .common).autoconnect()) { _ in
            // Periodic refresh for duration updates
            if isVisible {
                refreshCostStats()
            }
        }
    }
    
    // MARK: - Billing Data
    
    /// Ensure billing data is loaded from the API
    private func ensureBillingDataLoaded() async {
        guard !isRefreshingBilling else { return }
        isRefreshingBilling = true
        defer { isRefreshingBilling = false }
        
        do {
            // Trigger fresh fetch of model capabilities (includes billing data)
            _ = try await endpointManager.getGitHubCopilotModelCapabilities()
            logger.debug("Refreshed billing data for cost tracking")
        } catch {
            logger.debug("Could not refresh billing data: \(error.localizedDescription)")
        }
    }
    
    // MARK: - Compact View
    
    private func compactCostView(_ stats: SessionCostStatistics) -> some View {
        HStack(spacing: 16) {
            costCard("Requests", "\(stats.totalRequests)")
            costCard("Tokens", formatTokenCount(stats.totalTokens))
            
            if stats.premiumRequestsUsed > 0 {
                costCard("Premium", "\(stats.premiumRequestsUsed)", color: .orange)
            }
            
            if stats.freeRequestsUsed > 0 {
                costCard("Free", "\(stats.freeRequestsUsed)", color: .green)
            }
            
            // Session duration
            let duration = Date().timeIntervalSince(stats.sessionStartTime)
            costCard("Duration", formatDuration(duration))
        }
    }
    
    // MARK: - Detailed View
    
    private func detailedCostView(_ stats: SessionCostStatistics) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            // Summary row
            summarySection(stats)
            
            // Per-model breakdown
            if !stats.modelBreakdown.isEmpty {
                modelBreakdownSection(stats.modelBreakdown)
            }
        }
    }
    
    private func summarySection(_ stats: SessionCostStatistics) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Session Summary")
                .font(.subheadline)
                .fontWeight(.semibold)
            
            LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 4), spacing: 12) {
                detailedCostCard("Total Requests", "\(stats.totalRequests)")
                detailedCostCard("Input Tokens", formatTokenCount(stats.totalInputTokens))
                detailedCostCard("Output Tokens", formatTokenCount(stats.totalOutputTokens))
                detailedCostCard("Total Tokens", formatTokenCount(stats.totalTokens))
            }
            
            // Premium vs Free breakdown
            if stats.premiumRequestsUsed > 0 || stats.freeRequestsUsed > 0 {
                HStack(spacing: 16) {
                    if stats.premiumRequestsUsed > 0 {
                        HStack(spacing: 4) {
                            Circle()
                                .fill(Color.orange)
                                .frame(width: 8, height: 8)
                            Text("Premium: \(stats.premiumRequestsUsed)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    if stats.freeRequestsUsed > 0 {
                        HStack(spacing: 4) {
                            Circle()
                                .fill(Color.green)
                                .frame(width: 8, height: 8)
                            Text("Free: \(stats.freeRequestsUsed)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    
                    Spacer()
                    
                    // Session duration
                    let duration = Date().timeIntervalSince(stats.sessionStartTime)
                    Text("Session: \(formatDuration(duration))")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding()
        .background(Color.blue.opacity(0.1))
        .cornerRadius(8)
    }
    
    private func modelBreakdownSection(_ breakdown: [SessionCostSummary]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Per-Model Breakdown")
                .font(.subheadline)
                .fontWeight(.semibold)
            
            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(breakdown) { summary in
                        modelRow(summary)
                    }
                }
            }
            .frame(maxHeight: 200)
        }
        .padding()
        .background(Color.purple.opacity(0.1))
        .cornerRadius(8)
    }
    
    private func modelRow(_ summary: SessionCostSummary) -> some View {
        HStack(spacing: 8) {
            // Premium/Free indicator
            Circle()
                .fill(summary.isPremium ? Color.orange : Color.green)
                .frame(width: 8, height: 8)
            
            // Model name
            Text(summary.model)
                .font(.caption)
                .fontWeight(.medium)
                .lineLimit(1)
            
            Spacer()
            
            // Request count
            Text("\(summary.requestCount) req")
                .font(.caption)
                .foregroundColor(.secondary)
            
            // Token count
            Text(formatTokenCount(summary.totalTokens))
                .font(.caption)
                .foregroundColor(.secondary)
            
            // Multiplier if premium
            if summary.isPremium, let multiplier = summary.premiumMultiplier {
                Text("\(String(format: "%.1f", multiplier))x")
                    .font(.caption)
                    .foregroundColor(.orange)
                    .padding(.horizontal, 4)
                    .background(Color.orange.opacity(0.2))
                    .cornerRadius(4)
            }
        }
        .padding(.vertical, 4)
    }
    
    private var noCostDataView: some View {
        HStack {
            Text("No API requests yet this session")
                .foregroundColor(.secondary)
            Spacer()
        }
    }
    
    // MARK: - Helper Views
    
    private func costCard(_ title: String, _ value: String, color: Color = .primary) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.system(.title3, design: .monospaced))
                .fontWeight(.bold)
                .foregroundColor(color)
            Text(title)
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .frame(minWidth: 60)
    }
    
    private func detailedCostCard(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundColor(.secondary)
            Text(value)
                .font(.system(.body, design: .monospaced))
                .fontWeight(.medium)
        }
        .padding(.vertical, 4)
    }
    
    // MARK: - Helpers
    
    private func refreshCostStats() {
        costStats = performanceMonitor.generateSessionCostStatistics { model in
            // Try to get billing info from EndpointManager
            if let billing = endpointManager.getGitHubCopilotModelBillingInfo(modelId: model) {
                return billing
            }
            
            // Fallback: Infer premium status from model name patterns
            // Known premium models have multipliers, free models are explicitly 0x
            let lowercasedModel = model.lowercased()
            
            // Claude models are premium
            if lowercasedModel.contains("claude") {
                // Claude Haiku is 0.33x, Sonnet is 0.33x, Opus would be higher
                if lowercasedModel.contains("haiku") {
                    return (isPremium: true, multiplier: 0.33)
                } else if lowercasedModel.contains("sonnet") {
                    return (isPremium: true, multiplier: 0.33)
                }
                return (isPremium: true, multiplier: 1.0)
            }
            
            // GPT-4.5 is premium
            if lowercasedModel.contains("gpt-4.5") {
                return (isPremium: true, multiplier: 4.0)
            }
            
            // o1/o3 models are premium (reasoning models)
            if lowercasedModel.hasPrefix("o1") || lowercasedModel.hasPrefix("o3") {
                return (isPremium: true, multiplier: 1.0)
            }
            
            // GPT-4.1 and most others are free (0x)
            if lowercasedModel.contains("gpt-4.1") || lowercasedModel.contains("gpt-4o") {
                return (isPremium: false, multiplier: 0.0)
            }
            
            // Default: assume free if not recognized
            return nil
        }
    }
    
    private func formatTokenCount(_ count: Int) -> String {
        if count >= 1_000_000 {
            return String(format: "%.1fM", Double(count) / 1_000_000)
        } else if count >= 1000 {
            return String(format: "%.1fK", Double(count) / 1000)
        }
        return "\(count)"
    }
    
    private func formatDuration(_ interval: TimeInterval) -> String {
        let minutes = Int(interval) / 60
        let seconds = Int(interval) % 60
        
        if minutes >= 60 {
            let hours = minutes / 60
            let mins = minutes % 60
            return "\(hours)h \(mins)m"
        } else if minutes > 0 {
            return "\(minutes)m \(seconds)s"
        } else {
            return "\(seconds)s"
        }
    }
}

// MARK: - Preview

#if DEBUG
struct CostTrackingView_Previews: PreviewProvider {
    static var previews: some View {
        CostTrackingView(
            performanceMonitor: PerformanceMonitor(),
            isVisible: .constant(true)
        )
        .frame(width: 500)
        .padding()
    }
}
#endif
