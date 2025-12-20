// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import Foundation
import Logging

/// Web content extractor for clean text and metadata extraction from web pages Uses HTTP requests and HTML parsing with robots.txt compliance.
public class WebContentExtractor {
    private let logger = Logger(label: "com.sam.web.ContentExtractor")
    private let robotsChecker = RobotsChecker()
    private let session: URLSession

    public init() {
        /// Use ephemeral configuration to prevent keychain prompts URLSessionConfiguration.default triggers "SAM WebCrypto Master Key" keychain prompt Solution: Use .ephemeral which disables credential storage completely.
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30.0
        config.timeoutIntervalForResource = 60.0
        config.httpMaximumConnectionsPerHost = 4
        config.urlCredentialStorage = nil
        self.session = URLSession(configuration: config)
    }

    /// Extract structured content from a web page URL.
    public func extractContent(from url: URL) async throws -> WebPageContent {
        logger.debug("Extracting content from: \(url.absoluteString)")

        /// Step 1: Validate URL access and check robots.txt.
        try await validateURLAccess(url)

        /// Step 2: Fetch raw HTML content.
        let htmlContent = try await fetchHTMLContent(from: url)

        /// Step 3: Parse and extract structured content.
        let extractedContent = try parseHTMLContent(htmlContent, sourceURL: url)

        /// Step 4: Clean and structure the content.
        let cleanedContent = cleanExtractedContent(extractedContent)

        /// Step 5: Generate content summary.
        let summary = generateContentSummary(cleanedContent.text)

        let webPageContent = WebPageContent(
            url: url,
            title: extractedContent.title,
            content: cleanedContent.text,
            summary: summary,
            metadata: extractedContent.metadata
        )

        logger.debug("Successfully extracted \(cleanedContent.text.count) characters from: \(url.host ?? "unknown")")
        return webPageContent
    }

    // MARK: - Helper Methods

    private func validateURLAccess(_ url: URL) async throws {
        /// Check robots.txt compliance.
        let isAllowed = try await robotsChecker.canAccess(url: url, userAgent: "SAM-Research-Bot/1.0")

        guard isAllowed else {
            logger.warning("Access blocked by robots.txt: \(url)")
            throw WebResearchError.robotsBlocked(url)
        }
    }

    private func fetchHTMLContent(from url: URL) async throws -> String {
        var request = URLRequest(url: url)

        /// Set appropriate headers - Use standard browser User-Agent to avoid bot blocking Many websites (Yelp, Petco, etc.) return 403 when they detect "Bot" in User-Agent We still respect robots.txt via robotsChecker.canAccess() before fetching.
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
                        forHTTPHeaderField: "User-Agent")
        request.setValue("text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
                        forHTTPHeaderField: "Accept")
        request.setValue("gzip, deflate, br",
                        forHTTPHeaderField: "Accept-Encoding")
        request.setValue("en-US,en;q=0.9",
                        forHTTPHeaderField: "Accept-Language")

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw WebResearchError.httpError(response)
        }

        guard 200...299 ~= httpResponse.statusCode else {
            logger.error("HTTP error \(httpResponse.statusCode) for: \(url)")
            throw WebResearchError.httpError(response)
        }

        /// Detect text encoding.
        let encoding = detectTextEncoding(from: data, response: httpResponse)

        guard let htmlString = String(data: data, encoding: encoding) else {
            throw WebResearchError.contentExtractionFailed(url)
        }

        return htmlString
    }

    private func parseHTMLContent(_ html: String, sourceURL: URL) throws -> ExtractedContent {
        let parser = HTMLContentParser()

        return ExtractedContent(
            title: parser.extractTitle(from: html),
            text: parser.extractMainText(from: html),
            headings: parser.extractHeadings(from: html),
            links: parser.extractLinks(from: html, baseURL: sourceURL),
            metadata: parser.extractMetadata(from: html)
        )
    }

    private func cleanExtractedContent(_ content: ExtractedContent) -> ExtractedContent {
        /// Clean and normalize the extracted text.
        var cleanText = content.text

        /// Remove excessive whitespace.
        cleanText = cleanText.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)

        /// Remove common web artifacts.
        cleanText = cleanText.replacingOccurrences(of: "\\[\\d+\\]", with: "", options: .regularExpression)
        cleanText = cleanText.replacingOccurrences(of: "\\bClick here\\b", with: "", options: .regularExpression)
        cleanText = cleanText.replacingOccurrences(of: "\\bRead more\\b", with: "", options: .regularExpression)

        /// Trim and normalize.
        cleanText = cleanText.trimmingCharacters(in: .whitespacesAndNewlines)

        return ExtractedContent(
            title: content.title.trimmingCharacters(in: .whitespacesAndNewlines),
            text: cleanText,
            headings: content.headings.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) },
            links: content.links,
            metadata: content.metadata
        )
    }

    private func generateContentSummary(_ text: String) -> String {
        /// Generate a concise summary of the content.
        let sentences = text.components(separatedBy: ". ")
        let importantSentences = sentences.filter { sentence in
            sentence.count > 20 && sentence.count < 150
        }

        /// Take first few important sentences as summary.
        let summaryLength = min(3, importantSentences.count)
        let summary = Array(importantSentences.prefix(summaryLength)).joined(separator: ". ")

        return summary.isEmpty ? String(text.prefix(200)) : summary
    }

    private func detectTextEncoding(from data: Data, response: HTTPURLResponse) -> String.Encoding {
        /// Try to detect encoding from Content-Type header.
        if let contentType = response.value(forHTTPHeaderField: "Content-Type") {
            let charsetRegex = try! NSRegularExpression(pattern: "charset=([^;\\s]+)", options: .caseInsensitive)
            let range = NSRange(location: 0, length: contentType.count)

            if let match = charsetRegex.firstMatch(in: contentType, options: [], range: range) {
                let charsetRange = Range(match.range(at: 1), in: contentType)!
                let charset = String(contentType[charsetRange]).lowercased()

                switch charset {
                case "utf-8", "utf8":
                    return .utf8

                case "iso-8859-1", "latin1":
                    return .isoLatin1

                case "windows-1252":
                    return .windowsCP1252

                default:
                    break
                }
            }
        }

        /// Fallback: try UTF-8, then other common encodings.
        if String(data: data, encoding: .utf8) != nil {
            return .utf8
        } else if String(data: data, encoding: .isoLatin1) != nil {
            return .isoLatin1
        } else {
            return .ascii
        }
    }
}

// MARK: - HTML Content Parser

/// HTML parser for extracting structured content from web pages.
public class HTMLContentParser {

    /// Extract page title from HTML.
    public func extractTitle(from html: String) -> String {
        /// Try to extract from <title> tag.
        if let titleRange = html.range(of: "<title[^>]*>([^<]+)</title>", options: .regularExpression) {
            let titleMatch = String(html[titleRange])
            let title = titleMatch.replacingOccurrences(of: "<title[^>]*>", with: "", options: .regularExpression)
                                  .replacingOccurrences(of: "</title>", with: "")
            return title.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        /// Fallback to og:title or h1.
        if let ogTitle = extractMetaProperty(from: html, property: "og:title") {
            return ogTitle
        }

        if let h1Title = extractFirstHeading(from: html, level: 1) {
            return h1Title
        }

        return "Untitled"
    }

    /// Extract main text content from HTML.
    public func extractMainText(from html: String) -> String {
        var text = html

        /// Remove scripts, styles, and other non-content elements.
        text = removeHTMLElements(text, tags: ["script", "style", "nav", "header", "footer", "aside"])

        /// Remove HTML comments.
        text = text.replacingOccurrences(of: "<!--[\\s\\S]*?-->", with: "", options: .regularExpression)

        /// Remove all HTML tags.
        text = text.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)

        /// Decode HTML entities.
        text = decodeHTMLEntities(text)

        /// Clean up whitespace.
        text = text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)

        return text
    }

    /// Extract headings (h1-h6) from HTML.
    public func extractHeadings(from html: String) -> [String] {
        var headings: [String] = []

        for level in 1...6 {
            let pattern = "<h\(level)[^>]*>([^<]+)</h\(level)>"
            let regex = try! NSRegularExpression(pattern: pattern, options: .caseInsensitive)
            let range = NSRange(location: 0, length: html.count)

            let matches = regex.matches(in: html, options: [], range: range)

            for match in matches {
                if let headingRange = Range(match.range(at: 1), in: html) {
                    let heading = String(html[headingRange]).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !heading.isEmpty {
                        headings.append(heading)
                    }
                }
            }
        }

        return headings
    }

    /// Extract links from HTML.
    public func extractLinks(from html: String, baseURL: URL) -> [URL] {
        var links: [URL] = []

        let linkPattern = "<a[^>]+href=[\"']([^\"']+)[\"'][^>]*>"
        let regex = try! NSRegularExpression(pattern: linkPattern, options: .caseInsensitive)
        let range = NSRange(location: 0, length: html.count)

        let matches = regex.matches(in: html, options: [], range: range)

        for match in matches {
            if let urlRange = Range(match.range(at: 1), in: html) {
                let urlString = String(html[urlRange])

                if let absoluteURL = URL(string: urlString, relativeTo: baseURL) {
                    links.append(absoluteURL)
                }
            }
        }

        return Array(Set(links))
    }

    /// Extract metadata from HTML.
    public func extractMetadata(from html: String) -> [String: String] {
        var metadata: [String: String] = [:]

        /// Extract meta tags.
        let metaPattern = "<meta\\s+([^>]+)>"
        let metaRegex = try! NSRegularExpression(pattern: metaPattern, options: .caseInsensitive)
        let range = NSRange(location: 0, length: html.count)

        let matches = metaRegex.matches(in: html, options: [], range: range)

        for match in matches {
            if let metaRange = Range(match.range(at: 1), in: html) {
                let metaAttributes = String(html[metaRange])

                /// Extract name and content.
                if let name = extractAttribute(from: metaAttributes, attribute: "name"),
                   let content = extractAttribute(from: metaAttributes, attribute: "content") {
                    metadata[name.lowercased()] = content
                }

                /// Extract property and content (for Open Graph).
                if let property = extractAttribute(from: metaAttributes, attribute: "property"),
                   let content = extractAttribute(from: metaAttributes, attribute: "content") {
                    metadata[property.lowercased()] = content
                }
            }
        }

        return metadata
    }

    // MARK: - Helper Methods

    private func removeHTMLElements(_ html: String, tags: [String]) -> String {
        var result = html

        for tag in tags {
            let pattern = "<\(tag)[^>]*>[\\s\\S]*?</\(tag)>"
            result = result.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        }

        return result
    }

    private func decodeHTMLEntities(_ text: String) -> String {
        var result = text

        /// Common HTML entities.
        let entities = [
            "&amp;": "&",
            "&lt;": "<",
            "&gt;": ">",
            "&quot;": "\"",
            "&apos;": "'",
            "&nbsp;": " ",
            "&mdash;": "—",
            "&ndash;": "–",
            "&hellip;": "…"
        ]

        for (entity, replacement) in entities {
            result = result.replacingOccurrences(of: entity, with: replacement)
        }

        /// Decode numeric entities - simplified approach In production, use proper HTML entity decoder.
        result = result.replacingOccurrences(of: "&#\\d+;", with: "", options: .regularExpression)

        return result
    }

    private func extractMetaProperty(from html: String, property: String) -> String? {
        let pattern = "<meta\\s+property=[\"']\(property)[\"']\\s+content=[\"']([^\"']+)[\"'][^>]*>"

        if let range = html.range(of: pattern, options: .regularExpression) {
            let match = String(html[range])

            if let contentRange = match.range(of: "content=[\"']([^\"']+)[\"']", options: .regularExpression) {
                let content = String(match[contentRange])
                    .replacingOccurrences(of: "content=[\"']", with: "")
                    .replacingOccurrences(of: "[\"']", with: "", options: .regularExpression)

                return content.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        return nil
    }

    private func extractFirstHeading(from html: String, level: Int) -> String? {
        let pattern = "<h\(level)[^>]*>([^<]+)</h\(level)>"

        if let range = html.range(of: pattern, options: .regularExpression) {
            let match = String(html[range])

            return match.replacingOccurrences(of: "<h\(level)[^>]*>", with: "", options: .regularExpression)
                       .replacingOccurrences(of: "</h\(level)>", with: "")
                       .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return nil
    }

    private func extractAttribute(from text: String, attribute: String) -> String? {
        let pattern = "\(attribute)=[\"']([^\"']+)[\"']"

        if let range = text.range(of: pattern, options: .regularExpression) {
            let match = String(text[range])

            return match.replacingOccurrences(of: "\(attribute)=[\"']", with: "")
                       .replacingOccurrences(of: "[\"']", with: "", options: .regularExpression)
        }

        return nil
    }
}

// MARK: - Supporting Models

/// Extracted content structure from HTML parsing.
public struct ExtractedContent {
    let title: String
    let text: String
    let headings: [String]
    let links: [URL]
    let metadata: [String: String]
}

// MARK: - Robots.txt Checker

/// Robots.txt compliance checker for respectful web crawling CRITICAL FIX: Made actor for thread-safe cache access during parallel web_operations.
public actor RobotsChecker {
    private let logger = Logger(label: "com.sam.web.RobotsChecker")
    private var robotsCache: [String: RobotsInfo] = [:]
    private let cacheTimeout: TimeInterval = 3600

    /// Use ephemeral URLSession to prevent keychain prompts.
    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.urlCredentialStorage = nil
        return URLSession(configuration: config)
    }()

    /// Check if access is allowed for the given URL and user agent.
    public func canAccess(url: URL, userAgent: String) async throws -> Bool {
        guard let host = url.host else {
            return false
        }

        /// Check cache first.
        if let cachedInfo = robotsCache[host],
           Date().timeIntervalSince(cachedInfo.fetchedAt) < cacheTimeout {
            return isPathAllowed(path: url.path, userAgent: userAgent, robotsInfo: cachedInfo)
        }

        /// Fetch robots.txt.
        let robotsURL = URL(string: "https://\(host)/robots.txt")!

        do {
            let robotsContent = try await fetchRobotsContent(from: robotsURL)
            let robotsInfo = parseRobotsContent(robotsContent)

            /// Cache the result.
            robotsCache[host] = robotsInfo

            return isPathAllowed(path: url.path, userAgent: userAgent, robotsInfo: robotsInfo)

        } catch {
            logger.debug("Could not fetch robots.txt for \(host): \(error)")
            /// If robots.txt is not accessible, assume access is allowed.
            return true
        }
    }

    private func fetchRobotsContent(from url: URL) async throws -> String {
        let (data, response) = try await session.data(from: url)

        guard let httpResponse = response as? HTTPURLResponse,
              200...299 ~= httpResponse.statusCode else {
            throw WebResearchError.httpError(response)
        }

        return String(data: data, encoding: .utf8) ?? ""
    }

    private func parseRobotsContent(_ content: String) -> RobotsInfo {
        var robotsInfo = RobotsInfo()
        let lines = content.components(separatedBy: .newlines)

        var currentUserAgent: String?

        for line in lines {
            let trimmedLine = line.trimmingCharacters(in: .whitespacesAndNewlines)

            if trimmedLine.isEmpty || trimmedLine.hasPrefix("#") {
                continue
            }

            let components = trimmedLine.components(separatedBy: ":").map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
            }

            guard components.count >= 2 else { continue }

            let directive = components[0].lowercased()
            let value = components[1]

            switch directive {
            case "user-agent":
                currentUserAgent = value.lowercased()

            case "disallow":
                if let userAgent = currentUserAgent {
                    if robotsInfo.disallowedPaths[userAgent] == nil {
                        robotsInfo.disallowedPaths[userAgent] = []
                    }
                    robotsInfo.disallowedPaths[userAgent]?.append(value)
                }

            case "allow":
                if let userAgent = currentUserAgent {
                    if robotsInfo.allowedPaths[userAgent] == nil {
                        robotsInfo.allowedPaths[userAgent] = []
                    }
                    robotsInfo.allowedPaths[userAgent]?.append(value)
                }

            case "crawl-delay":
                if let userAgent = currentUserAgent,
                   let delay = Double(value) {
                    robotsInfo.crawlDelays[userAgent] = delay
                }

            default:
                break
            }
        }

        return robotsInfo
    }

    private func isPathAllowed(path: String, userAgent: String, robotsInfo: RobotsInfo) -> Bool {
        let normalizedUserAgent = userAgent.lowercased()

        /// Check specific user agent rules first.
        if let disallowed = robotsInfo.disallowedPaths[normalizedUserAgent] {
            for disallowedPath in disallowed {
                if path.hasPrefix(disallowedPath) {
                    /// Check if there's a more specific allow rule.
                    if let allowed = robotsInfo.allowedPaths[normalizedUserAgent] {
                        for allowedPath in allowed {
                            if path.hasPrefix(allowedPath) && allowedPath.count > disallowedPath.count {
                                return true
                            }
                        }
                    }
                    return false
                }
            }
        }

        /// Check wildcard (*) rules.
        if let disallowed = robotsInfo.disallowedPaths["*"] {
            for disallowedPath in disallowed {
                if path.hasPrefix(disallowedPath) {
                    if let allowed = robotsInfo.allowedPaths["*"] {
                        for allowedPath in allowed {
                            if path.hasPrefix(allowedPath) && allowedPath.count > disallowedPath.count {
                                return true
                            }
                        }
                    }
                    return false
                }
            }
        }

        return true
    }
}

/// Robots.txt parsing result.
private struct RobotsInfo {
    var disallowedPaths: [String: [String]] = [:]
    var allowedPaths: [String: [String]] = [:]
    var crawlDelays: [String: Double] = [:]
    let fetchedAt = Date()
}
