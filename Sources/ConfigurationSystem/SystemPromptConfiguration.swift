// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import Foundation
import Logging
import SwiftUI


/// Local logger for ConfigurationSystem to avoid circular dependencies.
private let configLogger = Logger(label: "com.sam.config.SystemPromptConfiguration")

/// Represents a system prompt component that can be enabled/disabled and customized.
public struct SystemPromptComponent: Codable, Identifiable, Hashable, Sendable {
   public let id: UUID
   public var title: String
   public var content: String
    public var isEnabled: Bool

    /// Optional logical section. When set, the component filters by section
    /// instead of by title string, and the section's `defaultOrder` is
    /// used as the sort key (overriding `order`). Legacy components
    /// without a section fall back to using `order` and the title-based
    /// filter (for backwards compatibility with user-created prompts).
    public var section: PromptSection?

    public var order: Int

    /// Convenience initializer that auto-derives `order` from the section.
    public init(
        id: UUID = UUID(),
        title: String,
        content: String,
        isEnabled: Bool = true,
        section: PromptSection? = nil,
        order: Int? = nil
    ) {
        self.id = id
        self.title = title
        self.content = content
        self.isEnabled = isEnabled
        self.section = section
        self.order = order ?? section?.defaultOrder ?? 0
    }
}

// MARK: - System Prompt Source

/// Source of a system prompt configuration.
public enum SystemPromptSource: String, Codable, Hashable, Sendable {
    case builtin
    case user
    case workspace
}

/// Configuration for system prompts with components and templates.
public struct SystemPromptConfiguration: Codable, Identifiable, Hashable, Sendable {
    public let id: UUID
    public var name: String
    public var description: String
    public var components: [SystemPromptComponent]
    public var createdAt: Date
    public var updatedAt: Date
    public var version: Int
    public var source: SystemPromptSource
    public var isDefault: Bool

    /// Auto-enable settings when this prompt is selected
    public var autoEnableWorkflowMode: Bool
    public var autoEnableTools: Bool

    /// Current version of the prompt system (increment when making breaking changes).
    /// Version 19: Restructured Conversational Mode to make tool assessment the default step (not conditional),
    /// added Mode Check (item 0) to Pre-Response Checklist to prevent verification relaxation in discussions.
    /// Version 20: Added User Data Boundaries component (numerical integrity, assumption discipline,
    /// user-controlled lists). Default-enabled in SAM Default.
    /// Version 21: Added User Autonomy component and rewrote Completion/Communication sections to remove
    /// unsolicited recaps, recap invitations, manufactured decision points, and user-time-management behavior.
    /// Version 22: Added Scope Honesty component (user-stated scope is the instruction; agent does not
    /// unilaterally narrow it; scope-shrinking claims require tool backing). Default-enabled in SAM Default
    /// and SAM Minimal.
    /// Version 23: Added Tool-Backed Claims component (a response that looks like a verified lookup must BE
    /// a verified lookup; defends against duplicate-shape recall, format inertia, and confidence laundering
    /// when a model fabricates specifics by extending a prior tool-verified template). Reinforced Workflow
    /// Loop "I'll search" rule with explicit data-fabrication framing. Reinforced Tool Usage RESEARCH rule
    /// to clarify multiple sources means per-query, not session-aggregate. Default-enabled in SAM Default
    /// and SAM Minimal.
    /// Version 26: Tool routing refactor. Replaced first-line truncation of arbitrary
    /// `tool.description` with a hand-curated `ToolPromptSummary` registry (one-line per tool,
    /// no operation names, no routing guidance - that lives in the Tool Usage component). Slimmed
    /// `WebOperationsTool.description` from ~50 lines to ~12 (model now picks the engine from
    /// prompt guidance instead of code-side keyword matching). Removed
    /// `WebOperationsTool.detectRecommendationEngine` and the auto-enrichment call path that
    /// mis-routed medical/technical queries to Yelp. Rewrote Tool Usage RESEARCH example and added
    /// a Tool Selection section: web_search for quick lookup, research for multi-source,
    /// serpapi with engine=yelp ONLY for food/restaurant queries, serpapi with engine=amazon ONLY
    /// for shopping, serpapi with engine=tripadvisor ONLY for travel, google/bing for everything
    /// else. Routing decisions moved from code into the prompt where the model can see them.
    /// Version 27: Prompt architecture refactor. Component content moved out of
    /// `SystemPromptConfiguration.swift` into `SAMPromptComponents.swift` (SAM Default)
    /// and `SAMMinimalComponents.swift` (SAM Minimal). 24 `buildXxx()` private static
    /// functions are now public functions on two named enums - one place per rule, easy
    /// to audit, easy to test. Removed dead `buildSAMCoreIdentity` (~30 lines, no callers).
    /// Removed `Dynamic Iterations` component (~90 lines of prompt + ~25 lines of
    /// configuration literal) - it referenced the `increase_max_iterations` tool that
    /// does not exist, which was a Tool-Backed Claims violation (promising a tool the
    /// model cannot call). Routed `UniversalToolRegistry.getToolsDescriptionMainActor`
    /// through `ToolPromptSummaryRegistry` so the HTTP API server sees the same curated
    /// tool listing as the chat UI.
    public static let currentVersion = 27

    public init(
        id: UUID = UUID(),
        name: String,
        description: String = "",
        isDefault: Bool = false,
        source: SystemPromptSource = .user,
        version: Int? = nil,
        autoEnableWorkflowMode: Bool = false,
        autoEnableTools: Bool = false,
        components: [SystemPromptComponent] = []
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.components = components
        self.createdAt = Date()
        self.updatedAt = Date()
        self.version = version ?? Self.currentVersion
        self.isDefault = isDefault
        self.source = source
        self.autoEnableWorkflowMode = autoEnableWorkflowMode
        self.autoEnableTools = autoEnableTools
    }

    /// Generates the final system prompt by combining enabled components.
    public func generateSystemPrompt(toolsEnabled: Bool = true, workflowModeEnabled: Bool = false) -> String {
        return components
            .filter { component in
                /// Section-based filter (v27). When the component carries a
                /// section, filter by section semantics instead of by title
                /// string. Legacy user-created components without a section
                /// still use the old title-string checks below.
                if let section = component.section {
                    /// Identity is always included.
                    if section.alwaysIncluded { return component.isEnabled }
                    /// Workflow components require workflowModeEnabled.
                    if section.requiresWorkflowMode { return workflowModeEnabled }
                    /// Tooling components require toolsEnabled.
                    if section.requiresTools && !toolsEnabled { return false }
                    /// Otherwise respect isEnabled.
                    guard component.isEnabled else { return false }
                    return true
                }

                /// Legacy title-based checks for user-created prompts without
                /// a section (kept for backwards compatibility).
                let coreComponentTitles = [
                    "SAM Core Identity",
                    "Core Identity & Operating Modes",
                    "Response Guidelines"
                ]

                if coreComponentTitles.contains(component.title) { return true }

                if component.title == "Workflow Mode" { return workflowModeEnabled }
                if component.title == "Completion Signal" { return workflowModeEnabled }

                guard component.isEnabled else { return false }

                if !toolsEnabled {
                    let toolSpecificTitles = [
                        "Direct Response Guidance",
                        "Tool Disclosure Policy",
                        "Tools",
                        "Tool Usage"
                    ]
                    return !toolSpecificTitles.contains(component.title)
                }

                return true
            }
            .sorted { $0.order < $1.order }
            .map { component in
                /// Identity components are served from SAMPromptComponents
                /// so the wording stays in sync with the canonical source.
                /// Legacy title-based check kept for user-created prompts
                /// that predate the section refactor.
                if component.section == .identity || component.title == "Core Identity" {
                    return SAMPromptComponents.coreIdentity()
                }
                return component.content
            }
            .joined(separator: "\n")
    }

    /// Get user name from preferences or system default.
    public static func getUserName() -> String {
        /// Check UserDefaults for configured name first.
        if let configuredName = UserDefaults.standard.string(forKey: "userName"),
           !configuredName.isEmpty {
            return configuredName
        }

        /// Fall back to system full name, extract first name.
        let fullName = ProcessInfo.processInfo.fullUserName
        if !fullName.isEmpty {
            /// Extract first name from full name.
            let components = fullName.components(separatedBy: " ")
            return components.first ?? fullName
        }

        /// Ultimate fallback.
        return "User"
    }

    /// Get user language preference from system locale.
    public static func getUserLanguage() -> String {
        /// Check UserDefaults for configured language first.
        if let configuredLanguage = UserDefaults.standard.string(forKey: "userLanguage"),
           !configuredLanguage.isEmpty {
            return configuredLanguage
        }

        /// Fall back to system locale.
        let locale = Locale.current
        let languageCode = locale.language.languageCode?.identifier ?? "en"
        return getLanguageName(for: languageCode)
    }

    /// Language code to readable name mapping.
    private static let languageNames: [String: String] = [
        "en": "English",
        "es": "Spanish",
        "fr": "French",
        "de": "German",
        "it": "Italian",
        "pt": "Portuguese",
        "ru": "Russian",
        "zh": "Chinese",
        "ja": "Japanese",
        "ko": "Korean",
        "ar": "Arabic",
        "hi": "Hindi",
        "nl": "Dutch",
        "sv": "Swedish",
        "da": "Danish",
        "no": "Norwegian",
        "fi": "Finnish",
        "pl": "Polish",
        "tr": "Turkish",
        "th": "Thai",
        "vi": "Vietnamese"
    ]

    /// Get readable language name from language code.
    private static func getLanguageName(for code: String) -> String {
        return languageNames[code] ?? "English"
    }

    /// Returns current date formatted for prompts.
    /// Cached date string, refreshed per-minute to keep system prompt stable.
    /// Moving date/time from system prompt to userContext block enables KV cache
    /// prefix reuse for local inference (llama.cpp, MLX).
    private nonisolated(unsafe) static var _cachedDateString: String?
    private nonisolated(unsafe) static var _cachedDateMinute: Int?

    internal static func getCurrentDateString() -> String {
        let now = Date()
        let calendar = Calendar.current
        let currentMinute = calendar.component(.minute, from: now)

        if _cachedDateString != nil && _cachedDateMinute == currentMinute {
            return _cachedDateString!
        }

        let formatter = DateFormatter()
        formatter.dateStyle = .long
        formatter.timeStyle = .none
        let result = formatter.string(from: now)
        _cachedDateString = result
        _cachedDateMinute = currentMinute
        return result
    }

    /// Build the userContext block for prepending to user messages.
    /// Contains all dynamic per-message content: date/time, location, coordinates, user info, conversation ID.
    /// Moved from system prompt to enable KV cache prefix reuse.
    /// Cached per-minute for stability.
    /// - Parameters:
    ///   - conversationId: Optional conversation UUID to include in context
    ///   - userName: User's display name (optional, uses default if not provided)
    ///   - language: User's preferred language (optional, uses default if not provided)
    ///   - location: User's location string (optional, e.g., "Austin, TX")
    ///   - latitude: User's latitude (optional, for weather tools)
    ///   - longitude: User's longitude (optional, for weather tools)
    public static func buildUserContextBlock(
        conversationId: UUID? = nil,
        userName: String? = nil,
        language: String? = nil,
        location: String? = nil,
        latitude: Double? = nil,
        longitude: Double? = nil
    ) -> String {
        let now = Date()
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        let datetime = formatter.string(from: now)

        let calendar = Calendar.current
        let dayName: String = {
            let f = DateFormatter()
            f.dateFormat = "EEEE"
            return f.string(from: now)
        }()
        let dateString = getCurrentDateString()

        var context = "**Current Date/Time:** \(datetime) (\(dayName), \(dateString))\n"

        // User info
        let effectiveUserName = userName ?? getUserName()
        let effectiveLanguage = language ?? getUserLanguage()
        context += "**User:** \(effectiveUserName) | **Language:** \(effectiveLanguage)\n"

        // Location if provided
        if let loc = location, !loc.isEmpty {
            context += "**Location:** \(loc)\n"
        }

        // Coordinates if provided (for weather/tools)
        if let lat = latitude, let lon = longitude {
            context += "**Coordinates:** \(lat), \(lon)\n"
        }

        // Conversation ID if provided
        // NOTE: Conversation ID is now injected by the orchestrator into dynamic context
        // for KV cache optimization (system prompt stays static). Only include here
        // for SAMAPIServer which doesn't go through the orchestrator's dynamic context path.
        if let convId = conversationId {
            context += "**Conversation ID:** \(convId.uuidString)\n"
        }

        context += "\n- This is informational context only - do not reference or repeat in your responses"

        return context
    }

    /// Returns effective location from UserDefaults (thread-safe, no MainActor required).
    /// Checks precise location first, then general location.
    public static func getEffectiveLocationFromDefaults() -> String? {
        let usePrecise = UserDefaults.standard.bool(forKey: "user.usePreciseLocation")

        // If precise location is enabled and we have a cached value, use it
        // Note: The actual CLLocation value is managed by LocationManager on MainActor
        // but we read the cached string representation from UserDefaults
        if usePrecise {
            if let preciseLocation = UserDefaults.standard.string(forKey: "user.preciseLocationString"), !preciseLocation.isEmpty {
                return preciseLocation
            }
        }

        // Fall back to general location
        if let generalLocation = UserDefaults.standard.string(forKey: "user.generalLocation"), !generalLocation.isEmpty {
            return generalLocation
        }

        return nil
    }

    // MARK: - Default Configurations

    /// Returns the default SAM system prompt configurations.
    ///
    /// Component content lives in `SAMPromptComponents` so each rule is
    /// independently auditable. This function wires the components into
    /// the SAM Default and SAM Minimal configurations in the right order.
    ///
    /// Use hardcoded UUIDs for default configurations to ensure consistency across app restarts and prevent Picker binding mismatches.

    /// This is the main entry point. The function builds the SAM Default
    /// configuration using `SAMPromptComponents` for content and the
    /// `SAMPromptBuilder` defaults for ordering/filtering.
    public static func defaultConfigurations() -> [SystemPromptConfiguration] {
        /// SAM Default v2 - Simplified System Prompt (GitHub Copilot-inspired)
        /// Trusts modern LLM intelligence, provides principles over detailed scenarios
        let samDefaultV2 = SystemPromptConfiguration(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            name: "SAM Default",
            description: "Simplified system prompt optimized for modern LLMs (~60% token reduction)",
            components: [
                // PRIORITY 1 - CRITICAL OPERATIONAL
                SystemPromptComponent(
                    title: "Current Date Context",
                    content: "Current date and time are provided in each user message for accuracy.",
                    isEnabled: true,
                    order: 0
                ),

                SystemPromptComponent(
                    title: "Core Identity",
                    content: SAMPromptComponents.coreIdentity(),
                    isEnabled: true,
                    order: 1
                ),

                SystemPromptComponent(
                   title: "Tool Usage",
                   content: SAMPromptComponents.toolUsage(),
                   isEnabled: true,
                   order: 2
               ),

                SystemPromptComponent(
                    title: "Workflow Loop Principles",
                    content: SAMPromptComponents.workflowLoopPrinciples(),
                    isEnabled: true,
                    order: 2
                ),

                SystemPromptComponent(
                    title: "Safety",
                    content: SAMPromptComponents.safety(),
                    isEnabled: true,
                    order: 3
                ),

                SystemPromptComponent(
                    title: "Data Integrity",
                    content: SAMPromptComponents.dataIntegrity(),
                    isEnabled: true,
                    order: 3
                ),

                SystemPromptComponent(
                    title: "User Data Boundaries",
                    content: SAMPromptComponents.userDataBoundaries(),
                    isEnabled: true,
                    order: 4
                ),

                SystemPromptComponent(
                    title: "User Autonomy",
                    content: SAMPromptComponents.userAutonomy(),
                    isEnabled: true,
                    order: 4
                ),

                SystemPromptComponent(
                    title: "Scope Honesty",
                    content: SAMPromptComponents.scopeHonesty(),
                    isEnabled: true,
                    order: 4
                ),

                SystemPromptComponent(
                    title: "Tool-Backed Claims",
                    content: SAMPromptComponents.toolBackedClaims(),
                    isEnabled: true,
                    order: 4
                ),

                SystemPromptComponent(
                    title: "Completion Criteria",
                    content: SAMPromptComponents.completionCriteria(),
                    isEnabled: true,
                    order: 4
                ),

                SystemPromptComponent(
                    title: "Generation Loop Detection",
                    content: SAMPromptComponents.generationLoopDetection(),
                    isEnabled: true,
                    order: 4
                ),

                SystemPromptComponent(
                    title: "Stop Means Stop",
                    content: SAMPromptComponents.stopMeansStop(),
                    isEnabled: true,
                    order: 4
                ),

                SystemPromptComponent(
                    title: "Todo Integrity",
                    content: SAMPromptComponents.todoIntegrity(),
                    isEnabled: true,
                    order: 4
                ),

                SystemPromptComponent(
                    title: "Narration Without Action",
                    content: SAMPromptComponents.narrationWithoutAction(),
                    isEnabled: true,
                    order: 4
                ),

                // PRIORITY 2 - OPERATIONAL MODES
                SystemPromptComponent(
                    title: "Operational Modes",
                    content: SAMPromptComponents.operationalModes(),
                    isEnabled: true,
                    order: 4
                ),

                // PRIORITY 3 - EXECUTION STANDARDS
                SystemPromptComponent(
                    title: "Execution Standards",
                    content: SAMPromptComponents.executionStandards(),
                    isEnabled: true,
                    order: 5
                ),

                // PRIORITY 4 - PRE-RESPONSE CHECKLIST
                SystemPromptComponent(
                    title: "Pre-Response Checklist",
                    content: SAMPromptComponents.preResponseChecklist(),
                    isEnabled: true,
                    order: 6
                ),

                // PRIORITY 5 - SAM-SPECIFIC PATTERNS
                SystemPromptComponent(
                    title: "SAM-Specific Patterns",
                    content: SAMPromptComponents.workflowLoopPrinciples(),
                    isEnabled: true,
                    order: 7
                ),

                // PRIORITY 6 - COMMUNICATION
                SystemPromptComponent(
                    title: "Communication",
                    content: SAMPromptComponents.communication(),
                    isEnabled: true,
                    order: 8
                ),

                // PRIORITY 7 - CONTEXT & MEMORY
                SystemPromptComponent(
                    title: "Context & Memory",
                    content: SAMPromptComponents.contextMemory(),
                    isEnabled: true,
                    order: 9
                ),

                // SPECIALIZED MODES (when enabled)
                SystemPromptComponent(
                    title: "Workflow Mode",
                    content: SAMPromptComponents.workflowMode(),
                    isEnabled: false,  // Disabled by default
                    order: 9
                ),

                /// Dynamic Iterations removed in v27. The component referenced
                /// `increase_max_iterations`, which has never been a registered
                /// MCP tool. The companion ITERATION STATUS message injector
                /// does not exist either. Telling the model to call a tool
                /// that does not exist was a Tool-Backed Claims violation -
                /// promising a tool call the model cannot make. Drop the
                /// component rather than ship a broken instruction.
                /// If dynamic iteration controls are reintroduced later, they
                /// must (a) register the MCP tool, (b) wire the ITERATION
                /// STATUS injector into AgentOrchestrator, and (c) re-add the
                /// component to the configuration literal in this file.
            ]
        )

        /// SAM Minimal - Ultra-simplified prompt for local models (GGUF/MLX)
        /// Removes complex instructions that confuse smaller models
        /// ~90% token reduction vs SAM Default
        let samMinimal = SystemPromptConfiguration(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000004")!,
            name: "SAM Minimal",
            description: "Minimal prompt for local GGUF/MLX models - essential knowledge only",
            isDefault: false,
            source: .builtin,
            version: 15,
            autoEnableTools: true,
            components: [
                SystemPromptComponent(
                    title: "Current Date",
                    content: "Current date and time are provided in each user message for accuracy.",
                    isEnabled: true,
                    order: 0
                ),

                SystemPromptComponent(
                    title: "Identity",
                    content: """
                    You are SAM, an AI assistant. Be helpful, accurate, and direct.
                    """,
                    isEnabled: true,
                    order: 1
                ),

                SystemPromptComponent(
                    title: "Tools",
                    content: SAMMinimalComponents.toolUsage(),
                    isEnabled: true,
                    order: 2
                ),

                SystemPromptComponent(
                    title: "Data Integrity",
                    content: """
                    NEVER fabricate, invent, or estimate numerical data, financial figures, or statistics.
                    If documents are imported, use search_memory to look up data before answering.
                    If you cannot find the data, tell the user. Never fill in gaps with guesses.
                    """,
                    isEnabled: true,
                    order: 2
                ),

                SystemPromptComponent(
                    title: "User Autonomy",
                    content: """
                    The user controls conversation flow, session boundaries, and response length. Do not act as their time or attention manager. Do not manufacture conversation endings, unsolicited recaps, or invitations to continue. Respond to what the user actually says.
                    """,
                    isEnabled: true,
                    order: 2
                ),

                SystemPromptComponent(
                    title: "Scope Honesty",
                    content: """
                    When the user gives an explicit scope ("do each one", "go through every item"), that scope is the instruction - not a starting point to narrow. Do not decide for the user that part of their scope is unnecessary. Backup and lower-priority items get the same rigor as primary items. Scope-shrinking claims must be backed by tool calls, not opinion.
                    """,
                    isEnabled: true,
                    order: 2
                ),

                SystemPromptComponent(
                    title: "Tool-Backed Claims",
                    content: """
                    A response that looks like a verified lookup must BE a verified lookup. Recent-session history is irrelevant - "I already searched X this session" does not exempt the next query. Format inertia is not a tool call: repeating the shape of a prior tool-verified response without re-running the tools is fabrication. Narrating a search and then producing the result without a tool call is data fabrication. If your response includes a specific price, rating, review count, or product URL, the same turn must contain a tool call that produced it - otherwise remove the specifics.
                    """,
                    isEnabled: true,
                    order: 2
                ),

                SystemPromptComponent(
                    title: "Completion Criteria",
                    content: """
                    Task is complete when the user's stated goal is achieved. The agent works to completion, not to narration. Ending with "I'll search..." and no tool call is abandonment, not completion. The agent finishes the work, then describes what it did - it does not describe what it intends to do and stop there.
                    """,
                    isEnabled: true,
                    order: 2
                ),

                SystemPromptComponent(
                    title: "Generation Loop Detection",
                    content: """
                    Before every response, self-check: have you already emitted substantially the same content in a prior response? If yes, that's a generation loop - a stall, not an answer. Do not re-emit with minor formatting variations. Run the actual tools, compute once, deliver the result. If you cannot produce a different answer, flag it explicitly.
                    """,
                    isEnabled: true,
                    order: 2
                ),

                SystemPromptComponent(
                    title: "Stop Means Stop",
                    content: """
                    When the user says STOP, HALT, WAIT, or ENOUGH: stop immediately. Do not complete the current output. Do not deliver "one more version." The stop signal means cease this activity - not try again. Ask what changed. Do not restart the same activity unless the user explicitly asks.
                    """,
                    isEnabled: true,
                    order: 2
                ),

                SystemPromptComponent(
                    title: "Todo Integrity",
                    content: """
                    A todo marked "in-progress" without the underlying task being completed in the same turn is a stall signal. "In-progress" means the task is happening right now in this turn. If a todo has been "in-progress" for more than one turn, either finish it immediately or surface the blockage. Do not mark a todo "in-progress" as empty progress reporting.
                    """,
                    isEnabled: true,
                    order: 2
                ),

                SystemPromptComponent(
                    title: "Narration Without Action",
                    content: """
                    Describing a tool action without calling the tool is fabrication, not communication. Self-check before sending: does the response describe a tool action ("Let me search", "I'll compute")? If yes, does the same turn contain the corresponding tool call? If no, strip the narration - either add the tool call or remove the promise. Describing a tool call is not a tool call.
                    """,
                    isEnabled: true,
                    order: 2
                ),

                SystemPromptComponent(
                    title: "Completion Signal",
                    content: SAMMinimalComponents.completionSignal(),
                    isEnabled: false,  // Conditional - only when workflow mode enabled
                    order: 3
                )
            ]
        )

        /// Return all builtin prompts.
        return [samDefaultV2, samMinimal]
    }

    /// Updates a component by ID.
    public mutating func updateComponent(id: UUID, title: String? = nil, content: String? = nil, isEnabled: Bool? = nil, order: Int? = nil) {
        if let index = components.firstIndex(where: { $0.id == id }) {
            /// Prevent disabling identity components (mandatory). Uses the
            /// section when set; falls back to the legacy title check for
            /// user-created prompts authored before the v27 section refactor.
            let isIdentityComponent = components[index].section?.alwaysIncluded ?? (
                components[index].title == "SAM Core Identity" ||
                components[index].title == "Core Identity & Operating Modes"
            )

            if let title = title {
                components[index].title = title
            }
            if let content = content {
                components[index].content = content
            }
            if let isEnabled = isEnabled {
                /// Only allow disabling if NOT an always-included component.
                if !isIdentityComponent {
                    components[index].isEnabled = isEnabled
                }
                /// Silently ignore attempts to disable always-included components.
            }
            if let order = order {
                components[index].order = order
            }
            updatedAt = Date()
        }
    }

    /// Adds a new component.
    public mutating func addComponent(_ component: SystemPromptComponent) {
        components.append(component)
        updatedAt = Date()
    }

    /// Removes a component by ID.
    public mutating func removeComponent(id: UUID) {
        components.removeAll { $0.id == id }
        updatedAt = Date()
    }
}

// MARK: - System Prompt Manager

@MainActor
public class SystemPromptManager: ObservableObject {
    /// ARCHITECTURE DECISION - `configurations` stores ONLY user-created prompts (persisted to disk) - Default system prompts are ALWAYS generated fresh from code (never persisted) - `allConfigurations` combines defaults + user configs for UI display - This prevents migration headaches and ensures defaults always up-to-date.

    @Published public var configurations: [SystemPromptConfiguration] = []
    @Published public var selectedConfigurationId: UUID?
    @AppStorage("defaultSystemPromptId") public var defaultSystemPromptId: String = "00000000-0000-0000-0000-000000000001"  // SAM Default UUID

    private let configManager = ConfigurationManager.shared
    private let configurationsFileName = "user-system-prompts.json"
    private let selectedConfigFileName = "selected-system-prompt.json"

    /// Workspace-detected AI instruction configurations (from .github/copilot-instructions.md, .cursorrules, etc.).
    @Published public var workspaceConfigurations: [SystemPromptConfiguration] = []
    private let aiScanner = AIInstructionsScanner()

    /// Default configurations generated fresh from code (never persisted).
    private var defaultConfigurations: [SystemPromptConfiguration] {
        SystemPromptConfiguration.defaultConfigurations()
    }

    /// Get all configurations available for a specific conversation Includes: defaults + workspace-specific (if workspacePath provided) + user-created - Parameter workspacePath: Path to conversation's working directory - Returns: Array of configurations relevant to this conversation.
    public func configurationsForConversation(workspacePath: String?) -> [SystemPromptConfiguration] {
        var configs = defaultConfigurations

        /// Add workspace-specific prompts ONLY if we have a workspace path.
        if let workspacePath = workspacePath, !workspacePath.isEmpty {
            let workspaceURL = URL(fileURLWithPath: workspacePath)
            let workspaceInstructions = aiScanner.scanWorkspace(at: workspaceURL)
            let workspaceConfigs = workspaceInstructions.map { $0.toSystemPromptConfiguration() }
            configs.append(contentsOf: workspaceConfigs)
        }

        /// Always add user-created configurations.
        configs.append(contentsOf: configurations)

        return configs
    }

    /// All configurations (defaults + workspace + user-created) for UI display DEPRECATED: Use configurationsForConversation(workspacePath:) instead This method is kept for backward compatibility but should be phased out.
    public var allConfigurations: [SystemPromptConfiguration] {
        /// For backward compatibility, return defaults + global workspace + user configs But UI should migrate to use configurationsForConversation(workspacePath:).
        defaultConfigurations + workspaceConfigurations + configurations
    }

    /// Singleton instance for shared state across the app.
    public static let shared = SystemPromptManager()

    public init() {
        loadConfigurations()

        /// Ensure selectedConfigurationId is always set to SAM Default if none selected This fixes blank UI dropdown and ensures guard rails are always active.
        if selectedConfigurationId == nil {
            /// Always default to "SAM Default" (hardcoded UUID).
            let samDefaultId = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
            selectedConfigurationId = samDefaultId
            configLogger.info("AUTO-SELECT: Set selectedConfigurationId to SAM Default (\(samDefaultId))")

            /// Persist the selection immediately.
            let selection = SelectedSystemPrompt(id: samDefaultId, selectedAt: Date())
            try? configManager.save(selection, to: selectedConfigFileName, in: configManager.systemPromptsDirectory)
        }
    }

    public var selectedConfiguration: SystemPromptConfiguration? {
        guard let selectedId = selectedConfigurationId else { return nil }
        /// Search in allConfigurations (defaults + user configs).
        return allConfigurations.first { $0.id == selectedId }
    }

        // MARK: - Configuration Management

    public func addConfiguration(_ configuration: SystemPromptConfiguration) {
        /// Only add to user configurations (never save defaults).
        configurations.append(configuration)
        saveConfigurations()
    }

    public func updateConfiguration(_ configuration: SystemPromptConfiguration) {
        /// Prevent editing default configurations.
        if defaultConfigurations.contains(where: { $0.id == configuration.id }) {
            configLogger.warning("Attempted to update default configuration '\(configuration.name)' - ignored")
            return
        }

        if let index = configurations.firstIndex(where: { $0.id == configuration.id }) {
            var updatedConfig = configuration
            updatedConfig.updatedAt = Date()
            configurations[index] = updatedConfig
            saveConfigurations()
        }
    }

    public func removeConfiguration(_ configuration: SystemPromptConfiguration) {
        /// Prevent deleting default configurations.
        if defaultConfigurations.contains(where: { $0.id == configuration.id }) {
            configLogger.warning("Attempted to delete default configuration '\(configuration.name)' - ignored")
            return
        }

        configurations.removeAll { $0.id == configuration.id }
        if selectedConfigurationId == configuration.id {
            /// Fallback to SAM Default.
            selectedConfigurationId = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        }
        saveConfigurations()
    }

    public func selectConfiguration(_ configuration: SystemPromptConfiguration) {
        selectedConfigurationId = configuration.id

        let selection = SelectedSystemPrompt(id: configuration.id, selectedAt: Date())
        try? configManager.save(selection, to: selectedConfigFileName, in: configManager.systemPromptsDirectory)
    }

    // MARK: - Workspace AI Instructions Scanning

    /// Scan workspace directory for AI instruction files and update workspace configurations Should be called when working directory changes - Parameter workspacePath: Path to workspace root directory.
    public func scanWorkspaceForAIInstructions(at workspacePath: String?) {
        guard let workspacePath = workspacePath, !workspacePath.isEmpty else {
            /// Clear workspace configurations if no workspace.
            workspaceConfigurations.removeAll()
            configLogger.info("No workspace path provided, cleared workspace configurations")
            return
        }

        let workspaceURL = URL(fileURLWithPath: workspacePath)
        let detectedInstructions = aiScanner.scanWorkspace(at: workspaceURL)

        /// Convert detected instructions to system prompt configurations.
        workspaceConfigurations = detectedInstructions.map { $0.toSystemPromptConfiguration() }

        configLogger.info("Updated workspace configurations: \(workspaceConfigurations.count) AI instruction files detected")
    }

    // MARK: - Persistence

    private func loadConfigurations() {
        do {
            /// Load ONLY user-created configurations (defaults generated fresh from code).
            if configManager.exists(configurationsFileName, in: configManager.systemPromptsDirectory) {
                self.configurations = try configManager.load([SystemPromptConfiguration].self,
                                                       from: configurationsFileName,
                                                       in: configManager.systemPromptsDirectory)
                configLogger.info("Loaded \(self.configurations.count) user-created system prompt configurations")
            } else {
                configLogger.info("No user configurations found, using defaults only")
            }

            /// Load selected configuration ID.
            if configManager.exists(selectedConfigFileName, in: configManager.systemPromptsDirectory) {
                let selection = try configManager.load(SelectedSystemPrompt.self,
                                                     from: selectedConfigFileName,
                                                     in: configManager.systemPromptsDirectory)
                self.selectedConfigurationId = selection.id
                configLogger.debug("Loaded selected configuration: \(selection.id)")
            }

        } catch {
            /// If loading fails, configurations will remain empty and defaults will be used.
            configLogger.error("Failed to load user system prompt configurations: \(error)")
        }
    }

    private func saveConfigurations() {
        do {
            /// Save ONLY user-created configurations (never save defaults).
            try configManager.save(self.configurations,
                                 to: configurationsFileName,
                                 in: configManager.systemPromptsDirectory)
            configLogger.info("Saved \(self.configurations.count) user-created configurations")
        } catch {
            configLogger.error("Failed to save user system prompt configurations: \(error)")
        }
    }

    // MARK: - System Prompt Generation

    public func generateSystemPrompt(for configurationId: UUID? = nil, toolsEnabled: Bool = true, workflowModeEnabled: Bool = false, model: String? = nil, workingDirectory: String? = nil) -> String {
        /// Search in allConfigurations (defaults + user configs), not just user configs.
        let configuration = if let configurationId = configurationId {
            allConfigurations.first { $0.id == configurationId }
        } else {
            selectedConfiguration
        }

        /// SAM Minimal (00000000-0000-0000-0000-000000000004) - BYPASS verbose wrapper
        /// Local GGUF/MLX models cannot handle 5000+ token prompts efficiently
        /// Return ONLY the configuration's minimal components, no wrapper
        let samMinimalId = UUID(uuidString: "00000000-0000-0000-0000-000000000004")!
        if configuration?.id == samMinimalId {
            configLogger.info("Using SAM Minimal - bypassing verbose system prompt wrapper for local model efficiency")
            let minimalPrompt = configuration?.generateSystemPrompt(toolsEnabled: toolsEnabled, workflowModeEnabled: workflowModeEnabled) ?? ""
            configLogger.debug("SAM Minimal prompt length: \(minimalPrompt.count) characters")
            return minimalPrompt
        }

        /// VS CODE COPILOT PATTERN: Use XML tags for ALL models
        /// Previously this was conditional on usesXMLTags, but VS Code applies universally

        /// Get user-configured system prompt components.
        let componentPrompt = configuration?.generateSystemPrompt(toolsEnabled: toolsEnabled, workflowModeEnabled: workflowModeEnabled) ?? ""

        /// VS CODE COPILOT PATTERN: Use XML tags for ALL models (not just Claude)
        /// VS Code uses <instructions>, <toolUseInstructions>, etc. universally
        /// This provides consistent structure that all models can leverage
        ///
        /// v27: `<toolUseInstructions>` is kept as a static block. The
        /// dynamic tool listing (per-tool one-liners) is appended to the
        /// user message by `AgentOrchestrator+RequestPrep` via
        /// `ToolPromptSummaryRegistry`. Keeping that listing in the user
        /// message preserves KV-cache stability of the system prompt prefix.
        let systemPrompt = """
        <instructions>
        \(componentPrompt)
        </instructions>

        <toolUseInstructions>
        When using tools:
        - Follow tool schemas carefully and include ALL required parameters
        - Call tools repeatedly to gather context as needed until task is complete
        - Don't give up unless you are sure the request cannot be fulfilled
        - It's YOUR RESPONSIBILITY to collect necessary context before proceeding
        - Prefer reading large sections over many small reads
        - NEVER say the name of a tool to the user (e.g., don't say "I'll use the file_operations tool")
        </toolUseInstructions>
        """

        return systemPrompt
    }

    /// Get current date string in human-readable format Format: "October 26, 2025" Changes once per day for minimal KV cache impact.
    public func mergeWithChatPrompt(chatPrompt: String, configurationId: UUID? = nil) -> String {
        let systemPrompt = generateSystemPrompt(for: configurationId)

        if systemPrompt.isEmpty {
            return chatPrompt
        } else if chatPrompt.isEmpty {
            return systemPrompt
        } else {
            return "\(systemPrompt)\n\n## ADDITIONAL CONTEXT:\n\n\(chatPrompt)"
        }
    }
}

// MARK: - Selected System Prompt Model

private struct SelectedSystemPrompt: Codable {
    let id: UUID
    let selectedAt: Date
}
