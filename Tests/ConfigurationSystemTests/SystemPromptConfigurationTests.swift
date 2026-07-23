// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)

import XCTest
@testable import ConfigurationSystem

/// Regression tests for the v21 User Autonomy prompt revision.
///
/// These tests pin the absence of behavioral patterns that drove the model to
/// manufacture conversation endings, recaps, and session boundaries on the
/// user's behalf. They also pin the presence of the new User Autonomy rule
/// so future prompt edits cannot silently regress.
final class SystemPromptConfigurationTests: XCTestCase {
    /// Hardcoded UUIDs match buildDefaultConfigurations() in SystemPromptConfiguration.swift.
    private let samDefaultId = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    private let samMinimalId = UUID(uuidString: "00000000-0000-0000-0000-000000000004")!

    private func samDefault() -> SystemPromptConfiguration? {
        SystemPromptConfiguration.defaultConfigurations().first { $0.id == samDefaultId }
    }

    private func samMinimal() -> SystemPromptConfiguration? {
        SystemPromptConfiguration.defaultConfigurations().first { $0.id == samMinimalId }
    }

    private func generatedPrompt(for config: SystemPromptConfiguration?, toolsEnabled: Bool = true, workflowModeEnabled: Bool = false) -> String {
        return config?.generateSystemPrompt(toolsEnabled: toolsEnabled, workflowModeEnabled: workflowModeEnabled) ?? ""
    }

    // MARK: - Version

    func testCurrentVersionIs21() {
        XCTAssertEqual(
            SystemPromptConfiguration.currentVersion,
            21,
            "Prompt system must be on version 21 after the User Autonomy revision."
        )
    }

    // MARK: - Component presence

    func testSAMDefaultIncludesUserAutonomyComponent() {
        guard let config = samDefault() else {
            XCTFail("SAM Default configuration missing.")
            return
        }
        XCTAssertTrue(
            config.components.contains(where: { $0.title == "User Autonomy" }),
            "SAM Default must include a User Autonomy component."
        )
    }

    func testSAMMinimalIncludesUserAutonomyComponent() {
        guard let config = samMinimal() else {
            XCTFail("SAM Minimal configuration missing.")
            return
        }
        XCTAssertTrue(
            config.components.contains(where: { $0.title == "User Autonomy" }),
            "SAM Minimal must include a User Autonomy component."
        )
    }

    // MARK: - User Autonomy content in generated prompt

    func testSAMDefaultPromptContainsUserAutonomyRules() {
        let prompt = generatedPrompt(for: samDefault())
        XCTAssertTrue(prompt.contains("## User Autonomy"), "Generated prompt must contain the User Autonomy header.")
        XCTAssertTrue(prompt.contains("user is the authority"), "Generated prompt must assert user authority over session boundaries.")
        XCTAssertTrue(prompt.contains("Manufacture conversation endings"), "Generated prompt must forbid manufactured conversation endings.")
        XCTAssertTrue(prompt.contains("Workflow Mode retains its phase-boundary recaps"), "Generated prompt must carve out Workflow Mode recap behavior.")
    }

    func testSAMMinimalPromptContainsUserAutonomyRule() {
        let prompt = generatedPrompt(for: samMinimal())
        XCTAssertTrue(prompt.contains("Do not manufacture conversation endings"), "SAM Minimal must forbid manufactured conversation endings.")
        XCTAssertTrue(prompt.contains("Do not act as their time or attention manager"), "SAM Minimal must state the user-autonomy rule.")
    }

    // MARK: - User Autonomy is unconditional

    func testUserAutonomyIncludedWhenToolsDisabled() {
        let prompt = generatedPrompt(for: samDefault(), toolsEnabled: false, workflowModeEnabled: false)
        XCTAssertTrue(
            prompt.contains("## User Autonomy"),
            "User Autonomy must remain in the prompt when tools are disabled."
        )
    }

    func testUserAutonomyIncludedInWorkflowMode() {
        let prompt = generatedPrompt(for: samDefault(), toolsEnabled: true, workflowModeEnabled: true)
        XCTAssertTrue(
            prompt.contains("## User Autonomy"),
            "User Autonomy must remain in the prompt when workflow mode is enabled."
        )
    }

    // MARK: - Absence of problematic patterns

    /// Phrases that drove the v21 revision. If any of these reappear in the
    /// generated SAM Default prompt OUTSIDE the explicit "Never say" list, the
    /// model has regressed into manufacturing conversation endings or managing
    /// the user's time/attention. Phrases that the diagnostic added to the
    /// "Never say" anti-example list are excluded from this check because they
    /// are intentionally present as prohibitions the model must obey.
    private let bannedPhrasesSAMDefault: [(phrase: String, reason: String)] = [
        ("Conversational Partner Protocol", "Removed section that mandated unsolicited recaps."),
        ("Invite follow-up", "Manufactured invitation to continue the conversation."),
        ("Complete when answer is delivered", "Auto-completion signal in conversational mode."),
        ("If a step could benefit from user review or decision, pause and request input", "Manufactured decision point."),
        ("Adapt communication style to the user's preferences, such as confirming each step, summarizing progress frequently", "Over-caretaking behavior."),
        ("Summarize accomplishments, present results, and ask if the user wants to review, continue, or discuss further", "Auto-recap-on-completion behavior."),
        ("Never terminate the conversation abruptly", "Forced invitation-to-continue rule."),
        ("Data gathered via tools (when required), question answered thoroughly", "Old conversational-mode completion definition."),
    ]

    func testSAMDefaultPromptContainsNoBannedPhrases() {
        let prompt = generatedPrompt(for: samDefault())
        for entry in bannedPhrasesSAMDefault {
            XCTAssertFalse(
                prompt.contains(entry.phrase),
                "Banned phrase found in SAM Default prompt: \"\(entry.phrase)\". Reason: \(entry.reason)"
            )
        }
    }

    // MARK: - Explicit "Never say" additions

    /// The diagnostic's Never-say additions should be present in the
    /// Communication component so the model is told not to emit them.
    func testSAMDefaultPromptForbidsSessionBoundaryPhrases() {
        let prompt = generatedPrompt(for: samDefault())
        let additions = [
            "Let me know if you'd like to stop",
            "Would you like to take a break?",
            "We can pick this up tomorrow",
            "You've done enough",
            "Time to rest",
            "You're tired",
        ]
        for phrase in additions {
            XCTAssertTrue(
                prompt.contains(phrase),
                "Communication Never-say list must include \"\(phrase)\" so the model is told not to emit it."
            )
        }
    }

    // MARK: - Pre-Response Checklist Mode Check extension

    func testSAMDefaultPromptIncludesNoImplicitUrgencyRule() {
        let prompt = generatedPrompt(for: samDefault())
        XCTAssertTrue(
            prompt.contains("no implicit urgency, completion timeline, or length limit"),
            "Mode Check must include the no-implicit-urgency / length-limit rule."
        )
    }

    // MARK: - User Autonomy must be unconditional, not gated on subject

    func testUserAutonomyIsNotGatedOnSubject() {
        let prompt = generatedPrompt(for: samDefault())
        XCTAssertFalse(
            prompt.contains("competent adult"),
            "User Autonomy must not gate on a user-class conditional."
        )
        XCTAssertFalse(
            prompt.contains("their own health") || prompt.contains("their own body") || prompt.contains("their own diagnoses"),
            "User Autonomy must not gate on a subject conditional (health/medical)."
        )
    }
}
