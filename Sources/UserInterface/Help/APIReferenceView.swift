// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import SwiftUI

// MARK: - UI Setup
struct APIReferenceView: View {
    @State private var selectedSection: APISection = .overview
    @State private var searchText: String = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            /// Header with close button.
            HStack {
                Text("SAM API Reference")
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

            /// Tab-based navigation.
            TabView(selection: $selectedSection) {
                ForEach(APISection.allCases) { section in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 20) {
                            section.content
                        }
                        .padding()
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .tabItem {
                        Label(section.title, systemImage: section.icon)
                    }
                    .tag(section)
                }
            }
        }
        .frame(minWidth: 1000, minHeight: 700)
    }
}

// MARK: - API Sections Enum
enum APISection: String, CaseIterable, Identifiable {
    case overview
    case chatCompletions
    case advancedEndpoints
    case models
    case conversations
    case mcpTools
    case documentTools
    case memoryTools
    case webTools
    case fileTools
    case examples

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: return "Overview"
        case .chatCompletions: return "Chat Completions"
        case .advancedEndpoints: return "Advanced Endpoints"
        case .models: return "Models API"
        case .conversations: return "Conversations API"
        case .mcpTools: return "MCP Tools"
        case .documentTools: return "Document Tools"
        case .memoryTools: return "Memory & Search"
        case .webTools: return "Web Research"
        case .fileTools: return "File Operations"
        case .examples: return "Examples"
        }
    }

    var icon: String {
        switch self {
        case .overview: return "book.fill"
        case .chatCompletions: return "message.fill"
        case .advancedEndpoints: return "gearshape.2.fill"
        case .models: return "cpu"
        case .conversations: return "bubble.left.and.bubble.right.fill"
        case .mcpTools: return "hammer.fill"
        case .documentTools: return "doc.text.fill"
        case .memoryTools: return "brain"
        case .webTools: return "globe"
        case .fileTools: return "folder.fill"
        case .examples: return "sparkles"
        }
    }

    @ViewBuilder
    var content: some View {
        switch self {
        case .overview:
            OverviewContent()

        case .chatCompletions:
            ChatCompletionsContent()

        case .advancedEndpoints:
            AdvancedEndpointsContent()

        case .models:
            ModelsAPIContent()

        case .conversations:
            ConversationsAPIContent()

        case .mcpTools:
            // MCP Tools documentation planned for future release
            Text("MCP Tools documentation coming soon")
                .foregroundColor(.secondary)

        case .documentTools:
            DocumentToolsContent()

        case .memoryTools:
            MemoryToolsContent()

        case .webTools:
            WebToolsContent()

        case .fileTools:
            FileToolsContent()

        case .examples:
            ExamplesContent()
        }
    }
}

// MARK: - UI Setup
struct OverviewContent: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("SAM API Overview")
                .font(.title2)
                .fontWeight(.bold)

            Text("SAM provides an OpenAI-compatible HTTP API for programmatic access to its conversational AI capabilities.")
                .foregroundColor(.secondary)

            SectionHeader(title: "Base URL")
            CodeBlock(code: "http://localhost:8080")
            Text("The default server port is 8080. You can change this in Settings → API Server.")
                .font(.caption)
                .foregroundColor(.secondary)

            SectionHeader(title: "Authentication")
            Text("SAM currently does not require authentication for local API access. All endpoints are accessible without an API key.")

            SectionHeader(title: "API Compatibility")
            VStack(alignment: .leading, spacing: 8) {
                FeatureRow(icon: "checkmark.circle.fill", text: "OpenAI Chat Completions API compatible", color: .green)
                FeatureRow(icon: "checkmark.circle.fill", text: "Streaming responses with Server-Sent Events", color: .green)
                FeatureRow(icon: "checkmark.circle.fill", text: "MCP (Model Context Protocol) tool execution", color: .green)
                FeatureRow(icon: "checkmark.circle.fill", text: "Multiple AI provider support (OpenAI, Anthropic, Google Gemini, GitHub Copilot, local models)", color: .green)
            }

            SectionHeader(title: "API Endpoints")

            EndpointCard(
                method: "POST",
                path: "/v1/chat/completions",
                description: "OpenAI-compatible chat completions with streaming support"
            )

            EndpointCard(
                method: "POST",
                path: "/api/chat/completions",
                description: "Alternative endpoint for SAM-specific features"
            )

            EndpointCard(
                method: "GET",
                path: "/v1/models",
                description: "List available AI models from all providers"
            )

            EndpointCard(
                method: "GET",
                path: "/health",
                description: "Health check endpoint"
            )

            EndpointCard(
                method: "POST",
                path: "/api/chat/autonomous",
                description: "Multi-step autonomous agent orchestration"
            )

            EndpointCard(
                method: "POST",
                path: "/api/chat/tool-response",
                description: "Submit user response for interactive tool execution"
            )

            EndpointCard(
                method: "GET",
                path: "/api/tool_result",
                description: "Retrieve large tool outputs by result ID"
            )

            SectionHeader(title: "Response Formats")
            Text("All responses follow standard HTTP status codes:")
            VStack(alignment: .leading, spacing: 4) {
                StatusCodeRow(code: "200", description: "Success")
                StatusCodeRow(code: "400", description: "Bad Request - Invalid parameters")
                StatusCodeRow(code: "500", description: "Internal Server Error")
            }
            .padding(.leading)
        }
    }
}

// MARK: - Chat Completions Content
struct ChatCompletionsContent: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Chat Completions API")
                .font(.title2)
                .fontWeight(.bold)

            Text("Send messages to AI models and receive responses. Supports both streaming and non-streaming modes.")
                .foregroundColor(.secondary)

            SectionHeader(title: "Endpoint")
            CodeBlock(code: "POST /v1/chat/completions\nPOST /api/chat/completions")

            SectionHeader(title: "Request Body")

            Text("**Standard OpenAI Parameters:**")
                .fontWeight(.semibold)

            ParameterRow(name: "model", type: "string", required: true, description: "AI model identifier (e.g., 'gpt-4', 'claude-3-5-sonnet', 'copilot')")
            ParameterRow(name: "messages", type: "array", required: true, description: "Array of message objects with 'role' and 'content' fields")
            ParameterRow(name: "stream", type: "boolean", required: false, description: "Enable streaming responses (default: true)")
            ParameterRow(name: "temperature", type: "number", required: false, description: "Sampling temperature 0.0-2.0 (default: 1.0)")
            ParameterRow(name: "max_tokens", type: "number", required: false, description: "Maximum tokens in response")
            ParameterRow(name: "top_p", type: "number", required: false, description: "Nucleus sampling parameter")
            ParameterRow(name: "repetition_penalty", type: "number", required: false, description: "Repetition penalty for local models")
            ParameterRow(name: "tools", type: "array", required: false, description: "Array of tool definitions for function calling")

            Text("**SAM-Specific Parameters:**")
                .fontWeight(.semibold)
                .padding(.top, 8)

            ParameterRow(name: "conversation_id", type: "string", required: false, description: "UUID of existing conversation (maps to ConversationModel.id)")
            ParameterRow(name: "session_id", type: "string", required: false, description: "Alternative session identifier")
            ParameterRow(name: "context_id", type: "string", required: false, description: "Shared memory context identifier")
            ParameterRow(name: "topic", type: "string", required: false, description: "Topic folder ID for conversation organization")
            ParameterRow(name: "mini_prompts", type: "array", required: false, description: "Array of mini-prompt names to enable")
            ParameterRow(name: "sam_config", type: "object", required: false, description: "Advanced SAM configuration (see SAM Config below)")

            SectionHeader(title: "SAM Config Object")
            Text("Optional configuration object for advanced features:")
                .foregroundColor(.secondary)
                .font(.caption)

            ParameterRow(name: "systemPromptId", type: "string", required: false, description: "System prompt UUID or name ('sam_default', 'autonomous_editor')")
            ParameterRow(name: "maxIterations", type: "number", required: false, description: "Maximum workflow iterations (default: 300)")
            ParameterRow(name: "workingDirectory", type: "string", required: false, description: "Working directory for file operations")
            ParameterRow(name: "enableReasoning", type: "boolean", required: false, description: "Enable extended reasoning for complex tasks")
            ParameterRow(name: "enableWorkflowMode", type: "boolean", required: false, description: "Enable autonomous workflow orchestration")

            SectionHeader(title: "Request Example (Non-Streaming)")
            CodeBlock(code: """
            curl -X POST http:
              -H "Content-Type: application/json" \\
              -d '{
                "model": "gpt-4",
                "messages": [
                  {"role": "user", "content": "What is the weather like today?"}
                ],
                "temperature": 0.7
              }'
            """)

            SectionHeader(title: "Response Example")
            CodeBlock(code: """
            {
              "id": "chatcmpl-123",
              "object": "chat.completion",
              "created": 1677652288,
              "model": "gpt-4",
              "choices": [{
                "index": 0,
                "message": {
                  "role": "assistant",
                  "content": "I don't have access to real-time weather data..."
                },
                "finish_reason": "stop"
              }],
              "usage": {
                "prompt_tokens": 15,
                "completion_tokens": 28,
                "total_tokens": 43
              },
              "sam_metadata": {
                "provider": {
                  "type": "openai",
                  "name": "OpenAI",
                  "is_local": false,
                  "base_url": "api.openai.com"
                },
                "model_info": {
                  "context_window": 8192,
                  "max_output_tokens": 8192,
                  "supports_tools": true,
                  "supports_vision": false,
                  "supports_streaming": true,
                  "family": "gpt-4"
                },
                "workflow": {
                  "iterations": 1,
                  "max_iterations": 300,
                  "tool_call_count": 0,
                  "tools_used": [],
                  "duration_seconds": 2.5,
                  "completion_reason": "workflow_complete",
                  "had_errors": false
                },
                "cost_estimate": {
                  "estimated_cost_usd": 0.0012,
                  "prompt_cost_per_1k": 0.03,
                  "completion_cost_per_1k": 0.06,
                  "currency": "USD",
                  "note": "Estimated based on published pricing"
                }
              }
            }
            """)

            SectionHeader(title: "SAM Metadata Fields")
            Text("SAM enhances responses with detailed metadata:")
                .foregroundColor(.secondary)

            VStack(alignment: .leading, spacing: 8) {
                BulletPoint(text: "**provider**: Type, name, local/remote, base URL")
                BulletPoint(text: "**model_info**: Context window, output limits, capabilities")
                BulletPoint(text: "**workflow**: Iterations, tool usage, duration, errors")
                BulletPoint(text: "**cost_estimate**: USD cost estimate with per-1K rates")
            }
            .font(.caption)

            SectionHeader(title: "Streaming Example")
            CodeBlock(code: """
            curl -X POST http:
              -H "Content-Type: application/json" \\
              -d '{
                "model": "gpt-4",
                "messages": [
                  {"role": "user", "content": "Tell me a story"}
                ],
                "stream": true
              }'
            """)

            Text("Streaming responses use Server-Sent Events (SSE) format:")
                .font(.caption)
                .foregroundColor(.secondary)

            CodeBlock(code: """
            data: {"id":"chatcmpl-123","choices":[{"delta":{"content":"Once"}}]}
            data: {"id":"chatcmpl-123","choices":[{"delta":{"content":" upon"}}]}
            data: {"id":"chatcmpl-123","choices":[{"delta":{"content":" a"}}]}
            data: [DONE]
            """)

            SectionHeader(title: "Tool Calling")
            Text("SAM automatically injects available MCP tools into requests. The AI can choose to call tools, and SAM executes them automatically.")

            CodeBlock(code: """
            {
              "model": "gpt-4",
              "messages": [
                {"role": "user", "content": "Search my memory for documents about AI"}
              ]
            }
            """)

            Text("The AI will automatically use the memory_search tool if needed.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }
}

// MARK: - Advanced Endpoints Content
struct AdvancedEndpointsContent: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Advanced Endpoints")
                .font(.title2)
                .fontWeight(.bold)

            Text("Specialized endpoints for autonomous workflows, tool interaction, and agent introspection.")
                .foregroundColor(.secondary)

            SectionHeader(title: "Autonomous Workflow")
            CodeBlock(code: "POST /api/chat/autonomous")

            Text("Enables multi-step autonomous agent orchestration. The agent can execute multiple iterations with tool calls automatically until task completion.")
                .foregroundColor(.secondary)

            ParameterRow(name: "model", type: "string", required: true, description: "AI model identifier")
            ParameterRow(name: "messages", type: "array", required: true, description: "Initial conversation messages")
            ParameterRow(name: "max_iterations", type: "number", required: false, description: "Maximum workflow iterations (default: 300)")
            ParameterRow(name: "conversationId", type: "string", required: false, description: "Existing conversation context")

            CodeBlock(code: """
            curl -X POST http://localhost:8080/api/chat/autonomous \\
              -H "Content-Type: application/json" \\
              -d '{
                "model": "gpt-4",
                "messages": [
                  {"role": "user", "content": "Research Swift 6 concurrency and create a summary document"}
                ],
                "max_iterations": 50
              }'
            """)

            Text("The agent will autonomously research, plan, and create the document with multiple tool calls.")
                .font(.caption)
                .foregroundColor(.secondary)

            SectionHeader(title: "Tool Response Submission")
            CodeBlock(code: "POST /api/chat/tool-response")

            Text("Submit user response when a tool requires interactive input (e.g., user_collaboration tool).")
                .foregroundColor(.secondary)

            ParameterRow(name: "conversationId", type: "string", required: true, description: "Conversation UUID")
            ParameterRow(name: "toolCallId", type: "string", required: true, description: "Tool call identifier waiting for response")
            ParameterRow(name: "userInput", type: "string", required: true, description: "User's response text")

            CodeBlock(code: """
            curl -X POST http://localhost:8080/api/chat/tool-response \\
              -H "Content-Type: application/json" \\
              -d '{
                "conversationId": "abc-123-def-456",
                "toolCallId": "call_abc123",
                "userInput": "Approve"
              }'
            """)

            SectionHeader(title: "Tool Result Retrieval")
            CodeBlock(code: "GET /api/tool_result")

            Text("Retrieve large tool outputs that were persisted instead of included inline. Supports pagination for very large results.")
                .foregroundColor(.secondary)

            ParameterRow(name: "conversationId", type: "string", required: true, description: "Conversation UUID (query parameter)")
            ParameterRow(name: "toolCallId", type: "string", required: true, description: "Tool call identifier (query parameter)")
            ParameterRow(name: "offset", type: "number", required: false, description: "Character offset to start reading from (default: 0)")
            ParameterRow(name: "length", type: "number", required: false, description: "Characters to read (default: 8192, max: 32768)")

            CodeBlock(code: """
            curl "http://localhost:8080/api/tool_result?conversationId=abc-123&toolCallId=call_xyz&offset=0&length=8192"
            """)

            SectionHeader(title: "Prompt Discovery")
            Text("Endpoints for agent awareness and configuration discovery:")

            EndpointCard(method: "GET", path: "/api/prompts/system", description: "List available system prompts")
            EndpointCard(method: "GET", path: "/api/prompts/mini", description: "List mini-prompt configurations")
            EndpointCard(method: "GET", path: "/api/topics", description: "List shared topics")

            SectionHeader(title: "Debug Endpoints")
            Text("Development and debugging tools:")

            EndpointCard(method: "GET", path: "/debug/mcp/tools", description: "List all MCP tools with schemas")
            EndpointCard(method: "POST", path: "/debug/mcp/execute", description: "Execute MCP tool directly")
            EndpointCard(method: "GET", path: "/debug/tools/available", description: "Tool registry status")

            Text("Debug endpoints are for development only and may change without notice.")
                .font(.caption)
                .foregroundColor(.secondary)
                .italic()
        }
    }
}

// MARK: - Models API Content
struct ModelsAPIContent: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Models API")
                .font(.title2)
                .fontWeight(.bold)

            Text("List and manage available AI models from all configured providers.")
                .foregroundColor(.secondary)

            SectionHeader(title: "List Models")
            CodeBlock(code: "GET /v1/models")

            Text("Returns all models from enabled providers (OpenAI, Anthropic, GitHub Copilot, local MLX models).")

            SectionHeader(title: "Request Example")
            CodeBlock(code: """
            curl http:
            """)

            SectionHeader(title: "Response Example")
            CodeBlock(code: """
            {
              "object": "list",
              "data": [
                {
                  "id": "gpt-4",
                  "object": "model",
                  "created": 1677649963,
                  "owned_by": "openai"
                },
                {
                  "id": "claude-3-5-sonnet-20241022",
                  "object": "model",
                  "created": 1677649963,
                  "owned_by": "anthropic"
                },
                {
                  "id": "copilot",
                  "object": "model",
                  "created": 1677649963,
                  "owned_by": "github"
                }
              ]
            }
            """)

            SectionHeader(title: "Download Local Models")
            CodeBlock(code: "POST /api/models/download")

            Text("Download GGUF or MLX models from HuggingFace.")
                .foregroundColor(.secondary)

            ParameterRow(name: "modelUrl", type: "string", required: true, description: "HuggingFace model URL or identifier")

            CodeBlock(code: """
            curl -X POST http://localhost:8080/api/models/download \\
              -H "Content-Type: application/json" \\
              -d '{
                "modelUrl": "https://huggingface.co/mlx-community/Qwen2.5-3B-Instruct-4bit"
              }'
            """)

            SectionHeader(title: "Check Download Status")
            CodeBlock(code: "GET /api/models/download/{downloadId}/status")

            Text("Monitor download progress and completion status.")
                .foregroundColor(.secondary)

            CodeBlock(code: """
            curl http://localhost:8080/api/models/download/abc-123/status
            """)

            SectionHeader(title: "Cancel Download")
            CodeBlock(code: "DELETE /api/models/download/{downloadId}")

            Text("Cancel an in-progress model download.")
                .foregroundColor(.secondary)

            CodeBlock(code: """
            curl -X DELETE http://localhost:8080/api/models/download/abc-123
            """)

            SectionHeader(title: "List Installed Models")
            CodeBlock(code: "GET /api/models")

            Text("Returns locally installed GGUF, MLX, and Stable Diffusion models in ~/Library/Caches/sam/models/")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }
}

// MARK: - Conversations API Content
struct ConversationsAPIContent: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Conversations API")
                .font(.title2)
                .fontWeight(.bold)

            Text("Manage conversation history and retrieve past interactions.")
                .foregroundColor(.secondary)

            SectionHeader(title: "List Conversations")
            CodeBlock(code: "GET /v1/conversations")

            Text("Returns all conversations with their metadata.")

            SectionHeader(title: "Request Example")
            CodeBlock(code: """
            curl http:
            """)

            SectionHeader(title: "Get Conversation")
            CodeBlock(code: "GET /v1/conversations/{conversationId}")

            Text("Retrieve complete conversation history including all messages.")

            SectionHeader(title: "Request Example")
            CodeBlock(code: """
            curl http:
            """)

            SectionHeader(title: "Conversation-Scoped Memory")
            Text("Each conversation has isolated memory. Documents imported in conversation A cannot be accessed in conversation B.")

            CodeBlock(code: """
            # Import document in conversation A
            curl -X POST http:
              -H "Content-Type: application/json" \\
              -d '{
                "model": "gpt-4",
                "conversationId": "conversation-a",
                "messages": [{
                  "role": "user",
                  "content": "Import this document and remember it"
                }]
              }'

            # Document only accessible in conversation A, not B
            """)
        }
    }
}

// MARK: - Document Tools Content
struct DocumentToolsContent: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Document Tools")
                .font(.title2)
                .fontWeight(.bold)

            Text("Tools for document import, creation, and management.")
                .foregroundColor(.secondary)

            ToolCard(
                name: "document_operations",
                description: "Unified tool for document import, creation, and information retrieval"
            )

            SectionHeader(title: "Import Documents")
            ParameterRow(name: "operation", type: "string", required: true, description: "'document_import'")
            ParameterRow(name: "path", type: "string", required: true, description: "File path or URL to document")
            ParameterRow(name: "tags", type: "array", required: false, description: "Tags for organizing imported content")

            CodeBlock(code: """
            {
              "operation": "document_import",
              "path": "/path/to/document.pdf"
            }
            """)

            SectionHeader(title: "Create Documents")
            ParameterRow(name: "operation", type: "string", required: true, description: "'document_create'")
            ParameterRow(name: "content", type: "string", required: true, description: "Document content (supports markdown)")
            ParameterRow(name: "format", type: "string", required: true, description: "'pdf', 'docx', 'markdown', 'txt'")
            ParameterRow(name: "output_path", type: "string", required: false, description: "Custom output directory")

            CodeBlock(code: """
            {
              "operation": "document_create",
              "content": "# Report\\n\\nThis is my report content",
              "format": "pdf"
            }
            """)

            SectionHeader(title: "Supported Formats")
            VStack(alignment: .leading, spacing: 8) {
                FormatRow(format: "PDF", icon: "doc.text.fill", features: ["Formatted markdown rendering", "Tables, lists, code blocks", "Professional styling"])
                FormatRow(format: "DOCX", icon: "doc.fill", features: ["Microsoft Word format", "Heading styles", "Lists and tables"])
                FormatRow(format: "Markdown", icon: "text.alignleft", features: ["YAML frontmatter", "Metadata support", "Plain text format"])
            }
        }
    }
}

// MARK: - Memory Tools Content
struct MemoryToolsContent: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Memory & Search Tools")
                .font(.title2)
                .fontWeight(.bold)

            Text("Semantic memory and search capabilities using Vector RAG.")
                .foregroundColor(.secondary)

            ToolCard(
                name: "memory_search",
                description: "Search conversation memory and imported documents"
            )

            ParameterRow(name: "operation", type: "string", required: true, description: "'search'")
            ParameterRow(name: "query", type: "string", required: true, description: "Search query text")
            ParameterRow(name: "similarity_threshold", type: "number", required: false, description: "Minimum similarity score 0.0-1.0 (default: 0.3)")
            ParameterRow(name: "max_results", type: "number", required: false, description: "Maximum results to return (default: 10)")

            CodeBlock(code: """
            {
              "operation": "search",
              "query": "machine learning algorithms",
              "similarity_threshold": 0.5,
              "max_results": 5
            }
            """)

            SectionHeader(title: "Semantic Search")
            Text("Memory search uses embeddings to find semantically similar content, not just keyword matching.")

            SectionHeader(title: "File Search Tools")

            ToolCard(name: "file_search", description: "Search for files by name/pattern using glob patterns")
            ToolCard(name: "semantic_search", description: "Semantic code search across workspace")
            ToolCard(name: "grep_search", description: "Fast text search with regex support")
        }
    }
}

// MARK: - Web Tools Content
struct WebToolsContent: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Web Research Tools")
                .font(.title2)
                .fontWeight(.bold)

            Text("Tools for web scraping, search, and research.")
                .foregroundColor(.secondary)

            ToolCard(
                name: "web_research",
                description: "Comprehensive web research with search and content extraction"
            )

            ParameterRow(name: "query", type: "string", required: true, description: "Research query or topic")
            ParameterRow(name: "max_results", type: "number", required: false, description: "Maximum search results (default: 5)")

            ToolCard(
                name: "web_scraping",
                description: "Extract content from specific URLs"
            )

            ParameterRow(name: "url", type: "string", required: true, description: "URL to scrape")
            ParameterRow(name: "selector", type: "string", required: false, description: "CSS selector for specific content")

            ToolCard(
                name: "fetch_webpage",
                description: "Fetch and parse webpage content"
            )

            SectionHeader(title: "Example: Research Topic")
            CodeBlock(code: """
            {
              "query": "latest developments in quantum computing 2024",
              "max_results": 10
            }
            """)
        }
    }
}

// MARK: - File Tools Content
struct FileToolsContent: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("File Operation Tools")
                .font(.title2)
                .fontWeight(.bold)

            Text("Tools for file and directory management.")
                .foregroundColor(.secondary)

            SectionHeader(title: "File Reading & Writing")
            ToolCard(name: "read_file", description: "Read file contents with optional line range")
            ToolCard(name: "create_file", description: "Create new file with content")
            ToolCard(name: "replace_string_in_file", description: "Find and replace text in files")
            ToolCard(name: "delete_file", description: "Delete files or directories")
            ToolCard(name: "rename_file", description: "Rename or move files")

            SectionHeader(title: "Directory Operations")
            ToolCard(name: "list_dir", description: "List directory contents")
            ToolCard(name: "create_directory", description: "Create new directory")

            SectionHeader(title: "Code Analysis")
            ToolCard(name: "list_code_usages", description: "Find references to functions/classes")
            ToolCard(name: "get_errors", description: "Get compile/lint errors")

            SectionHeader(title: "Git Operations")
            ToolCard(name: "git_commit", description: "Stage and commit changes")
            ToolCard(name: "get_changed_files", description: "List modified files in Git")

            SectionHeader(title: "Terminal")
            ToolCard(name: "run_in_terminal", description: "Execute shell commands")
            ToolCard(name: "get_terminal_output", description: "Retrieve terminal output")
        }
    }
}

// MARK: - Examples Content
struct ExamplesContent: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Usage Examples")
                .font(.title2)
                .fontWeight(.bold)

            SectionHeader(title: "Example 1: Simple Chat")
            CodeBlock(code: """
            curl -X POST http:
              -H "Content-Type: application/json" \\
              -d '{
                "model": "gpt-4",
                "messages": [
                  {"role": "user", "content": "Hello, SAM!"}
                ]
              }'
            """)

            SectionHeader(title: "Example 2: Document Import & Search")
            CodeBlock(code: """
            # Import document
            curl -X POST http:
              -H "Content-Type: application/json" \\
              -d '{
                "model": "gpt-4",
                "conversationId": "my-conversation",
                "messages": [{
                  "role": "user",
                  "content": "Import the file report.pdf"
                }]
              }'

            # Search imported content
            curl -X POST http:
              -H "Content-Type: application/json" \\
              -d '{
                "model": "gpt-4",
                "conversationId": "my-conversation",
                "messages": [{
                  "role": "user",
                  "content": "Search my memory for key findings"
                }]
              }'
            """)

            SectionHeader(title: "Example 3: Generate Report")
            CodeBlock(code: """
            curl -X POST http:
              -H "Content-Type: application/json" \\
              -d '{
                "model": "gpt-4",
                "messages": [{
                  "role": "user",
                  "content": "Create a PDF report with title Q4 Analysis containing a summary of our Q4 performance"
                }]
              }'
            """)

            SectionHeader(title: "Example 4: Web Research")
            CodeBlock(code: """
            curl -X POST http:
              -H "Content-Type: application/json" \\
              -d '{
                "model": "gpt-4",
                "messages": [{
                  "role": "user",
                  "content": "Research the latest Swift 6 features and summarize them"
                }]
              }'
            """)

            SectionHeader(title: "Example 5: Code Analysis")
            CodeBlock(code: """
            curl -X POST http:
              -H "Content-Type: application/json" \\
              -d '{
                "model": "gpt-4",
                "messages": [{
                  "role": "user",
                  "content": "Find all usages of the DocumentGenerator class"
                }]
              }'
            """)
        }
    }
}

// MARK: - UI Setup

struct SectionHeader: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.headline)
            .fontWeight(.semibold)
            .padding(.top, 8)
    }
}

struct CodeBlock: View {
    let code: String

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Text(code)
                .font(.system(.body, design: .monospaced))
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(nsColor: .controlBackgroundColor))
                .cornerRadius(6)
        }
    }
}

struct ParameterRow: View {
    let name: String
    let type: String
    let required: Bool
    let description: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(.system(.body, design: .monospaced))
                    .fontWeight(.medium)
                Text(type)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .frame(width: 150, alignment: .leading)

            if required {
                Text("Required")
                    .font(.caption)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.red.opacity(0.2))
                    .cornerRadius(4)
            } else {
                Text("Optional")
                    .font(.caption)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.blue.opacity(0.2))
                    .cornerRadius(4)
            }

            Text(description)
                .font(.body)
                .foregroundColor(.secondary)
        }
        .padding(.vertical, 4)
    }
}

struct EndpointCard: View {
    let method: String
    let path: String
    let description: String

    var body: some View {
        HStack(spacing: 12) {
            Text(method)
                .font(.system(.caption, design: .monospaced))
                .fontWeight(.bold)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(methodColor)
                .cornerRadius(4)

            VStack(alignment: .leading, spacing: 2) {
                Text(path)
                    .font(.system(.body, design: .monospaced))
                    .fontWeight(.medium)
                Text(description)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding()
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(8)
    }

    var methodColor: Color {
        switch method {
        case "GET": return Color.blue.opacity(0.7)
        case "POST": return Color.green.opacity(0.7)
        case "PUT": return Color.orange.opacity(0.7)
        case "DELETE": return Color.red.opacity(0.7)
        default: return Color.gray.opacity(0.7)
        }
    }
}

struct ToolCard: View {
    let name: String
    let description: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "wrench.and.screwdriver")
                .foregroundColor(.blue)
                .font(.title3)

            VStack(alignment: .leading, spacing: 4) {
                Text(name)
                    .font(.system(.body, design: .monospaced))
                    .fontWeight(.semibold)
                Text(description)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
        .cornerRadius(8)
    }
}

struct FeatureRow: View {
    let icon: String
    let text: String
    let color: Color

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundColor(color)
            Text(text)
                .font(.body)
        }
    }
}

struct StatusCodeRow: View {
    let code: String
    let description: String

    var body: some View {
        HStack(spacing: 8) {
            Text(code)
                .font(.system(.body, design: .monospaced))
                .fontWeight(.bold)
                .foregroundColor(codeColor)
            Text(description)
                .foregroundColor(.secondary)
        }
    }

    var codeColor: Color {
        if code.starts(with: "2") { return .green }
        if code.starts(with: "4") { return .orange }
        if code.starts(with: "5") { return .red }
        return .gray
    }
}

struct FormatRow: View {
    let format: String
    let icon: String
    let features: [String]

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundColor(.blue)

            VStack(alignment: .leading, spacing: 4) {
                Text(format)
                    .fontWeight(.semibold)
                ForEach(features, id: \.self) { feature in
                    Text("• \(feature)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.3))
        .cornerRadius(8)
    }
}

// MARK: - UI Setup
#Preview {
    APIReferenceView()
}
