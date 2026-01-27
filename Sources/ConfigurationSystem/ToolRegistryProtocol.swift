// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (c) 2025 Andrew Wyatt - SAM Project

import Foundation

/// Protocol for tool registry implementations that provide tool descriptions
/// Used by system prompt managers and agent orchestrators to discover available tools
public protocol ToolRegistryProtocol: Sendable {
    /// Get tools description from any thread context
    nonisolated func getToolsDescription() -> String
    
    /// Get tools description from main actor context
    @MainActor func getToolsDescriptionMainActor() -> String
}
