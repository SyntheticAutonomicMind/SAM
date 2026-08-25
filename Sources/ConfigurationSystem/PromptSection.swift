// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)

import Foundation

/// Logical section of a SAM system prompt component.
///
/// Each prompt component belongs to one section. Sections are ordered and
/// the section's `order` value is the canonical position the model sees.
/// Adding a new component no longer requires choosing a magic `order: Int`
/// (the previous design had 11 components sharing `order: 4`); pick a
/// section and the position is fixed.
///
/// Sections are also the basis for filtering. Instead of `if component.title
/// == "Workflow Mode"` (string equality across the codebase), the filter
/// checks `component.section == .workflow` and the section declares whether
/// it is conditional. String-based filters rot; enum-based filters do not.
public enum PromptSection: Int, Codable, CaseIterable, Sendable {
    /// Identity, current date, "you are SAM" framing. Always present.
    /// Cannot be disabled by the user.
    case identity = 0

    /// Tool selection guidance, tool schema reference, workflow loop
    /// primitives. Always present when tools are enabled.
    case tooling = 10

    /// User autonomy, scope honesty, user data boundaries. Atomic rules
    /// about what the user controls. Always present.
    case autonomy = 20

    /// Data integrity, tool-backed claims, scope of fabrication rules.
    /// Numbers, assumptions, lists. Always present.
    case integrity = 30

    /// Completion criteria, generation-loop detection, stop-means-stop,
    /// todo integrity, narration-without-action. Operational discipline.
    /// Always present.
    case completion = 40

    /// Operational modes, execution standards, pre-response checklist,
    /// communication, context memory. Generic operational patterns.
    /// Always present.
    case operational = 50

    /// Workflow Mode and Completion Signal. CONDITIONAL on workflow mode
    /// being enabled. Default-disable; show when the user toggles it.
    case workflow = 60

    /// Computed default order for a component in this section. The model
    /// sees components in this order. Replace magic `order: 4` with
    /// `section: .completion`.
    public var defaultOrder: Int { rawValue }

    /// Whether components in this section should be included by default,
    /// regardless of `component.isEnabled`. Identity is always-on so the
    /// model always knows who it is.
    public var alwaysIncluded: Bool {
        switch self {
        case .identity: return true
        case .workflow: return false
        default: return true
        }
    }

    /// Whether components in this section are conditional on a runtime
    /// flag (currently `workflowModeEnabled`). The filter checks this so
    /// workflow components are dropped by default.
    public var requiresWorkflowMode: Bool {
        self == .workflow
    }

    /// Whether components in this section are conditional on tools being
    /// enabled. Tooling-related components (Tool Usage, Tool Selection)
    /// are dropped when tools are off.
    public var requiresTools: Bool {
        self == .tooling
    }

    /// Human-readable name for the section. Used in editor UI and
    /// debugging logs.
    public var displayName: String {
        switch self {
        case .identity: return "Identity"
        case .tooling: return "Tool Selection"
        case .autonomy: return "User Authority"
        case .integrity: return "Data Integrity"
        case .completion: return "Completion Discipline"
        case .operational: return "Operational Patterns"
        case .workflow: return "Workflow Mode"
        }
    }
}
