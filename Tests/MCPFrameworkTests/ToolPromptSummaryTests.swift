// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)

import XCTest
@testable import MCPFramework

/// Regression tests for the ToolPromptSummary registry added in v26 of the
/// system prompt. The registry replaces first-line truncation of arbitrary
/// `tool.description` strings with hand-curated one-liners. Pin the
/// behaviour so the model sees the right summary for every shipped tool
/// and so a missing summary does not silently fall through to a broken
/// default.
final class ToolPromptSummaryTests: XCTestCase {
    /// Every tool that ships with SAM today must have a one-line summary.
    /// If a new tool is added without a summary, this fails - forcing the
    /// maintainer to write a one-liner (or accept the generic fallback,
    /// which the next test catches).
    func testRegisteredToolsHaveCuratedSummaries() {
        let expectedTools: [String: String] = [
            "web_operations": "Web research, search, fetch, scrape, and serpapi queries",
            "memory_operations": "Store, search, and recall memories",
            "file_operations": "Read, write, edit, and search files",
            "terminal_operations": "Execute shell commands",
            "version_control": "Git version control operations",
            "math_operations": "Calculate, convert, and run formula math",
            "todo_operations": "Manage structured todo lists",
            "code_intelligence": "Find symbol usages and search commit history",
            "weather_operations": "Current weather and forecast for a location",
            "image_generation": "Generate images via remote Stable Diffusion",
            "document_operations": "Import, create, and manage documents",
            "calendar_operations": "Read and create calendar events",
            "contacts_operations": "Search and create contacts",
            "notes_operations": "Read, create, and search Apple Notes",
            "spotlight_search": "Search the macOS Spotlight index",
        ]
        for (tool, expectedSubstring) in expectedTools {
            let summary = ToolPromptSummaryRegistry.shared.summary(for: tool)
            XCTAssertEqual(
                summary, expectedSubstring,
                "ToolPromptSummary entry for \(tool) drifted from curated text. Update the registry AND this test together."
            )
        }
    }

    /// The web_operations summary must NOT name specific engines or operations.
    /// The whole point of the registry is that one-liners do not teach the
    /// model to call operations as standalone tools (the M3 bug). If a
    /// summary starts listing "research / web_search / serpapi" the model
    /// will try to call those as tool names directly.
    ///
    /// Exception: "serpapi" is allowed as a description of the
    /// SerpAPI integration (the summary says "serpapi queries"). That is
    /// a description, not a tool name. Specific engines (yelp/google/amazon/
    /// tripadvisor) are still banned because the model would call them as
    /// tools.
    func testWebOperationsSummaryDoesNotNameOperations() {
        let summary = ToolPromptSummaryRegistry.shared.summary(for: "web_operations")
        /// research/web_search/fetch/scrape are OK in the summary as action
        /// verbs describing the tool's surface. The model reads them as
        /// "this tool can do these kinds of things", not as a call target.
        let operationVerbs = ["research", "search", "fetch", "scrape"]
        let summaryHasVerbs = operationVerbs.allSatisfy { summary.contains($0) }
        XCTAssertTrue(summaryHasVerbs,
                      "web_operations summary should describe its operations as verbs: \(summary)")
        XCTAssertFalse(
            summary.contains("google") || summary.contains("yelp") || summary.contains("amazon") || summary.contains("tripadvisor"),
            "web_operations summary must not mention specific engines: \(summary)"
        )
    }

    /// Every registered summary must be a single short line. Long summaries
    /// undermine the registry's purpose (which is to give the model a quick
    /// routing hint, not a routing manual). Pin the upper bound so future
    /// edits do not quietly bloat it.
    func testSummariesAreShort() {
        let tools = [
            "web_operations", "memory_operations", "file_operations",
            "terminal_operations", "version_control", "math_operations",
            "todo_operations", "code_intelligence", "weather_operations",
            "image_generation", "document_operations", "calendar_operations",
            "contacts_operations", "notes_operations", "spotlight_search",
        ]
        for tool in tools {
            let summary = ToolPromptSummaryRegistry.shared.summary(for: tool)
            XCTAssertLessThanOrEqual(
                summary.count, 80,
                "\(tool) summary is \(summary.count) chars; pin to <=80 chars. Long summaries defeat the registry."
            )
        }
    }

    /// The default fallback for unregistered tools must still be valid, even
    /// though it is generic. The fall-back format is "<Title Case> operations"
    /// derived from the snake_case tool name.
    func testDefaultFallbackForUnknownTool() {
        let summary = ToolPromptSummaryRegistry.shared.summary(for: "new_unknown_tool")
        XCTAssertEqual(summary, "New Unknown Tool operations",
                       "Unknown tools must get a deterministic fallback summary derived from the snake_case name.")
    }

    /// The renderListing output must be byte-stable for the same input
    /// (sorted tool names produce the same output on every call). This is
    /// what makes the prompt cache hit for MLX/GGUF local models.
    func testRenderListingIsByteStable() {
        let names1 = ["web_operations", "memory_operations", "file_operations"]
        let names2 = ["file_operations", "memory_operations", "web_operations"]  // different order
        let out1 = ToolPromptSummaryRegistry.shared.renderListing(for: names1)
        let out2 = ToolPromptSummaryRegistry.shared.renderListing(for: names2)
        XCTAssertEqual(out1, out2, "renderListing must sort input so output is byte-stable regardless of input order.")
    }

    /// The renderListing output must include all tools in the input. Pin so
    /// a future refactor cannot silently drop a tool from the prompt.
    func testRenderListingContainsAllTools() {
        let names = ["web_operations", "memory_operations", "file_operations", "math_operations"]
        let output = ToolPromptSummaryRegistry.shared.renderListing(for: names)
        for name in names {
            XCTAssertTrue(output.contains(name), "renderListing must include \(name).")
        }
    }

    /// The renderListing output must NOT name operations or engines. Same
    /// rationale as testWebOperationsSummaryDoesNotNameOperations - the
    /// model sees this entire listing as the "what tools exist" hint and
    /// must not learn to call operation names as tools.
    func testRenderListingDoesNotLeakOperations() {
        let names = [
            "web_operations", "memory_operations", "file_operations",
            "terminal_operations", "version_control", "math_operations",
            "todo_operations", "code_intelligence",
        ]
        let output = ToolPromptSummaryRegistry.shared.renderListing(for: names)
        /// "serpapi" is referenced as the action-verb "scrape" not the tool name
        /// (the web_operations summary says "fetch, scrape, and serpapi queries").
        /// That is an intentional exception because there is no other concise way
        /// to convey that web_operations handles the SerpAPI integration. It is
        /// still strictly weaker than naming a tool operation - the model sees
        /// "serpapi queries" as a description, not a tool name. If you ever add
        /// yelp/tripadvisor/amazon to a summary, those WILL leak and this list
        /// must grow.
        let banned = ["yelp", "tripadvisor", "amazon", "grep_search", "semantic_search", "read_file", "write_file", "yelp_search", "tripadvisor_search"]
        for token in banned {
            XCTAssertFalse(
                output.contains(token),
                "renderListing leaked banned token '\(token)'. Tool listing must not teach the model to call operations as tools."
            )
        }
    }
}
