// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import Foundation
import SwiftUI
import Logging

/// Production-grade MarkdownProcessor for SAM using custom markdown implementation Zero third-party dependencies - full control over markdown rendering and styling.
class MarkdownProcessor {
    private let logger = Logger(label: "com.sam.ui.MarkdownProcessor")

    /// Process markdown text with visual indicators for status markers - Parameter markdown: Raw markdown text from AI responses - Returns: Markdown string with visual indicators added.
    func processMarkdown(_ markdown: String) -> String {
        logger.debug("Processing markdown content: \(markdown.prefix(50))...")

        /// Add visual indicators to status markers.
        let markdownWithIndicators = addVisualIndicators(markdown)

        logger.debug("Markdown processing completed successfully")
        return markdownWithIndicators
    }

    /// Add visual indicators (Unicode symbols) to status markers Replaces text-only markers with symbols for better visual feedback - Parameter markdown: Raw markdown with status markers (SUCCESS:, ERROR:, etc.) - Returns: Markdown with visual indicators added.
    private func addVisualIndicators(_ markdown: String) -> String {
        var result = markdown

        /// Replace status markers with Unicode symbols Using Unicode box drawing characters and symbols that render consistently.
        result = result.replacingOccurrences(of: "SUCCESS:", with: "SUCCESS:")
        result = result.replacingOccurrences(of: "ERROR:", with: "")
        result = result.replacingOccurrences(of: "WARNING:", with: "")
        result = result.replacingOccurrences(of: "INFO:", with: "→")

        return result
    }
}
