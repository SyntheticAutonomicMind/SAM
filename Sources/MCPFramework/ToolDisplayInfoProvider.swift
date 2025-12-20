// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

/// ToolDisplayInfoProvider.swift MCPFramework Created on October 26, 2025.

import Foundation

/// Protocol for tools to provide their own display information for user-facing progress messages.
public protocol ToolDisplayInfoProvider {
    /// Extract human-readable display information from tool arguments.
    static func extractDisplayInfo(from arguments: [String: Any]) -> String?

    /// Extract structured details for tool card display.
    static func extractToolDetails(from arguments: [String: Any]) -> [String]?

    /// Optional: Get the tool's name for display purposes.
    static var displayName: String { get }
}

/// Default implementation for displayName and extractToolDetails.
public extension ToolDisplayInfoProvider {
    static var displayName: String {
        return String(describing: Self.self)
            .replacingOccurrences(of: "Tool", with: "")
            .replacingOccurrences(of: "Operations", with: "")
    }

    /// Default implementation returns nil - tools must opt-in to structured details.
    static func extractToolDetails(from arguments: [String: Any]) -> [String]? {
        return nil
    }
}

/// Registry for tools that provide display information.
public class ToolDisplayInfoRegistry {
    /// Singleton instance.
    public nonisolated(unsafe) static let shared = ToolDisplayInfoRegistry()

    /// Map of tool name → display info provider.
    private var providers: [String: any ToolDisplayInfoProvider.Type] = [:]

    private init() {}

    /// Register a tool as a display info provider.
    public func register(_ toolName: String, provider: any ToolDisplayInfoProvider.Type) {
        providers[toolName] = provider
    }

    /// Get display info for a tool call.
    public func getDisplayInfo(for toolName: String, arguments: [String: Any]) -> String? {
        guard let provider = providers[toolName] else {
            return nil
        }
        return provider.extractDisplayInfo(from: arguments)
    }

    /// Get structured tool details for a tool call.
    public func getToolDetails(for toolName: String, arguments: [String: Any]) -> [String]? {
        guard let provider = providers[toolName] else {
            return nil
        }
        return provider.extractToolDetails(from: arguments)
    }

    /// Check if a tool has a registered display info provider.
    public func hasProvider(for toolName: String) -> Bool {
        return providers[toolName] != nil
    }
}
