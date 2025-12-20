// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import Foundation
import Logging

/// Scans workspace for AI assistant instruction files and creates system prompt configurations Supports: GitHub Copilot, Cursor, Aider, Windsurf, Cline, and generic AI instructions.
public class AIInstructionsScanner {
    private let logger = Logger(label: "com.sam.config.AIInstructionsScanner")

    /// Cache to avoid repeated file system scans
    private var cachedResults: [String: [DetectedAIInstructions]] = [:]
    private var cacheTimestamps: [String: Date] = [:]
    private let cacheExpirationSeconds: TimeInterval = 5.0

    /// Known AI instruction file patterns.
    private let instructionFilePatterns: [(name: String, paths: [String])] = [
        ("GitHub Copilot Instructions", [".github/copilot-instructions.md"]),
        ("Cursor Rules", [".cursorrules"]),
        ("Aider Instructions", [".aider.md", "aider_rules.md"]),
        ("Windsurf Rules", [".windsurfrules"]),
        ("Cline Rules", [".clinerules"]),
        ("Generic AI Instructions", [".ai-instructions.md", "AI_INSTRUCTIONS.md"])
    ]

    /// Scan workspace directory for AI instruction files - Parameter workspacePath: Path to workspace root directory - Returns: Array of detected instruction file configurations.
    public func scanWorkspace(at workspacePath: URL) -> [DetectedAIInstructions] {
        let cachePath = workspacePath.path

        /// Check if we have a recent cached result
        if let cachedTimestamp = cacheTimestamps[cachePath],
           let cached = cachedResults[cachePath],
           Date().timeIntervalSince(cachedTimestamp) < cacheExpirationSeconds {
            return cached
        }

        var detected: [DetectedAIInstructions] = []

        logger.info("Scanning workspace for AI instruction files: \(workspacePath.path)")

        for pattern in instructionFilePatterns {
            for relativePath in pattern.paths {
                let fullPath = workspacePath.appendingPathComponent(relativePath)

                if FileManager.default.fileExists(atPath: fullPath.path) {
                    do {
                        let content = try String(contentsOf: fullPath, encoding: .utf8)
                        let instructions = DetectedAIInstructions(
                            name: pattern.name,
                            filePath: relativePath,
                            fullPath: fullPath,
                            content: content
                        )
                        detected.append(instructions)
                        logger.info("Found AI instructions: \(pattern.name) at \(relativePath)")
                    } catch {
                        logger.error("Failed to read \(relativePath): \(error)")
                    }
                }
            }
        }

        logger.info("Detected \(detected.count) AI instruction files")

        /// Update cache
        cachedResults[cachePath] = detected
        cacheTimestamps[cachePath] = Date()

        return detected
    }

    /// Clear cache for a specific workspace or all workspaces
    public func clearCache(for workspacePath: URL? = nil) {
        if let workspacePath = workspacePath {
            let cachePath = workspacePath.path
            cachedResults.removeValue(forKey: cachePath)
            cacheTimestamps.removeValue(forKey: cachePath)
        } else {
            cachedResults.removeAll()
            cacheTimestamps.removeAll()
        }
    }
}

/// Represents a detected AI instructions file.
public struct DetectedAIInstructions: Identifiable {
    public let id = UUID()
    public let name: String
    public let filePath: String
    public let fullPath: URL
    public let content: String

    /// Convert to SystemPromptConfiguration.
    public func toSystemPromptConfiguration() -> SystemPromptConfiguration {
        return SystemPromptConfiguration(
            id: id,
            name: name,
            description: "Automatically detected from workspace: \(filePath)",
            isDefault: false,
            source: .workspace,
            components: [
                SystemPromptComponent(
                    title: name,
                    content: content,
                    isEnabled: true,
                    order: 0
                )
            ]
        )
    }
}
