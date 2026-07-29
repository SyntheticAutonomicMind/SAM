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

    func testCurrentVersionIs23() {
        XCTAssertEqual(
            SystemPromptConfiguration.currentVersion,
            23,
            "Prompt system must be on version 23 after the Tool-Backed Claims revision."
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

// MARK: - v22 Scope Honesty regression guards

/// v22 added a Scope Honesty component addressing the pattern of agents
/// unilaterally narrowing user-stated scope ("you don't need to research the
/// rest", treating backup lists as filler, rationalizing shortcuts as
/// efficiency). These tests pin the component's presence and its core rules
/// so future prompt edits cannot silently regress.
extension SystemPromptConfigurationTests {

    func testSAMDefaultIncludesScopeHonestyComponent() {
        guard let config = samDefault() else {
            XCTFail("SAM Default configuration missing.")
            return
        }
        XCTAssertTrue(
            config.components.contains(where: { $0.title == "Scope Honesty" }),
            "SAM Default must include a Scope Honesty component."
        )
    }

    func testSAMMinimalIncludesScopeHonestyComponent() {
        guard let config = samMinimal() else {
            XCTFail("SAM Minimal configuration missing.")
            return
        }
        XCTAssertTrue(
            config.components.contains(where: { $0.title == "Scope Honesty" }),
            "SAM Minimal must include a Scope Honesty component."
        )
    }

    func testScopeHonestyIsDefaultEnabled() {
        guard let config = samDefault() else {
            XCTFail("SAM Default configuration missing.")
            return
        }
        guard let component = config.components.first(where: { $0.title == "Scope Honesty" }) else {
            XCTFail("Scope Honesty component missing from SAM Default.")
            return
        }
        XCTAssertTrue(
            component.isEnabled,
            "Scope Honesty must be default-enabled to actually take effect."
        )
    }

    func testScopeHonestyAppearsInGeneratedPrompt() {
        let prompt = generatedPrompt(for: samDefault())
        XCTAssertTrue(
            prompt.contains("Scope Honesty"),
            "Generated SAM Default prompt must include the Scope Honesty section header."
        )
        XCTAssertTrue(
            prompt.contains("The user sets the scope"),
            "Scope Honesty must state the core principle that the user sets the scope."
        )
    }

    /// Pin the five core anti-patterns the rule guards against. If any of
    /// these phrases are removed from the prompt, the rule has lost one of
    /// its load-bearing statements and the regression risk returns.
    func testScopeHonestyContainsCoreAntiPatterns() {
        let prompt = generatedPrompt(for: samDefault())
        let requiredPhrases = [
            "Do not decide for the user that part of their scope is unnecessary",
            "Backup, secondary, or lower-priority items get the same rigor",
            "Scope-shrinking claims require tool backing",
            "Do not rationalize shortcuts as efficiency or helpfulness",
            "Self-check before scope-shrinking",
        ]
        for phrase in requiredPhrases {
            XCTAssertTrue(
                prompt.contains(phrase),
                "Scope Honesty must include the rule: \"\(phrase)\"."
            )
        }
    }

    /// Scope Honesty is part of the user-authority axis alongside User
    /// Autonomy and User Data Boundaries. Verify the cross-link from User
    /// Autonomy exists so the editor view surfaces both rules together.
    func testScopeHonestyCrossLinkedFromUserAutonomy() {
        let prompt = generatedPrompt(for: samDefault())
        XCTAssertTrue(
            prompt.contains("See also Scope Honesty"),
            "User Autonomy must cross-link to Scope Honesty so the related rule is discoverable."
        )
    }

    /// User Data Boundaries Section C ("lists are user-controlled") is
    /// adjacent to Scope Honesty. The Section C closing line should mention
    /// the new component so backup-list rigor is discoverable from there too.
    func testScopeHonestyCrossLinkedFromUserDataBoundaries() {
        let prompt = generatedPrompt(for: samDefault())
        XCTAssertTrue(
            prompt.contains("See also Scope Honesty for backup/secondary list rigor"),
            "User Data Boundaries must cross-link to Scope Honesty for backup/secondary list rigor."
        )
    }

    /// The rule must be domain-neutral - no user-class or subject
    /// conditional. (Mirror of the User Autonomy test that established this
    /// pattern.)
    func testScopeHonestyIsNotGatedOnSubject() {
        let prompt = generatedPrompt(for: samDefault())
        XCTAssertFalse(
            prompt.contains("competent adult"),
            "Scope Honesty must not gate on a user-class conditional."
        )
        XCTAssertFalse(
            prompt.contains("real estate") || prompt.contains("medical") || prompt.contains("legal advice"),
            "Scope Honesty must not gate on a subject conditional."
        )
    }

    /// SAM Minimal is for local small models - the rule there is a tight
    /// one-liner. Pin the essential message so future rewrites keep the
    /// scope-discipline signal.
    func testSAMMinimalScopeHonestyIsConcise() {
        guard let config = samMinimal() else {
            XCTFail("SAM Minimal configuration missing.")
            return
        }
        guard let component = config.components.first(where: { $0.title == "Scope Honesty" }) else {
            XCTFail("Scope Honesty component missing from SAM Minimal.")
            return
        }
        XCTAssertTrue(
            component.content.contains("scope is the instruction"),
            "SAM Minimal Scope Honesty must keep the 'scope is the instruction' message."
        )
        XCTAssertTrue(
            component.content.contains("backed by tool calls"),
            "SAM Minimal Scope Honesty must mention tool backing."
        )
        // SAM Minimal is for small models; the rule there should be
        // substantially shorter than the full SAM Default version.
        let defaultContent = samDefault()?.components
            .first(where: { $0.title == "Scope Honesty" })?.content ?? ""
        XCTAssertLessThan(
            component.content.count,
            defaultContent.count,
            "SAM Minimal Scope Honesty should be more concise than SAM Default."
        )
    }
}

// MARK: - v23 Tool-Backed Claims regression guards

/// v23 added a Tool-Backed Claims component addressing the pattern of
/// agents fabricating specifics (prices, ratings, URLs) by extending a
/// prior tool-verified response template without re-running the tools.
/// The failure mode: a recent prior turn already used a tool pattern,
/// the new turn "feels similar", and the model narrates a search while
/// producing fabricated results.
///
/// These tests pin the component's presence, its core rules, and the
/// cross-links to related components so future prompt edits cannot
/// silently regress the protection.
extension SystemPromptConfigurationTests {

    func testSAMDefaultIncludesToolBackedClaimsComponent() {
        guard let config = samDefault() else {
            XCTFail("SAM Default configuration missing.")
            return
        }
        XCTAssertTrue(
            config.components.contains(where: { $0.title == "Tool-Backed Claims" }),
            "SAM Default must include a Tool-Backed Claims component."
        )
    }

    func testSAMMinimalIncludesToolBackedClaimsComponent() {
        guard let config = samMinimal() else {
            XCTFail("SAM Minimal configuration missing.")
            return
        }
        XCTAssertTrue(
            config.components.contains(where: { $0.title == "Tool-Backed Claims" }),
            "SAM Minimal must include a Tool-Backed Claims component."
        )
    }

    func testToolBackedClaimsIsDefaultEnabled() {
        guard let config = samDefault() else {
            XCTFail("SAM Default configuration missing.")
            return
        }
        guard let component = config.components.first(where: { $0.title == "Tool-Backed Claims" }) else {
            XCTFail("Tool-Backed Claims component missing from SAM Default.")
            return
        }
        XCTAssertTrue(
            component.isEnabled,
            "Tool-Backed Claims must be default-enabled to actually take effect."
        )
    }

    func testToolBackedClaimsAppearsInGeneratedPrompt() {
        let prompt = generatedPrompt(for: samDefault())
        XCTAssertTrue(
            prompt.contains("Tool-Backed Claims"),
            "Generated SAM Default prompt must include the Tool-Backed Claims section header."
        )
        XCTAssertTrue(
            prompt.contains("a verified lookup must BE a verified lookup"),
            "Tool-Backed Claims must state the core principle that a response that looks verified must BE verified."
        )
    }

    /// Pin the four core rules guarding against the failure mode. If any
    /// of these phrases are removed from the prompt, the rule has lost
    /// one of its load-bearing statements and the regression risk returns.
    func testToolBackedClaimsContainsCoreAntiPatterns() {
        let prompt = generatedPrompt(for: samDefault())
        let requiredPhrases = [
            "Recent-session history is irrelevant",
            "Format inertia is not a tool call",
            "Tool call must precede the matching text",
            "Self-check before specific claims",
        ]
        for phrase in requiredPhrases {
            XCTAssertTrue(
                prompt.contains(phrase),
                "Tool-Backed Claims must include the rule: \"\(phrase)\"."
            )
        }
    }

    /// Pin the explicit per-session-history exemption line. This is the
    /// rule that addresses the exact failure mode (the model reasoning
    /// "I already searched X this session" and skipping the tool call).
    func testToolBackedClaimsHasPerSessionHistoryRule() {
        let prompt = generatedPrompt(for: samDefault())
        XCTAssertTrue(
            prompt.contains("I already searched for X") &&
            prompt.contains("does not exempt the next query"),
            "Tool-Backed Claims must explicitly address the per-session-history exemption pattern."
        )
    }

    /// The Workflow Loop "I'll search" rule must now reference fabrication
    /// framing so the model sees narrating a search without doing one as
    /// a data-integrity violation, not just a workflow lapse.
    func testWorkflowLoopSearchRuleHasFabricationFraming() {
        let prompt = generatedPrompt(for: samDefault())
        XCTAssertTrue(
            prompt.contains("data fabrication") &&
            prompt.contains("See Tool-Backed Claims"),
            "Workflow Loop 'I'll search' rule must frame narrating without doing as data fabrication and cross-link Tool-Backed Claims."
        )
    }

    /// Tool Usage RESEARCH > "Multiple sources" must be clarified as
    /// per-query, not session-aggregate. A prior turn's searches do not
    /// satisfy this for the current turn.
    func testToolUsageResearchClarifiesPerQuery() {
        let prompt = generatedPrompt(for: samDefault())
        XCTAssertTrue(
            prompt.contains("Multiple sources PER CURRENT QUERY") ||
            prompt.contains("per-query, not session-aggregate"),
            "Tool Usage RESEARCH rule must clarify that multiple sources means per-query."
        )
    }

    /// Pre-Response Checklist item #1 must reference that prior searches
    /// in this session do not satisfy the requirement for a new query.
    func testPreResponseChecklistAddressesSessionHistory() {
        let prompt = generatedPrompt(for: samDefault())
        XCTAssertTrue(
            prompt.contains("Prior searches in this session do not satisfy this for a new query") ||
            prompt.contains("each verifiable question gets its own tool call"),
            "Pre-Response Checklist must address the per-session-history exemption."
        )
    }

    /// Cross-link from User Data Boundaries Section A so the data-integrity
    /// framing extends to web-sourced specifics, not just math.
    func testToolBackedClaimsCrossLinkedFromUserDataBoundaries() {
        let prompt = generatedPrompt(for: samDefault())
        XCTAssertTrue(
            prompt.contains("Web-sourced specifics") &&
            prompt.contains("See Tool-Backed Claims"),
            "User Data Boundaries Section A must cross-link to Tool-Backed Claims for web-sourced specifics."
        )
    }

    /// The rule must be domain-neutral - no user-class or subject
    /// conditional. (Mirror of the v21/v22 tests that established this
    /// pattern.)
    func testToolBackedClaimsIsNotGatedOnSubject() {
        let prompt = generatedPrompt(for: samDefault())
        XCTAssertFalse(
            prompt.contains("competent adult"),
            "Tool-Backed Claims must not gate on a user-class conditional."
        )
        XCTAssertFalse(
            prompt.contains("shopping only") || prompt.contains("medical only") || prompt.contains("legal only"),
            "Tool-Backed Claims must not gate on a subject conditional."
        )
    }

    /// SAM Minimal is for local small models - the rule there is a tight
    /// one-liner. Pin the essential message so future rewrites keep the
    /// four-rule signal (session-history exemption, format inertia,
    /// narration-without-action, self-check before specific claims).
    func testSAMMinimalToolBackedClaimsIsConcise() {
        guard let config = samMinimal() else {
            XCTFail("SAM Minimal configuration missing.")
            return
        }
        guard let component = config.components.first(where: { $0.title == "Tool-Backed Claims" }) else {
            XCTFail("Tool-Backed Claims component missing from SAM Minimal.")
            return
        }
        XCTAssertTrue(
            component.content.contains("Recent-session history is irrelevant"),
            "SAM Minimal Tool-Backed Claims must mention session-history exemption."
        )
        XCTAssertTrue(
            component.content.contains("Format inertia is not a tool call"),
            "SAM Minimal Tool-Backed Claims must mention format inertia."
        )
        XCTAssertTrue(
            component.content.contains("data fabrication") ||
            component.content.contains("fabrication"),
            "SAM Minimal Tool-Backed Claims must frame narrating-without-action as fabrication."
        )
        XCTAssertTrue(
            component.content.contains("specific price"),
            "SAM Minimal Tool-Backed Claims must mention self-check before specific claims."
        )
        // SAM Minimal is for small models; the rule there should be
        // substantially shorter than the full SAM Default version.
        let defaultContent = samDefault()?.components
            .first(where: { $0.title == "Tool-Backed Claims" })?.content ?? ""
        XCTAssertLessThan(
            component.content.count,
            defaultContent.count,
            "SAM Minimal Tool-Backed Claims should be more concise than SAM Default."
        )
    }
}
