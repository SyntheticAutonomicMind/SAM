// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import Foundation
import Logging

/// MCP Tool for fetching webpage content Downloads and extracts main content from web pages.
public class FetchWebpageTool: MCPTool, @unchecked Sendable {
    private let logger = Logger(label: "com.sam.tools.fetch_webpage")

    /// Use ephemeral URLSession to prevent keychain prompts URLSession.shared triggers "SAM WebCrypto Master Key" keychain dialog.
    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30.0
        config.timeoutIntervalForResource = 60.0
        config.urlCredentialStorage = nil
        return URLSession(configuration: config)
    }()

    public let name = "fetch_webpage"
    public let description = "Fetches the main content from a web page. This tool is useful for summarizing or analyzing the content of a webpage. You should use this tool when you think the user is looking for information from a specific webpage."

    public var parameters: [String: MCPToolParameter] {
        return [
            "urls": MCPToolParameter(
                type: .array,
                description: "URLs to fetch",
                required: true,
                arrayElementType: .string
            ),
            "query": MCPToolParameter(
                type: .string,
                description: "Content description (for filtering/context)",
                required: true
            )
        ]
    }

    public init() {}

    public func initialize() async throws {}

    public func execute(parameters: [String: Any], context: MCPExecutionContext) async -> MCPToolResult {
        /// Extract parameters.
        guard let urls = parameters["urls"] as? [String], !urls.isEmpty else {
            return MCPToolResult(
                toolName: name,
                success: false,
                output: MCPOutput(content: """
                    ERROR: Missing or empty 'urls' parameter

                    Required parameter: urls (array of strings)
                    Example: {"urls": ["https://example.com/article"]}

                    You provided: \(parameters["urls"] ?? "nothing")
                    """)
            )
        }

        /// IMPROVED ERROR: Check if query parameter exists first, then check if empty.
        guard let query = parameters["query"] as? String else {
            return MCPToolResult(
                toolName: name,
                success: false,
                output: MCPOutput(content: """
                    ERROR: Missing 'query' parameter

                    Required parameter: query (string, describes what content you're looking for)
                    Example: {"query": "latest news headlines"}

                    You provided: \(parameters["query"] ?? "nothing")

                    TIP: The query parameter helps contextualize what information to extract from the page.
                    """)
            )
        }

        guard !query.isEmpty else {
            return MCPToolResult(
                toolName: name,
                success: false,
                output: MCPOutput(content: """
                    ERROR: Parameter 'query' cannot be empty

                    The query parameter must contain a description of what you're looking for.
                    Example: "latest news headlines", "product specifications", "article content"

                    You provided: "" (empty string)

                    TIP: Describe what content you want to extract from the page.
                    """)
            )
        }

        /// Fetch the first URL from the provided list.
        let urlString = urls[0]

        guard let url = URL(string: urlString) else {
            return MCPToolResult(
                toolName: name,
                success: false,
                output: MCPOutput(content: "Invalid URL: \(urlString)")
            )
        }

        logger.debug("Fetching webpage: \(urlString)")

        do {
            /// Fetch the webpage using ephemeral session (no credential prompts).
            var request = URLRequest(url: url)
            request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/91.0.4472.124 Safari/537.36", forHTTPHeaderField: "User-Agent")
            request.timeoutInterval = 30.0

            let (data, response) = try await session.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse,
                  200...299 ~= httpResponse.statusCode else {
                let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
                return MCPToolResult(
                    toolName: name,
                    success: false,
                    output: MCPOutput(content: "HTTP error: \(statusCode)")
                )
            }

            /// Convert to string.
            guard let html = String(data: data, encoding: .utf8) else {
                return MCPToolResult(
                    toolName: name,
                    success: false,
                    output: MCPOutput(content: "Failed to decode webpage content")
                )
            }

            /// Extract title (simple regex approach).
            let title = extractTitle(from: html)

            /// Simple HTML stripping (remove tags).
            let content = stripHTMLTags(from: html)

            /// Trim whitespace and limit length.
            let trimmedContent = content
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .components(separatedBy: .whitespacesAndNewlines)
                .filter { !$0.isEmpty }
                .joined(separator: " ")

            /// Limit content length to avoid overwhelming output.
            let maxLength = 10000
            let finalContent = String(trimmedContent.prefix(maxLength))

            let result: [String: Any] = [
                "success": true,
                "url": urlString,
                "title": title,
                "content": finalContent,
                "length": finalContent.count,
                "query": query
            ]

            guard let jsonData = try? JSONSerialization.data(withJSONObject: result, options: .prettyPrinted),
                  let jsonString = String(data: jsonData, encoding: .utf8) else {
                return MCPToolResult(
                    toolName: name,
                    success: false,
                    output: MCPOutput(content: "Failed to encode result")
                )
            }

            logger.debug("Successfully fetched webpage: \(urlString) (\(finalContent.count) chars)")

            return MCPToolResult(
                toolName: name,
                success: true,
                output: MCPOutput(content: jsonString, mimeType: "application/json")
            )

        } catch {
            logger.error("Failed to fetch webpage: \(error)")
            return MCPToolResult(
                toolName: name,
                success: false,
                output: MCPOutput(content: "Failed to fetch webpage: \(error.localizedDescription)")
            )
        }
    }

    public func validateParameters(_ parameters: [String: Any]) throws -> Bool {
        guard let urls = parameters["urls"] as? [String], !urls.isEmpty else {
            return false
        }
        guard let query = parameters["query"] as? String, !query.isEmpty else {
            return false
        }
        return true
    }

    // MARK: - Helper Methods

    private func extractTitle(from html: String) -> String {
        /// Simple regex to extract <title> content.
        if let range = html.range(of: "<title>(.*?)</title>", options: [.regularExpression, .caseInsensitive]) {
            let titleMatch = String(html[range])
            let cleanTitle = titleMatch
                .replacingOccurrences(of: "<title>", with: "", options: .caseInsensitive)
                .replacingOccurrences(of: "</title>", with: "", options: .caseInsensitive)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return cleanTitle
        }
        return "Untitled"
    }

    private func stripHTMLTags(from html: String) -> String {
        /// Log sample of incoming HTML to understand structure.
        let sampleLength = min(500, html.count)
        let htmlSample = String(html.prefix(sampleLength))
        logger.debug("HTML sample (first \(sampleLength) chars): \(htmlSample)")

        /// Remove script and style tags with their content.
        var cleaned = html
            .replacingOccurrences(of: "<script[^>]*>[\\s\\S]*?</script>", with: "", options: .regularExpression, range: nil)
            .replacingOccurrences(of: "<style[^>]*>[\\s\\S]*?</style>", with: "", options: .regularExpression, range: nil)

        /// Check if HTML contains temperature patterns before tag removal.
        let tempPattern = try? NSRegularExpression(pattern: "\\d+[°F]?\\s*[-–—]\\s*\\d+[°F]?", options: [])
        if let regex = tempPattern {
            let matches = regex.matches(in: cleaned, range: NSRange(cleaned.startIndex..., in: cleaned))
            if !matches.isEmpty {
                logger.debug("Found \(matches.count) temperature patterns BEFORE tag removal")
            }
        }

        /// Remove all HTML tags.
        cleaned = cleaned.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression, range: nil)

        /// Check for temperature patterns after tag removal.
        if let regex = tempPattern {
            let matches = regex.matches(in: cleaned, range: NSRange(cleaned.startIndex..., in: cleaned))
            if !matches.isEmpty {
                logger.debug("Found \(matches.count) temperature patterns AFTER tag removal")
            } else {
                logger.warning("Temperature patterns LOST after tag removal - investigating...")
                /// Check if we have numbers without hyphens.
                let numberPattern = try? NSRegularExpression(pattern: "\\d{2}F?\\d{2}F", options: [])
                if let numRegex = numberPattern {
                    let numMatches = numRegex.matches(in: cleaned, range: NSRange(cleaned.startIndex..., in: cleaned))
                    if !numMatches.isEmpty {
                        logger.error("Found \(numMatches.count) merged number patterns (e.g., '7282F') - hyphens were stripped!")
                    }
                }
            }
        }

        /// Decode HTML entities (basic ones).
        cleaned = cleaned
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            /// Decode hyphen entities (bug fix for missing hyphens in scraped content) Websites often encode hyphens as HTML entities which were being left as-is.
            .replacingOccurrences(of: "&#45;", with: "-")
            .replacingOccurrences(of: "&#x2D;", with: "-")
            .replacingOccurrences(of: "&hyphen;", with: "-")
            .replacingOccurrences(of: "&#8209;", with: "-")
            .replacingOccurrences(of: "&#x2011;", with: "-")
            .replacingOccurrences(of: "&ndash;", with: "–")
            .replacingOccurrences(of: "&#8211;", with: "–")
            .replacingOccurrences(of: "&mdash;", with: "—")
            .replacingOccurrences(of: "&#8212;", with: "—")

        /// Final check after entity decoding.
        if let regex = tempPattern {
            let matches = regex.matches(in: cleaned, range: NSRange(cleaned.startIndex..., in: cleaned))
            logger.debug("Found \(matches.count) temperature patterns AFTER entity decoding")
        }

        return cleaned
    }
}
