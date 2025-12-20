// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import XCTest
import Markdown
@testable import UserInterface

final class UserInterfaceTests: XCTestCase {
    func testMessageBubble() {
        /// Basic test structure - UI testing will be expanded later.
        XCTAssertTrue(true)
    }

    func testOrderedListChunkBoundaryDoesNotMerge() throws {
        let md = """
        1. First step
        2. Second step
        3. Third step

        1. Item one
        1. Item two
        1. Item three
        """

        let parser = MarkdownSemanticParser()
        /// Use a small chunk size to force chunking and simulate boundary conditions.
        let elements = MarkdownChunker.chunkAndParse(md, parser: parser, targetChunkSize: 20)

        /// Collect ordered lists.
        let orderedLists: [[MarkdownListItem]] = elements.compactMap { elem in
            if case .orderedList(let items) = elem { return items }
            return nil
        }

        XCTAssertEqual(orderedLists.count, 2, "Expected two separate ordered lists after chunked parsing")
        XCTAssertEqual(orderedLists[0].first?.originalNumber, 1)
        XCTAssertEqual(orderedLists[1].first?.originalNumber, 1)
    }

    func testListItemTitleAndDescriptionPreserved() throws {
        let md = """
        1. Orlando Community Events This Weekend
        A roundup of art fairs, music festivals, and family activities happening across the Orlando metro area this weekend.
        Read more
        """

        let parser = MarkdownSemanticParser()
        let elements = parser.parseMarkdown(md)

        /// Find the first ordered list element.
        guard let firstList = elements.first(where: { elem in
            if case .orderedList = elem { return true }
            return false
        }) else {
            XCTFail("No ordered list found in parsed elements")
            return
        }

        if case .orderedList(let items) = firstList {
            guard let firstItem = items.first else {
                XCTFail("Ordered list has no items")
                return
            }

            /// Convert attributed text to a plain string and ensure it contains a newline.
            let plain = String(firstItem.text.characters)
            XCTAssertTrue(plain.contains("\n"), "Expected a newline between title and description, got: \(plain)")
        } else {
            XCTFail("First list element was not an ordered list")
        }
    }

    func testSanitizeEmphasisTrailingSpaces() throws {
        let input = "This is **header: ** followed by text"
        // Ensure sanitizer transforms input to remove the trailing space before closing delimiters
        let sanitized = MarkdownASTRenderer.sanitizeEmphasisTrailingSpaces(in: input)

        XCTAssertTrue(sanitized.contains("**header:**") || sanitized.contains("**header:***"), "Sanitizer did not normalize trailing space: \(sanitized)")

        // Also verify that parsing the sanitized text yields a Strong node for the emphasized portion
        let doc = Document(parsing: sanitized)
        var foundStrong = false

        func walk(_ node: Markup) {
            if node is Strong { foundStrong = true }
            if let container = node as? BlockMarkup {
                for child in container.children { walk(child) }
            } else if let container = node as? InlineMarkup {
                for child in container.children { walk(child) }
            }
        }

        walk(doc)
        XCTAssertTrue(foundStrong, "Expected a Strong node after parsing sanitized markdown")
    }
}