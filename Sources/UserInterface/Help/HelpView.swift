// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import SwiftUI

// MARK: - UI Setup
struct HelpView: View {
    @State private var selectedSection: HelpSection = .quickStart
    @State private var searchText: String = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            /// Header with close button.
            HStack {
                Text("SAM User Guide")
                    .font(.title)
                    .fontWeight(.bold)

                Spacer()

                Button(action: { dismiss() }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding()
            .background(Color(nsColor: .controlBackgroundColor))

            Divider()

            /// Sidebar + Detail Pane layout.
            HStack(spacing: 0) {
                /// Left sidebar.
                VStack(spacing: 0) {
                    Text("Contents")
                        .font(.headline)
                        .padding()
                        .frame(maxWidth: .infinity, alignment: .leading)

                    Divider()

                    List(HelpSection.allCases, selection: $selectedSection) { section in
                        Label(section.title, systemImage: section.icon)
                            .tag(section)
                    }
                    .listStyle(.sidebar)
                }
                .frame(width: 220)

                Divider()

                /// Right content pane.
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        selectedSection.content
                    }
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .frame(minWidth: 900, minHeight: 600)
    }
}

// MARK: - Help Sections Enum
enum HelpSection: String, CaseIterable, Identifiable {
    case quickStart
    case keyboardShortcuts
    case modelProviders
    case capabilities
    case imageGenerationGuide
    case conversationManagement
    case personalities
    case documentFormats
    case toolReference
    case mcpToolsDeepDive
    case advancedPrompting
    case performanceOptimization
    case gettingStartedExamples
    case troubleshooting
    case privacySecurity

    var id: String { rawValue }

    var title: String {
        switch self {
        case .quickStart: return "Quick Start Guide"
        case .keyboardShortcuts: return "Keyboard & Navigation"
        case .modelProviders: return "Model Providers"
        case .capabilities: return "Core Capabilities"
        case .imageGenerationGuide: return "Image Generation Guide"
        case .conversationManagement: return "Conversation Management"
        case .personalities: return "Personalities & Traits"
        case .documentFormats: return "Document Formats"
        case .toolReference: return "Tool Reference"
        case .mcpToolsDeepDive: return "MCP & Tools Deep Dive"
        case .advancedPrompting: return "Advanced Prompting"
        case .performanceOptimization: return "Performance & Optimization"
        case .gettingStartedExamples: return "Getting Started Examples"
        case .troubleshooting: return "Troubleshooting"
        case .privacySecurity: return "Privacy & Security"
        }
    }

    var icon: String {
        switch self {
        case .quickStart: return "star.fill"
        case .keyboardShortcuts: return "keyboard"
        case .modelProviders: return "cpu.fill"
        case .capabilities: return "brain"
        case .imageGenerationGuide: return "photo.on.rectangle.angled"
        case .conversationManagement: return "folder.fill"
        case .personalities: return "theatermasks"
        case .documentFormats: return "doc.text"
        case .toolReference: return "wrench.and.screwdriver"
        case .mcpToolsDeepDive: return "puzzlepiece.extension"
        case .advancedPrompting: return "wand.and.stars"
        case .performanceOptimization: return "speedometer"
        case .gettingStartedExamples: return "lightbulb.fill"
        case .troubleshooting: return "lifepreserver"
        case .privacySecurity: return "lock.shield"
        }
    }

    @ViewBuilder
    var content: some View {
        switch self {
        case .quickStart:
            QuickStartContent()

        case .keyboardShortcuts:
            KeyboardShortcutsContent()

        case .modelProviders:
            ModelProvidersContent()

        case .capabilities:
            CapabilitiesContent()

        case .imageGenerationGuide:
            ImageGenerationGuideContent()

        case .conversationManagement:
            ConversationManagementContent()

        case .personalities:
            PersonalitiesContent()

        case .documentFormats:
            DocumentFormatsContent()

        case .toolReference:
            ToolReferenceContent()

        case .mcpToolsDeepDive:
            MCPToolsDeepDiveContent()

        case .advancedPrompting:
            AdvancedPromptingContent()

        case .performanceOptimization:
            PerformanceOptimizationContent()

        case .gettingStartedExamples:
            GettingStartedExamplesContent()

        case .troubleshooting:
            TroubleshootingContent()

        case .privacySecurity:
            PrivacySecurityContent()
        }
    }
}

// MARK: - UI Setup
struct QuickStartContent: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Getting Started with SAM")
                .font(.largeTitle)
                .fontWeight(.bold)

            Text("Welcome to SAM, your intelligent AI assistant for macOS!")
                .font(.title3)
                .foregroundColor(.secondary)

            Divider()

            HelpSection_Group(title: "First Launch") {
                HelpStep(number: 1, text: "Open SAM from your Applications folder")
                HelpStep(number: 2, text: "Choose your AI provider (OpenAI, Anthropic, GitHub Copilot, or Local models)")
                HelpStep(number: 3, text: "Configure your API key in Preferences (⌘,)")
                HelpStep(number: 4, text: "Start chatting - SAM will guide you through its capabilities")
            }

            HelpSection_Group(title: "Your First Conversation") {
                ExamplePrompt(
                    title: "Simple greeting:",
                    prompt: "Hello SAM, what can you help me with?"
                )
                ExamplePrompt(
                    title: "Ask for help:",
                    prompt: "I need to organize my Downloads folder"
                )
                ExamplePrompt(
                    title: "Research task:",
                    prompt: "Find information about renewable energy trends"
                )
            }

            HelpSection_Group(title: "Interface Overview") {
                BulletPoint(text: "**Chat Area**: Main conversation window where you interact with SAM")
                BulletPoint(text: "**Sidebar**: Access your conversation history and create new chats")
                BulletPoint(text: "**Pin Conversations**: Click pin icon (or right-click conversation) to keep important chats at top of sidebar")
                BulletPoint(text: "**Global Search** (F): Search across all conversations for messages, code, and content")
                BulletPoint(text: "**Terminal**: Click terminal button in toolbar to open a command line for each conversation")
                BulletPoint(text: "**Working Folder**: Click folder button to set where SAM saves and reads files")
                BulletPoint(text: "**Menu Bar**: File, Edit, Conversation, and Help menus")
                BulletPoint(text: "**Preferences** (⌘,): Configure AI providers, system prompts, and settings")
            }

            HelpSection_Group(title: "Conversation Management") {
                Text("SAM makes it easy to organize and find your conversations:")
                    .font(.body)
                    .fontWeight(.semibold)
                    .padding(.bottom, 8)

                BulletPoint(text: "**Create conversations**: Click \"New Conversation\" in sidebar")
                BulletPoint(text: "**Auto-numbered names**: \"New Conversation\", \"New Conversation (2)\", \"New Conversation (3)\"")
                BulletPoint(text: "**Rename anytime**: Double-click title or right-click → Rename")
                BulletPoint(text: "**Directory sync**: Working directories match conversation names (~/SAM/{name}/)")
                BulletPoint(text: "**Auto-rename folders**: When you rename a conversation, its folder renames too")
                BulletPoint(text: "**Human-readable paths**: Easy to find files in Finder")
                BulletPoint(text: "**Pin important chats**: Click pin icon to keep conversations at top of sidebar")

                Text("**Example**: Create \"Python Tutorial\" conversation → Files appear in ~/SAM/Python Tutorial/")
                    .font(.callout)
                    .foregroundColor(.secondary)
                    .italic()
                    .padding(.top, 8)

                Text("**Tip**: Right-click any conversation for quick actions (rename, duplicate, export, delete)!")
                    .font(.callout)
                    .foregroundColor(.blue)
                    .italic()
                    .padding(.top, 4)
            }

            HelpSection_Group(title: "Chat Toolbar Options") {
                Text("The toolbar above the input box lets you control how SAM responds:")
                    .font(.body)
                    .padding(.bottom, 8)

                BulletPoint(text: "**Model**: Choose which AI model to use (GPT-4, Claude, Copilot, local models)")
                BulletPoint(text: "**Prompt**: Select system prompt (SAM Default or custom prompts you've created)")
                BulletPoint(text: "**Temp** (Temperature): Controls creativity (0.0 = focused/deterministic, 2.0 = creative/varied)")
                BulletPoint(text: "**Top-P**: Nucleus sampling (0.0 = most likely words only, 1.0 = all possibilities)")
                BulletPoint(text: "**Max Tokens**: Maximum length of SAM's response (1k to 32k)")
                BulletPoint(text: "**Context**: How much conversation history SAM can see (2k to 128k tokens)")
                BulletPoint(text: "**Tools**: Enable/disable tool usage (when ON, SAM can use web search, file operations, etc.)")
                BulletPoint(text: "**Terminal**: Open the terminal panel to run commands and watch SAM work")
                BulletPoint(text: "**Folder**: View or change the working folder for this conversation")
                BulletPoint(text: "**Parameters Button (wrench/screwdriver icon)**: Opens Advanced Parameters panel for temperature, top-p, and other settings")

                Text("**Tip**: Use lower temperature (0.2-0.5) for factual tasks, higher (0.7-1.0) for creative writing. Turn Tools OFF if you just want to chat. Open the terminal to see exactly what SAM is doing.")
                    .font(.callout)
                    .foregroundColor(.secondary)
                    .italic()
                    .padding(.top, 8)
            }

            HelpSection_Group(title: "Choosing the Right System Prompt") {
                Text("System prompts define SAM's personality and behavior. Choose the one that matches your task:")
                    .font(.body)
                    .fontWeight(.semibold)
                    .padding(.bottom, 8)

                VStack(alignment: .leading, spacing: 12) {
                    SystemPromptOption(
                        name: "SAM Default",
                        bestFor: "General use, balanced approach",
                        description: "Autonomous AI partner with evidence-based problem-solving. Works independently, tests solutions, and provides proven results. Good for most tasks."
                    )

                    SystemPromptOption(
                        name: "SAM Minimal",
                        bestFor: "Local GGUF/MLX models",
                        description: "Ultra-simplified prompt for smaller local models. Removes complex instructions that confuse local models. Use this with downloaded models running on your Mac."
                    )
                }

                Text("**When to switch**: Use Minimal for local models. Stick with Default for everything else.")
                    .font(.callout)
                    .foregroundColor(.secondary)
                    .italic()
                    .padding(.top, 8)

                Text("**How to change**: Select from the Prompt dropdown in the chat toolbar, or click Parameters button → System Prompt.")
                    .font(.callout)
                    .foregroundColor(.blue)
                    .italic()
                    .padding(.top, 4)
            }

            HelpSection_Group(title: "Advanced Parameters") {
                Text("Click the Parameters button (wrench/screwdriver icon) in the chat toolbar to access advanced settings:")
                    .font(.body)
                    .padding(.bottom, 8)

                BulletPoint(text: "**Model Selection**: Override default model for this conversation")
                BulletPoint(text: "**System Prompt**: Choose specialized prompts (SAM Default, SAM Minimal)")
                BulletPoint(text: "**Cost Estimation**: See billing multiplier for premium models (0x = free, 1x-20x = premium)")
                BulletPoint(text: "**Shared Topics**: Enable topic workspace sharing for multi-conversation projects")
                BulletPoint(text: "**Topic Selector**: Choose which shared topic to use (changes working directory)")
                BulletPoint(text: "**Workflow Mode**: Enable for multi-step autonomous tasks (agents use tools iteratively)")
                BulletPoint(text: "**Dynamic Iterations**: Adaptive max iterations based on task complexity")
                BulletPoint(text: "**Terminal Access**: Control whether agents can execute terminal commands")

                Text("**Shared Topics Example**: Enable Shared Topics → select \"My Project\" → working directory becomes ~/SAM/My Project/ instead of conversation-specific folder")
                    .font(.callout)
                    .foregroundColor(.secondary)
                    .italic()
                    .padding(.top, 8)

                Text("**Note**: Shared Topics only affects new conversations. To use shared workspace, create new topic in Preferences → Shared Topics first.")
                    .font(.callout)
                    .foregroundColor(.orange)
                    .italic()
                    .padding(.top, 4)
            }

            HelpSection_Group(title: "Embedded Terminal: Work Together") {
                Text("Each conversation has a shared terminal where you and the AI can work together on command-line tasks:")
                    .font(.body)
                    .padding(.bottom, 8)

                BulletPoint(text: "**Shared Workspace**: Both you and the AI can run commands in the same terminal")
                BulletPoint(text: "**See Everything**: When the AI runs a command, you see it happen in real-time")
                BulletPoint(text: "**You Can Help**: Type your own commands to check results, make changes, or guide the AI")
                BulletPoint(text: "**Stays Organized**: Each conversation has its own terminal and working folder")
                BulletPoint(text: "**Pick Your Folder**: Choose where files should be saved (default: ~/SAM/)")

                Text("**Example**: Ask the AI to create a Python script. You can run it yourself, see errors, and work together to fix them - all in the same terminal.")
                    .font(.callout)
                    .foregroundColor(.secondary)
                    .italic()
                    .padding(.top, 8)
            }

            HelpSection_Group(title: "Keyboard Shortcuts") {
                Text("Master these shortcuts to work faster in SAM:")
                    .font(.body)
                    .fontWeight(.semibold)
                    .padding(.bottom, 8)

                KeyboardShortcut(keys: "N", description: "New conversation")
                KeyboardShortcut(keys: "K", description: "Clear current conversation")
                KeyboardShortcut(keys: "⇧R", description: "Rename conversation")
                KeyboardShortcut(keys: "⇧D", description: "Duplicate conversation")
                KeyboardShortcut(keys: "⇧E", description: "Export conversation")
                KeyboardShortcut(keys: "⌘ + ⌫", description: "Delete conversation")
                KeyboardShortcut(keys: "F", description: "Search conversations")
                KeyboardShortcut(keys: "⇧/", description: "Show this help")
                KeyboardShortcut(keys: ",", description: "Open Preferences")
                KeyboardShortcut(keys: "W", description: "Close window")

                Text("**Tip**: Right-click any conversation for quick actions menu!")
                    .font(.callout).italic().foregroundColor(.blue).padding(.top, 8)
            }

            HelpSection_Group(title: "Mini-Prompts: Add Context to Your Conversations") {
                Text("Mini-prompts let you inject consistent context without repeating yourself:")
                    .font(.body)
                    .padding(.bottom, 8)

                BulletPoint(text: "**Click Mini-Prompts button** (Mini-Prompts icon) in toolbar to open panel")
                BulletPoint(text: "**Create prompts** for personal info, project details, or preferences")
                BulletPoint(text: "**Toggle per conversation**: Enable only relevant prompts")
                BulletPoint(text: "**Auto-injected**: Context added automatically to your messages")

                ExamplePrompt(
                    title: "Example mini-prompt:",
                    prompt: "I'm working on a SwiftUI macOS app. I prefer clean code with descriptive variable names and comprehensive error handling."
                )

                Text("**Use Case**: Once enabled, SAM knows this context in every message without you repeating it. Perfect for weather queries, local search, and system-specific questions!")
                    .font(.callout)
                    .foregroundColor(.secondary)
                    .italic()
                    .padding(.top, 8)

                Text("See **Advanced Prompting** tab for detailed guide and best practices.")
                    .font(.caption)
                    .foregroundColor(.blue)
                    .padding(.top, 4)
            }

            HelpSection_Group(title: "Shared Topics: Collaborate Across Conversations") {
                Text("Shared topics let multiple conversations work together in the same workspace with shared files, memory, and terminal sessions. Perfect for complex projects requiring different expertise or parallel work streams.")
                    .font(.body)
                    .padding(.bottom, 8)

                Text("Setup:")
                    .fontWeight(.semibold)
                    .padding(.top, 4)

                BulletPoint(text: "**Create topics** in Preferences → Shared Topics (e.g., \"My Project\")")
                BulletPoint(text: "**Enable in conversation**: Click Parameters button (wrench/screwdriver icon) → Advanced Parameters → toggle Shared Topics ON")
                BulletPoint(text: "**Select topic**: Choose from dropdown to set working directory to ~/SAM/{topic-name}/")

                Text("What Gets Shared:")
                    .fontWeight(.semibold)
                    .padding(.top, 12)

                BulletPoint(text: "**Files & Directories**: All file operations use the shared topic directory")
                BulletPoint(text: "**Memory (VectorRAG)**: Document imports and memory storage shared across conversations")
                BulletPoint(text: "**Terminal Directory**: All terminal commands execute in the shared workspace")
                BulletPoint(text: "**Context**: Different conversations can build on each other's work")

                Text("Use Cases:")
                    .fontWeight(.semibold)
                    .padding(.top, 12)

                Text("**Software Development Project**")
                    .fontWeight(.medium)
                BulletPoint(text: "Conversation 1: Research and design (imports docs, creates architecture)")
                BulletPoint(text: "Conversation 2: Backend implementation (reads design, writes code)")
                BulletPoint(text: "Conversation 3: Testing (accesses code files, creates test suite)")
                BulletPoint(text: "Conversation 4: Documentation (reads code, generates docs)")
                Text("All conversations share the same codebase and can access each other's work")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .italic()
                    .padding(.leading, 20)

                Text("**Research Project**")
                    .fontWeight(.medium)
                    .padding(.top, 8)
                BulletPoint(text: "Conversation 1: Web research on topic A → stores findings in memory")
                BulletPoint(text: "Conversation 2: Web research on topic B → different focus area")
                BulletPoint(text: "Conversation 3: Synthesis → searches shared memory from both conversations")
                BulletPoint(text: "Conversation 4: Report writing → uses accumulated knowledge")
                Text("Each conversation contributes to a growing knowledge base")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .italic()
                    .padding(.leading, 20)

                Text("**Learning & Knowledge Building**")
                    .fontWeight(.medium)
                    .padding(.top, 8)
                BulletPoint(text: "Conversation 1: Import textbooks and documentation")
                BulletPoint(text: "Conversation 2: Ask questions → searches shared imported docs")
                BulletPoint(text: "Conversation 3: Practice exercises → references shared knowledge")
                Text("Build a persistent knowledge base that grows over time")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .italic()
                    .padding(.leading, 20)

                Text("Best Practices:")
                    .fontWeight(.semibold)
                    .padding(.top, 12)

                BulletPoint(text: "**Use for related work**: Shared topics work best when conversations tackle different aspects of the same project")
                BulletPoint(text: "**Organize by project**: Create separate topics for unrelated projects")
                BulletPoint(text: "**Clear naming**: Use descriptive conversation names (\"Backend Dev\", \"Testing\", \"Docs\")")
                BulletPoint(text: "**Memory cleanup**: Use clear_memories cautiously - it affects ALL conversations in the topic")

                Text("When NOT to Use Shared Topics:")
                    .fontWeight(.semibold)
                    .padding(.top, 12)

                BulletPoint(text: "**Unrelated conversations**: Keep different projects in separate topics or isolated conversations")
                BulletPoint(text: "**Privacy concerns**: Isolated conversations keep all data completely separate")
                BulletPoint(text: "**Experimental work**: Use isolated conversations for trying new ideas without affecting shared workspace")

                Text("**Benefits**: Enables true multi-conversation collaboration with shared context, organized workspace, and accumulated knowledge. Perfect for large projects where different conversations handle different aspects!")
                    .font(.callout)
                    .foregroundColor(.secondary)
                    .italic()
                    .padding(.top, 8)

                Text("**Security**: Agents can only access files inside the topic workspace. Outside access requires your permission via MCPAuthorizationGuard.")
                    .font(.callout)
                    .foregroundColor(.orange)
                    .italic()
                    .padding(.top, 4)
            }

            HelpSection_Group(title: "Subagents: Delegate Complex Tasks") {
                Text("Subagents are specialized AI agents that SAM can create to handle complex sub-tasks independently. Each subagent works in parallel, inherits your settings, and returns results when complete. They appear as separate conversations in your sidebar with a \"Working\" indicator.")
                    .font(.body)
                    .padding(.bottom, 8)

                Text("How It Works:")
                    .fontWeight(.semibold)
                    .padding(.top, 4)

                BulletPoint(text: "**SAM Creates Subagent**: When you request complex or parallel work, SAM uses run_subagent tool")
                BulletPoint(text: "**Settings Inherited**: Subagent gets same model, system prompt, tools, and context window as parent")
                BulletPoint(text: "**Independent Work**: Subagent appears in sidebar with name and \"Working\" indicator")
                BulletPoint(text: "**Results Returned**: When complete, subagent's final message is returned to parent conversation")
                BulletPoint(text: "**Persistent**: Subagent conversation remains in sidebar for review and continued use")

                Text("Common Use Cases:")
                    .fontWeight(.semibold)
                    .padding(.top, 12)

                Text("**Parallel Research**")
                    .fontWeight(.medium)
                ExamplePrompt(
                    title: "Example:",
                    prompt: "Research these three topics in parallel:\n1. Machine learning frameworks\n2. Cloud providers comparison\n3. Security best practices"
                )
                Text("SAM creates 3 subagents, each researching one topic simultaneously, then synthesizes results")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .italic()
                    .padding(.leading, 20)

                Text("**Specialized Analysis**")
                    .fontWeight(.medium)
                    .padding(.top, 8)
                ExamplePrompt(
                    title: "Example:",
                    prompt: "Analyze this codebase for:\n- Security vulnerabilities\n- Performance bottlenecks\n- Code quality issues"
                )
                Text("Subagents focus on specific aspects, providing detailed specialized reports")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .italic()
                    .padding(.leading, 20)

                Text("**Multi-Step Workflows**")
                    .fontWeight(.medium)
                    .padding(.top, 8)
                ExamplePrompt(
                    title: "Example:",
                    prompt: "Create a web app:\n1. Design database schema\n2. Implement REST API\n3. Build frontend interface"
                )
                Text("Each step handled by dedicated subagent with appropriate expertise focus")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .italic()
                    .padding(.leading, 20)

                Text("**Research + Implementation**")
                    .fontWeight(.medium)
                    .padding(.top, 8)
                ExamplePrompt(
                    title: "Example:",
                    prompt: "Research best React state management libraries, then implement a demo using the top choice"
                )
                Text("Subagent 1 researches, Subagent 2 implements based on research findings")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .italic()
                    .padding(.leading, 20)

                Text("Best Practices:")
                    .fontWeight(.semibold)
                    .padding(.top, 12)

                BulletPoint(text: "**Clear naming**: Give subagents descriptive names (\"Security Analysis\", \"Backend Research\")")
                BulletPoint(text: "**Discrete tasks**: Best for well-defined sub-tasks with clear completion criteria")
                BulletPoint(text: "**Review results**: Check subagent conversations for detailed work and intermediate steps")
                BulletPoint(text: "**Combine with shared topics**: Subagents can all work in same shared workspace")

                Text("When to Use Subagents:")
                    .fontWeight(.semibold)
                    .padding(.top, 12)

                BulletPoint(text: "**Parallel work**: Multiple independent tasks that can run simultaneously")
                BulletPoint(text: "**Complex projects**: Break large requests into focused sub-tasks")
                BulletPoint(text: "**Specialized expertise**: Different tasks need different focus/approach")
                BulletPoint(text: "**Long-running tasks**: Delegate time-intensive work while continuing main conversation")

                Text("**Pro Tip**: Combine subagents with shared topics! Create a shared topic, then let multiple subagents collaborate in the same workspace. Each focuses on different aspects while sharing files and memory.")
                    .font(.callout)
                    .foregroundColor(.blue)
                    .italic()
                    .padding(.top, 8)

                Text("**Note**: Subagent conversations persist in sidebar - you can review their work, ask followup questions, or delete them when no longer needed.")
                    .font(.callout)
                    .foregroundColor(.secondary)
                    .italic()
                    .padding(.top, 4)
            }

            HelpSection_Group(title: "AI Image Generation") {
                Text("SAM supports diffusion models for AI image generation including Stable Diffusion, Z-Image, and others. You can generate images directly or use natural language requests with LLM assistance.")
                    .font(.body)
                    .padding(.bottom, 8)

                BulletPoint(text: "**Install Models**: Go to Preferences → Image Generation → Model Browser")
                BulletPoint(text: "**Browse Models**: Search HuggingFace or CivitAI for models")
                BulletPoint(text: "**Download & Convert**: Download SafeTensors and/or convert to CoreML")
                BulletPoint(text: "**Generate**: Select model in chat interface or ask AI to generate images")

                ExamplePrompt(
                    title: "Natural language:",
                    prompt: "Generate an image of a serene mountain landscape at sunset"
                )
                ExamplePrompt(
                    title: "Direct request:",
                    prompt: "Create a photo of a cat sitting on a windowsill"
                )
            }

            HelpSection_Group(title: "Finding Past Conversations") {
                Text("Use **F** to search across all your conversations instantly:")
                    .font(.body)
                    .padding(.bottom, 8)

                BulletPoint(text: "Search for keywords, code snippets, or topics from any conversation")
                BulletPoint(text: "Results show context with highlighted matches")
                BulletPoint(text: "Click any result to jump directly to that message")
                BulletPoint(text: "Press **Escape** to close the search overlay")

                Text("Perfect for finding that solution you discussed weeks ago or locating specific code examples!")
                    .font(.callout)
                    .foregroundColor(.secondary)
                    .italic()
                    .padding(.top, 8)
            }
        }
    }
}

// MARK: - Model Providers Content
struct ModelProvidersContent: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("AI Model Providers")
                .font(.largeTitle)
                .fontWeight(.bold)

            Text("SAM supports 6 different AI providers with multiple models each. Choose the provider and model that best fits your needs!")
                .font(.title3)
                .foregroundColor(.secondary)

            Divider()

            HelpSection_Group(title: "OpenAI") {
                BulletPoint(text: "**GPT-4 Turbo**: Most capable model, excellent for complex tasks (8k-128k context)")
                BulletPoint(text: "**GPT-3.5 Turbo**: Fast and cost-effective for simpler tasks (4k-16k context)")
                BulletPoint(text: "**O1/O3 Series**: Advanced reasoning models for complex problem-solving (8k-128k context)")
                BulletPoint(text: "**Setup**: Add your OpenAI API key in Preferences → API Providers")
                Text("Best for: General-purpose AI, coding, analysis, creative writing")
                    .font(.callout).italic().foregroundColor(.secondary)
            }

            HelpSection_Group(title: "GitHub Copilot") {
                BulletPoint(text: "**GPT-4**: Access GPT-4 through your Copilot subscription")
                BulletPoint(text: "**Claude 3.5 Sonnet**: Access Anthropic's models through Copilot")
                BulletPoint(text: "**O1 Series**: Advanced reasoning through Copilot")
                BulletPoint(text: "**Setup**: Uses your GitHub Copilot subscription - requires authentication")
                Text("Best for: Developers with Copilot access who want multiple models")
                    .font(.callout).italic().foregroundColor(.secondary)
            }

            HelpSection_Group(title: "Anthropic/Claude") {
                BulletPoint(text: "**Claude 3.5 Sonnet**: Excellent reasoning and coding (90k context)")
                BulletPoint(text: "**Claude 4**: Latest generation with improved capabilities (200k context)")
                BulletPoint(text: "**Claude 4.5 Sonnet**: Enhanced performance and accuracy (200k context)")
                BulletPoint(text: "**Setup**: Add your Anthropic API key in Preferences → API Providers")
                Text("Best for: Long documents, detailed analysis, nuanced conversations")
                    .font(.callout).italic().foregroundColor(.secondary)
            }

            HelpSection_Group(title: "Google Gemini") {
                BulletPoint(text: "**Gemini 2.0 Flash**: Fast and efficient latest generation (1M context)")
                BulletPoint(text: "**Gemini 1.5 Pro**: Most capable previous generation (2M context!)")
                BulletPoint(text: "**Gemini 1.5 Flash**: Faster processing with excellent performance (1M context)")
                BulletPoint(text: "**Setup**: Add your Google AI API key in Preferences → API Providers")
                Text("Best for: Massive context windows, processing huge documents or codebases")
                    .font(.callout).italic().foregroundColor(.secondary)
            }

            HelpSection_Group(title: "xAI Grok") {
                BulletPoint(text: "**Grok-2**: Latest reasoning-focused model (128k context)")
                BulletPoint(text: "**Grok Vision**: Multimodal capabilities for image understanding")
                BulletPoint(text: "**Setup**: Add your xAI API key in Preferences → API Providers")
                Text("Best for: Real-time information, alternative perspectives, multimodal tasks")
                    .font(.callout).italic().foregroundColor(.secondary)
            }

            HelpSection_Group(title: "Local Models (MLX & GGUF)") {
                BulletPoint(text: "**Apple MLX**: Optimized for Apple Silicon, uses model.safetensors format")
                BulletPoint(text: "**Llama.cpp (GGUF)**: Efficient quantized models, cross-platform")
                BulletPoint(text: "**Models Location**: ~/.sam/models/ (auto-detected)")
                BulletPoint(text: "**Popular**: Qwen2.5 Coder, Qwen3, Llama 3, Phi-3, Mistral")
                BulletPoint(text: "**Context**: Typically 32k-128k depending on model and quantization")
                BulletPoint(text: "**Setup**: Download models to ~/.sam/models/ - SAM auto-detects them")
                Text("Best for: Complete privacy, offline work, no API costs, Apple Silicon optimization")
                    .font(.callout).italic().foregroundColor(.secondary)
            }

            HelpSection_Group(title: "Stable Diffusion (Image Generation)") {
                Text("SAM supports Stable Diffusion models for AI image generation with two execution engines:")
                    .font(.body)
                    .padding(.bottom, 4)

                BulletPoint(text: "**CoreML**: Apple Silicon optimized, fast inference, lower memory usage")
                BulletPoint(text: "**Python**: Fallback using diffusers library, broader compatibility")

                Text("Models can have one or both formats. SAM automatically detects available formats and enables appropriate engine options.")
                    .font(.body)
                    .padding(.vertical, 8)

                Text("Model Sources:")
                    .fontWeight(.semibold)
                    .padding(.top, 4)

                BulletPoint(text: "**HuggingFace**: Official Stable Diffusion models and community variants")
                BulletPoint(text: "**CivitAI**: Community models with search, filtering, and NSFW controls")

                Text("Both sources support real-time download tracking and automatic CoreML conversion.")
                    .font(.callout)
                    .foregroundColor(.secondary)
                    .italic()
                    .padding(.top, 8)
            }

            HelpSection_Group(title: "Choosing a Provider") {
                Text("Consider these factors when selecting a provider and model:")
                    .fontWeight(.semibold)
                    .padding(.bottom, 4)

                BulletPoint(text: "**Task Complexity**: Use GPT-4, Claude 4, or O1 for complex reasoning. Use GPT-3.5 or Flash models for simple tasks")
                BulletPoint(text: "**Context Size**: Need to process huge documents? Use Gemini Pro (2M tokens)")
                BulletPoint(text: "**Privacy**: Use local models for completely private, offline work")
                BulletPoint(text: "**Cost**: Local models are free to run. GPT-3.5 is cheaper than GPT-4")
                BulletPoint(text: "**Speed**: Flash models and GPT-3.5 respond faster than larger models")
                BulletPoint(text: "**Specialty**: Claude excels at analysis, GPT-4 at coding, O1 at reasoning, local models at privacy")

                Text("**Pro Tip**: You can switch models mid-conversation! Try different models for different parts of your workflow.")
                    .font(.callout).italic().foregroundColor(.blue).padding(.top, 8)
            }
        }
    }
}

// MARK: - Capabilities Content
struct CapabilitiesContent: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("What SAM Can Do")
                .font(.largeTitle)
                .fontWeight(.bold)

            Text("SAM is a powerful AI assistant with extensive capabilities across many domains.")
                .font(.title3)
                .foregroundColor(.secondary)

            Divider()

            CapabilityCategory(
                icon: "magnifyingglass",
                title: "Research & Information",
                description: "Comprehensive web research, article summarization, and information synthesis"
            ) {
                ExamplePrompt(prompt: "Research the latest developments in quantum computing")
                ExamplePrompt(prompt: "Summarize this article: [paste URL]")
                ExamplePrompt(prompt: "What are the top 10 programming languages in 2025?")
            }

            CapabilityCategory(
                icon: "doc.text",
                title: "Document Management",
                description: "Create, import, and analyze documents in multiple formats"
            ) {
                ExamplePrompt(prompt: "Create a PDF report about my project findings")
                ExamplePrompt(prompt: "Import this Word document and summarize it")
                ExamplePrompt(prompt: "Convert this data to an Excel spreadsheet")
            }

            CapabilityCategory(
                icon: "chevron.left.forwardslash.chevron.right",
                title: "Code & Development",
                description: "Write code, debug issues, search codebases, and automate tasks"
            ) {
                ExamplePrompt(prompt: "Create a Python script to analyze CSV data")
                ExamplePrompt(prompt: "Find all uses of the authenticate() function in my project")
                ExamplePrompt(prompt: "Debug this error: [paste error message]")
            }

            CapabilityCategory(
                icon: "folder",
                title: "File Operations",
                description: "Search, organize, and work with files in your conversation's folder"
            ) {
                ExamplePrompt(prompt: "Find all Swift files in my Sources directory")
                ExamplePrompt(prompt: "Read the contents of config.json")
                ExamplePrompt(prompt: "Create a file called notes.txt with my meeting notes")
            }

            CapabilityCategory(
                icon: "brain.head.profile",
                title: "Memory & Learning",
                description: "Store and recall information from previous conversations"
            ) {
                ExamplePrompt(prompt: "Remember that my preferred coding style is 4-space indentation")
                ExamplePrompt(prompt: "Search my memory for conversations about machine learning")
                ExamplePrompt(prompt: "What documents have I imported this week?")
            }

            CapabilityCategory(
                icon: "terminal",
                title: "Terminal & Automation",
                description: "Run shell commands in the built-in terminal and watch the results appear in real-time"
            ) {
                ExamplePrompt(prompt: "Use terminal to list all files in current directory")
                ExamplePrompt(prompt: "Run 'cat README.md' and show me what's inside")
                ExamplePrompt(prompt: "Check my git status using the terminal")
                ExamplePrompt(prompt: "Create a test file and verify it worked")
            }

            CapabilityCategory(
                icon: "photo.fill",
                title: "Image Generation (AI Art)",
                description: "Create images from text descriptions using Stable Diffusion models with CoreML or Python engines"
            ) {
                BulletPoint(text: "**Model Management**: Browse and download models from HuggingFace and CivitAI")
                BulletPoint(text: "**Format Selection**: Use CoreML (optimized) or Python (compatible) engines")
                BulletPoint(text: "**Real-time Tracking**: Monitor downloads and conversions with live progress")
                BulletPoint(text: "**Direct Generation**: Type prompts directly in chat interface")
                BulletPoint(text: "**LLM-Driven**: Ask AI assistant to generate images with natural language")

                ExamplePrompt(prompt: "Generate an image of a serene mountain landscape at sunset")
                ExamplePrompt(prompt: "Make an image of a futuristic city with flying cars at night")
                ExamplePrompt(prompt: "Generate a photo-realistic image of a cat sitting on a windowsill")
            }

            CapabilityCategory(
                icon: "cpu",
                title: "Local AI Inference",
                description: "Run AI models locally on your Mac with complete privacy and Apple Silicon optimization"
            ) {
                ExamplePrompt(prompt: "Use Qwen Coder for code generation without internet")
                ExamplePrompt(prompt: "Run Llama 3 locally for private conversations")
                ExamplePrompt(prompt: "Switch to local model for offline work")
            }
        }
    }
}

// MARK: - Tool Reference Content
struct ToolReferenceContent: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Tool Reference")
                .font(.largeTitle)
                .fontWeight(.bold)

            Text("SAM has 38 powerful tools using the Model Context Protocol (MCP). You don't need to learn these - just ask naturally and SAM will use the right tools automatically!")
                .font(.title3)
                .foregroundColor(.secondary)

            Divider()

            ToolCategory(icon: "brain", title: "Memory & Learning", color: .purple) {
                Tool(name: "memory_operations", description: "Search conversation history and imported documents using semantic similarity. Store important information for later recall. Track todos and manage task progress across sessions. Access conversation context like conversation ID.")
            }

            ToolCategory(icon: "globe", title: "Web & Research", color: .blue) {
                Tool(name: "web_operations", description: "Search the web, fetch webpage content, and conduct comprehensive research across multiple sources. Synthesize information from various websites into coherent summaries.")
            }

            ToolCategory(icon: "doc.text", title: "Documents", color: .green) {
                Tool(name: "document_operations", description: "Import PDFs, Word documents, text files, and images into conversation memory. Extract text and metadata. Create formatted documents in various formats.")
            }

            ToolCategory(icon: "folder", title: "File Operations", color: .orange) {
                Tool(name: "file_operations", description: "Read, write, search, and manage files. Create and edit files, rename and organize, search with glob patterns or regex, find code references, and apply patches. All file operations use your conversation's working directory.")
            }

            ToolCategory(icon: "terminal", title: "Terminal & Automation", color: .gray) {
                Tool(name: "terminal_operations", description: "Execute shell commands in your conversation's embedded terminal. Commands appear in the visible terminal panel and respect your working directory. Check command output and history.")
            }

            ToolCategory(icon: "hammer", title: "Build & Version Control", color: .indigo) {
                Tool(name: "build_and_version_control", description: "Run tests, create and execute build tasks, commit changes to git, and view file diffs. Manage your development workflow from within conversations.")
            }

            ToolCategory(icon: "person.2", title: "User Collaboration", color: .cyan) {
                Tool(name: "user_collaboration", description: "Request your input during complex tasks. SAM can ask for confirmation, clarification, or decisions before proceeding with important operations.")
            }

            ToolCategory(icon: "lightbulb", title: "Planning", color: .yellow) {
                Tool(name: "think", description: "Plan and organize complex multi-step tasks before execution. Helps SAM break down large requests into manageable steps and reason through problems.")
            }

            ToolCategory(icon: "photo.fill", title: "Image Generation", color: .pink) {
                Tool(name: "image_generation", description: "Generate images from text descriptions using Stable Diffusion. Supports model selection, engine choice (CoreML/Python), and advanced parameters.")

                Text("**Parameters:**")
                    .fontWeight(.semibold)
                    .padding(.top, 8)

                BulletPoint(text: "`prompt` (required): Text description of desired image")
                BulletPoint(text: "`model` (optional): Model ID (e.g., 'stable-diffusion/model-name')")
                BulletPoint(text: "`engine` (optional): 'coreml' or 'python' (auto-selected if not specified)")
                BulletPoint(text: "`size` (optional): Image dimensions (e.g., '512x512', '1024x1024')")
                BulletPoint(text: "`steps` (optional): Number of diffusion steps (default: 20)")
                BulletPoint(text: "`guidance_scale` (optional): How closely to follow prompt (default: 7.5)")
                BulletPoint(text: "`seed` (optional): Random seed for reproducibility")

                Text("**Example requests:**")
                    .fontWeight(.semibold)
                    .padding(.top, 8)

                ExamplePrompt(prompt: "Generate an image of a serene mountain landscape at sunset")
                ExamplePrompt(prompt: "Create a cyberpunk city scene with neon lights, 1024x1024")
            }

            ToolCategory(icon: "person.2.circle.fill", title: "Subagents & Delegation", color: .mint) {
                Tool(name: "run_subagent", description: "Create specialized AI agents to handle complex sub-tasks. Subagents inherit your settings (model, prompts, tools) and work independently, then return results. Perfect for parallel research, specialized analysis, or delegating discrete tasks. Each subagent appears as a separate conversation in your sidebar with \"working\" indicator.")
            }

            /// Note: UI operations like exporting conversations, managing system prompts, and updating preferences are available through the menu bar (File, Edit, View menus) and Preferences window (⌘,).
        }
    }
}

// MARK: - Personalities Content
struct PersonalitiesContent: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Personalities & Traits")
                .font(.largeTitle)
                .fontWeight(.bold)

            Text("Customize SAM's tone, style, and behavior using trait-based personalities.")
                .font(.title3)
                .foregroundColor(.secondary)

            Divider()

            HelpSection_Group(title: "What Are Personalities?") {
                Text("Personalities modify how SAM communicates without changing the underlying AI model.")
                    .padding(.bottom, 8)

                BulletPoint(text: "**Trait-Based**: Select from 5 categories (Tone, Formality, Verbosity, Humor, Teaching Style)")
                BulletPoint(text: "**Built-in Options**: Professional, Friendly, Concise, Detailed, and more")
                BulletPoint(text: "**Fully Editable**: Even built-in personalities can be customized")
                BulletPoint(text: "**Per-Conversation**: Different personalities for different tasks")
                BulletPoint(text: "**Prompt Augmentation**: Personalities merge with system prompts at runtime")
            }

            HelpSection_Group(title: "Built-in Personalities") {
                Text("SAM includes ready-to-use personalities:")
                    .padding(.bottom, 8)

                BulletPoint(text: "**Assistant** (Default): Neutral, balanced tone for general use")
                BulletPoint(text: "**Technical Expert**: Professional, detailed, technical communication")
                BulletPoint(text: "**Creative Writer**: Expressive, engaging, narrative-focused style")
                BulletPoint(text: "**Teacher**: Patient, educational, encouraging approach")
                BulletPoint(text: "**Researcher**: Analytical, thorough, evidence-based responses")

                Text("All built-in personalities can be edited to create your own custom versions.")
                    .font(.callout)
                    .foregroundColor(.secondary)
                    .italic()
                    .padding(.top, 8)
            }

            HelpSection_Group(title: "Creating Custom Personalities") {
                Text("Build personalities tailored to your specific needs:")
                    .padding(.bottom, 8)

                Text("**Step 1: Open Personality Preferences**")
                    .fontWeight(.semibold)
                BulletPoint(text: "⌘, (Preferences) → Personalities")
                BulletPoint(text: "Click \"New Personality\" button")

                Text("**Step 2: Basic Information**")
                    .fontWeight(.semibold)
                    .padding(.top, 8)
                BulletPoint(text: "**Name**: Descriptive identifier (e.g., \"Code Reviewer\", \"Creative Brainstormer\")")
                BulletPoint(text: "**Description**: Optional details about intended use")

                Text("**Step 3: Select Traits**")
                    .fontWeight(.semibold)
                    .padding(.top, 8)
                BulletPoint(text: "**Tone**: Friendly, Professional, Casual, Enthusiastic, Empathetic")
                BulletPoint(text: "**Formality**: Formal, Semi-Formal, Informal, Conversational")
                BulletPoint(text: "**Verbosity**: Concise, Balanced, Detailed, Comprehensive")
                BulletPoint(text: "**Humor**: Serious, Light Touch, Witty, Playful")
                BulletPoint(text: "**Teaching Style**: Direct, Socratic, Encouraging, Step-by-Step")

                Text("Select one trait from each category to define the personality.")
                    .font(.callout)
                    .foregroundColor(.secondary)
                    .italic()
                    .padding(.top, 4)

                Text("**Step 4: Custom Instructions (Optional)**")
                    .fontWeight(.semibold)
                    .padding(.top, 8)
                BulletPoint(text: "Add specific behavioral instructions beyond traits")
                BulletPoint(text: "Example: \"Always include code examples\", \"Focus on practical applications\"")
                BulletPoint(text: "Example: \"Prefer TypeScript over JavaScript\", \"Use metric units\"")

                Text("**Step 5: Preview & Save**")
                    .fontWeight(.semibold)
                    .padding(.top, 8)
                BulletPoint(text: "Review prompt preview to see how traits combine")
                BulletPoint(text: "Click \"Create Personality\" to save")
                BulletPoint(text: "Personality appears in all model selection menus")
            }

            HelpSection_Group(title: "Editing Personalities") {
                Text("Modify existing personalities (built-in or custom):")
                    .padding(.bottom, 8)

                BulletPoint(text: "**Edit Built-in**: Right-click → Edit creates editable copy")
                BulletPoint(text: "**Edit Custom**: Right-click → Edit modifies in-place")
                BulletPoint(text: "**Live Preview**: See prompt changes as you adjust traits")
                BulletPoint(text: "**Save Changes**: Click \"Save Changes\" to update")

                Text("Built-in personalities are never modified directly - editing creates a custom copy you can customize.")
                    .font(.callout)
                    .foregroundColor(.secondary)
                    .italic()
                    .padding(.top, 8)
            }

            HelpSection_Group(title: "Using Personalities") {
                Text("Apply personalities to conversations:")
                    .padding(.bottom, 8)

                Text("**Set Default for New Conversations:**")
                    .fontWeight(.semibold)
                BulletPoint(text: "Preferences → Personalities → \"Default for New Conversations\"")
                BulletPoint(text: "Select desired personality from dropdown")
                BulletPoint(text: "All new conversations use this personality")

                Text("**Per-Conversation Selection:**")
                    .fontWeight(.semibold)
                    .padding(.top, 8)
                BulletPoint(text: "Open conversation settings (gear icon in chat header)")
                BulletPoint(text: "Select personality from \"Personality\" picker")
                BulletPoint(text: "Each conversation can have different personality")
                BulletPoint(text: "Changes apply immediately to future messages")
            }

            HelpSection_Group(title: "Personality + System Prompt") {
                Text("How personalities interact with system prompts:")
                    .padding(.bottom, 8)

                BulletPoint(text: "**Merging**: Personalities are added to system prompts at runtime")
                BulletPoint(text: "**Non-Destructive**: Original system prompts remain unchanged")
                BulletPoint(text: "**Order**: System prompt first, then personality traits and custom instructions")
                BulletPoint(text: "**Flexibility**: Change personality without affecting core system prompt")

                Text("**Example Flow:**")
                    .fontWeight(.semibold)
                    .padding(.top, 8)
                BulletPoint(text: "1. System Prompt: \"You are a helpful AI assistant...\"")
                BulletPoint(text: "2. Personality Traits: \"Communicate in a friendly, conversational tone...\"")
                BulletPoint(text: "3. Custom Instructions: \"Always include code examples...\"")
                BulletPoint(text: "4. Final Prompt: All combined and sent to AI")
            }

            HelpSection_Group(title: "Best Practices") {
                Text("**Trait Selection Tips:**")
                    .fontWeight(.semibold)
                BulletPoint(text: "Start with one of the built-in personalities as a template")
                BulletPoint(text: "Select complementary traits (e.g., Friendly + Conversational + Balanced)")
                BulletPoint(text: "Avoid conflicting traits (e.g., Concise + Comprehensive)")

                Text("**Custom Instructions Guidelines:**")
                    .fontWeight(.semibold)
                    .padding(.top, 8)
                BulletPoint(text: "Be specific and actionable")
                BulletPoint(text: "Focus on behavior, not capabilities")
                BulletPoint(text: "Keep instructions concise (traits handle general tone)")
                BulletPoint(text: "Test with sample conversations to validate")

                Text("**Organization:**")
                    .fontWeight(.semibold)
                    .padding(.top, 8)
                BulletPoint(text: "Create task-specific personalities (Coding, Writing, Research)")
                BulletPoint(text: "Delete unused custom personalities to reduce clutter")
                BulletPoint(text: "Name descriptively for easy identification")
            }

            HelpSection_Group(title: "Example Personalities") {
                Text("**Code Reviewer:**")
                    .fontWeight(.semibold)
                BulletPoint(text: "Tone: Professional, Formality: Formal, Verbosity: Detailed")
                BulletPoint(text: "Custom: \"Focus on best practices, security, and performance\"")

                Text("**Brainstorming Partner:**")
                    .fontWeight(.semibold)
                    .padding(.top, 8)
                BulletPoint(text: "Tone: Enthusiastic, Formality: Conversational, Humor: Witty")
                BulletPoint(text: "Custom: \"Encourage wild ideas, no criticism, build on suggestions\"")

                Text("**Technical Documenter:**")
                    .fontWeight(.semibold)
                    .padding(.top, 8)
                BulletPoint(text: "Tone: Professional, Verbosity: Comprehensive, Teaching: Step-by-Step")
                BulletPoint(text: "Custom: \"Include examples, diagrams when applicable, clear headings\"")

                Text("**Learning Tutor:**")
                    .fontWeight(.semibold)
                    .padding(.top, 8)
                BulletPoint(text: "Tone: Empathetic, Teaching: Socratic, Formality: Semi-Formal")
                BulletPoint(text: "Custom: \"Ask questions before explaining, check understanding\"")
            }

            HelpSection_Group(title: "Deleting Personalities") {
                Text("Remove custom personalities:")
                    .padding(.bottom, 8)

                BulletPoint(text: "Right-click personality → Delete")
                BulletPoint(text: "Built-in personalities cannot be deleted (only edited to create copies)")
                BulletPoint(text: "Deletion is immediate and cannot be undone")
                BulletPoint(text: "Conversations using deleted personality revert to default")
            }
        }
    }
}

// MARK: - Document Formats Content
struct DocumentFormatsContent: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Supported Document Formats")
                .font(.largeTitle)
                .fontWeight(.bold)

            Text("SAM can import and create documents in multiple formats.")
                .font(.title3)
                .foregroundColor(.secondary)

            Divider()

            HelpSection_Group(title: "Import Formats (document_operations with operation: 'import')") {
                Text("SAM can read and analyze these document types:")
                    .foregroundColor(.secondary)

                FormatSupport(format: "PDF", icon: "doc.text.fill", color: .red, description: "Portable Document Format - full text extraction")
                FormatSupport(format: "DOCX", icon: "doc.fill", color: .blue, description: "Microsoft Word documents - content and formatting")
                FormatSupport(format: "TXT", icon: "doc.plaintext", color: .gray, description: "Plain text files - any encoding")
                FormatSupport(format: "RTF", icon: "doc.richtext", color: .orange, description: "Rich Text Format - formatted text")
                FormatSupport(format: "Images", icon: "photo", color: .green, description: "PNG, JPG, HEIC - OCR text extraction")

                ExamplePrompt(prompt: "Import this PDF: file:///Users/username/Documents/report.pdf")
                ExamplePrompt(prompt: "Analyze this Word document and summarize it")
            }

            HelpSection_Group(title: "Export Formats (document_create)") {
                Text("SAM can create professionally formatted documents:")
                    .foregroundColor(.secondary)

                FormatSupport(format: "PDF", icon: "doc.text.fill", color: .red, description: "Professional PDFs with custom metadata and formatting")
                FormatSupport(format: "DOCX", icon: "doc.fill", color: .blue, description: "Microsoft Word documents - compatible with Word 2007+")
                FormatSupport(format: "XLSX", icon: "tablecells", color: .green, description: "Excel spreadsheets - structured data with formulas")
                FormatSupport(format: "Markdown", icon: "text.alignleft", color: .purple, description: "Markdown files - for documentation and notes")
                FormatSupport(format: "RTF", icon: "doc.richtext", color: .orange, description: "Rich Text Format - cross-platform formatted text")

                ExamplePrompt(prompt: "Create a PDF report titled 'Q4 Analysis' with this content: [...]")
                ExamplePrompt(prompt: "Generate an Excel spreadsheet with this data: Name,Age\\nAlice,30\\nBob,25")
                ExamplePrompt(prompt: "Create a Word document about machine learning fundamentals")
            }

            HelpSection_Group(title: "Document Metadata") {
                Text("When creating documents, you can specify:")
                    .foregroundColor(.secondary)

                BulletPoint(text: "**Title**: Document title for header and metadata")
                BulletPoint(text: "**Author**: Author name in document properties")
                BulletPoint(text: "**Description**: Brief description of content")
                BulletPoint(text: "**Output Path**: Custom save location (defaults to ~/Downloads)")

                ExamplePrompt(prompt: "Create a PDF with title='Annual Report' author='John Smith' content='...'")
            }
        }
    }
}

// MARK: - Advanced Prompting Content
struct AdvancedPromptingContent: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Advanced Prompting Techniques")
                .font(.largeTitle)
                .fontWeight(.bold)

            Text("Master these techniques to get the most out of SAM.")
                .font(.title3)
                .foregroundColor(.secondary)

            Divider()

            HelpSection_Group(title: "Mini-Prompts: Contextual Information") {
                Text("Mini-prompts allow you to inject contextual information into your conversations automatically. Perfect for maintaining consistent context without repeating yourself.")
                    .padding(.bottom, 8)

                Text("What are Mini-Prompts?")
                    .fontWeight(.semibold)
                    .padding(.top, 4)

                Text("Mini-prompts are reusable snippets of contextual information that automatically enhance your messages. Unlike system prompts (which apply to all conversations), mini-prompts are per-conversation and can be toggled on/off as needed.")
                    .padding(.bottom, 8)

                Text("Common Use Cases:")
                    .fontWeight(.semibold)
                    .padding(.top, 4)

                BulletPoint(text: "Personal context: Location, timezone, preferences")
                BulletPoint(text: "Project details: Current project name, technology stack, goals")
                BulletPoint(text: "Code preferences: Language, style guide, patterns to follow")
                BulletPoint(text: "Technical specs: Hardware, OS, development environment")
                BulletPoint(text: "Role context: Position, expertise areas, experience level")

                Text("How to Use:")
                    .fontWeight(.semibold)
                    .padding(.top, 12)

                BulletPoint(text: "Click the Mini-Prompts button (Mini-Prompts icon) in the toolbar")
                BulletPoint(text: "Create a new prompt with a descriptive name")
                BulletPoint(text: "Add your contextual information")
                BulletPoint(text: "Toggle prompts on/off per conversation")
                BulletPoint(text: "Enabled prompts are automatically added to your messages")

                Text("Technical Details:")
                    .fontWeight(.semibold)
                    .padding(.top, 12)

                BulletPoint(text: "Per-conversation: Each conversation has independent mini-prompt settings")
                BulletPoint(text: "Persistent: Settings survive app restart")
                BulletPoint(text: "User-message injection: Context added to your message, not system prompt")
                BulletPoint(text: "Hidden in UI: Context visible to AI but filtered from chat display")

                Text("Pro Tips:")
                    .fontWeight(.semibold)
                    .padding(.top, 12)

                BulletPoint(text: "Keep prompts focused: One topic per mini-prompt")
                BulletPoint(text: "Enable only relevant prompts: Too much context can dilute effectiveness")
                BulletPoint(text: "Update when needed: Edit prompts as your project/context evolves")
                BulletPoint(text: "Use descriptive names: Makes it easy to identify purpose at a glance")
            }

            HelpSection_Group(title: "System Prompt Customization") {
                Text("System prompts define SAM's behavior and personality across all conversations.")
                    .padding(.bottom, 8)

                BulletPoint(text: "Access via Preferences → System Prompts")
                BulletPoint(text: "Create custom prompts for different use cases")
                BulletPoint(text: "Switch between prompts per conversation")
                BulletPoint(text: "Affects all AI responses in conversation")

                Text("Difference from Mini-Prompts:")
                    .fontWeight(.semibold)
                    .padding(.top, 8)

                Text("• System Prompt: Defines HOW the AI responds (tone, style, approach)")
                Text("• Mini-Prompt: Defines WHAT the AI knows (your context, preferences, details)")
            }

            HelpSection_Group(title: "Memory Management Strategies") {
                Text("Effective use of document import and memory search:")
                    .padding(.bottom, 8)

                BulletPoint(text: "Import reference documents at conversation start")
                BulletPoint(text: "Use memory search to retrieve specific information")
                BulletPoint(text: "Memory is conversation-scoped by default")
                BulletPoint(text: "Adjust similarity_threshold for broader/narrower results")
            }

            HelpSection_Group(title: "Multi-Step Task Planning") {
                Text("Break complex tasks into clear steps:")
                    .padding(.bottom, 8)

                BulletPoint(text: "Start with research: Import docs, search memory")
                BulletPoint(text: "Plan approach: Ask SAM to outline steps")
                BulletPoint(text: "Execute incrementally: One step at a time")
                BulletPoint(text: "Verify results: Check outputs before proceeding")
                BulletPoint(text: "Iterate as needed: Refine based on results")
            }
        }
    }
}

// MARK: - Troubleshooting Content
struct TroubleshootingContent: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Troubleshooting")
                .font(.largeTitle)
                .fontWeight(.bold)

            Text("Solutions to common issues and questions.")
                .font(.title3)
                .foregroundColor(.secondary)

            Divider()

            TroubleshootingItem(
                question: "SAM isn't responding to my messages",
                solution: """
                Check these items:
                • Verify your API key is configured in Preferences (⌘,)
                • Check your internet connection for cloud AI providers
                • Restart SAM and try again
                • Check the Console app for SAM error messages
                """
            )

            TroubleshootingItem(
                question: "Document import failed",
                solution: """
                Possible causes:
                • File path incorrect (use file:
                • File format not supported
                • File corrupted or password-protected
                • Insufficient disk space for extraction

                Try: Verify file opens in its native application first
                """
            )

            TroubleshootingItem(
                question: "DOCX/XLSX export shows error",
                solution: """
                Ensure:
                • Output directory has write permissions
                • Filename doesn't contain invalid characters (/, :, etc.)
                • Sufficient disk space available
                • No existing file is locked/open in another app
                """
            )

            TroubleshootingItem(
                question: "Web research returns no results",
                solution: """
                Check:
                • Internet connection is active
                • Search API keys configured (Google, Bing) in Preferences
                • Query is specific enough (avoid single-word queries)
                • Try rephrasing your research question
                """
            )

            TroubleshootingItem(
                question: "Memory search doesn't find my documents",
                solution: """
                Remember:
                • Documents must be imported first with document_operations (operation: 'import')
                • Memory is conversation-scoped by default
                • Use similarity_threshold=0.3 for broader results
                • Try different query phrasings
                """
            )

            TroubleshootingItem(
                question: "SAM is using too much memory/CPU",
                solution: """
                Optimize performance:
                • Close unused conversations
                • Clear conversation history periodically (File > Clear History)
                • Use cloud AI instead of local models for resource-intensive tasks
                • Restart SAM to clear cached data
                """
            )

            TroubleshootingItem(
                question: "How do I export my conversations?",
                solution: """
                Export conversations:
                • File > Export Conversation (O)
                • Choose format: JSON (full data), Text (readable), Markdown (formatted)
                • Or ask SAM: "Export this conversation as JSON"
                """
            )

            TroubleshootingItem(
                question: "Local model not appearing in dropdown",
                solution: """
                Check these items:
                • Verify model is in correct directory structure: ~/Library/Caches/sam/models/provider/model/
                • Restart SAM to rescan for new models
                • Check SAM User Guide (Help menu) for detailed installation instructions
                """
            )

            TroubleshootingItem(
                question: "Local inference is slow or uses too much memory",
                solution: """
                Optimize local model performance:
                • Use 4-bit quantized models instead of 8-bit (faster, less memory)
                • Close memory-intensive applications
                • Check Activity Monitor for memory pressure
                • First inference slower (model loading) - subsequent requests much faster
                • Consider smaller models (7B instead of 13B) for limited RAM
                • Keep SAM running to avoid model reload penalty
                """
            )

            HelpSection_Group(title: "Stable Diffusion Issues") {
                TroubleshootingItem(
                    question: "Model not appearing in picker",
                    solution: """
                    Check these items:
                    • Verify model directory contains .mlmodelc files (CoreML) or .safetensors files
                    • Check Preferences → Local Models to see detected models
                    • Restart SAM to rescan models
                    • Check model directory structure matches expected format
                    """
                )

                TroubleshootingItem(
                    question: "Conversion failed",
                    solution: """
                    Troubleshoot conversion issues:
                    • Check logs for specific error messages (now properly filtered)
                    • Ensure Python environment is properly installed
                    • Verify sufficient disk space (~5-10GB per model)
                    • Try downloading SafeTensors only (skip conversion)
                    • Check model compatibility (SD 1.x, 2.x, SDXL supported)
                    """
                )

                TroubleshootingItem(
                    question: "Engine selection disabled",
                    solution: """
                    This is normal behavior:
                    • Model only has one format available
                    • CoreML-only: Download SafeTensors to enable Python option
                    • SafeTensors-only: Convert to CoreML to enable CoreML option
                    • Check model info to see available formats
                    """
                )

                TroubleshootingItem(
                    question: "Download stuck or slow",
                    solution: """
                    If download appears stuck:
                    • Check internet connection
                    • Large models (SDXL) can take 15-30 minutes
                    • Progress updates every few seconds (not real-time)
                    • Cancel and retry if truly stuck
                    • Check available disk space
                    """
                )
            }
        }
    }
}

// MARK: - Privacy & Security Content
struct PrivacySecurityContent: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Privacy & Security")
                .font(.largeTitle)
                .fontWeight(.bold)

            Text("How SAM protects your data and respects your privacy.")
                .font(.title3)
                .foregroundColor(.secondary)

            Divider()

            HelpSection_Group(title: "Data Storage") {
                BulletPoint(text: "**Conversation History**: Stored locally in ~/Library/Application Support/sam/")
                BulletPoint(text: "**Vector Database**: Encrypted SQLite database for memory search")
                BulletPoint(text: "**Imported Documents**: Chunked and stored in local database")
                BulletPoint(text: "**Temporary Files**: Automatically cleaned up after operations")
            }

            HelpSection_Group(title: "AI Provider Options") {
                Text("**Important:** When using remote API providers, your conversation data (messages, prompts, and context) is sent to third-party servers for processing. Choose local models if privacy is a concern.")
                    .font(.callout)
                    .foregroundColor(.orange)
                    .padding(.vertical, 8)
                    .padding(.horizontal, 12)
                    .background(Color.orange.opacity(0.1))
                    .cornerRadius(8)

                Text("Cloud Providers (OpenAI, Anthropic, GitHub Copilot):")
                    .fontWeight(.semibold)
                    .padding(.top, 8)
                BulletPoint(text: "Data sent to provider's servers for processing")
                BulletPoint(text: "Your messages and conversation context visible to third party")
                BulletPoint(text: "Subject to provider's privacy policy and terms of service")
                BulletPoint(text: "Faster processing, more powerful models")
                BulletPoint(text: "Requires internet connection and API keys")

                Text("Local Models (GGUF & MLX):")
                    .fontWeight(.semibold)
                    .padding(.top, 8)
                BulletPoint(text: "All processing happens on your Mac")
                BulletPoint(text: "No data sent to external servers - complete privacy")
                BulletPoint(text: "Works offline without internet connection")
                BulletPoint(text: "Complete conversation privacy - nothing leaves your device")
                BulletPoint(text: "Supports GGUF models (via llama.cpp) and MLX native models")
                BulletPoint(text: "Optimized for Apple Silicon (M1/M2/M3 chips)")
            }

            HelpSection_Group(title: "API Direct Mode") {
                Text("When enabled in Preferences:")
                    .foregroundColor(.secondary)
                BulletPoint(text: "Bypasses SAM's processing layer")
                BulletPoint(text: "No system prompts or MCP tools")
                BulletPoint(text: "Direct communication with AI provider")
                BulletPoint(text: "Useful for sensitive/private conversations")
            }

            HelpSection_Group(title: "MCP Tool Security Controls") {
                Text("SAM uses Model Context Protocol (MCP) tools with multiple layers of security:")
                    .font(.body)
                    .padding(.bottom, 8)

                Text("**Built-in Guard Rails:**")
                    .fontWeight(.semibold)
                BulletPoint(text: "**Smart Tool Selection**: SAM automatically chooses appropriate tools based on your request")
                BulletPoint(text: "**Behavioral Controls**: System prompts enforce responsible tool usage patterns")
                BulletPoint(text: "**Parameter Validation**: All tool inputs validated before execution")

                Text("**User Control:**")
                    .fontWeight(.semibold)
                    .padding(.top, 8)
                BulletPoint(text: "**Tools Toggle**: Disable all tool usage via toolbar (when OFF, SAM cannot use any tools)")
                BulletPoint(text: "**Conversation Isolation**: Each conversation has separate memory/context")
                BulletPoint(text: "**user_collaboration Tool**: SAM can ask for confirmation before destructive operations")

                Text("**Destructive Operation Protection:**")
                    .fontWeight(.semibold)
                    .padding(.top, 8)
                BulletPoint(text: "File deletion, renaming, and modification tools require explicit parameters")
                BulletPoint(text: "No wildcard deletion (e.g., 'delete all .txt files' requires individual file paths)")
                BulletPoint(text: "System prompts encourage SAM to ask user confirmation via user_collaboration")

                Text("**Tip**: If you want SAM to have zero ability to use tools (for maximum safety), toggle Tools OFF in the toolbar.")
                    .font(.callout)
                    .foregroundColor(.secondary)
                    .italic()
                    .padding(.top, 8)
            }

            HelpSection_Group(title: "Security Best Practices") {
                BulletPoint(text: "**API Keys**: Store in Preferences, never share in conversations")
                BulletPoint(text: "**Sensitive Data**: Use local models or API Direct mode")
                BulletPoint(text: "**Exported Files**: Secure exported conversations (may contain sensitive info)")
                BulletPoint(text: "**Updates**: Keep SAM updated for latest security fixes")
            }

            HelpSection_Group(title: "Data Deletion") {
                Text("To remove your data:")
                    .foregroundColor(.secondary)
                BulletPoint(text: "**Clear History**: File > Clear History (removes all conversations)")
                BulletPoint(text: "**Delete Specific Conversation**: Conversation > Delete Conversation")
                BulletPoint(text: "**Complete Removal**: Delete ~/Library/Application Support/sam/")
            }
        }
    }
}

// MARK: - Reusable Components
struct HelpSection_Group<Content: View>: View {
    let title: String
    let content: Content

    init(title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            /// Section title.
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(.primary)
                .padding(.bottom, 4)

            /// Section content.
            VStack(alignment: .leading, spacing: 10) {
                content
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.5))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.secondary.opacity(0.2), lineWidth: 1)
        )
    }
}

struct HelpStep: View {
    let number: Int
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(number)")
                .font(.title3)
                .fontWeight(.bold)
                .foregroundColor(.white)
                .frame(width: 32, height: 32)
                .background(Circle().fill(Color.accentColor))

            Text(text)
                .font(.body)
        }
    }
}

struct ExamplePrompt: View {
    let title: String?
    let prompt: String

    init(title: String? = nil, prompt: String) {
        self.title = title
        self.prompt = prompt
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let title = title {
                Text(title)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Text(prompt)
                .font(.body)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(nsColor: .controlBackgroundColor))
                .cornerRadius(8)
                .contextMenu {
                    Button("Copy Example") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(prompt, forType: .string)
                    }
                }
        }
    }
}

struct BulletPoint: View {
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text("•")
                .font(.body)
                .foregroundColor(.secondary)

            Text(.init(text))
                .font(.body)
        }
    }
}

struct KeyboardShortcut: View {
    let keys: String
    let description: String

    var body: some View {
        HStack {
            Text(keys)
                .font(.system(.body, design: .monospaced))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color(nsColor: .controlBackgroundColor))
                .cornerRadius(4)

            Text(description)
                .font(.body)

            Spacer()
        }
    }
}

struct CapabilityCategory<Content: View>: View {
    let icon: String
    let title: String
    let description: String
    let examples: Content

    init(icon: String, title: String, description: String, @ViewBuilder examples: () -> Content) {
        self.icon = icon
        self.title = title
        self.description = String(description)
        self.examples = examples()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            /// Header with icon and title.
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 20, weight: .medium))
                    .foregroundColor(.accentColor)
                    .frame(width: 24, height: 24)

                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(.primary)

                    Text(description)
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
            }
            .padding(.bottom, 4)

            /// Examples list.
            VStack(alignment: .leading, spacing: 8) {
                examples
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.accentColor.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.accentColor.opacity(0.2), lineWidth: 1)
        )
    }
}

struct ToolCategory<Content: View>: View {
    let icon: String
    let title: String
    let color: Color
    let tools: Content

    init(icon: String, title: String, color: Color, @ViewBuilder tools: () -> Content) {
        self.icon = icon
        self.title = title
        self.color = color
        self.tools = tools()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            /// Header with icon and title.
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 20, weight: .medium))
                    .foregroundColor(color)
                    .frame(width: 24, height: 24)

                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.primary)
            }
            .padding(.bottom, 4)

            /// Tools list.
            VStack(alignment: .leading, spacing: 10) {
                tools
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(color.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(color.opacity(0.2), lineWidth: 1)
        )
    }
}

struct Tool: View {
    let name: String
    let description: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text("•")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(.secondary)
                .frame(width: 8, alignment: .leading)

            VStack(alignment: .leading, spacing: 3) {
                Text(name)
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .foregroundColor(.primary)

                Text(description)
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 2)
    }
}

struct FormatSupport: View {
    let format: String
    let icon: String
    let color: Color
    let description: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .medium))
                .foregroundColor(color)
                .frame(width: 32, height: 32)
                .background(
                    Circle()
                        .fill(color.opacity(0.1))
                )

            VStack(alignment: .leading, spacing: 3) {
                Text(format)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.primary)

                Text(description)
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 6)
    }
}

struct TroubleshootingItem: View {
    let question: String
    let solution: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            /// Question header.
            HStack(spacing: 10) {
                Image(systemName: "questionmark.circle.fill")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundColor(.orange)
                    .frame(width: 24, height: 24)

                Text(question)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.primary)
            }

            /// Solution text.
            Text(solution)
                .font(.system(size: 13))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.orange.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.orange.opacity(0.2), lineWidth: 1)
        )
    }
}

struct SystemPromptOption: View {
    let name: String
    let bestFor: String
    let description: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(name)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.primary)

                Spacer()

                Text(bestFor)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.secondary)
                    .italic()
            }

            Text(description)
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.accentColor.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(Color.accentColor.opacity(0.15), lineWidth: 1)
        )
    }
}

// MARK: - Keyboard Shortcuts Content
struct KeyboardShortcutsContent: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Keyboard Shortcuts & Navigation")
                .font(.largeTitle)
                .fontWeight(.bold)

            Text("Master keyboard shortcuts to work faster and more efficiently.")
                .font(.title3)
                .foregroundColor(.secondary)

            Divider()

            HelpSection_Group(title: "Essential Shortcuts") {
                ShortcutRow(keys: "⌘N", description: "New conversation")
                ShortcutRow(keys: "⌘,", description: "Open Preferences")
                ShortcutRow(keys: "⌘W", description: "Close current window")
                ShortcutRow(keys: "⌘Q", description: "Quit SAM")
                ShortcutRow(keys: "⌘?", description: "Open Help (this window)")
            }

            HelpSection_Group(title: "Conversation Shortcuts") {
                ShortcutRow(keys: "⌘T", description: "Toggle tools on/off")
                ShortcutRow(keys: "⌘Return", description: "Send message")
                ShortcutRow(keys: "⌘K", description: "Clear chat input")
                ShortcutRow(keys: "⌘L", description: "Focus message input")
                ShortcutRow(keys: "⌘[", description: "Previous conversation")
                ShortcutRow(keys: "⌘]", description: "Next conversation")
            }

            HelpSection_Group(title: "Editing & Selection") {
                ShortcutRow(keys: "⌘A", description: "Select all text")
                ShortcutRow(keys: "⌘C", description: "Copy selected text")
                ShortcutRow(keys: "⌘V", description: "Paste text")
                ShortcutRow(keys: "⌘Z", description: "Undo")
                ShortcutRow(keys: "⇧⌘Z", description: "Redo")
            }

            HelpSection_Group(title: "File Operations") {
                ShortcutRow(keys: "⌘O", description: "Open file/conversation")
                ShortcutRow(keys: "⌘S", description: "Save conversation")
                ShortcutRow(keys: "⌘E", description: "Export conversation")
                ShortcutRow(keys: "⌘I", description: "Import document")
            }

            HelpSection_Group(title: "Navigation Tips") {
                BulletPoint(text: "**Sidebar Navigation**: Click conversation names to switch between chats")
                BulletPoint(text: "**Topic Folders**: Organize conversations into folders for easy access")
                BulletPoint(text: "**Search**: Use search bar to find specific conversations or messages")
                BulletPoint(text: "**Scroll to Top**: Click conversation name in header to scroll to top")
            }

            HelpSection_Group(title: "Productivity Tips") {
                BulletPoint(text: "**Tools Toggle**: Quickly disable tools for simple Q&A with ⌘T")
                BulletPoint(text: "**Model Picker**: Access from toolbar - no menu diving needed")
                BulletPoint(text: "**Mini-Prompts**: One-click context injection via toolbar button")
                BulletPoint(text: "**System Prompts**: Quick personality changes via conversation settings")
            }
        }
    }
}

// MARK: - Image Generation Guide Content
struct ImageGenerationGuideContent: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Image Generation Guide")
                .font(.largeTitle)
                .fontWeight(.bold)

            Text("Complete guide to creating AI-generated images with Stable Diffusion.")
                .font(.title3)
                .foregroundColor(.secondary)

            Divider()

            HelpSection_Group(title: "Quick Start") {
                Text("Generate your first image in 3 steps:")
                    .fontWeight(.semibold)
                    .padding(.bottom, 8)

                BulletPoint(text: "**1. Install a Model**: Go to Preferences → Image Generation → Model Browser")
                BulletPoint(text: "**2. Download**: Find a model you like and download it (with optional CoreML conversion)")
                BulletPoint(text: "**3. Generate**: Type your prompt in chat or ask the AI to generate an image")

                ExamplePrompt(prompt: "Generate an image of a serene mountain landscape at sunset")
                ExamplePrompt(prompt: "Create a photo-realistic image of a cat on a windowsill")
            }

            HelpSection_Group(title: "Model Selection") {
                Text("**Where to Find Models:**")
                    .fontWeight(.semibold)

                BulletPoint(text: "**HuggingFace**: Official Stable Diffusion models and popular variants")
                BulletPoint(text: "**CivitAI**: 100,000+ community models with search, filtering, NSFW controls")

                Text("**Model Types:**")
                    .fontWeight(.semibold)
                    .padding(.top, 8)

                BulletPoint(text: "**SD 1.5**: 512×512 images, fast, wide variety of fine-tuned models")
                BulletPoint(text: "**SD 2.x**: 768×768 images, improved quality")
                BulletPoint(text: "**SDXL**: 1024×1024 images, highest quality, slower")

                Text("**Recommendation**: Start with SD 1.5 models - faster and more community options.")
                    .font(.callout)
                    .foregroundColor(.secondary)
                    .italic()
                    .padding(.top, 8)
            }

            HelpSection_Group(title: "Engine Selection") {
                Text("SAM supports two execution engines for Stable Diffusion:")
                    .padding(.bottom, 8)

                Text("**CoreML (Recommended)**")
                    .fontWeight(.semibold)
                BulletPoint(text: "Apple Silicon optimized (M1/M2/M3)")
                BulletPoint(text: "Fast inference (2-4 seconds per image)")
                BulletPoint(text: "Lower memory usage")
                BulletPoint(text: "Energy efficient")

                Text("**Python (Fallback)**")
                    .fontWeight(.semibold)
                    .padding(.top, 8)
                BulletPoint(text: "Uses diffusers library")
                BulletPoint(text: "Broader model compatibility")
                BulletPoint(text: "Works with any .safetensors file")
                BulletPoint(text: "Slower but more flexible")

                Text("**Auto-Selection**: SAM automatically chooses the best available engine based on what formats you have.")
                    .font(.callout)
                    .foregroundColor(.secondary)
                    .italic()
                    .padding(.top, 8)
            }

            HelpSection_Group(title: "Workflow: Browse → Download → Convert → Generate") {
                Text("**Step 1: Browse Models**")
                    .fontWeight(.semibold)
                BulletPoint(text: "Open Preferences → Image Generation")
                BulletPoint(text: "Choose HuggingFace or CivitAI tab")
                BulletPoint(text: "Search by name, tags, or browse popular models")
                BulletPoint(text: "Preview images and read descriptions")

                Text("**Step 2: Download**")
                    .fontWeight(.semibold)
                    .padding(.top, 8)
                BulletPoint(text: "Click Download button on model card")
                BulletPoint(text: "Watch real-time progress updates")
                BulletPoint(text: "Large models (SDXL) may take 15-30 minutes")

                Text("**Step 3: Convert to CoreML (Optional)**")
                    .fontWeight(.semibold)
                    .padding(.top, 8)
                BulletPoint(text: "Click Convert button after download completes")
                BulletPoint(text: "Conversion takes 10-20 minutes depending on model")
                BulletPoint(text: "Watch conversion progress with model name displayed")
                BulletPoint(text: "Requires ~5-10GB temporary disk space")

                Text("**Step 4: Generate Images**")
                    .fontWeight(.semibold)
                    .padding(.top, 8)
                BulletPoint(text: "Select model from picker in chat interface")
                BulletPoint(text: "Choose engine (or let SAM auto-select)")
                BulletPoint(text: "Type your prompt and generate")
                BulletPoint(text: "Images saved to ~/Library/Caches/sam/images/")
            }

            HelpSection_Group(title: "Prompt Engineering Tips") {
                Text("Write better prompts for better results:")
                    .padding(.bottom, 8)

                BulletPoint(text: "**Be Specific**: \"Serene mountain landscape at sunset\" vs \"mountains\"")
                BulletPoint(text: "**Add Style**: \"watercolor painting of...\", \"photo-realistic...\", \"digital art of...\"")
                BulletPoint(text: "**Include Details**: Lighting, mood, composition, colors")
                BulletPoint(text: "**Use Quality Tags**: \"8k\", \"detailed\", \"highly detailed\", \"masterpiece\"")
                BulletPoint(text: "**Negative Prompts**: Some models support negative prompts (what NOT to include)")

                Text("**Examples:**")
                    .fontWeight(.semibold)
                    .padding(.top, 8)

                ExamplePrompt(prompt: "A serene mountain landscape at sunset, golden hour lighting, 8k, detailed")
                ExamplePrompt(prompt: "Photo-realistic portrait of a cat sitting on a windowsill, natural lighting")
                ExamplePrompt(prompt: "Futuristic city with flying cars, neon lights, cyberpunk style, digital art")
                ExamplePrompt(prompt: "Watercolor painting of a peaceful forest stream, soft colors, artistic")
            }

            HelpSection_Group(title: "Advanced Parameters") {
                BulletPoint(text: "**Steps**: Number of diffusion steps (default: 20). More steps = higher quality, slower generation")
                BulletPoint(text: "**Guidance Scale**: How closely to follow prompt (default: 7.5). Higher = stricter adherence")
                BulletPoint(text: "**Seed**: Random seed for reproducibility. Same seed + prompt = same image")
                BulletPoint(text: "**Size**: Image dimensions. Must match model's training (512×512 for SD 1.5, 1024×1024 for SDXL)")
                BulletPoint(text: "**Scheduler**: Sampling algorithm (DPM++, Euler, etc.). Different algorithms produce different results")
            }

            HelpSection_Group(title: "LLM-Driven Generation") {
                Text("Ask the AI assistant to generate images using natural language:")
                    .padding(.bottom, 8)

                ExamplePrompt(prompt: "Generate an image of a serene mountain landscape")
                ExamplePrompt(prompt: "Create a futuristic city scene for me")
                ExamplePrompt(prompt: "Make me an image of a cat on a windowsill")

                Text("The AI will:")
                    .fontWeight(.semibold)
                    .padding(.top, 8)
                BulletPoint(text: "Extract parameters from your description")
                BulletPoint(text: "Select an appropriate installed model")
                BulletPoint(text: "Choose optimal settings")
                BulletPoint(text: "Generate and display the image")
                BulletPoint(text: "All through natural conversation")
            }

            HelpSection_Group(title: "Troubleshooting") {
                TroubleshootingItem(
                    question: "Model not appearing in picker",
                    solution: """
                    • Verify model directory has .mlmodelc files (CoreML) or .safetensors
                    • Check Preferences → Local Models to see detected models
                    • Restart SAM to rescan models
                    """
                )

                TroubleshootingItem(
                    question: "Conversion failed",
                    solution: """
                    • Check logs for specific error messages
                    • Ensure sufficient disk space (~5-10GB per model)
                    • Try downloading SafeTensors only (skip conversion)
                    • Verify model compatibility (SD 1.x, 2.x, SDXL supported)
                    """
                )

                TroubleshootingItem(
                    question: "Generation quality poor",
                    solution: """
                    • Try increasing steps (30-50 for higher quality)
                    • Adjust guidance scale (7.5-10 for stronger prompt adherence)
                    • Improve prompt with more specific details
                    • Try a different model or scheduler
                    """
                )
            }
        }
    }
}

// MARK: - Conversation Management Content
struct ConversationManagementContent: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Conversation Management")
                .font(.largeTitle)
                .fontWeight(.bold)

            Text("Organize, export, and manage your conversations effectively.")
                .font(.title3)
                .foregroundColor(.secondary)

            Divider()

            HelpSection_Group(title: "Creating Conversations") {
                BulletPoint(text: "**New Conversation**: Click + button in sidebar or press ⌘N")
                BulletPoint(text: "**Name Automatically**: First message becomes conversation name")
                BulletPoint(text: "**Rename Anytime**: Double-click conversation name to edit")
                BulletPoint(text: "**Fresh Start**: Each new conversation starts with clean context")
            }

            HelpSection_Group(title: "Topic Folders") {
                Text("Organize conversations into folders for easy access:")
                    .padding(.bottom, 8)

                BulletPoint(text: "**Create Folder**: Click folder icon or right-click in sidebar")
                BulletPoint(text: "**Move Conversations**: Right-click conversation → Move to Folder")
                BulletPoint(text: "**Collapse/Expand**: Click arrow to show/hide folder contents")
                BulletPoint(text: "**Organize by Project**: Work, Personal, Research, etc.")
                BulletPoint(text: "**Color Coding**: (Future feature) - assign colors to folders")

                Text("**Example Structure:**")
                    .fontWeight(.semibold)
                    .padding(.top, 8)
                BulletPoint(text: "📁 Work → Client Projects, Internal Docs, Meetings")
                BulletPoint(text: "📁 Personal → Ideas, Learning, Notes")
                BulletPoint(text: "📁 Code → Python Help, SwiftUI, Debugging")
            }

            HelpSection_Group(title: "Conversation Settings") {
                Text("Customize each conversation independently:")
                    .padding(.bottom, 8)

                BulletPoint(text: "**Model Selection**: Choose different AI models per conversation")
                BulletPoint(text: "**System Prompt**: Apply different personalities or behaviors")
                BulletPoint(text: "**Mini-Prompts**: Enable contextual information per conversation")
                BulletPoint(text: "**Tools Toggle**: Enable/disable tools independently")
                BulletPoint(text: "**Memory Scope**: Documents imported in one conversation don't affect others")

                Text("Access settings via conversation header or right-click menu.")
                    .font(.callout)
                    .foregroundColor(.secondary)
                    .italic()
                    .padding(.top, 8)
            }

            HelpSection_Group(title: "Exporting Conversations") {
                Text("Share or archive conversations in multiple formats:")
                    .padding(.bottom, 8)

                Text("**Supported Formats:**")
                    .fontWeight(.semibold)
                BulletPoint(text: "**PDF**: Professional document with formatting and metadata")
                BulletPoint(text: "**DOCX**: Microsoft Word document for editing")
                BulletPoint(text: "**Markdown**: Plain text with formatting for sharing")
                BulletPoint(text: "**JSON**: Complete conversation data for re-import")

                Text("**How to Export:**")
                    .fontWeight(.semibold)
                    .padding(.top, 8)
                BulletPoint(text: "File menu → Export Conversation (⌘E)")
                BulletPoint(text: "Right-click conversation → Export")
                BulletPoint(text: "Choose format and save location")
                BulletPoint(text: "Includes all messages, timestamps, and metadata")

                Text("**Use Cases:**")
                    .fontWeight(.semibold)
                    .padding(.top, 8)
                BulletPoint(text: "Share research findings with team (PDF/DOCX)")
                BulletPoint(text: "Archive important conversations (JSON)")
                BulletPoint(text: "Create documentation from AI assistance (Markdown)")
                BulletPoint(text: "Backup before major changes")
            }

            HelpSection_Group(title: "Importing & Sharing") {
                Text("Import conversations or documents:")
                    .padding(.bottom, 8)

                BulletPoint(text: "**Import Conversation**: File → Import → Select JSON export")
                BulletPoint(text: "**Import Documents**: Drag & drop PDFs, DOCX into conversation")
                BulletPoint(text: "**Share with Others**: Export as JSON and send to colleagues")
                BulletPoint(text: "**Privacy Note**: Exported conversations contain all messages and context")
            }

            HelpSection_Group(title: "Search & Filtering") {
                BulletPoint(text: "**Search Bar**: Find conversations by name or content")
                BulletPoint(text: "**Filter by Folder**: Click folder to show only its conversations")
                BulletPoint(text: "**Recent Conversations**: Automatically sorted by last activity")
                BulletPoint(text: "**Find in Conversation**: ⌘F to search within active chat")
            }

            HelpSection_Group(title: "Deletion & Cleanup") {
                Text("Managing conversation history:")
                    .padding(.bottom, 8)

                BulletPoint(text: "**Delete Conversation**: Right-click → Delete (⌘⌫)")
                BulletPoint(text: "**Clear All History**: File → Clear History (removes all conversations)")
                BulletPoint(text: "**Cannot Undo**: Deletion is permanent unless you have backups")
                BulletPoint(text: "**Best Practice**: Export important conversations before cleanup")
            }

            HelpSection_Group(title: "Keyboard Shortcuts") {
                ShortcutRow(keys: "⌘N", description: "New conversation")
                ShortcutRow(keys: "⌘[", description: "Previous conversation")
                ShortcutRow(keys: "⌘]", description: "Next conversation")
                ShortcutRow(keys: "⌘E", description: "Export conversation")
                ShortcutRow(keys: "⌘⌫", description: "Delete conversation")
                ShortcutRow(keys: "⌘F", description: "Find in conversation")
            }
        }
    }
}

// MARK: - MCP Tools Deep Dive Content
struct MCPToolsDeepDiveContent: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("MCP & Tools Deep Dive")
                .font(.largeTitle)
                .fontWeight(.bold)

            Text("Understanding the Model Context Protocol and how SAM's tools work.")
                .font(.title3)
                .foregroundColor(.secondary)

            Divider()

            HelpSection_Group(title: "What is Model Context Protocol (MCP)?") {
                Text("MCP is a standardized way for AI assistants to interact with external tools and services.")
                    .padding(.bottom, 8)

                Text("**Key Concepts:**")
                    .fontWeight(.semibold)
                BulletPoint(text: "**Tools**: Capabilities the AI can use (file operations, web search, etc.)")
                BulletPoint(text: "**Parameters**: Inputs required for each tool")
                BulletPoint(text: "**Execution**: AI decides when and how to use tools based on your request")
                BulletPoint(text: "**Responses**: Tool results are incorporated into AI's response")

                Text("**Why MCP Matters:**")
                    .fontWeight(.semibold)
                    .padding(.top, 8)
                BulletPoint(text: "Extends AI beyond text generation to real actions")
                BulletPoint(text: "Standardized interface across different AI providers")
                BulletPoint(text: "Controlled, safe interaction with system resources")
                BulletPoint(text: "Transparent - you see what tools are being used")
            }

            HelpSection_Group(title: "How Tools Work in SAM") {
                Text("**When You Send a Message:**")
                    .fontWeight(.semibold)
                    .padding(.bottom, 8)

                BulletPoint(text: "1. SAM's system prompt lists all available tools")
                BulletPoint(text: "2. AI analyzes your request and determines if tools are needed")
                BulletPoint(text: "3. AI selects appropriate tools and specifies parameters")
                BulletPoint(text: "4. SAM executes tools and returns results to AI")
                BulletPoint(text: "5. AI incorporates results into its response to you")

                Text("**Example Flow:**")
                    .fontWeight(.semibold)
                    .padding(.top, 8)

                Text("You: \"What files are in my Documents folder?\"")
                    .font(.callout)
                    .italic()
                    .padding(.leading, 12)

                BulletPoint(text: "AI recognizes this needs file_operations tool")
                BulletPoint(text: "AI specifies operation: 'list_directory'")
                BulletPoint(text: "AI provides path: '~/Documents'")
                BulletPoint(text: "SAM executes tool, returns file list")
                BulletPoint(text: "AI formats response: \"Here are the files in your Documents folder...\"")
            }

            HelpSection_Group(title: "Tool Categories") {
                Text("**File & Document Operations:**")
                    .fontWeight(.semibold)
                BulletPoint(text: "file_operations - Read, write, create, delete files")
                BulletPoint(text: "document_operations - Import PDFs/DOCX, create documents")
                BulletPoint(text: "analyze_document - Extract info from files")

                Text("**Research & Information:**")
                    .fontWeight(.semibold)
                    .padding(.top, 8)
                BulletPoint(text: "web_operations - Search web, fetch URLs, research")
                BulletPoint(text: "memory_search - Search conversation memory")
                BulletPoint(text: "fetch_page - Get web page content")

                Text("**System & Development:**")
                    .fontWeight(.semibold)
                    .padding(.top, 8)
                BulletPoint(text: "execute_terminal_command - Run shell commands")
                BulletPoint(text: "calendar_operations - Access calendar events")
                BulletPoint(text: "task_planning - Structured task management")

                Text("**Creative:**")
                    .fontWeight(.semibold)
                    .padding(.top, 8)
                BulletPoint(text: "image_generation - Create AI art with Stable Diffusion")
                BulletPoint(text: "text_to_speech - Convert text to audio")

                Text("**Collaboration:**")
                    .fontWeight(.semibold)
                    .padding(.top, 8)
                BulletPoint(text: "user_collaboration - Ask for your confirmation")
                BulletPoint(text: "panel - Display formatted output")
            }

            HelpSection_Group(title: "Tool Selection & Usage") {
                Text("**How AI Chooses Tools:**")
                    .fontWeight(.semibold)
                    .padding(.bottom, 8)

                BulletPoint(text: "**Intent Recognition**: Understands what you want to accomplish")
                BulletPoint(text: "**Capability Matching**: Selects tools that can fulfill request")
                BulletPoint(text: "**Parameter Extraction**: Pulls required info from your message")
                BulletPoint(text: "**Fallback Logic**: Uses alternatives if primary tool unavailable")

                Text("**Smart Behaviors:**")
                    .fontWeight(.semibold)
                    .padding(.top, 8)
                BulletPoint(text: "Asks for clarification if parameters unclear")
                BulletPoint(text: "Combines multiple tools for complex tasks")
                BulletPoint(text: "Validates inputs before execution")
                BulletPoint(text: "Handles errors gracefully with helpful messages")
            }

            HelpSection_Group(title: "Safety & Control") {
                Text("**Built-in Guardrails:**")
                    .fontWeight(.semibold)
                    .padding(.bottom, 8)

                BulletPoint(text: "**Parameter Validation**: All inputs checked before execution")
                BulletPoint(text: "**Scope Limits**: Tools can't access arbitrary files or data")
                BulletPoint(text: "**No Wildcards**: Deletion requires explicit file paths")
                BulletPoint(text: "**System Prompts**: Encourage responsible tool usage")

                Text("**User Controls:**")
                    .fontWeight(.semibold)
                    .padding(.top, 8)
                BulletPoint(text: "**Tools Toggle**: Disable ALL tools via toolbar (⌘T)")
                BulletPoint(text: "**user_collaboration**: AI can ask your permission before actions")
                BulletPoint(text: "**Conversation Isolation**: Each chat has separate memory/context")
                BulletPoint(text: "**Transparency**: Tool usage visible in conversation")

                Text("**Best Practices:**")
                    .fontWeight(.semibold)
                    .padding(.top, 8)
                BulletPoint(text: "Toggle tools OFF for simple Q&A")
                BulletPoint(text: "Review AI's tool usage for sensitive operations")
                BulletPoint(text: "Use API Direct mode for zero tool access")
                BulletPoint(text: "Backup important files before bulk operations")
            }

            HelpSection_Group(title: "Advanced Usage") {
                Text("**Chaining Tools:**")
                    .fontWeight(.semibold)
                    .padding(.bottom, 8)

                Text("AI can combine multiple tools for complex tasks:")
                    .padding(.leading, 12)

                ExamplePrompt(prompt: "Research Python async/await, summarize findings, and save to a file")

                BulletPoint(text: "1. web_operations: Search for Python async/await documentation")
                BulletPoint(text: "2. fetch_page: Get content from top results")
                BulletPoint(text: "3. Analysis: Extract key concepts")
                BulletPoint(text: "4. file_operations: Save summary to file")

                Text("**Context Awareness:**")
                    .fontWeight(.semibold)
                    .padding(.top, 8)
                BulletPoint(text: "Tools remember previous results in conversation")
                BulletPoint(text: "Can reference earlier tool outputs")
                BulletPoint(text: "Build on previous work without re-execution")

                Text("**Error Handling:**")
                    .fontWeight(.semibold)
                    .padding(.top, 8)
                BulletPoint(text: "AI explains what went wrong in user-friendly terms")
                BulletPoint(text: "Suggests alternatives when tools fail")
                BulletPoint(text: "Can retry with adjusted parameters")
            }

            HelpSection_Group(title: "Future Extensions") {
                Text("MCP enables future capabilities:")
                    .padding(.bottom, 8)

                BulletPoint(text: "**Custom Tools**: Create your own tools for specific workflows")
                BulletPoint(text: "**Third-Party Integrations**: Connect to external services")
                BulletPoint(text: "**Workflow Automation**: Define multi-step processes")
                BulletPoint(text: "**Team Tools**: Share custom capabilities with colleagues")
            }
        }
    }
}

// MARK: - Performance & Optimization Content
struct PerformanceOptimizationContent: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Performance & Optimization")
                .font(.largeTitle)
                .fontWeight(.bold)

            Text("Get the best performance from SAM on your hardware.")
                .font(.title3)
                .foregroundColor(.secondary)

            Divider()

            HelpSection_Group(title: "Hardware Requirements") {
                Text("**Minimum Requirements:**")
                    .fontWeight(.semibold)
                BulletPoint(text: "macOS 13.0 (Ventura) or later")
                BulletPoint(text: "8GB RAM (16GB recommended)")
                BulletPoint(text: "10GB free disk space for app + models")
                BulletPoint(text: "Intel or Apple Silicon processor")

                Text("**Recommended for Best Experience:**")
                    .fontWeight(.semibold)
                    .padding(.top, 8)
                BulletPoint(text: "Apple Silicon (M1/M2/M3) for Metal acceleration")
                BulletPoint(text: "16GB+ RAM for local LLMs and image generation")
                BulletPoint(text: "50GB+ free space for multiple models")
                BulletPoint(text: "SSD for faster model loading")
            }

            HelpSection_Group(title: "Model Selection for Performance") {
                Text("**Cloud Providers (Fastest Response):**")
                    .fontWeight(.semibold)
                BulletPoint(text: "OpenAI GPT-4: Instant responses, no local processing")
                BulletPoint(text: "Anthropic Claude: Fast, reliable, excellent quality")
                BulletPoint(text: "GitHub Copilot: Optimized for code generation")
                BulletPoint(text: "Trade-off: Requires internet, sends data to third party")

                Text("**Local Models (Privacy, Offline):**")
                    .fontWeight(.semibold)
                    .padding(.top, 8)
                BulletPoint(text: "MLX Models: Apple Silicon optimized, excellent performance")
                BulletPoint(text: "GGUF Models: Cross-platform, good compatibility")
                BulletPoint(text: "Trade-off: Slower than cloud, requires RAM")

                Text("**Model Size Guidelines:**")
                    .fontWeight(.semibold)
                    .padding(.top, 8)
                BulletPoint(text: "7B models: Fast, suitable for 8-16GB RAM")
                BulletPoint(text: "13B models: Balanced, needs 16-32GB RAM")
                BulletPoint(text: "34B+ models: Best quality, requires 32GB+ RAM")
            }

            HelpSection_Group(title: "Memory Management") {
                Text("SAM manages memory automatically, but you can optimize:")
                    .padding(.bottom, 8)

                Text("**Document Import:**")
                    .fontWeight(.semibold)
                BulletPoint(text: "Import only relevant documents per conversation")
                BulletPoint(text: "Large PDFs chunked automatically")
                BulletPoint(text: "Delete unused conversation memory to free space")

                Text("**Conversation History:**")
                    .fontWeight(.semibold)
                    .padding(.top, 8)
                BulletPoint(text: "Long conversations use more memory")
                BulletPoint(text: "Start fresh conversation for new topics")
                BulletPoint(text: "Export and delete old conversations periodically")

                Text("**Model Loading:**")
                    .fontWeight(.semibold)
                    .padding(.top, 8)
                BulletPoint(text: "Models loaded on first use, cached in memory")
                BulletPoint(text: "Switching models may cause brief delay")
                BulletPoint(text: "Keep frequently-used models on fast SSD")
            }

            HelpSection_Group(title: "Stable Diffusion Performance") {
                Text("**CoreML vs Python:**")
                    .fontWeight(.semibold)
                    .padding(.bottom, 8)

                BulletPoint(text: "**CoreML**: 2-4 seconds per image on Apple Silicon")
                BulletPoint(text: "**Python**: 10-30 seconds per image depending on hardware")
                BulletPoint(text: "**Recommendation**: Always convert to CoreML on M1/M2/M3")

                Text("**Generation Speed Tips:**")
                    .fontWeight(.semibold)
                    .padding(.top, 8)
                BulletPoint(text: "Use SD 1.5 models for fastest results (512×512)")
                BulletPoint(text: "SDXL slower but higher quality (1024×1024)")
                BulletPoint(text: "Reduce steps (15-20) for faster preview, increase (30-50) for final")
                BulletPoint(text: "Close other memory-intensive apps during generation")
            }

            HelpSection_Group(title: "Batch Processing") {
                Text("Optimize for multiple operations:")
                    .padding(.bottom, 8)

                BulletPoint(text: "**Document Import**: Drag multiple files at once")
                BulletPoint(text: "**File Operations**: Process files in same conversation")
                BulletPoint(text: "**Image Generation**: Generate variations with same seed")
                BulletPoint(text: "**Conversation Export**: Export multiple as batch (future)")
            }

            HelpSection_Group(title: "Network & API Performance") {
                Text("**Cloud Provider Tips:**")
                    .fontWeight(.semibold)
                    .padding(.bottom, 8)

                BulletPoint(text: "Stable internet required for cloud models")
                BulletPoint(text: "Slow connection = delayed responses")
                BulletPoint(text: "Consider local models if internet unreliable")
                BulletPoint(text: "API Direct mode slightly faster (skips tool processing)")

                Text("**Rate Limits:**")
                    .fontWeight(.semibold)
                    .padding(.top, 8)
                BulletPoint(text: "Cloud providers have rate limits")
                BulletPoint(text: "Upgrade API tier for higher limits")
                BulletPoint(text: "Local models have no rate limits")
            }

            HelpSection_Group(title: "Storage Optimization") {
                Text("**Disk Space Usage:**")
                    .fontWeight(.semibold)
                    .padding(.bottom, 8)

                BulletPoint(text: "SAM app: ~200MB")
                BulletPoint(text: "Python environment: ~1.5GB")
                BulletPoint(text: "Local LLM models: 4-20GB each")
                BulletPoint(text: "SD models (CoreML): 2-6GB each")
                BulletPoint(text: "SD models (SafeTensors): 2-6GB each")
                BulletPoint(text: "Conversations & cache: Variable")

                Text("**Cleanup Recommendations:**")
                    .fontWeight(.semibold)
                    .padding(.top, 8)
                BulletPoint(text: "Delete unused models from Preferences")
                BulletPoint(text: "Clear old conversations periodically")
                BulletPoint(text: "Delete SafeTensors after CoreML conversion")
                BulletPoint(text: "Keep staging directory clean")
            }

            HelpSection_Group(title: "Activity Monitor") {
                Text("Monitor SAM's resource usage:")
                    .padding(.bottom, 8)

                BulletPoint(text: "Open macOS Activity Monitor")
                BulletPoint(text: "Search for \"SAM\" process")
                BulletPoint(text: "Check Memory, CPU, GPU usage")
                BulletPoint(text: "Normal: 200MB-2GB RAM depending on models")
                BulletPoint(text: "High CPU during generation/inference is normal")
            }

            HelpSection_Group(title: "Performance Troubleshooting") {
                TroubleshootingItem(
                    question: "SAM is slow or unresponsive",
                    solution: """
                    • Check available RAM (Activity Monitor)
                    • Close unused conversations
                    • Switch to smaller local model or cloud provider
                    • Restart SAM to clear caches
                    • Check for macOS updates
                    """
                )

                TroubleshootingItem(
                    question: "Image generation very slow",
                    solution: """
                    • Use CoreML instead of Python engine
                    • Switch to SD 1.5 instead of SDXL
                    • Reduce steps (20 instead of 50)
                    • Close other GPU-intensive apps
                    • Ensure model fully converted to CoreML
                    """
                )

                TroubleshootingItem(
                    question: "Running out of disk space",
                    solution: """
                    • Delete unused models (Preferences → Local Models)
                    • Delete SafeTensors after CoreML conversion
                    • Clear conversation history (File → Clear History)
                    • Empty ~/Library/Caches/sam/staging/
                    • Check ~/Library/Caches/sam/ for large files
                    """
                )
            }
        }
    }
}

// MARK: - Getting Started Examples Content
struct GettingStartedExamplesContent: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Getting Started Examples")
                .font(.largeTitle)
                .fontWeight(.bold)

            Text("Real-world examples to help you get the most out of SAM.")
                .font(.title3)
                .foregroundColor(.secondary)

            Divider()

            HelpSection_Group(title: "Example 1: Code Generation & Debugging") {
                Text("**Scenario**: You need to write a Swift function and debug an error.")
                    .fontWeight(.semibold)
                    .padding(.bottom, 8)

                Text("**Step 1: Generate Code**")
                    .font(.callout)
                    .fontWeight(.medium)
                ExamplePrompt(prompt: "Write a Swift function that reads a JSON file and parses it into a struct")

                Text("**Step 2: Save to File**")
                    .font(.callout)
                    .fontWeight(.medium)
                    .padding(.top, 8)
                ExamplePrompt(prompt: "Save that code to ~/Projects/JSONParser.swift")

                Text("**Step 3: Debug**")
                    .font(.callout)
                    .fontWeight(.medium)
                    .padding(.top, 8)
                ExamplePrompt(prompt: "I'm getting error 'Type Foo does not conform to Decodable'. Here's my struct: [paste code]")

                Text("**What SAM Does:**")
                    .fontWeight(.semibold)
                    .padding(.top, 8)
                BulletPoint(text: "Generates complete, working code")
                BulletPoint(text: "Uses file_operations tool to save file")
                BulletPoint(text: "Analyzes error and provides fix")
                BulletPoint(text: "Explains the issue in plain language")
            }

            HelpSection_Group(title: "Example 2: Research & Documentation") {
                Text("**Scenario**: Research a topic and create a formatted document.")
                    .fontWeight(.semibold)
                    .padding(.bottom, 8)

                Text("**Step 1: Research**")
                    .font(.callout)
                    .fontWeight(.medium)
                ExamplePrompt(prompt: "Research the latest features in Swift 6 and summarize the key changes")

                Text("**Step 2: Expand**")
                    .font(.callout)
                    .fontWeight(.medium)
                    .padding(.top, 8)
                ExamplePrompt(prompt: "Give me more details about data isolation and actor models")

                Text("**Step 3: Create Document**")
                    .font(.callout)
                    .fontWeight(.medium)
                    .padding(.top, 8)
                ExamplePrompt(prompt: "Create a professional PDF document with this research, titled 'Swift 6 Features Overview'")

                Text("**What SAM Does:**")
                    .fontWeight(.semibold)
                    .padding(.top, 8)
                BulletPoint(text: "Uses web_operations to search for information")
                BulletPoint(text: "Fetches and analyzes relevant sources")
                BulletPoint(text: "Synthesizes findings into coherent summary")
                BulletPoint(text: "Creates formatted PDF with document_operations")
            }

            HelpSection_Group(title: "Example 3: Document Analysis") {
                Text("**Scenario**: Analyze a PDF and extract specific information.")
                    .fontWeight(.semibold)
                    .padding(.bottom, 8)

                Text("**Step 1: Import**")
                    .font(.callout)
                    .fontWeight(.medium)
                ExamplePrompt(prompt: "Import this PDF: file:///Users/me/Documents/Annual_Report_2024.pdf")

                Text("**Step 2: Analyze**")
                    .font(.callout)
                    .fontWeight(.medium)
                    .padding(.top, 8)
                ExamplePrompt(prompt: "What were the key financial metrics in Q4?")

                Text("**Step 3: Extract Data**")
                    .font(.callout)
                    .fontWeight(.medium)
                    .padding(.top, 8)
                ExamplePrompt(prompt: "Create a table comparing Q3 vs Q4 revenue and expenses")

                Text("**Step 4: Export**")
                    .font(.callout)
                    .fontWeight(.medium)
                    .padding(.top, 8)
                ExamplePrompt(prompt: "Save that table as a DOCX file")

                Text("**What SAM Does:**")
                    .fontWeight(.semibold)
                    .padding(.top, 8)
                BulletPoint(text: "Imports PDF with document_operations")
                BulletPoint(text: "Stores content in conversation memory")
                BulletPoint(text: "Searches memory for specific information")
                BulletPoint(text: "Structures data as requested")
                BulletPoint(text: "Creates formatted output document")
            }

            HelpSection_Group(title: "Example 4: Creative Image Generation") {
                Text("**Scenario**: Create custom artwork for a project.")
                    .fontWeight(.semibold)
                    .padding(.bottom, 8)

                Text("**Step 1: Install Model**")
                    .font(.callout)
                    .fontWeight(.medium)
                BulletPoint(text: "Preferences → Image Generation → HuggingFace")
                BulletPoint(text: "Search for \"realistic-vision\"")
                BulletPoint(text: "Download and convert to CoreML")

                Text("**Step 2: Generate**")
                    .font(.callout)
                    .fontWeight(.medium)
                    .padding(.top, 8)
                ExamplePrompt(prompt: "Generate an image of a serene mountain landscape at sunset, 8k quality, detailed")

                Text("**Step 3: Refine**")
                    .font(.callout)
                    .fontWeight(.medium)
                    .padding(.top, 8)
                ExamplePrompt(prompt: "Make it more vibrant with warmer colors")

                Text("**Step 4: Variations**")
                    .font(.callout)
                    .fontWeight(.medium)
                    .padding(.top, 8)
                ExamplePrompt(prompt: "Create 3 variations with different times of day")

                Text("**What SAM Does:**")
                    .fontWeight(.semibold)
                    .padding(.top, 8)
                BulletPoint(text: "Uses image_generation tool")
                BulletPoint(text: "Selects appropriate model and engine")
                BulletPoint(text: "Adjusts parameters based on requests")
                BulletPoint(text: "Generates variations with different seeds")
            }

            HelpSection_Group(title: "Example 5: Automated Workflow") {
                Text("**Scenario**: Automate a multi-step process.")
                    .fontWeight(.semibold)
                    .padding(.bottom, 8)

                Text("**Complex Request:**")
                    .font(.callout)
                    .fontWeight(.medium)
                ExamplePrompt(prompt: """
                Research Python best practices for async/await, \
                summarize the top 5 patterns, \
                create code examples for each, \
                and save everything to a markdown file
                """)

                Text("**What SAM Does (Automatically):**")
                    .fontWeight(.semibold)
                    .padding(.top, 8)
                BulletPoint(text: "1. web_operations: Research async/await patterns")
                BulletPoint(text: "2. fetch_page: Get detailed documentation")
                BulletPoint(text: "3. Analysis: Identify top 5 patterns")
                BulletPoint(text: "4. Code Generation: Create examples for each")
                BulletPoint(text: "5. file_operations: Save to markdown file")
                BulletPoint(text: "6. Confirmation: Shows saved file path")

                Text("**Key Point**: You make one request, SAM executes the entire workflow.")
                    .font(.callout)
                    .foregroundColor(.secondary)
                    .italic()
                    .padding(.top, 8)
            }

            HelpSection_Group(title: "Example 6: Using Mini-Prompts for Context") {
                Text("**Scenario**: You want SAM to remember your project context.")
                    .fontWeight(.semibold)
                    .padding(.bottom, 8)

                Text("**Step 1: Create Mini-Prompt**")
                    .font(.callout)
                    .fontWeight(.medium)
                BulletPoint(text: "Click Mini-Prompts button in toolbar")
                BulletPoint(text: "Create new: \"Current Project Context\"")
                BulletPoint(text: "Content: \"Working on SwiftUI macOS app called TaskMaster. Using Swift 6, targeting macOS 14+.\"")
                BulletPoint(text: "Enable for this conversation")

                Text("**Step 2: Make Requests**")
                    .font(.callout)
                    .fontWeight(.medium)
                    .padding(.top, 8)
                ExamplePrompt(prompt: "How should I structure my view models?")

                Text("**What Happens:**")
                    .fontWeight(.semibold)
                    .padding(.top, 8)
                BulletPoint(text: "SAM automatically includes project context")
                BulletPoint(text: "Responses tailored to SwiftUI + Swift 6")
                BulletPoint(text: "No need to repeat project details")
                BulletPoint(text: "Context persists across messages")
            }

            HelpSection_Group(title: "Example 7: Calendar Integration") {
                Text("**Scenario**: Manage your calendar through conversation.")
                    .fontWeight(.semibold)
                    .padding(.bottom, 8)

                Text("**Check Schedule:**")
                    .font(.callout)
                    .fontWeight(.medium)
                ExamplePrompt(prompt: "What meetings do I have tomorrow?")

                Text("**Find Time:**")
                    .font(.callout)
                    .fontWeight(.medium)
                    .padding(.top, 8)
                ExamplePrompt(prompt: "When am I free this week for a 2-hour block?")

                Text("**Create Event:**")
                    .font(.callout)
                    .fontWeight(.medium)
                    .padding(.top, 8)
                ExamplePrompt(prompt: "Schedule 'Team Planning' for Thursday 2pm-4pm")

                Text("**What SAM Does:**")
                    .fontWeight(.semibold)
                    .padding(.top, 8)
                BulletPoint(text: "Uses calendar_operations tool")
                BulletPoint(text: "Reads your macOS Calendar data")
                BulletPoint(text: "Finds free slots intelligently")
                BulletPoint(text: "Creates events with proper formatting")
            }

            HelpSection_Group(title: "Pro Tips") {
                BulletPoint(text: "**Be Specific**: More detail = better results")
                BulletPoint(text: "**Iterate**: Refine outputs through conversation")
                BulletPoint(text: "**Use Context**: Enable mini-prompts for consistent context")
                BulletPoint(text: "**Combine Tools**: Let SAM chain operations automatically")
                BulletPoint(text: "**Save Work**: Export important conversations")
                BulletPoint(text: "**Experiment**: Try different models and prompts")
            }
        }
    }
}

// MARK: - Helper Views

struct ShortcutRow: View {
    let keys: String
    let description: String

    var body: some View {
        HStack(spacing: 12) {
            Text(keys)
                .font(.system(.body, design: .monospaced))
                .fontWeight(.semibold)
                .foregroundColor(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Color.accentColor)
                .cornerRadius(6)
                .frame(minWidth: 80, alignment: .leading)

            Text(description)
                .font(.body)
                .foregroundColor(.secondary)
        }
        .padding(.vertical, 4)
    }
}

// MARK: - UI Setup
#Preview {
    HelpView()
}
