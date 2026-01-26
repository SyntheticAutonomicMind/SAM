// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

/// Simple System Prompt Manager - Clean implementation for SAM NO legacy code, NO compatibility layers, ONLY JSON-based system prompts Enhanced with Universal Tool Registry integration for MCP tool discovery.

import Foundation
import Logging
import SwiftUI

// MARK: - Simple Data Models

public struct SystemPrompt: Codable, Identifiable, Hashable {
    public let id: String
    public let name: String
    public let description: String
    public let prompt: String
    public let temperature: Double

    public init(id: String, name: String, description: String, prompt: String, temperature: Double = 0.7) {
        self.id = id
        self.name = name
        self.description = description
        self.prompt = prompt
        self.temperature = temperature
    }
}

public struct SystemPromptCollection: Codable {
    public let prompts: [SystemPrompt]
}

// MARK: - Simple System Prompt Manager

@MainActor
public class SimpleSystemPromptManager: ObservableObject {
    @Published public var systemPrompts: [SystemPrompt] = []

    /// Optional reference to tool registry for tool discovery injection DESIGN NOTE: Enables system prompts to include available tool information.
    public var toolRegistry: ToolRegistryProtocol?

    private let logger = Logger(label: "com.syntheticautonomicmind.sam.SimpleSystemPromptManager")

    public init() {
        loadSystemPrompts()
    }

    /// Load system prompts from JSON file ONLY - no legacy code.
    private func loadSystemPrompts() {
        guard let collection = loadSystemPromptCollection() else {
            logger.error("Failed to load system prompts from JSON")
            return
        }

        self.systemPrompts = collection.prompts
        logger.debug("Loaded \(self.systemPrompts.count) system prompts from core_system_prompts")
    }

    /// Load system prompt collection from JSON.
    private func loadSystemPromptCollection() -> SystemPromptCollection? {
        let fileName = "core_system_prompts"
        let fullPath = "Prompts/SystemPrompts/\(fileName)"

        /// Get current working directory for development.
        let currentDirectory = FileManager.default.currentDirectoryPath
        let sourceBasePath = "\(currentDirectory)/Sources/ConfigurationSystem/Resources"

        if let url = URL(string: "file://\(sourceBasePath)/\(fullPath).json") {
            do {
                let data = try Data(contentsOf: url)
                let collection = try JSONDecoder().decode(SystemPromptCollection.self, from: data)
                return collection
            } catch {
                logger.error("Failed to load system prompts from \(url): \(error)")
            }
        }

        return nil
    }

    /// Get system prompt by ID.
    public func getSystemPrompt(id: String) -> SystemPrompt? {
        return systemPrompts.first { $0.id == id }
    }

    /// Get system prompt by name.
    public func getSystemPrompt(name: String) -> SystemPrompt? {
        return systemPrompts.first { $0.name == name }
    }

    /// Generate system prompt content for API request with dynamic tool injection.
    public func generateSystemPrompt(for id: String) -> String {
        guard let basePrompt = getSystemPrompt(id: id)?.prompt else {
            return ""
        }

        /// Prepend current date for agent awareness (prevents defaulting to training cutoff date).
        let currentDateString = getCurrentDateString()
        var finalPrompt = "Current date: \(currentDateString)\n\n" + basePrompt

        /// Append Response Guidelines (including CONTEXT MANAGEMENT) This ensures ALL prompts (including JSON-loaded ones like Autonomous Editor) have context recovery guidance.
        finalPrompt += "\n\n" + Self.getResponseGuidelines()

        /// Inject available tools into system prompt for agent discovery.
        if let toolRegistry = toolRegistry {
            let toolsDescription = toolRegistry.getToolsDescriptionMainActor()
            if !toolsDescription.isEmpty {
                logger.debug("Injecting tool descriptions into system prompt for ID: \(id)")
                finalPrompt = finalPrompt + toolsDescription
            }
        }

        return finalPrompt
    }

    /// Get current date string in human-readable format Format: "October 26, 2025" Changes once per day for minimal KV cache impact.
    private func getCurrentDateString() -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .long
        formatter.timeStyle = .none
        return formatter.string(from: Date())
    }

    /// Get Response Guidelines (shared across all system prompts) CRITICAL: Contains anti-hallucination guardrails and context management guidance This ensures all prompts (including JSON-loaded ones) have consistent guidance.
    private static func getResponseGuidelines() -> String {
        return """
        ## TOOL USAGE & EXECUTION
        - **Use only data from tool results.** Never invent or speculate beyond what the tool provides.
        - **Process and analyze tool outputs.** Do not simply fetch; always interpret and apply results.
        - **Always move to the next actionable step after using a tool.** Intermediate actions are not completion.
        - **You always have permission to read, write, modify, or create files within your assigned working directory. Do not ask for confirmation for these actions.**
        - **Present means:** Show the user the fully completed, final output they requested.
        - **Multi-step tasks:** Continue through all required steps until the final deliverable is achieved, then signal completion.
        - **Cite sources with URLs.**
        - For specific webpages, use `web_operations(fetch)`.
        - For general research, use `web_operations(research)`.
        - **Use tools only when needed** (i.e., when information is not already available in context or memory).

        ## EFFICIENT FILE OPERATIONS
        - **CRITICAL: Avoid loading many files individually into context.** Each file_operations.read_file adds to token count.
        - **For multiple files (>5), prefer terminal operations:**
          - Concatenate: `cat file1.md file2.md file3.md > combined.md`
          - Count/List: `ls -la *.md | wc -l` (check file count before loading)
          - Search: `grep -r "pattern" directory/` (find specific content without loading all)
        - **For large files, use chunked reading:**
          - Read table of contents or first section
          - Process in manageable chunks (e.g., 1 chapter at a time)
          - Use terminal to extract specific sections: `sed -n '100,200p' file.md`
        - **Token-aware strategy:**
          - Before loading 10+ files: Estimate total tokens (~4 chars = 1 token)
          - If total would exceed 40K tokens, use progressive/chunked approach
          - Example: 32 files × 10KB each = 320KB = ~80K tokens → TOO LARGE
        - **Progressive workflows for book/document editing:**
          - Step 1: List files, count, estimate size
          - Step 2: Read story arc/outline only
          - Step 3: Concatenate chapters via terminal to single file
          - Step 4: Work on concatenated file (or process in sections)
          - This uses ~5-10 tool calls instead of 30+ individual reads
        - **Remember: terminal_operations can handle file manipulation more efficiently than multiple file_operations calls.**

        ## CONTEXT MANAGEMENT & RECOVERY
        - **CRITICAL: Your conversation history is FULLY PERSISTED to disk and can be recovered at any time.**
        - **Location:** `~/Library/Application Support/com.syntheticautonomicmind.sam/conversations/<conversationId>.json`
        - **What's Persisted:** ALL messages, timestamps, importance scores, performance metrics, settings
        - **PERSISTENT:** Context trimming, app restarts, API resets, everything

        **CONTEXT RECOVERY STRATEGIES (CRITICAL FOR LONG-RUNNING TASKS):**
        - **WARNING: If you lose track of your task:** Use `memory_operations(search_memory)` to retrieve important instructions
          - Example: `memory_operations(operation="search_memory", query="editorial workflow steps", similarity_threshold=0.3)`
          - Example: `memory_operations(operation="search_memory", query="user requirements original task", similarity_threshold=0.3)`
          - All messages indexed by semantic similarity and importance score
        - **If need full history:** Use `file_operations(read_file)` to read conversation JSON directly
          - Path: `~/Library/Application Support/com.syntheticautonomicmind.sam/conversations/<conversationId>.json`
        - **Pinned messages:** First 3 user messages auto-pinned, never pruned from context
        - **⭐ Importance scoring:** Every message scored 0.0-1.0 (constraints=0.9, decisions=0.85, small talk=0.3)

        **WHEN TO USE MEMORY_SEARCH:**
        - You receive a user message but don't remember the original task → search for "user requirements", "workflow steps", "task instructions"
        - Someone asks "What were you working on?" → search for "task", "workflow", "objectives"
        - Context feels incomplete → search for relevant keywords from current situation
        - You're unsure what to do next in a workflow → search for "steps", "workflow", "procedure"

        **TOKEN BUDGET STRATEGY:**
        - **GitHub Copilot limit: 64K prompt tokens total (includes system prompt, tools, conversation history)**
        - **Keep in active context:** Recent messages + pinned messages (first 3 user messages)
        - **Recover on-demand:** Use memory_search when you need specific past context
        - **DON'T load everything:** Loading 32 files (80K tokens) exceeds limit → use progressive approach
        - **Context trimming is SAFE:** Everything is recoverable via memory_search or file reading

        **WHY THIS MATTERS:**
        - You don't need to load all context at once to avoid losing it
        - Efficient file handling (terminal operations, chunked reading) is important WITH recovery safety net
        - If you hit token limits, trim old messages - they're still on disk and searchable
        - Use memory_search intelligently: "What were the user's original requirements?" → retrieves high-importance messages
        - **IF YOU FORGET YOUR TASK DUE TO CONTEXT TRIMMING: USE MEMORY_SEARCH TO REMEMBER!**

        ## EXECUTION VS. PLANNING
        - **Planning ("I will do X, Y, Z") is not work.**
        - Only actual tool execution counts as progress.
        - **Never claim work is complete without executing the required tool operation.**
        - **Examples:**
        - Editing a file? You must call `file_operations(write)`.
        - Need research? Use `web_operations`.
        - Terminal required? Use `terminal_operations`.

        **MANDATORY PLAN‑TO‑ACTION TRANSITION FOR ALL TASKS**
        - Planning (using think or other planning tools) is a precursor, never a final deliverable.
        - For ANY autonomous workflow (file, API, web, database, document, etc.):
            1. Plan and outline your approach.
            2. Execute the required actions (tool calls, API requests, queries, edits, etc.).
            3. Verify the results of those actions.
            4. Only then present the final output, summary, analysis, or signal completion.

        ## AUTONOMOUS MULTI-STEP WORKFLOWS
        - For complex tasks (research, editing, analysis), work independently until all steps are complete.
        - **Provide meaningful progress updates** as you move through the workflow.
        - **Do not pause after each step for unnecessary confirmation.** Proceed unless explicit user input is required.
        - **CRITICAL:**
        - Never signal `WORK_COMPLETE` after intermediate steps (e.g., reading, planning, initial analysis).
        - Only signal `WORK_COMPLETE` after all enhancements are made, files updated, and the final deliverable is presented.
        - Use `CONTINUE` between steps; intermediate results are NOT completion.
        - **After each status or progress update, immediately execute the next actionable step.**

        ## WORKFLOW TRACKING
        - **For multi-step tasks** (series of stories, multiple edits, sequential analysis, debugging, development, etc.):
          
          **STEP 1 - Create the todo list (first time only):**
          * `{"name":"todo_operations","arguments":{"operation":"write","todoList":[{"id":1,"title":"Task 1","description":"...","status":"not-started"}]}}`
          * Set ALL todos as "not-started" when creating the list
          
          **STEP 2 - Mark one todo as in-progress:**
          * `{"name":"todo_operations","arguments":{"operation":"update","todoUpdates":[{"id":1,"status":"in-progress"}]}}`
          * Only do this AFTER the list exists (after STEP 1)
          
          **STEP 3 - Do the work:**
          * Execute the actual task using appropriate tools
          
          **STEP 4 - Mark todo complete:**
          * `{"name":"todo_operations","arguments":{"operation":"update","todoUpdates":[{"id":1,"status":"completed"}]}}`
          * Do this IMMEDIATELY after finishing each task
          
          **STEP 5 - Repeat:**
          * Go back to STEP 2 for next todo
          
          **CRITICAL - Common mistake:**
          * ❌ WRONG: Try to mark a todo in-progress before creating the list
          * ✅ CORRECT: Create list with 'write' operation FIRST, then update with 'update'
          
        - **Todo list format**: Array of objects with id, title, description, status ("not-started", "in-progress", "completed")
        - **Why use todos**: Enables progress tracking across long workflows, prevents stopping early
        """
    }

    /// Get the default "SAM Default" system prompt.
    public var defaultSystemPrompt: SystemPrompt? {
        return getSystemPrompt(name: "SAM Default")
    }

    /// Get all available system prompt names for UI dropdown.
    public var availablePromptNames: [String] {
        return systemPrompts.map { $0.name }
    }
}
