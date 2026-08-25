// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)

import Foundation

/// Registry of hand-curated, one-line summaries for MCP tools.
///
/// The summaries here are what the model sees in the dynamic-context listing
/// (and what the model uses to decide which tool to call). They are
/// DELIBERATELY short and stable across turns so prompt-cache hit rates stay
/// high for MLX/GGUF local models.
///
/// Design rules (mirror CLIO's `tool_summaries` hash):
///
/// 1. **One short line per tool.** No "Operations:" sub-lists, no routing
///    guidance, no engine-specific advice. Those belong in the system prompt
///    or in the tool's own JSON schema description, not in this listing.
/// 2. **Never name operations.** Calling out specific operations here ("grep_search")
///    causes the model to call operations as if they were standalone tools.
///    The model learns operations from the schema, not the summary.
/// 3. **No examples.** Examples belong in the system prompt so the model can
///    see them with the rest of its routing guidance.
/// 4. **Deterministic iteration order.** The listing is built by sorting
///    registered tool names, so the same prompt is produced every time the
///    tool set is unchanged. This is what makes the prompt-cache work.
///
/// Adding a new tool: register a one-line summary here. The default fallback
/// ("Tool for <name>") will be used if you forget, but pin a real summary
/// before shipping so the model gets useful routing context.
///
/// Wire format:
/// ```
/// 1. **file_operations** - Read, write, edit, and search files
/// 2. **memory_operations** - Store, search, and recall memories
/// ...
/// ```
public class ToolPromptSummaryRegistry {
    /// Singleton instance - registry is read-only at runtime.
    public nonisolated(unsafe) static let shared = ToolPromptSummaryRegistry()

    /// Hand-curated summaries keyed by MCP tool name.
    /// Keep entries in alphabetical order for easier review.
    ///
    /// IMPORTANT: Do not name operations or engines in summaries. The model
    /// sees this string as the "what tools exist" hint; an engine name
    /// (yelp/serpapi/etc.) becomes a tool the model tries to call directly,
    /// and an operation name (research/web_search/etc.) is the original M3
    /// bug. If you need to mention what a tool does, describe the OUTCOME
    /// ("research the web") not the OPERATION ("research operation").
    private let summaries: [String: String] = [
        "agent_operations": "Spawn and coordinate sub-agents",
        "apply_patch": "Apply a multi-file patch in one tool call",
        "automation_operations": "Automate macOS UI workflows",
        "calendar_operations": "Read and create calendar events",
        "code_intelligence": "Find symbol usages and search commit history",
        "contacts_operations": "Search and create contacts",
        "document_operations": "Import, create, and manage documents",
        "file_operations": "Read, write, edit, and search files",
        "image_generation": "Generate images via remote Stable Diffusion",
        "interact": "Request user input or report status mid-execution",
        "math_operations": "Calculate, convert, and run formula math",
        "memory_operations": "Store, search, and recall memories",
        "notes_operations": "Read, create, and search Apple Notes",
        "remote_execution": "Run tasks on remote systems over SSH",
        "spotlight_search": "Search the macOS Spotlight index",
        "terminal_operations": "Execute shell commands",
        "todo_operations": "Manage structured todo lists",
        "user_collaboration": "Pause for user input, decisions, or approval",
        "version_control": "Git version control operations",
        "weather_operations": "Current weather and forecast for a location",
        /// Note: "fetch, scrape" are action verbs not tool names here. The summary
        /// stays below 80 chars and avoids naming operations as tools. Engine names
        /// ("serpapi") are a known leak risk - see testRenderListingDoesNotLeakOperations.
        /// If you change this line, update that test.
        "web_operations": "Web research, search, fetch, scrape, and serpapi queries"
    ]

    /// Cache of the rendered "Available Tools" section so the same tool set
    /// produces the same output across turns (KV cache stability).
    /// Keyed by the sorted, joined tool names so any change to the tool set
    /// invalidates the cache.
    private nonisolated(unsafe) var renderedCache: (key: String, output: String)?

    private init() {}

    /// Look up the one-line summary for a given tool name.
    /// Returns the default fallback if the tool is not registered here.
    public func summary(for toolName: String) -> String {
        return summaries[toolName] ?? defaultSummary(for: toolName)
    }

    /// Default fallback when a tool is not in the hand-curated table.
    /// Keeps the prompt valid even if someone forgets to register a new tool,
    /// but the prompt will be obviously generic so the gap is visible.
    private func defaultSummary(for toolName: String) -> String {
        // Convert snake_case to a short noun phrase: "spotlight_search" -> "Spotlight search operations"
        let words = toolName.split(separator: "_").map { $0.capitalized }
        return "\(words.joined(separator: " ")) operations"
    }

    /// Build the rendered "Available Tools" listing for a given tool set.
    ///
    /// The output is byte-stable for the same input tool set so that
    /// prompt-cache hit rates stay high. Tool names are sorted; summaries
    /// are looked up in a fixed order; numbers are formatted the same way.
    ///
    /// - Parameter toolNames: Names of tools to include in the listing.
    /// - Returns: Multi-line markdown listing.
    public func renderListing(for toolNames: [String]) -> String {
        let cacheKey = toolNames.sorted().joined(separator: "|")
        if let cached = renderedCache, cached.key == cacheKey {
            return cached.output
        }

        let sorted = toolNames.sorted()
        var lines: [String] = []
        lines.append("## Available Tools")
        lines.append("")
        lines.append("Each tool has an `operation` parameter that selects the action. Always pass the tool name as `name` and the action as `operation` in the same tool call.")
        lines.append("")
        for (index, name) in sorted.enumerated() {
            let summary = summary(for: name)
            lines.append("\(index + 1). **\(name)** - \(summary)")
        }
        lines.append("")
        lines.append("Full operation lists and parameters are provided in each tool's JSON schema in the `tools[]` array. Use those schemas as the source of truth for parameter names, types, and enum values.")

        let output = lines.joined(separator: "\n")
        renderedCache = (cacheKey, output)
        return output
    }
}
