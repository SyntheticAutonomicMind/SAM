<!-- SPDX-License-Identifier: CC-BY-NC-4.0 -->
<!-- SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius) -->


# Configuration System

**Version:** 3.0  
**Last Updated:** August 23, 2026  
**Location:** `Sources/ConfigurationSystem/`

---

## Overview

The Configuration System provides centralized management of all SAM settings, preferences, and runtime configuration. It replaces UserDefaults with a robust JSON-based configuration system, ensuring atomic writes, proper backups, and organized storage of all application state.

**Key Responsibilities:**
- File-based configuration management (JSON)
- Working directory configuration
- System prompt management (component-based)
- Application preferences
- Endpoint/API provider configuration
- Performance monitoring
- Build-time configuration
- Model configuration and pricing

**Design Philosophy:**
- JSON-first (no UserDefaults except for simple flags)
- Atomic writes with temp file -> rename pattern
- Organized directory structure in Application Support
- Codable-based type safety
- Centralized configuration access

---

## Directory Structure

```
~/Library/Application Support/SAM/
├── conversations/          # Conversation JSON files
│   ├── backups/           # Automatic backups
│   ├── {UUID}/            # Per-conversation directories
│   │   ├── conversation.json
│   │   ├── tasks.json
│   │   └── .vectorrag/
│   └── active-conversation.json  # Current conversation ID
├── system-prompts/        # System prompt templates
├── endpoints/             # API endpoint configurations
├── preferences/           # Application preferences
└── backups/              # Configuration backups
```

---

## Core Components

### ConfigurationManager

**File:** `ConfigurationManager.swift`  
**Type:** Singleton (`@MainActor`)  
**Purpose:** Central hub for all file-based configuration operations

**Key Features:**
- Generic save/load for any Codable type
- Atomic write operations (temp -> rename)
- Directory structure management
- File existence checking
- Configuration deletion
- Automatic directory creation

**Public Interface:**

```swift
@MainActor
public class ConfigurationManager: ObservableObject {
    public static let shared = ConfigurationManager()
    
    // Directory URLs
    public let configurationDirectory: URL      // ~/Library/Application Support/SAM/
    public let conversationsDirectory: URL      // .../conversations/
    public let systemPromptsDirectory: URL      // .../system-prompts/
    public let endpointsDirectory: URL          // .../endpoints/
    public let preferencesDirectory: URL        // .../preferences/
    public let backupsDirectory: URL            // .../backups/
    
    // Generic configuration operations
    func save<T: Codable>(_ object: T, to filename: String, in directory: URL) throws
    func load<T: Codable>(_ type: T.Type, from filename: String, in directory: URL) throws -> T
    func exists(_ filename: String, in directory: URL) -> Bool
    func delete(_ filename: String, in directory: URL) throws
    func listFiles(in directory: URL, withExtension ext: String) throws -> [String]
}
```

**Atomic Write Pattern:**

```swift
// 1. Write to temporary file
let tempURL = fileURL.appendingPathExtension("tmp")
try data.write(to: tempURL)

// 2. Atomic rename (replaces existing file)
_ = try FileManager.default.replaceItem(
    at: fileURL,
    withItemAt: tempURL,
    backupItemName: nil,
    options: [],
    resultingItemURL: nil
)
```

**Why Atomic Writes:**
- Prevents corruption if app crashes during write
- Ensures file is always in valid state
- OS-level atomic operation (all or nothing)

---

### WorkingDirectoryConfiguration

**File:** `WorkingDirectoryConfiguration.swift`  
**Type:** Singleton (`ObservableObject`)  
**Purpose:** Manage conversation working directory paths

**Key Features:**
- Configurable base path (default: `~/SAM`)
- Per-conversation subdirectories
- Path normalization and validation
- Automatic directory creation
- Persistent storage via UserDefaults

**Public Interface:**

```swift
public class WorkingDirectoryConfiguration: ObservableObject {
    public static let shared = WorkingDirectoryConfiguration()
    
    @Published public private(set) var basePath: String  // e.g., "~/SAM"
    
    public var expandedBasePath: String  // Expands ~ to full path
    
    func updateBasePath(_ newPath: String)
    func resetToDefault()
    func buildPath(subdirectory: String) -> String
}
```

**Usage Example:**

```swift
let config = WorkingDirectoryConfiguration.shared
let workDir = config.buildPath(subdirectory: "My Conversation")
// Result: "/Users/andrew/SAM/My Conversation/"
```

**Path Building Logic:**
1. Replace `/` in subdirectory name with `-` (safety)
2. Append to base path
3. Expand `~` to full user path
4. Ensure trailing slash

---

### EndpointConfigurationManager / Provider Management

**File:** `EndpointConfigurationManager.swift`  
**Type:** Singleton (`@MainActor`)  
**Purpose:** Manage API provider configurations (replaces legacy EndpointConfigurationManager)

**Key Responsibilities:**
- Load/save provider configurations
- Validate provider settings
- Handle multiple provider types
- Manage model lists per provider

**Supported Providers (as of 2026-08):**
- OpenAI
- GitHub Copilot
- DeepSeek
- Google Gemini
- MiniMax
- OpenRouter
- Ollama Cloud
- Z.AI (Chat)
- Z.AI (Coding)
- Local MLX
- Local CachyLLama
- Local llama.cpp
- Remote llama.cpp
- Custom OpenAI-compatible

**Configuration Structure:**

```swift
public struct ProviderConfiguration: Codable, Identifiable {
    public let id: UUID
    public var name: String
    public var providerType: String           // "openai", "github_copilot", "gemini", etc.
    public var baseURL: String?
    public var apiKey: String?                // Stored in Keychain, not here
    public var defaultModel: String?
    public var isActive: Bool
    public var customHeaders: [String: String]?
    public var providerSpecificSettings: [String: Any]?  // Model-specific config
}
```

**Public Interface:**

```swift
@MainActor
public class ProviderConfigurationManager: ObservableObject {
    public static let shared = ProviderConfigurationManager()
    
    @Published public var providers: [ProviderConfiguration] = []
    @Published public var activeProvider: ProviderConfiguration?
    
    func loadProviders() async throws
    func saveProviders() async throws
    func addProvider(_ provider: ProviderConfiguration) async throws
    func updateProvider(_ provider: ProviderConfiguration) async throws
    func deleteProvider(id: UUID) async throws
    func setActiveProvider(_ provider: ProviderConfiguration) async throws
}
```

---

### SystemPromptConfiguration (Component-Based)

**File:** `SystemPromptConfiguration.swift`  
**Purpose:** Define system prompt structure using modular components

**Prompt Architecture (v25+):**

SAM's system prompt is built from **ordered components**. Each component is a self-contained module that can be enabled/disabled independently.

**Built-in Profiles:**
1. **SAM Default** (UUID: `00000000-0000-0000-0000-000000000001`) - Full featured
2. **SAM Minimal** (UUID: `00000000-0000-0000-0000-000000000004`) - Concise version

**Component Filters:**
- **Always Included (Core):** "SAM Core Identity", "Core Identity & Operating Modes", "Response Guidelines"
- **Conditional:** "Workflow Mode" (only when workflow mode enabled)
- **Filtered Out:** "Dynamic Iterations" (always excluded)
- **Tools Disabled Filter:** "Tool Usage", "Direct Response Guidance", "Tool Disclosure Policy", "Tools" (when toolsEnabled=false)

**Component Order (SAM Default v25):**

| Order | Component | Description |
|-------|-----------|-------------|
| 1 | SAM Core Identity | WHO SAM is (helpful, accurate, approachable agent) |
| 2 | Current Date Context | Hallucination prevention |
| 3 | User Autonomy | User controls session, time, attention, scope |
| 4 | Scope Honesty | All scope items get equal rigor |
| 5 | Tool-Backed Claims | Every specific claim must be verified |
| 6 | Agent Identity & Completion Criteria | "YOU ARE AN AGENT" framing |
| 7 | Response Guidelines | Quality standards, formatting, style |
| 8 | Tool Usage | Principles for tool execution, math verification |
| 9 | Operational Modes | Conversational vs Task Execution |
| 10 | Execution Standards | Error recovery, completion criteria |
| 11 | Communication Protocol | Style guide |
| 12 | Context & Memory | Memory operations, document import |
| 13 | Data Visualization | Mermaid diagram rendering rules |
| 14 | Workflow Mode | Mode-specific guidance (conditional) |
| 15 | Dynamic Iterations | Iteration monitoring (filtered out) |
| 16 | Two-Phase Workflow | Pattern recommendation |
| 17 | Sequential Lists | Pattern guidance |

**Structure:**

```swift
public struct SystemPromptComponent: Codable, Identifiable {
    public let id: UUID
    public var name: String
    public var content: String
    public var order: Int
    public var isCore: Bool              // Always included
    public var filters: [ComponentFilter] // Conditional inclusion
}

public struct SystemPromptProfile: Codable, Identifiable {
    public let id: UUID
    public var name: String
    public var componentIds: [UUID]      // Ordered component references
    public var version: Int
}
```

**Manager:** `SystemPromptManager` (singleton) handles profile selection, component resolution, and prompt assembly.

**Version:** Current `currentVersion = 25` (as of 2026-07-29)

---

### ApplicationPreferencesManager

**File:** `ApplicationPreferencesManager.swift`  
**Type:** Singleton (`@MainActor`)  
**Purpose:** Manage application-wide preferences

**Preferences Structure:**

```swift
public struct ApplicationPreferences: Codable {
    // UI Preferences
    public var theme: Theme
    public var fontSize: Double
    public var showLineNumbers: Bool
    public var autoSaveConversations: Bool
    
    // Voice Preferences
    public var voiceEnabled: Bool
    public var voiceLanguage: String
    public var wakeWord: String
    public var ttsVoice: String
    public var ttsSpeed: Double
    public var relayModeEnabled: Bool
    public var relayModeTimeout: TimeInterval
    
    // Model Preferences
    public var defaultModel: String?
    public var temperatureDefault: Double
    
    // Update Channel
    public var updateChannel: UpdateChannel  // stable, development
    
    // API Server
    public var apiServerEnabled: Bool
    public var apiServerPort: Int
    public var apiServerCORS: Bool
    
    // Advanced
    public var enablePerformanceMonitoring: Bool
    public var maxMemoryUsage: Int64
    public var logLevel: LogLevel
}
```

---

### PerformanceMonitor

**File:** `PerformanceMonitor.swift`  
**Purpose:** Runtime performance tracking and reporting

**Monitored Metrics:**
- CPU usage (user + system time)
- Memory usage (resident size - RSS)
- GPU utilization (via Metal)
- Model load times
- Inference latency
- Token generation rate
- Cost tracking per conversation

**Public Interface:**

```swift
@MainActor
public class PerformanceMonitor: ObservableObject {
    @Published public var cpuUsage: Double = 0.0
    @Published public var memoryUsage: Int64 = 0
    @Published public var gpuUtilization: Double = 0.0
    @Published public var costTracking: [UUID: Double] = [:]  // Per-conversation cost
    
    func startMonitoring()
    func stopMonitoring()
    func recordModelLoad(modelId: String, duration: TimeInterval)
    func recordInference(duration: TimeInterval, tokens: Int)
    func recordAPICost(conversationId: UUID, cost: Double)
}
```

---

### ModelConfigurationManager

**File:** `ModelConfiguration.swift`  
**Type:** Singleton  
**Purpose:** Centralized model metadata, pricing, and configuration system

**Key Features:**
- **Model Metadata**: Context windows, prompt formats, provider defaults
- **Pricing Information**: Cost per million tokens (input/output)
- **Format Specifications**: Delta mode, XML tags, stateful markers
- **Runtime Configuration**: Provider-specific behavior settings

**ModelConfig Structure:**

```swift
public struct ModelConfig: Codable {
    public let provider: String                    // "gemini", "openai", etc.
    public let promptFormat: PromptFormat          // System prompt, XML tags
    public let providerDefaults: ModelProviderDefaults  // Delta mode, streaming
    public let supportsStatefulMarker: Bool        // For conversational state
    public let contextWindow: Int                  // Maximum context tokens
    public let requiresAlternatingMessages: Bool   // Claude requirement
    
    // Pricing (per million tokens)
    public let costPerMillionInputTokens: Double?
    public let costPerMillionOutputTokens: Double?
    
    /// Computed cost display string
    public var costDisplayString: String {
        // Returns: "0x" (free), "$0.10/$0.40" (paid), or "-" (unknown)
    }
}

public struct PromptFormat: Codable {
    public let systemPromptKey: String    // "system", "systemInstruction"
    public let useXMLTags: Bool          // Claude optimization
}

public struct ModelProviderDefaults: Codable {
    public let deltaMode: String         // "cumulative" or "incremental"
    public let supportsStreaming: Bool
}
```

**Storage Location:**

```
Sources/ConfigurationSystem/Resources/model_config.json
```

**Configuration File Structure:**

```json
{
  "model_configurations": {
    "gemini-2.5-pro": {
      "provider": "gemini",
      "prompt_format": {
        "system_prompt_key": "systemInstruction",
        "use_xml_tags": false
      },
      "provider_defaults": {
        "delta_mode": "cumulative",
        "supports_streaming": true
      },
      "supports_stateful_marker": false,
      "context_window": 2097152,
      "requires_alternating_messages": false,
      "cost_per_million_input_tokens": 1.25,
      "cost_per_million_output_tokens": 10.0
    },
    "minimax-m3": {
      "provider": "minimax",
      "prompt_format": {
        "system_prompt_key": "system",
        "use_xml_tags": false
      },
      "provider_defaults": {
        "delta_mode": "cumulative",
        "supports_streaming": true
      },
      "supports_stateful_marker": false,
      "context_window": 131072,
      "requires_alternating_messages": false,
      "cost_per_million_input_tokens": 0.50,
      "cost_per_million_output_tokens": 2.0
    }
  }
}
```

**Public Interface:**

```swift
public class ModelConfigurationManager {
    public static let shared = ModelConfigurationManager()
    
    /// Get configuration for model (tries exact match, then base name)
    public func getConfiguration(for modelName: String) -> ModelConfig?
    
    /// Get context window size
    public func getContextWindow(for modelName: String) -> Int?
    
    /// Get cost display string (e.g., "$0.10/$0.40", "0x")
    public func getCostDisplayString(for modelName: String) -> String?
}
```

**Pricing Display Format:**

- **Free models**: `"0x"` (zero multiplier)
- **Paid models**: `"$0.10/$0.40"` (input/output per million tokens)
- **Unknown**: `"-"`

Cost formatting rules:
- Whole numbers: `$2/$12` (no decimals)
- Decimals < 1: `$0.10/$0.40` (two decimals)
- Decimals ≥ 1: `$1.25/$10.0` (one decimal)

**Fallback Strategy:**

1. Try exact model name match (e.g., `"gemini/gemini-2.5-pro"`)
2. Try base model name (strip provider prefix: `"gemini-2.5-pro"`)
3. Return `nil` if not found

---

### BuildConfiguration

**File:** `BuildConfiguration.swift`  
**Purpose:** Compile-time configuration flags

```swift
public enum BuildConfiguration {
    public static var isDebug: Bool {
        #if DEBUG
        return true
        #else
        return false
        #endif
    }
    
    public static var isRelease: Bool {
        !isDebug
    }
}
```

---

### Additional Components

| Component | Purpose |
|-----------|---------|
| **AIInstructionsScanner** | Scan for `.github/copilot-instructions.md` and similar |
| **LocationManager** | Geographic location for weather/location-aware features |
| **PersonalityManager / PersonalityTrait** | AI personality configurations |
| **PromptComponentLibrary** | Reusable prompt components for system prompt composition |
| **ToolResultStorage** | Store and retrieve tool execution results |
| **TodoReminderInjector** | Inject todo list context into conversation messages |

---

### TodoReminderInjector

**File:** `TodoReminderInjector.swift`

Provides todo list state injection for multi-step workflows, ensuring agents maintain awareness of task progress.

**Key Features:**
- **Injects on EVERY request** when todos exist (not periodically)
- **Progress rules included** to remind agent to update todos
- **Conversation-scoped** via effectiveScopeId
- **Stateless design** for thread safety

**Injection Trigger:**
```swift
func shouldInjectReminder(
    conversationId: UUID?,
    effectiveScopeId: UUID?,
    responseCount: Int
) async -> Bool {
    let todos = TodoManager.shared.getTodos(scopeId: effectiveScopeId ?? conversationId)
    return !todos.isEmpty
}
```

**Reminder Format:**
```
<todo_context>
## Current Todo List State
[Status counts: X completed, Y in-progress, Z not-started]

[Formatted todo items with status and descriptions]

## Progress Rules (CRITICAL)
- Before beginning ANY todo: mark it in-progress FIRST
- After completing ANY todo: mark it completed IMMEDIATELY
- Update todos FREQUENTLY - user sees progress through the list
- ONE todo can be in-progress at a time
</todo_context>
```

---

## Configuration Patterns

### Loading Configuration

```swift
let config = try ConfigurationManager.shared.load(
    MyConfiguration.self,
    from: "my-config.json",
    in: ConfigurationManager.shared.preferencesDirectory
)
```

### Saving Configuration

```swift
try ConfigurationManager.shared.save(
    myConfig,
    to: "my-config.json",
    in: ConfigurationManager.shared.preferencesDirectory
)
```

---

## See Also

- [System Prompt Evolution](SYSTEM_PROMPT_EVOLUTION.md) - Component history
- [API Framework](API_FRAMEWORK.md) - Provider integration
- [Agent Orchestrator](AGENT_ORCHESTRATOR.md) - Workflow configuration
- [Conversation Engine](CONVERSATION_ENGINE.md) - Conversation settings