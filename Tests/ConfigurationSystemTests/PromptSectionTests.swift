// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)

import XCTest
@testable import ConfigurationSystem

/// Tests for the v27 section-based filter that replaced title-string filters.
///
/// The whole point of `PromptSection` is to let the filter and order be
/// driven by enum cases rather than magic strings. If these tests break,
/// either a section was added without updating the enum (caught by the
/// exhaustive cases below) or the enum semantics drifted.
final class PromptSectionTests: XCTestCase {

    // MARK: - Enum stability

    /// All section cases. If you add a case, add it here.
    func testEnumCases() {
        let allCases = PromptSection.allCases
        let rawValues = allCases.map { $0.rawValue }.sorted()
        XCTAssertEqual(rawValues, [0, 10, 20, 30, 40, 50, 60],
                       "PromptSection rawValues must be stable and ordered. Add new sections at the end (next multiple of 10) so existing orderings stay intact.")
    }

    // MARK: - Always-included semantics

    /// Identity is always-on. The model always knows who it is.
    func testIdentityIsAlwaysIncluded() {
        XCTAssertTrue(PromptSection.identity.alwaysIncluded)
    }

    /// Workflow components require the workflowModeEnabled flag.
    func testWorkflowRequiresWorkflowMode() {
        XCTAssertTrue(PromptSection.workflow.requiresWorkflowMode)
    }

    /// Workflow is NOT always-included - the user has to opt in.
    func testWorkflowIsNotAlwaysIncluded() {
        XCTAssertFalse(PromptSection.workflow.alwaysIncluded)
    }

    /// Tooling sections require tools to be enabled.
    func testToolingRequiresTools() {
        XCTAssertTrue(PromptSection.tooling.requiresTools)
    }

    /// Non-tooling sections do not require tools.
    func testOtherSectionsDoNotRequireTools() {
        XCTAssertFalse(PromptSection.identity.requiresTools)
        XCTAssertFalse(PromptSection.autonomy.requiresTools)
        XCTAssertFalse(PromptSection.integrity.requiresTools)
        XCTAssertFalse(PromptSection.completion.requiresTools)
        XCTAssertFalse(PromptSection.operational.requiresTools)
        XCTAssertFalse(PromptSection.workflow.requiresTools)
    }

    // MARK: - Order semantics

    /// Sections are ordered such that identity comes first and workflow
    /// comes last. Pin the order so a future reordering cannot silently
    /// demote identity (which would put the model's identity later in
    /// the prompt and risk being lost to context window trimming).
    func testSectionOrder() {
        XCTAssertLessThan(PromptSection.identity.rawValue, PromptSection.tooling.rawValue)
        XCTAssertLessThan(PromptSection.tooling.rawValue, PromptSection.autonomy.rawValue)
        XCTAssertLessThan(PromptSection.autonomy.rawValue, PromptSection.integrity.rawValue)
        XCTAssertLessThan(PromptSection.integrity.rawValue, PromptSection.completion.rawValue)
        XCTAssertLessThan(PromptSection.completion.rawValue, PromptSection.operational.rawValue)
        XCTAssertLessThan(PromptSection.operational.rawValue, PromptSection.workflow.rawValue)
    }

    /// `defaultOrder` matches `rawValue` so the component initializer can
    /// use `section.defaultOrder` as the canonical order value.
    func testDefaultOrderMatchesRawValue() {
        for section in PromptSection.allCases {
            XCTAssertEqual(section.defaultOrder, section.rawValue,
                           "\(section).defaultOrder must equal \(section).rawValue so the SystemPromptComponent(section:) initializer can derive order.")
        }
    }

    // MARK: - SystemPromptComponent convenience

    /// A component created with a section automatically gets the section's
    /// `defaultOrder` as its `order`.
    func testComponentInitializerDerivesOrderFromSection() {
        let component = SystemPromptComponent(
            title: "Test",
            content: "...",
            section: .identity
        )
        XCTAssertEqual(component.order, PromptSection.identity.defaultOrder)
        XCTAssertEqual(component.section, .identity)
    }

    /// Explicit `order` overrides the section's default - useful for
    /// inserting a component mid-section without bumping the others.
    func testExplicitOrderOverridesSectionDefault() {
        let component = SystemPromptComponent(
            title: "Test",
            content: "...",
            section: .identity,
            order: 5
        )
        XCTAssertEqual(component.order, 5)
    }

    /// No section -> order 0 (legacy default).
    func testNoSectionDefaultsToOrderZero() {
        let component = SystemPromptComponent(
            title: "Legacy",
            content: "..."
        )
        XCTAssertNil(component.section)
        XCTAssertEqual(component.order, 0)
    }

    // MARK: - generateSystemPrompt integration

    /// When SAM Default's Core Identity component is section=identity, the
    /// generated prompt includes it regardless of `toolsEnabled`. Identity
    /// is always-included.
    func testIdentityAlwaysAppearsInPrompt() {
        guard let samDefault = SystemPromptConfiguration.defaultConfigurations().first(where: { $0.id == UUID(uuidString: "00000000-0000-0000-0000-000000000001") }) else {
            XCTFail("SAM Default configuration missing.")
            return
        }

        let promptWithTools = samDefault.generateSystemPrompt(toolsEnabled: true)
        let promptWithoutTools = samDefault.generateSystemPrompt(toolsEnabled: false)
        XCTAssertTrue(promptWithTools.contains("SAM") || promptWithTools.contains("Core Identity"),
                      "Core Identity must appear in the prompt with tools enabled.")
        XCTAssertTrue(promptWithoutTools.contains("SAM") || promptWithoutTools.contains("Core Identity"),
                      "Core Identity must appear even when tools are disabled.")
    }

    /// Workflow Mode component is filtered out when workflowModeEnabled=false.
    /// Pin this so a future regression cannot silently re-enable Workflow
    /// Mode for every conversation.
    func testWorkflowModeRequiresWorkflowEnabled() {
        guard let samDefault = SystemPromptConfiguration.defaultConfigurations().first(where: { $0.id == UUID(uuidString: "00000000-0000-0000-0000-000000000001") }) else {
            XCTFail("SAM Default configuration missing.")
            return
        }

        let promptWithoutWorkflow = samDefault.generateSystemPrompt(workflowModeEnabled: false)
        let promptWithWorkflow = samDefault.generateSystemPrompt(workflowModeEnabled: true)

        /// WORKFLOW MODE heading should not appear unless workflow is enabled.
        XCTAssertFalse(
            promptWithoutWorkflow.contains("WORKFLOW MODE"),
            "Workflow Mode component must NOT be in the prompt when workflowModeEnabled=false."
        )
        XCTAssertTrue(
            promptWithWorkflow.contains("WORKFLOW MODE"),
            "Workflow Mode component must be in the prompt when workflowModeEnabled=true."
        )
    }

    /// Legacy components (no section) still work. This is the backwards-
    /// compatibility path for user-created prompts authored before the v27
    /// section refactor.
    func testLegacyComponentWithoutSectionStillRenders() {
        let legacyConfig = SystemPromptConfiguration(
            id: UUID(),
            name: "Legacy Test",
            components: [
                SystemPromptComponent(
                    title: "My Custom Component",
                    content: "Custom content goes here.",
                    isEnabled: true,
                    order: 1
                    // No `section:` set.
                )
            ]
        )
        let prompt = legacyConfig.generateSystemPrompt()
        XCTAssertTrue(
            prompt.contains("Custom content goes here"),
            "Legacy components without a section must still render. The user-data migration path depends on this."
        )
    }
}
