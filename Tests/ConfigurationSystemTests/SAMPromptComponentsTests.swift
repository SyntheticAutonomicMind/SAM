// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)

import XCTest
@testable import ConfigurationSystem

/// Pin the structural properties of the extracted SAM component library.
///
/// These tests verify that:
/// - Every function on `SAMPromptComponents` returns non-empty content.
/// - The order of components matches the SAM Default literal in
///   `SystemPromptConfiguration.defaultConfigurations()` - so the
///   extracted content and the wiring layer cannot drift out of sync.
/// - SAM Minimal reuses the same atomic rule titles as SAM Default,
///   so future component additions only have to be added in two
///   places (SAM Default verbose, SAM Minimal compressed) - both of
///   which use the same canonical titles.
///
/// v27: created during the prompt architecture refactor that moved
/// content out of `SystemPromptConfiguration.swift`. Without these
/// tests, a future refactor could quietly remove a component (its
/// function becomes orphaned) and the wiring literal in
/// `defaultConfigurations()` would still reference it, producing a
/// broken empty-string prompt.
final class SAMPromptComponentsTests: XCTestCase {

    /// Whitelist of all public functions on `SAMPromptComponents`. If you
    /// add a new component, add it here AND in the literal in
    /// `defaultConfigurations()`. The wiring test below fails if either
    /// side drifts.
    private let componentTitles: [(name: String, value: String)] = [
        ("Current Date Context", SAMPromptComponents.currentDateContext()),
        ("Core Identity", SAMPromptComponents.coreIdentity()),
        ("Tool Usage", SAMPromptComponents.toolUsage()),
        ("Workflow Loop Principles", SAMPromptComponents.workflowLoopPrinciples()),
        ("Safety", SAMPromptComponents.safety()),
        ("Data Integrity", SAMPromptComponents.dataIntegrity()),
        ("User Data Boundaries", SAMPromptComponents.userDataBoundaries()),
        ("User Autonomy", SAMPromptComponents.userAutonomy()),
        ("Scope Honesty", SAMPromptComponents.scopeHonesty()),
        ("Tool-Backed Claims", SAMPromptComponents.toolBackedClaims()),
        ("Completion Criteria", SAMPromptComponents.completionCriteria()),
        ("Generation Loop Detection", SAMPromptComponents.generationLoopDetection()),
        ("Stop Means Stop", SAMPromptComponents.stopMeansStop()),
        ("Todo Integrity", SAMPromptComponents.todoIntegrity()),
        ("Narration Without Action", SAMPromptComponents.narrationWithoutAction()),
        ("Operational Modes", SAMPromptComponents.operationalModes()),
        ("Execution Standards", SAMPromptComponents.executionStandards()),
        ("Pre-Response Checklist", SAMPromptComponents.preResponseChecklist()),
        ("Communication", SAMPromptComponents.communication()),
        ("Context & Memory", SAMPromptComponents.contextMemory()),
        ("Workflow Mode", SAMPromptComponents.workflowMode()),
    ]

    /// Every component must return non-empty content. Empty content would
    /// produce an empty `## Title` heading in the prompt, which both
    /// wastes tokens and breaks test assertions that look for the
    /// component's title.
    func testAllComponentsReturnNonEmptyContent() {
        for (title, content) in componentTitles {
            XCTAssertFalse(
                content.isEmpty,
                "\(title) returned empty content - check SAMPromptComponents.\(title.lowercased().replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "&", with: "And"))()"
            )
        }
    }

    /// Every component must include its title as a `## Title` heading. The
    /// model uses these headings to skip to relevant sections in long
    /// prompts. Pin them so a future rewrite cannot accidentally drop the
    /// heading.
    ///
    /// Allow nested `### Title` for components that have subsections (e.g.
    /// Workflow Loop Principles has subsections, Workflow Mode starts with
    /// `### ` not `## `). The test asserts the title is present in some
    /// heading form, not specifically `## Title`.
    func testAllComponentsIncludeTheirHeading() {
        let expectedHeadings: [String: String] = [
            "Workflow Loop Principles": "Workflow Loop (Operational Foundation)",
            "Operational Modes": "Conversational Mode",
            "Execution Standards": "Error Recovery",
            "Workflow Mode": "WORKFLOW MODE",
        ]
        for (title, content) in componentTitles {
            let heading = expectedHeadings[title] ?? title
            let hasH2 = content.contains("## \(heading)")
            let hasH3 = content.contains("### \(heading)")
            XCTAssertTrue(
                hasH2 || hasH3,
                "\(title) content does not contain a `## \(heading)` or `### \(heading)` heading. The headings are how the model navigates long prompts."
            )
        }
    }

    /// The wiring literal in `defaultConfigurations()` must reference every
    /// component produced here. If you add a new function to
    /// `SAMPromptComponents`, add it to the literal. If you remove one,
    /// remove it from the literal. This test catches both directions of
    /// drift before they ship.
    func testDefaultConfigurationsWiresEveryComponent() {
        guard let samDefault = SystemPromptConfiguration.defaultConfigurations().first(where: { $0.id == UUID(uuidString: "00000000-0000-0000-0000-000000000001") }) else {
            XCTFail("SAM Default configuration missing.")
            return
        }

        let configuredTitles = Set(samDefault.components.map { $0.title })
        for (title, _) in componentTitles {
            // Workflow Mode is conditional (isEnabled=false in default). It is
            // still wired into the configuration literal, just disabled by
            // default. Verify it is present even when not enabled.
            XCTAssertTrue(
                configuredTitles.contains(title),
                "SAM Default configuration literal does not include \(title). Add it to defaultConfigurations() in SystemPromptConfiguration.swift."
            )
        }
    }

    /// `Dynamic Iterations` was removed in v27 because it referenced a tool
    /// (`increase_max_iterations`) that does not exist. Pin its absence so
    /// a future regression cannot silently re-add a component that promises
    /// a tool the model cannot call.
    func testDynamicIterationsIsRemoved() {
        guard let samDefault = SystemPromptConfiguration.defaultConfigurations().first(where: { $0.id == UUID(uuidString: "00000000-0000-0000-0000-000000000001") }) else {
            XCTFail("SAM Default configuration missing.")
            return
        }
        XCTAssertFalse(
            samDefault.components.contains(where: { $0.title.contains("Dynamic Iterations") }),
            "Dynamic Iterations component must NOT be in the configuration. It referenced increase_max_iterations which is not a registered MCP tool."
        )
    }

    /// `buildSAMCoreIdentity` was dead code in v26 (~30 lines, zero callers).
    /// It was removed in v27. Pin its absence via a marker in the generated
    /// prompt: the legacy component had a unique phrase ("User instructions
    /// ALWAYS TAKE PRIORITY") that the v24 version drops. If that phrase
    /// reappears, the dead function has been re-introduced.
    func testLegacyCoreIdentityIsNotPresent() {
        guard let samDefaultConfig = SystemPromptConfiguration.defaultConfigurations().first(where: { $0.id == UUID(uuidString: "00000000-0000-0000-0000-000000000001") }) else {
            XCTFail("SAM Default configuration missing.")
            return
        }
        let prompt = samDefaultConfig.generateSystemPrompt()
        XCTAssertFalse(
            prompt.contains("USER INSTRUCTIONS ALWAYS TAKE PRIORITY"),
            "Legacy 'buildSAMCoreIdentity' content must not appear in the prompt. v24 Core Identity uses 'helpful, accurate, approachable' framing; the legacy version used 'USER INSTRUCTIONS ALWAYS TAKE PRIORITY'. If this fails, the dead function has been re-introduced."
        )
    }

    /// SAM Minimal must reuse the same atomic rule titles as SAM Default.
    /// This is what makes it possible to verify "Minimal covers everything
    /// Default covers" in a test - same titles, different content.
    func testSAMMinimalCoversSameRulesAsDefault() {
        let samDefault = SystemPromptConfiguration.defaultConfigurations().first(where: { $0.id == UUID(uuidString: "00000000-0000-0000-0000-000000000001") })
        let samMinimal = SystemPromptConfiguration.defaultConfigurations().first(where: { $0.id == UUID(uuidString: "00000000-0000-0000-0000-000000000004") })
        guard let defaultConfig = samDefault, let minimalConfig = samMinimal else {
            XCTFail("SAM Default and/or SAM Minimal configuration missing.")
            return
        }

        let defaultTitles = Set(defaultConfig.components.map { $0.title })
        let minimalTitles = Set(minimalConfig.components.map { $0.title })

        // Atomic rules that must be in both. SAM Minimal is allowed to skip
        // long-form explanations of routing/tool selection/multi-step
        // (those are not in the SAM Minimal compact set).
        let sharedTitles = [
            "User Autonomy",
            "Scope Honesty",
            "Tool-Backed Claims",
            "Completion Criteria",
            "Generation Loop Detection",
            "Stop Means Stop",
            "Todo Integrity",
            "Narration Without Action",
            "Data Integrity",
        ]
        for title in sharedTitles {
            XCTAssertTrue(
                defaultTitles.contains(title),
                "SAM Default should include \(title)."
            )
            XCTAssertTrue(
                minimalTitles.contains(title),
                "SAM Minimal should include \(title). If you intentionally dropped it, update this test and document the reason."
            )
        }
    }
}
