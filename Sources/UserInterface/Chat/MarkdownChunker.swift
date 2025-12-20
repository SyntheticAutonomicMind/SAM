// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import Foundation
import Logging

/// Helper that splits very large markdown text into safe chunks, parses each chunk with an existing MarkdownSemanticParser, and merges the resulting elements.
struct MarkdownChunker {
    private static let logger = Logger(label: "com.sam.ui.MarkdownChunker")

    /// Chunk and parse markdown text using the provided parser.
    static func chunkAndParse(
        _ markdown: String,
        parser: MarkdownSemanticParser,
        targetChunkSize: Int = 200_000
    ) -> [MarkdownElement] {
        /// Fast path for small content.
        if markdown.count <= targetChunkSize {
            return parser.parseMarkdown(markdown)
        }

        /// Pre-scan for reference definitions and footnotes to prepend to each chunk.
        var defLines: [String] = []
        var otherLines: [String] = []

        let lines = markdown.components(separatedBy: .newlines)

    /// Regex for reference definitions and footnotes.
    let refDefRegex = try? NSRegularExpression(pattern: "^\\s*\\[[^\\]]+\\]:\\s+.+$")
    let footnoteDefRegex = try? NSRegularExpression(pattern: "^\\s*\\[\\^[^\\]]+\\]:\\s+.+$")

        for line in lines {
            let ns = line as NSString
            let range = NSRange(location: 0, length: ns.length)
            if let r = refDefRegex, r.firstMatch(in: line, range: range) != nil {
                defLines.append(line)
            } else if let f = footnoteDefRegex, f.firstMatch(in: line, range: range) != nil {
                defLines.append(line)
            } else {
                otherLines.append(line)
            }
        }

        /// Build chunks from otherLines, avoiding splitting inside fenced code blocks.
        var chunks: [[String]] = []
        var currentChunk: [String] = []
        var currentSize = 0
        var inFence = false

        func flushChunk() {
            if !currentChunk.isEmpty {
                chunks.append(currentChunk)
                currentChunk = []
                currentSize = 0
            }
        }

        for line in otherLines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            /// Toggle fenced code state simply on lines starting with ```.
            if trimmed.hasPrefix("```") {
                inFence.toggle()
            }

            currentChunk.append(line)
            currentSize += line.count + 1

            if currentSize >= targetChunkSize && !inFence {
                /// Try to backtrack to a safe boundary: blank line or header.
                var cutIndex = currentChunk.count - 1
                while cutIndex > 0 {
                    let candidate = currentChunk[cutIndex].trimmingCharacters(in: .whitespaces)
                    if candidate.isEmpty || candidate.hasPrefix("#") {
                        break
                    }
                    cutIndex -= 1
                }

                if cutIndex <= 0 {
                    /// No safe boundary found; just flush at current size.
                    flushChunk()
                } else {
                    /// Move remainder lines to next chunk.
                    let remainder = Array(currentChunk[(cutIndex+1)...])
                    currentChunk = Array(currentChunk[0...cutIndex])
                    flushChunk()
                    currentChunk = remainder
                    currentSize = remainder.joined(separator: "\n").count
                }
            }
        }

        flushChunk()

        /// Parse each chunk, prepending defLines so references resolve.
        var allElements: [MarkdownElement] = []

        for (index, chunkLines) in chunks.enumerated() {
            var chunkText = ""
            if !defLines.isEmpty {
                chunkText += defLines.joined(separator: "\n") + "\n\n"
            }
            chunkText += chunkLines.joined(separator: "\n")

            let parsed = parser.parseMarkdown(chunkText)

            /// Merge parsed into allElements with simple list-merging.
            if !allElements.isEmpty, let last = allElements.last, let first = parsed.first {
                /// Determine whether chunks were adjacent (no blank/header separator).
                var shouldMergeAcrossBoundary = true
                if index > 0 {
                    let prevChunk = chunks[index - 1]
                    if let lastLine = prevChunk.last {
                        let trimmedLast = lastLine.trimmingCharacters(in: .whitespaces)
                        /// If the previous chunk ended with an empty line or a header, treat as a separator.
                        if trimmedLast.isEmpty || trimmedLast.hasPrefix("#") {
                            shouldMergeAcrossBoundary = false
                        }
                    }
                }

                if shouldMergeAcrossBoundary {
                    switch (last, first) {
                    case (.orderedList(let aItems), .orderedList(let bItems)):
                        var merged = aItems
                        merged.append(contentsOf: bItems)
                        allElements.removeLast()
                        allElements.append(.orderedList(items: merged))
                        /// append remaining parsed elements after the first.
                        if parsed.count > 1 {
                            allElements.append(contentsOf: parsed.dropFirst())
                        }
                        continue
                    case (.unorderedList(let aItems), .unorderedList(let bItems)):
                        var merged = aItems
                        merged.append(contentsOf: bItems)
                        allElements.removeLast()
                        allElements.append(.unorderedList(items: merged))
                        if parsed.count > 1 {
                            allElements.append(contentsOf: parsed.dropFirst())
                        }
                        continue
                    default:
                        break
                    }
                }
            }

            allElements.append(contentsOf: parsed)
        }

        return allElements
    }
}
