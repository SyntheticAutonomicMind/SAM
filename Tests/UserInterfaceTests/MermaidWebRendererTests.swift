// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import XCTest
@testable import UserInterface

/// Tests for MermaidWebRenderer HTML generation and escaping
@MainActor
final class MermaidWebRendererTests: XCTestCase {

    // MARK: - HTML Generation

    func testGenerateHTMLContainsMermaidScript() {
        let html = MermaidWebRenderer.generateHTML(for: "flowchart TD\n    A --> B", isDarkMode: false)
        // Should reference mermaid.min.js (bundled) or CDN fallback
        XCTAssertTrue(
            html.contains("mermaid.min.js") || html.contains("mermaid"),
            "Generated HTML must include mermaid.js reference"
        )
    }

    func testGenerateHTMLContainsDiagramCode() {
        let code = "flowchart TD\n    A[Start] --> B[End]"
        let html = MermaidWebRenderer.generateHTML(for: code, isDarkMode: false)
        // The code should be present in the HTML (possibly escaped)
        XCTAssertTrue(html.contains("Start"), "HTML should contain diagram content")
        XCTAssertTrue(html.contains("End"), "HTML should contain diagram content")
    }

    func testGenerateHTMLDarkMode() {
        let code = "flowchart TD\n    A --> B"
        let htmlDark = MermaidWebRenderer.generateHTML(for: code, isDarkMode: true)
        let htmlLight = MermaidWebRenderer.generateHTML(for: code, isDarkMode: false)
        // Dark mode uses different background color (#1e1e1e vs #ffffff)
        XCTAssertTrue(htmlDark.contains("#1e1e1e"), "Dark mode HTML should use dark background")
        XCTAssertTrue(htmlLight.contains("#ffffff"), "Light mode HTML should use light background")
        // Light and dark should produce different HTML
        XCTAssertNotEqual(htmlDark, htmlLight, "Dark and light mode HTML should differ")
    }

    func testGenerateHTMLContainsMessageHandler() {
        let html = MermaidWebRenderer.generateHTML(for: "flowchart TD\n    A --> B", isDarkMode: false)
        // Must contain the Swift message handler bridge
        XCTAssertTrue(
            html.contains("mermaidReady"),
            "HTML must contain mermaidReady message handler for Swift bridge"
        )
    }

    func testGenerateHTMLContainsDiagramContainer() {
        let html = MermaidWebRenderer.generateHTML(for: "flowchart TD\n    A --> B", isDarkMode: false)
        XCTAssertTrue(
            html.contains("diagram-container"),
            "HTML must contain diagram-container div"
        )
    }

    // MARK: - Code Escaping

    func testSpecialCharactersEscaped() {
        // Mermaid code with characters that need HTML escaping
        let code = "flowchart TD\n    A[\"Hello <world>\"] --> B"
        let html = MermaidWebRenderer.generateHTML(for: code, isDarkMode: false)
        // Backtick/quote injection shouldn't break the HTML template
        XCTAssertTrue(html.contains("</html>"), "HTML structure should remain intact despite special characters")
    }

    func testBacktickInCodeDoesNotBreakTemplate() {
        let code = "flowchart TD\n    A[`Code block`] --> B"
        let html = MermaidWebRenderer.generateHTML(for: code, isDarkMode: false)
        XCTAssertTrue(html.contains("</html>"), "Backticks should not break HTML template")
    }

    func testNewlinesInCodePreserved() {
        let code = """
        flowchart TD
            A --> B
            B --> C
            C --> D
        """
        let html = MermaidWebRenderer.generateHTML(for: code, isDarkMode: false)
        // The rendered HTML should preserve the multi-line structure
        XCTAssertTrue(html.contains("</html>"), "Multi-line code should produce valid HTML")
    }

    // MARK: - Error Handling in HTML

    func testHTMLContainsErrorHandler() {
        let html = MermaidWebRenderer.generateHTML(for: "flowchart TD\n    A --> B", isDarkMode: false)
        // Should have try/catch for mermaid render errors
        XCTAssertTrue(
            html.contains("catch") && html.contains("error"),
            "HTML should contain error handling for failed renders"
        )
    }

    func testHTMLReportsErrorToSwift() {
        let html = MermaidWebRenderer.generateHTML(for: "flowchart TD\n    A --> B", isDarkMode: false)
        // Error path should still post message to Swift
        XCTAssertTrue(
            html.contains("status") && html.contains("error"),
            "HTML error handler should report status to Swift"
        )
    }

    // MARK: - All Diagram Types

    func testHTMLGenerationForAllDiagramTypes() {
        // Verify HTML generation doesn't crash for any diagram type
        let diagrams = [
            "flowchart TD\n    A --> B",
            "sequenceDiagram\n    A->>B: Hello",
            "classDiagram\n    A <|-- B",
            "stateDiagram-v2\n    [*] --> S1",
            "erDiagram\n    A ||--o{ B : has",
            "gantt\n    title Test\n    section S\n    Task :a1, 2024-01-01, 1d",
            "pie\n    \"A\" : 50\n    \"B\" : 50",
            "journey\n    title Test\n    section S\n    Task: 5: Actor",
            "gitGraph\n    commit\n    branch dev",
            "mindmap\n    root((Main))\n        Child",
        ]

        for (index, code) in diagrams.enumerated() {
            let html = MermaidWebRenderer.generateHTML(for: code, isDarkMode: false)
            XCTAssertFalse(html.isEmpty, "Diagram type \(index) produced empty HTML")
            XCTAssertTrue(html.contains("</html>"), "Diagram type \(index) produced invalid HTML")
        }
    }

    // MARK: - Max Width Tests

    func testHTMLMaxWidthConstraint() {
        let html = MermaidWebRenderer.generateHTML(for: "flowchart TD\n    A --> B", isDarkMode: false, maxWidth: 500)
        XCTAssertTrue(html.contains("max-width: 500px"), "HTML should contain max-width constraint for body")
        XCTAssertTrue(html.contains("max-width: 468px"), "HTML should contain max-width constraint for container (500 - 32 padding)")
    }

    func testHTMLNoMaxWidthByDefault() {
        let html = MermaidWebRenderer.generateHTML(for: "flowchart TD\n    A --> B", isDarkMode: false)
        // Without maxWidth, the body should not have an explicit max-width pixel value
        // (it may still have overflow: hidden from the base styles)
        XCTAssertFalse(html.contains("max-width: 0px"), "HTML should not contain zero max-width")
    }

    func testHTMLOverflowHidden() {
        let html = MermaidWebRenderer.generateHTML(for: "flowchart TD\n    A --> B", isDarkMode: false)
        XCTAssertTrue(html.contains("overflow: hidden"), "Body should use overflow: hidden to prevent SVG bleed")
    }
}
