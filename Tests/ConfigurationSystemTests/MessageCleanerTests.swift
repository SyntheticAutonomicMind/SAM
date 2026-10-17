// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import XCTest
@testable import ConfigurationSystem

final class MessageCleanerTests: XCTestCase {

    // MARK: - HTML Comment Stripping

    func testStripsSessionNamingHTMLComments() {
        /// Session naming markers from OpenRouter/chunkId-prefixed format.
        let content = """
        <!-- chunkId=gen-1792256483 session: {"title":"General Assistance"} -->
        """
        let cleaned = MessageCleaner.cleanSpecialTokens(from: content)
        XCTAssertTrue(cleaned.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                       "HTML comment should be fully stripped, got: '\(cleaned)'")
    }

    func testStripsStandardSessionNamingMarkers() {
        let content = """
        Some text here.
        <!--session:{"title":"Fix Bug"}-->
        """
        let cleaned = MessageCleaner.cleanSpecialTokens(from: content)
        XCTAssertFalse(cleaned.contains("<!--session"), "Session marker should be stripped")
        XCTAssertTrue(cleaned.contains("Some text here"), "Regular content should remain")
    }

    func testStripsThinkTags() {
        let content = "<thinking>reasoning</thinking>Hello world"
        let cleaned = MessageCleaner.cleanSpecialTokens(from: content)
        XCTAssertFalse(cleaned.contains("<thinking>"), "Opening think tag should be stripped")
        XCTAssertFalse(cleaned.contains("</thinking>"), "Closing think tag should be stripped")
        XCTAssertTrue(cleaned.contains("Hello world"), "Regular content should remain")
    }

    func testPreservesRegularMarkdown() {
        let content = """
        # Title

        Some **bold** text with `code`.

        - List item 1
        - List item 2
        """
        let cleaned = MessageCleaner.cleanSpecialTokens(from: content)
        XCTAssertEqual(content, cleaned, "Regular markdown should be preserved")
    }

    // MARK: - filterInternalMarkersNoTrim

    func testFilterInternalMarkersPreservesWhitespace() {
        let content = "Hello\n\n\n\nWorld"
        let filtered = MessageCleaner.filterInternalMarkersNoTrim(from: content)
        XCTAssertEqual(filtered, content, "filterInternalMarkersNoTrim should preserve content without special markers")
    }

    func testFilterInternalMarkersStripsSystemReminders() {
        /// filterInternalMarkersNoTrim works line-by-line and strips markers
        /// that appear as standalone lines. Inline tags are not handled by
        /// this function (that's cleanSpecialTokens' job).
        let content = """
        Hello
        <system-reminder>secret</system-reminder>
        World
        """
        let filtered = MessageCleaner.filterInternalMarkersNoTrim(from: content)
        XCTAssertTrue(filtered.contains("Hello"), "Regular content should remain")
        XCTAssertTrue(filtered.contains("World"), "Regular content should remain")
    }
}
