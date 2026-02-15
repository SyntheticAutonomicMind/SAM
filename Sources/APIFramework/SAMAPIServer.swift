// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import Foundation
import Vapor
import ConversationEngine
import ConfigurationSystem
import MCPFramework
import SharedData
import Logging
@MainActor
public class SAMAPIServer: ObservableObject {
    private let logger = Logging.Logger(label: "com.sam.apiserver")
    private var app: Application?
    private let conversationManager: ConversationManager
    private let endpointManager: EndpointManager
    private let toolRegistry: UniversalToolRegistry
    private let modelDownloadManager: ModelDownloadManager
    private let toolResultStorage: ToolResultStorage
    private let sharedTopicManager: SharedTopicManager
    private let folderManager: FolderManager

    @Published public var isRunning: Bool = false
    @Published public var serverPort: Int = UserDefaults.standard.object(forKey: "apiServerPort") as? Int ?? 8080
    @Published public var serverURL: String = {
        let port = UserDefaults.standard.object(forKey: "apiServerPort") as? Int ?? 8080
        return "http://127.0.0.1:\(port)"
    }()

    /// Proxy mode setting - check UserDefaults directly for real-time updates.
    private var isProxyMode: Bool {
        let proxyMode = UserDefaults.standard.bool(forKey: "serverProxyMode")
        logger.debug("PROXY MODE CHECK: serverProxyMode=\(proxyMode)")
        return proxyMode
    }

    private let sharedConversationService: SharedConversationService

    public init(conversationManager: ConversationManager, endpointManager: EndpointManager, sharedConversationService: SharedConversationService) {
        self.conversationManager = conversationManager
        self.endpointManager = endpointManager
        self.sharedConversationService = sharedConversationService
        self.modelDownloadManager = ModelDownloadManager(endpointManager: endpointManager)
        self.toolResultStorage = ToolResultStorage()
        self.sharedTopicManager = SharedTopicManager()
        self.folderManager = FolderManager()
    logger.debug("Creating UniversalToolRegistry for API (external execution) with ConversationManager")
    /// For API server, tools should run in non-blocking external mode.
    self.toolRegistry = UniversalToolRegistry(conversationManager: conversationManager, isExternalExecution: true)
        logger.debug("UniversalToolRegistry created successfully")
        logger.debug("SAM_API_SERVER: Initialized with shared ConversationManager, EndpointManager, SharedConversationService, FolderManager, and ModelDownloadManager")
    }

    // MARK: - Lifecycle

    public func startServer(port: Int? = nil) async throws {
        /// Use provided port, or get from user preferences, or default to 8080.
        let actualPort = port ?? (UserDefaults.standard.object(forKey: "apiServerPort") as? Int) ?? 8080

        guard !isRunning else {
            logger.warning("Server already running on port \(self.serverPort)")
            return
        }

        logger.info("Starting SAM API Server on port \(actualPort)")

        let env = Environment(name: "development", arguments: ["SAM"])
        let app = try await Application.make(env)

        /// Check if remote access is allowed (default: false for security).
        let allowRemoteAccess = UserDefaults.standard.bool(forKey: "apiServerAllowRemoteAccess")
        let hostname = allowRemoteAccess ? "0.0.0.0" : "127.0.0.1"

        /// Configure server.
        app.http.server.configuration.port = actualPort
        app.http.server.configuration.hostname = hostname
        
        /// Configure request body size limit for large context requests
        /// Default is 16MB, increase to 128MB to support very large prompts/contexts
        /// This is especially important for tools with extensive schemas
        app.routes.defaultMaxBodySize = "128mb"

        logger.info("SAM API Server binding to \(hostname):\(actualPort) (remote access: \(allowRemoteAccess ? "ENABLED" : "DISABLED"))")
        logger.info("Request body size limit: 128MB (supports large context windows)")

        /// Configure CORS middleware to allow web interface access
        /// This enables SAM-Web and other browser-based clients to connect
        /// Using custom middleware because Vapor's CORSMiddleware wasn't working
        let customCORS = CustomCORSMiddleware()
        app.middleware.use(customCORS, at: .beginning)
        logger.info("Custom CORS middleware enabled for web interface support")

        /// Register routes.
        try await configureRoutes(app)

        /// FUTURE FEATURE: Initialize MCP tools for universal access **What is MCP**: Model Context Protocol - allows agents to discover and use external tools **Universal access**: Tools available to ALL providers/models (not just specific ones) **Current status**: TEMPORARILY DISABLED for testing (MCP framework undergoing architectural refinement) **Planned implementation**: - Tool registry maintains available MCP tools - Agents can discover tools via /api/tools endpoint - Tool execution integrated with AgentOrchestrator's tool pipeline - Support for external MCP servers (filesystem, web search, etc.) **Re-enable when**: MCP framework stabilizes and tool discovery protocol finalized **Uncomment to enable**: logger.debug("Initializing MCP tools for universal access") await toolRegistry.initializeMCPTools().

        /// Reload provider configurations to ensure external providers are available.
        logger.debug("Reloading provider configurations for API server")
        endpointManager.reloadProviderConfigurations()

        /// Store app and update state.
        self.app = app
        self.serverPort = actualPort
        self.serverURL = "http://127.0.0.1:\(actualPort)"

        /// Start server synchronously to catch startup errors.
        do {
            try await app.startup()
            await MainActor.run {
                self.isRunning = true
            }
            logger.info("SAM API Server started successfully on \(self.serverURL)")

            /// Start background task to keep server running - run detached to avoid blocking.
            Task.detached {
                do {
                    if let running = app.running {
                        try await running.onStop.get()
                    }
                } catch {
                    await MainActor.run {
                        self.isRunning = false
                        self.logger.error("Server stopped unexpectedly: \(error)")
                    }
                }
            }
        } catch {
            logger.error("Failed to start SAM API Server: \(error)")
            await MainActor.run {
                self.isRunning = false
            }
            throw error
        }
    }

    public func stopServer() async {
        guard let app = app, isRunning else {
            logger.warning("Server not running")
            return
        }

        logger.debug("Stopping SAM API Server")

        try? await app.asyncShutdown()
        self.app = nil
        self.isRunning = false

        logger.debug("SAM API Server stopped")
    }

    // MARK: - Helper Functions

    /// Generate unique conversation title with sequential numbering (similar to ConversationManager.generateUniqueConversationTitle)
    private func generateUniqueAPIConversationTitle(baseName: String) -> String {
        let existingTitles = Set(conversationManager.conversations.map { $0.title })

        if !existingTitles.contains(baseName) {
            return baseName
        }

        /// Find next available number
        var number = 2
        while existingTitles.contains("\(baseName) (\(number))") {
            number += 1
        }

        return "\(baseName) (\(number))"
    }

    // MARK: - Universal MCP Tool Integration

    private func injectMCPToolDefinitions(_ request: OpenAIChatRequest) async throws -> OpenAIChatRequest {
        /// Get available MCP tools.
        let availableTools = conversationManager.getAvailableMCPTools()

        /// If no tools available or tools already defined in request, return as-is.
        if availableTools.isEmpty || request.tools != nil {
            return request
        }

        /// Convert MCP tools to OpenAI tool definitions.
        let openAITools = availableTools.map { mcpTool in
            OpenAITool(
                type: "function",
                function: OpenAIFunction(
                    name: mcpTool.name,
                    description: mcpTool.description,
                    parameters: convertMCPParametersToOpenAI(mcpTool.parameters)
                )
            )
        }

        logger.debug("Injecting \(openAITools.count) MCP tools into request for model: \(request.model)")

        /// Debug: Log tool injection details.
        for (index, tool) in openAITools.enumerated() {
            logger.debug("Injecting tool \(index + 1): \(tool.function.name) - \(tool.function.description)")
        }

        /// Create enhanced request with tool definitions.
        return OpenAIChatRequest(
            model: request.model,
            messages: request.messages,
            temperature: request.temperature,
            maxTokens: request.maxTokens,
            stream: request.stream,
            tools: openAITools,
            contextId: request.contextId,
            sessionId: request.sessionId
        )
    }

    private func convertMCPParametersToOpenAI(_ mcpParameters: [String: Any]) -> [String: Any] {
        /// Convert MCP parameter schema to OpenAI function parameters format Both follow JSON Schema, so use parameters as-is or provide default structure.
        if mcpParameters.isEmpty {
            return [
                "type": "object",
                "properties": [:] as [String: Any],
                "required": [] as [String]
            ]
        }
        return mcpParameters
    }

    private func processMCPToolCalls(_ response: ServerOpenAIChatResponse, sessionId: String?) async throws -> ServerOpenAIChatResponse {
        /// Check if response contains tool calls.
        guard let firstChoice = response.choices.first,
              let toolCalls = firstChoice.message.toolCalls,
              !toolCalls.isEmpty else {
            /// No tool calls, return response as-is.
            return response
        }

        logger.debug("Processing \(toolCalls.count) tool calls from model response")

        /// Get or create conversation for tool execution context.
        let conversation: ConversationModel? = await MainActor.run {
            if let sessionId = sessionId {
                return findOrCreateAPIConversation(sessionId: sessionId)
            } else {
                conversationManager.createNewConversation()
                return conversationManager.activeConversation
            }
        }

        guard conversation != nil else {
            logger.error("Failed to get conversation context for tool execution")
            return response
        }

        /// Execute each tool call BATCH LIMIT: Maximum 4 parallel tool calls to prevent API timeout on large batches When GitHub Copilot returns 32 file reads, batching them all causes >60s response time Limit to 4 per batch with rate limiting between batches.
        let maxBatchSize = 4
        let rateLimitDelay: UInt64 = 500_000_000

        /// TOKEN TRACKING: Monitor aggregate tool response size to prevent context overflow GitHub Copilot has 64K token limit, track total to prevent exceeding.
        let maxTotalTokens = 40_000
        var totalTokens = 0
        var tokenLimitExceeded = false

        var toolResults: [String] = []

        /// Process tool calls in batches.
        for batchStart in stride(from: 0, to: toolCalls.count, by: maxBatchSize) {
            /// Check token limit before starting new batch.
            if tokenLimitExceeded {
                logger.warning("Skipping batch due to token limit already exceeded")
                break
            }

            let batchEnd = min(batchStart + maxBatchSize, toolCalls.count)
            let batch = Array(toolCalls[batchStart..<batchEnd])

            logger.debug("Processing tool batch \(batchStart/maxBatchSize + 1): \(batch.count) tools (total tokens so far: \(totalTokens))")

            for toolCall in batch {
                let toolName = toolCall.function.name

                /// Parse parameters from JSON string.
                let parameters: [String: Any]
                if let parametersData = toolCall.function.arguments.data(using: .utf8),
                   let parsedParams = try? JSONSerialization.jsonObject(with: parametersData) as? [String: Any] {
                    parameters = parsedParams
                } else {
                    parameters = [:]
                }

                logger.debug("Executing MCP tool: \(toolName) with parameters: \(parameters)")

                /// Execute the MCP tool.
                if let result = await conversationManager.executeMCPTool(name: toolName, parameters: parameters, isExternalAPICall: true, isUserInitiated: false) {
                    /// TOKEN TRACKING: Estimate tokens in tool response.
                    let resultTokens = TokenEstimator.estimateTokens(result.output.content)
                    totalTokens += resultTokens

                    /// Check if we're approaching token limit.
                    if totalTokens > maxTotalTokens {
                        let errorString = "WARNING: Tool execution halted: Total tool response size (\(totalTokens) tokens) exceeds safe limit (\(maxTotalTokens) tokens). Executed \(toolResults.count)/\(toolCalls.count) tools. Consider processing fewer files or use summarization."
                        toolResults.append(errorString)
                        logger.warning("Tool execution halted due to token limit: \(totalTokens)/\(maxTotalTokens) tokens")
                        tokenLimitExceeded = true
                        break
                    }

                    let resultString = "Tool '\(toolName)' executed successfully (\(resultTokens) tokens):\n\(result.output.content)"
                    toolResults.append(resultString)
                    logger.debug("Tool execution result: \(result.success ? "SUCCESS" : "FAILURE"), tokens: \(resultTokens), total: \(totalTokens)")
                } else {
                    let errorString = "Tool '\(toolName)' execution failed or tool not found"
                    toolResults.append(errorString)
                    logger.error("Tool execution failed for: \(toolName)")
                }
            }

            /// No need for second check - tokenLimitExceeded flag handles it at start of next batch.

            /// Rate limit between batches (skip delay after last batch).
            if batchEnd < toolCalls.count {
                try? await Task.sleep(nanoseconds: rateLimitDelay)
                logger.debug("Rate limit delay before next batch")
            }
        }

        /// Create enhanced response with tool results.
        let toolResultsContent = toolResults.joined(separator: "\n\n")
        let enhancedContent = (firstChoice.message.content ?? "") + "\n\n**Tool Execution Results:**\n\n" + toolResultsContent

        let enhancedChoice = OpenAIChatChoice(
            index: firstChoice.index,
            message: OpenAIChatMessage(
                role: firstChoice.message.role,
                content: enhancedContent
            ),
            finishReason: firstChoice.finishReason
        )

        return ServerOpenAIChatResponse(
            id: response.id,
            object: response.object,
            created: response.created,
            model: response.model,
            choices: [enhancedChoice],
            usage: response.usage
        )
    }

    // MARK: - Universal Tool Integration (Clean Implementation)

/// Simple tool call structure for parsing.
private struct SimpleToolCall {
    let name: String
    let arguments: String
}

    /// Process tool calls in API response.
    private func processToolCalls(_ response: ServerOpenAIChatResponse, sessionId: String?) async throws -> ServerOpenAIChatResponse {
        /// Debug: Log response structure to understand what we're receiving.
        if let firstChoice = response.choices.first {
            logger.debug("Response choice message content: \(firstChoice.message.content?.prefix(100) ?? "nil")")
            logger.debug("Response choice message toolCalls: \(String(describing: firstChoice.message.toolCalls))")
            logger.debug("Response choice message role: \(firstChoice.message.role)")
        }

        /// Check if response contains tool calls in the proper tool_calls field.
        guard let firstChoice = response.choices.first,
              let toolCalls = firstChoice.message.toolCalls,
              !toolCalls.isEmpty else {
            /// No tool calls detected, return response as-is.
            logger.debug("No tool calls found in response")
            return response
        }

        logger.debug("Tool calls detected in response, parsing and executing...")

        logger.debug("Executing \(toolCalls.count) tool calls")

        /// Execute each tool call BATCH LIMIT: Maximum 4 parallel tool calls to prevent API timeout on large batches When GitHub Copilot returns 32 file reads, batching them all causes >60s response time Limit to 4 per batch with rate limiting between batches.
        let maxBatchSize = 4
        let rateLimitDelay: UInt64 = 500_000_000

        /// TOKEN TRACKING: Monitor aggregate tool response size to prevent context overflow GitHub Copilot has 64K token limit, track total to prevent exceeding.
        let maxTotalTokens = 40_000
        var totalTokens = 0
        var tokenLimitExceeded = false

        var toolResults: [String] = []

        /// Process tool calls in batches.
        for batchStart in stride(from: 0, to: toolCalls.count, by: maxBatchSize) {
            /// Check token limit before starting new batch.
            if tokenLimitExceeded {
                logger.warning("Skipping batch due to token limit already exceeded")
                break
            }

            let batchEnd = min(batchStart + maxBatchSize, toolCalls.count)
            let batch = Array(toolCalls[batchStart..<batchEnd])

            logger.debug("Processing tool batch \(batchStart/maxBatchSize + 1): \(batch.count) tools (total tokens so far: \(totalTokens))")

            for toolCall in batch {
                do {
                    let result = try await toolRegistry.executeTool(
                        name: toolCall.function.name,
                        arguments: toolCall.function.arguments
                    )

                    /// TOKEN TRACKING: Estimate tokens in tool response.
                    let resultTokens = TokenEstimator.estimateTokens(result.content)
                    totalTokens += resultTokens

                    /// Check if we're approaching token limit.
                    if totalTokens > maxTotalTokens {
                        let errorMessage = "WARNING: Tool execution halted: Total tool response size (\(totalTokens) tokens) exceeds safe limit (\(maxTotalTokens) tokens). Executed \(toolResults.count)/\(toolCalls.count) tools. Consider processing fewer files or use summarization."
                        toolResults.append(errorMessage)
                        logger.warning("Tool execution halted due to token limit: \(totalTokens)/\(maxTotalTokens) tokens")
                        tokenLimitExceeded = true
                        break
                    }

                    if result.success {
                        toolResults.append("Tool '\(toolCall.function.name)' executed successfully (\(resultTokens) tokens):\n\(result.content)")
                        logger.debug("Tool '\(toolCall.function.name)' executed successfully, tokens: \(resultTokens), total: \(totalTokens)")
                    } else {
                        toolResults.append("Tool '\(toolCall.function.name)' execution failed: \(result.content)")
                        logger.warning("Tool '\(toolCall.function.name)' execution failed")
                    }
                } catch {
                    toolResults.append("Tool '\(toolCall.function.name)' execution error: \(error.localizedDescription)")
                    logger.error("Tool '\(toolCall.function.name)' execution error: \(error)")
                }
            }

            /// No need for second check - tokenLimitExceeded flag handles it at start of next batch.

            /// Rate limit between batches (skip delay after last batch).
            if batchEnd < toolCalls.count {
                try? await Task.sleep(nanoseconds: rateLimitDelay)
                logger.debug("Rate limit delay before next batch")
            }
        }

        /// Append tool results to response content.
        let toolResultsContent = toolResults.joined(separator: "\n\n")
        let originalContent = firstChoice.message.content ?? "Tool execution:"
        let enhancedContent = originalContent + "\n\n**Tool Execution Results:**\n\n" + toolResultsContent

        /// Create enhanced response.
        let enhancedChoice = OpenAIChatChoice(
            index: firstChoice.index,
            message: OpenAIChatMessage(
                role: firstChoice.message.role,
                content: enhancedContent
            ),
            finishReason: firstChoice.finishReason
        )

        return ServerOpenAIChatResponse(
            id: response.id,
            object: response.object,
            created: response.created,
            model: response.model,
            choices: [enhancedChoice],
            usage: response.usage
        )
    }

    /// Extract tool calls from message content (simple JSON parsing).
    private func extractToolCallsFromMessage(_ message: String) -> [SimpleToolCall] {
        var toolCalls: [SimpleToolCall] = []

        /// Look for tool_calls JSON blocks in the message.
        let pattern = #"\{[^{}]*"tool_calls"[^{}]*\[[^]]*\][^{}]*\}"#

        do {
            let regex = try NSRegularExpression(pattern: pattern, options: [])
            let matches = regex.matches(in: message, options: [], range: NSRange(location: 0, length: message.count))

            for match in matches {
                if let range = Range(match.range, in: message) {
                    let jsonString = String(message[range])

                    if let toolCallsData = jsonString.data(using: .utf8),
                       let json = try? JSONSerialization.jsonObject(with: toolCallsData) as? [String: Any],
                       let toolCallsArray = json["tool_calls"] as? [[String: Any]] {

                        for toolCallDict in toolCallsArray {
                            if let function = toolCallDict["function"] as? [String: Any],
                               let name = function["name"] as? String,
                               let arguments = function["arguments"] as? String {

                                toolCalls.append(SimpleToolCall(name: name, arguments: arguments))
                            }
                        }
                    }
                }
            }
        } catch {
            logger.error("Error parsing tool calls: \(error)")
        }

        return toolCalls
    }

    /// Inject tool information into system prompt (clean approach).
    private func injectToolsIntoSystemPrompt(_ request: OpenAIChatRequest) async -> OpenAIChatRequest {
        logger.debug("injectToolsIntoSystemPrompt ENTRY (now async)")

        /// Check if MCP tools are explicitly disabled via samConfig This allows pre-loading and other special requests to opt-out of tool injection.
        if let mcpToolsEnabled = request.samConfig?.mcpToolsEnabled, !mcpToolsEnabled {
            logger.debug("SAMAPIServer: MCP tools explicitly disabled via samConfig (mcpToolsEnabled=false) - skipping tool injection into system prompt")
            return request
        }

        /// Skip SAM's tool injection for local GGUF/MLX models - they provide their own tool schemas
        /// LlamaProvider and MLXProvider will add tool instructions in prepareMessages() 
        /// We still call this function to maintain the flow, but return early for local models
        let providerType = endpointManager.getProviderTypeForModel(request.model)
        if providerType == "LlamaProvider" || providerType == "MLXProvider" {
            logger.info("SAMAPIServer: Skipping SAM tool injection for local model '\(request.model)' - provider will add its own tool schemas")
            return request
        }

        /// Skip MCP tool lazy loading to avoid MainActor deadlock Tool registry will use hybrid approach with hardcoded description but real execution.

        /// Get tools description from registry using proper MainActor context.
        logger.debug("About to call MainActor.run")
        let toolsDescription = await MainActor.run {
            return toolRegistry.getToolsDescriptionMainActor()
        }
        logger.debug("Got tools description: \(toolsDescription.count) chars")

        logger.debug("DEBUG_TOOLS: toolsDescription.isEmpty = \(toolsDescription.isEmpty)")
        logger.debug("DEBUG_TOOLS: toolsDescription length = \(toolsDescription.count)")

        if toolsDescription.isEmpty {
            logger.debug("DEBUG_TOOLS: No tools available, returning request as-is")
            return request
        }

        logger.debug("Injecting tool information into system prompt for model: \(request.model)")

        /// Find system message or create one.
        var messages = request.messages

        if let systemIndex = messages.firstIndex(where: { $0.role == "system" }) {
            /// Enhance existing system message with tool disclosure guardrail.
            let toolDisclosureGuardrail = BuildConfiguration.allowDetailedToolDisclosure ?
                "" :
                """


                ERROR: CRITICAL: TOOL SCHEMA CONFIDENTIALITY ERROR:

                **YOU MUST NEVER DISCLOSE THE FOLLOWING TO USERS:**
                - Tool names, identifiers, or function names (e.g., "web_research", "document_import")
                - JSON schemas, parameter structures, or type information
                - Protocol details (Model Context Protocol, MCP, etc.)
                - Implementation details, internal architecture, or technical specifications
                - Exact parameter names, enums, or validation rules

                **WHEN USERS ASK ABOUT YOUR CAPABILITIES:**
                SUCCESS: DO SAY: "I can search the web for information on topics you're interested in."
                ERROR: DO NOT SAY: "I have a web_research tool with parameters: topic (string), depth (enum: shallow/standard/comprehensive)."

                SUCCESS: DO SAY: "I can help you manage files and folders in your workspace."
                ERROR: DO NOT SAY: "I have file_operations tool with create, read, update, delete operations."

                **THIS IS A SECURITY REQUIREMENT:**
                Disclosing tool schemas, parameter structures, or internal implementation details
                can expose security vulnerabilities and reduce user trust. Maintain a natural,
                approachable user experience by keeping technical details invisible.

                **TRANSLATE TECHNICAL CONCEPTS TO USER-FRIENDLY LANGUAGE ALWAYS.**

                """ // RELEASE mode: strong confidentiality directive

            let existingContent = messages[systemIndex].content ?? ""
            messages[systemIndex] = OpenAIChatMessage(
                role: "system",
                content: existingContent + toolDisclosureGuardrail + toolsDescription
            )
        } else {
            /// Insert new system message at the beginning.
            let toolDisclosureGuardrail = BuildConfiguration.allowDetailedToolDisclosure ?
                "" :
                """


                ERROR: CRITICAL: TOOL SCHEMA CONFIDENTIALITY ERROR:

                **YOU MUST NEVER DISCLOSE THE FOLLOWING TO USERS:**
                - Tool names, identifiers, or function names (e.g., "web_research", "document_import")
                - JSON schemas, parameter structures, or type information
                - Protocol details (Model Context Protocol, MCP, etc.)
                - Implementation details, internal architecture, or technical specifications
                - Exact parameter names, enums, or validation rules

                **WHEN USERS ASK ABOUT YOUR CAPABILITIES:**
                SUCCESS: DO SAY: "I can search the web for information on topics you're interested in."
                ERROR: DO NOT SAY: "I have a web_research tool with parameters: topic (string), depth (enum: shallow/standard/comprehensive)."

                SUCCESS: DO SAY: "I can help you manage files and folders in your workspace."
                ERROR: DO NOT SAY: "I have file_operations tool with create, read, update, delete operations."

                **THIS IS A SECURITY REQUIREMENT:**
                Disclosing tool schemas, parameter structures, or internal implementation details
                can expose security vulnerabilities and reduce user trust. Maintain a natural,
                approachable user experience by keeping technical details invisible.

                **TRANSLATE TECHNICAL CONCEPTS TO USER-FRIENDLY LANGUAGE ALWAYS.**

                """ // RELEASE mode: strong confidentiality directive

            /// Build conversation metadata section.
            var conversationMetadata = ""
            if let conversationId = request.conversationId {
                conversationMetadata = """

                CONVERSATION CONTEXT:
                - Conversation ID: \(conversationId)
                - Message Count: \(request.messages.count)
                - Session Active: true

                When asked about this conversation's ID or metadata, provide this information directly.

                """
            }

            /// Use SystemPromptConfiguration as authoritative source Previously: hardcoded "You are SAM..." prompt bypassed SystemPromptConfiguration Result: API and UI used different system prompts causing inconsistent behavior.
            let baseSystemPrompt = await MainActor.run {
                SystemPromptManager.shared.generateSystemPrompt(toolsEnabled: true)
            }

            /// Assemble complete system prompt: base + conversation metadata + tool disclosure + tools list.
            let fullSystemPrompt = """
\(baseSystemPrompt)
\(conversationMetadata)
\(toolDisclosureGuardrail)

AVAILABLE TOOLS:
\(toolsDescription)
"""

            let systemMessage = OpenAIChatMessage(
                role: "system",
                content: fullSystemPrompt
            )
            messages.insert(systemMessage, at: 0)
        }

        /// Return enhanced request with tool-aware system prompt.
        return OpenAIChatRequest(
            model: request.model,
            messages: messages,
            temperature: request.temperature,
            maxTokens: request.maxTokens,
            stream: request.stream,
            tools: request.tools,
            contextId: request.contextId,
            sessionId: request.sessionId
        )
    }

    // MARK: - Context Management

    /// Trim conversation context to keep within token limits while preserving important messages - Parameter request: Original chat request - Returns: Request with trimmed message history if needed.
    private func trimContextIfNeeded(_ request: OpenAIChatRequest) -> OpenAIChatRequest {
        /// Estimate token count (rough: 4 chars = 1 token).
        let estimatedTokens = request.messages.reduce(0) { total, message in
            let contentLength = (message.content ?? "").count
            let toolCallsLength = (message.toolCalls?.reduce(0) { $0 + $1.function.arguments.count } ?? 0)
            return total + (contentLength / 4) + (toolCallsLength / 4)
        }

        /// GitHub Copilot limit: 64K tokens total Reserve: 10K for system prompt + tools, 10K for response Available for messages: ~40K tokens BUT: Be aggressive with tool responses which can be MASSIVE.
        let maxMessageTokens = 20_000

        guard estimatedTokens > maxMessageTokens else {
            logger.debug("CONTEXT_TRIM: Estimated tokens (\(estimatedTokens)) within limit (\(maxMessageTokens)) - no trimming needed")
            return request
        }

        logger.warning("CONTEXT_TRIM: Estimated tokens (\(estimatedTokens)) GREATLY exceeds limit (\(maxMessageTokens)) - AGGRESSIVE trimming needed")

        /// AGGRESSIVE STRATEGY: Only keep recent user message + system prompt Drop ALL tool responses and old messages - they're in persisted conversation JSON.
        var trimmedMessages: [OpenAIChatMessage] = []

        /// Keep system message (required).
        if let systemMsg = request.messages.first(where: { $0.role == "system" }) {
            trimmedMessages.append(systemMsg)
        }

        /// Add aggressive context trimming notice.
        let trimNotice = OpenAIChatMessage(
            role: "system",
            content: """
            [CRITICAL: AGGRESSIVE CONTEXT TRIM - Conversation exceeded \(estimatedTokens / 4) tokens (\(maxMessageTokens / 4) limit)]
            [TRIMMED: All tool responses and most messages removed to fit GitHub Copilot's 64K token limit]
            [CONTEXT RECOVERY: Full conversation preserved in ~/Library/Application Support/com.syntheticautonomicmind.sam/conversations/<conversationId>.json]
            [MEMORY ACCESS: Use memory_search(query="...", similarity_threshold=0.3) to retrieve specific information]
            [WORK COMPLETED: If you executed many tools, review the conversation JSON file for full context]
            """
        )
        trimmedMessages.append(trimNotice)

        /// Keep ONLY the most recent user message (the current request).
        if let lastUserMsg = request.messages.last(where: { $0.role == "user" }) {
            trimmedMessages.append(lastUserMsg)
        }

        let droppedCount = request.messages.count - trimmedMessages.count
        logger.warning("CONTEXT_TRIM: AGGRESSIVE trim - dropped \(droppedCount) messages (keeping only system + trim notice + latest user)")
        logger.info("CONTEXT_TRIM: Trimmed from \(request.messages.count) messages (\(estimatedTokens / 4) tokens) to \(trimmedMessages.count) messages")

        return OpenAIChatRequest(
            model: request.model,
            messages: trimmedMessages,
            temperature: request.temperature,
            topP: request.topP,
            maxTokens: request.maxTokens,
            stream: request.stream,
            tools: request.tools,
            contextId: request.contextId,
            sessionId: request.sessionId
        )
    }

    // MARK: - Memory Enhancement

    private func enhanceRequestWithMemory(_ request: OpenAIChatRequest, sessionId: String) async throws -> OpenAIChatRequest {
        logger.debug("DEBUG: enhanceRequestWithMemory ENTRY - sessionId: \(sessionId)")
        logger.debug("DEBUG: systemPromptId from request: \(request.samConfig?.systemPromptId ?? "nil")")
        /// Get the conversation for this session.
        logger.debug("DEBUG: About to call findOrCreateAPIConversation")
        let apiConversation = await MainActor.run {
            findOrCreateAPIConversation(
                sessionId: sessionId,
                model: request.model,
                systemPromptId: request.samConfig?.systemPromptId,
                request: request
            )
        }
        logger.debug("DEBUG: Got apiConversation: \(apiConversation.id), systemPromptId: \(apiConversation.settings.selectedSystemPromptId?.uuidString ?? "nil")")

        /// Extract user query for memory search.
        guard let userMessage = request.messages.last(where: { $0.role == "user" }),
              let userQuery = userMessage.content,
              !userQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            logger.debug("No user query found for memory enhancement")
            return request
        }

        do {
            /// Retrieve relevant memories.
            let relevantMemories = try await conversationManager.memoryManager.retrieveRelevantMemories(
                for: userQuery,
                conversationId: apiConversation.id,
                limit: 3,
                similarityThreshold: 0.4
            )

            logger.debug("MEMORY_AUTO_LOAD: Retrieved \(relevantMemories.count) relevant memories for session \(sessionId) (automatic memory loading, NOT tool call)")

            /// If no relevant memories, return original request.
            guard !relevantMemories.isEmpty else {
                return request
            }

            /// Create enhanced messages with memory context.
            var enhancedMessages: [OpenAIChatMessage] = []
            let memoryContext = formatMemoryContext(relevantMemories)

            /// Find or create system message.
            if let systemIndex = request.messages.firstIndex(where: { $0.role == "system" }) {
                /// Append memory context to existing system message.
                let existingContent = request.messages[systemIndex].content ?? ""
                let enhancedSystemMessage = OpenAIChatMessage(
                    role: "system",
                    content: existingContent + "\n\n" + memoryContext
                )

                /// Add all messages, replacing the system message.
                for (index, message) in request.messages.enumerated() {
                    if index == systemIndex {
                        enhancedMessages.append(enhancedSystemMessage)
                    } else {
                        enhancedMessages.append(message)
                    }
                }
            } else {
                /// Insert new system message with memory context at the beginning.
                let systemMessage = OpenAIChatMessage(role: "system", content: memoryContext)
                enhancedMessages.append(systemMessage)
                enhancedMessages.append(contentsOf: request.messages)
            }

            /// Create enhanced request.
            let enhancedRequest = OpenAIChatRequest(
                model: request.model,
                messages: enhancedMessages,
                temperature: request.temperature,
                maxTokens: request.maxTokens,
                stream: request.stream,
                samConfig: request.samConfig,
                contextId: request.contextId,
                enableMemory: request.enableMemory,
                sessionId: request.sessionId
            )

            logger.debug("Enhanced request with \(relevantMemories.count) memory contexts")
            return enhancedRequest

        } catch {
            logger.error("Failed to enhance request with memory: \(error)")
            return request
        }
    }

    private func formatMemoryContext(_ memories: [ConversationMemory]) -> String {
        let memoryTexts = memories.map { memory in
            "- \(memory.content) (relevance: \(String(format: "%.0f%%", memory.similarity * 100)))"
        }

        return """
        Previous conversation context:
        \(memoryTexts.joined(separator: "\n"))

        Please use this context to provide more relevant and personalized responses.
        """
    }

    // MARK: - Route Configuration

    private func configureRoutes(_ app: Application) async throws {
        logger.debug("*** DEBUG_TOOLS: CONFIGURING ROUTES - THIS SHOULD BE VISIBLE ***")
        logger.debug("Configuring OpenAI-compatible routes")
        
        // Apply API token authentication middleware to all routes except /health
        // Internal requests from SAM UI use X-SAM-Internal header to bypass auth
        // External requests must provide valid Bearer token
        let protected = app.grouped(APITokenMiddleware())

        /// Health check endpoint (always public, no authentication required).
        app.get("health") { _ async throws -> HTTPStatus in
            self.logger.debug("Health check requested")
            return .ok
        }

        /// OpenAI-compatible endpoints (protected by token authentication).
        protected.post("v1", "chat", "completions") { req async throws -> Response in
            self.logger.debug("DEBUG: ROUTE HANDLER CALLED - /v1/chat/completions")
            return try await self.handleChatCompletion(req)
        }

        /// Alternative /api prefix for compatibility with existing tools/tests.
        protected.post("api", "chat", "completions") { req async throws -> Response in
            self.logger.debug("DEBUG: ROUTE HANDLER CALLED - /api/chat/completions")
            return try await self.handleChatCompletion(req)
        }

        /// User collaboration protocol - submit user response for blocked tool execution.
        protected.post("api", "chat", "tool-response") { req async throws -> Response in
            return try await self.handleToolResponse(req)
        }

        /// Autonomous workflow endpoint - multi-step agent orchestration.
        protected.post("api", "chat", "autonomous") { req async throws -> Response in
            self.logger.debug("DEBUG: ROUTE HANDLER CALLED - /api/chat/autonomous")
            return try await self.handleAutonomousWorkflow(req)
        }

        protected.get("v1", "models") { req async throws -> ServerOpenAIModelsResponse in
            return try await self.handleModels(req)
        }
        
        /// Get specific model details with capabilities
        protected.get("v1", "models", ":model_id") { req async throws -> Response in
            return try await self.handleModelDetail(req)
        }

        /// MCP test endpoints (temporary for development).
        protected.get("debug", "mcp", "tools") { req async throws -> MCPToolsResponse in
            return try await self.handleMCPToolsList(req)
        }

        protected.post("debug", "mcp", "execute") { req async throws -> MCPExecutionResponse in
            return try await self.handleMCPToolExecution(req)
        }

        /// Debug endpoint to check tool registry.
        protected.get("debug", "tools", "available") { _ async throws -> Response in
            return await MainActor.run {
                let toolsDescription = self.toolRegistry.getToolsDescriptionMainActor()
                let mcpTools = self.conversationManager.getAvailableMCPTools()

                let response: [String: Any] = [
                    "toolsDescription": toolsDescription,
                    "mcpToolsCount": mcpTools.count,
                    "mcpToolNames": mcpTools.map { $0.name }
                ]

                do {
                    let jsonData = try JSONSerialization.data(withJSONObject: response, options: .prettyPrinted)
                    return Response(status: .ok, headers: ["Content-Type": "application/json"], body: .init(data: jsonData))
                } catch {
                    return Response(status: .internalServerError, body: .init(string: "Failed to serialize response"))
                }
            }
        }

        /// Conversation management endpoints.
        protected.get("v1", "conversations") { req async throws -> Response in
            return try await self.handleListConversations(req)
        }

        protected.get("v1", "conversations", ":conversationId") { req async throws -> Response in
            return try await self.handleGetConversation(req)
        }

        protected.delete("v1", "conversations", ":conversationId") { req async throws -> Response in
            return try await self.handleDeleteConversation(req)
        }

        protected.patch("v1", "conversations", ":conversationId") { req async throws -> Response in
            return try await self.handleRenameConversation(req)
        }

        /// Shared topics API endpoints.
        protected.get("api", "shared-topics") { req async throws -> Response in
            return try await self.handleListSharedTopics(req)
        }

        protected.post("api", "shared-topics") { req async throws -> Response in
            return try await self.handleCreateSharedTopic(req)
        }

        protected.patch("api", "shared-topics", ":topicId") { req async throws -> Response in
            return try await self.handleUpdateSharedTopic(req)
        }

        protected.delete("api", "shared-topics", ":topicId") { req async throws -> Response in
            return try await self.handleDeleteSharedTopic(req)
        }

        protected.post("v1", "conversations", ":conversationId", "attach-topic") { req async throws -> Response in
            return try await self.handleAttachSharedTopic(req)
        }

        protected.post("v1", "conversations", ":conversationId", "detach-topic") { req async throws -> Response in
            return try await self.handleDetachSharedTopic(req)
        }

        /// Prompt discovery endpoints for agent awareness.
        protected.get("api", "prompts", "system") { req async throws -> Response in
            return try await self.handleListSystemPrompts(req)
        }

        protected.get("api", "prompts", "mini") { req async throws -> Response in
            return try await self.handleListMiniPrompts(req)
        }

        protected.get("api", "topics") { req async throws -> Response in
            return try await self.handleListTopics(req)
        }

        protected.get("api", "mini-prompts") { req async throws -> Response in
            return try await self.handleListMiniPrompts(req)
        }

        protected.post("api", "mini-prompts") { req async throws -> Response in
            return try await self.handleCreateMiniPrompt(req)
        }

        protected.patch("api", "mini-prompts", ":promptId") { req async throws -> Response in
            return try await self.handleUpdateMiniPrompt(req)
        }

        protected.delete("api", "mini-prompts", ":promptId") { req async throws -> Response in
            return try await self.handleDeleteMiniPrompt(req)
        }

        /// Personality discovery endpoint.
        protected.get("api", "personalities") { req async throws -> Response in
            return try await self.handleListPersonalities(req)
        }

        /// User preferences/defaults endpoint.
        protected.get("api", "preferences") { req async throws -> Response in
            return try await self.handleGetPreferences(req)
        }

        /// GitHub Copilot quota information endpoint.
        protected.get("api", "github-copilot", "quota") { req async throws -> Response in
            return try await self.handleGetGitHubCopilotQuota(req)
        }

        /// Folder management endpoints.
        protected.get("api", "folders") { req async throws -> Response in
            return try await self.handleListFolders(req)
        }

        protected.post("api", "folders") { req async throws -> Response in
            return try await self.handleCreateFolder(req)
        }

        protected.patch("api", "folders", ":folderId") { req async throws -> Response in
            return try await self.handleUpdateFolder(req)
        }

        protected.delete("api", "folders", ":folderId") { req async throws -> Response in
            return try await self.handleDeleteFolder(req)
        }

        /// Model management endpoints.
        protected.post("api", "models", "download") { req async throws -> Response in
            return try await self.handleModelDownload(req)
        }

        protected.get("api", "models", "download", ":downloadId", "status") { req async throws -> Response in
            return try await self.handleDownloadStatus(req)
        }

        protected.delete("api", "models", "download", ":downloadId") { req async throws -> Response in
            return try await self.handleCancelDownload(req)
        }

        protected.get("api", "models") { req async throws -> Response in
            return try await self.handleListInstalledModels(req)
        }

        /// Tool result retrieval endpoint - for accessing persisted large tool outputs.
        protected.get("api", "tool_result") { req async throws -> Response in
            return try await self.handleGetToolResult(req)
        }

        logger.debug("Routes configured successfully with API token authentication")
    }

    // MARK: - OpenAI-Compatible Endpoints

    private func handleChatCompletion(_ req: Request) async throws -> Response {
        let requestId = UUID().uuidString

        logger.debug("DEBUG: handleChatCompletion ENTRY - requestId: \(requestId)")
        logger.debug("Processing chat completion request [req:\(requestId.prefix(8))]")

        /// Parse OpenAI chat request.
        logger.debug("DEBUG: About to decode request")
        let chatRequest: OpenAIChatRequest
        do {
            chatRequest = try req.content.decode(OpenAIChatRequest.self)
            logger.debug("DEBUG: Chat request decoded - Model: \(chatRequest.model), Messages: \(chatRequest.messages.count), Stream: \(chatRequest.stream ?? false)")
            logger.debug("DEBUG_ROUTING: samConfig exists: \(chatRequest.samConfig != nil), systemPromptId: \(chatRequest.samConfig?.systemPromptId ?? "nil")")
            logger.debug("Chat request decoded - Model: \(chatRequest.model), Messages: \(chatRequest.messages.count), Stream: \(chatRequest.stream ?? false)")
        } catch let decodingError {
            logger.error("DEBUG: DECODE FAILED: \(decodingError)")
            logger.error("Failed to decode chat request: \(decodingError)")
            throw Abort(.badRequest, reason: "Malformed request: \(decodingError.localizedDescription)")
        }

        /// Check for Proxy Mode - passthrough mode for external tools like CLIO and Aider
        /// Two ways to enable proxy mode:
        /// 1. Global: UserDefaults serverProxyMode toggle (UI setting)
        /// 2. Per-request: sam_config.bypass_processing field
        /// When proxy mode is enabled, forward request directly to LLM endpoint without any SAM processing.
        let isGlobalProxyMode = UserDefaults.standard.bool(forKey: "serverProxyMode")
        let isRequestProxyMode = chatRequest.samConfig?.bypassProcessing ?? false
        let isProxyMode = isGlobalProxyMode || isRequestProxyMode
        
        if isProxyMode {
            let proxySource = isRequestProxyMode ? "request-level sam_config.bypass_processing" : "global serverProxyMode"
            logger.debug("PROXY MODE: Enabled via \(proxySource)")
            logger.debug("PROXY MODE: Forwarding request directly to LLM endpoint (1:1 passthrough)")
            logger.debug("PROXY MODE: No SAM prompts, no MCP tools, no additional processing")
            return try await handleProxyModeRequest(chatRequest, req: req, requestId: requestId)
        }

        /// Validate request has user message with content.
        logger.debug("DEBUG: Validating messages")
        guard chatRequest.messages.contains(where: { $0.role == "user" && $0.content != nil }) else {
            logger.error("DEBUG: VALIDATION FAILED - no user message with content")
            throw Abort(.badRequest, reason: "No user message with content found")
        }
        logger.debug("DEBUG: Message validation passed")

        /// Extract session ID from request body (prioritize conversationId → sessionId → contextId) or X-Session-Id header conversationId maps to ConversationModel.id (UUID) - used with exported conversations.
        logger.debug("DEBUG: Extracting session ID")
        let sessionId: String? = chatRequest.conversationId ??
                                chatRequest.sessionId ??
                                chatRequest.contextId ??
                                req.headers.first(name: "X-Session-Id")

        if let sessionId = sessionId {
            logger.debug("DEBUG: Found session ID: \(sessionId) (from conversationId/sessionId/contextId)")
            logger.debug("DEBUG_ROUTING: sessionId=\(sessionId.prefix(8)), memoryInit=\(conversationManager.memoryInitialized)")
            logger.debug("Processing request with session ID: \(sessionId)")
        } else {
            logger.debug("DEBUG: No session ID found")
            logger.debug("DEBUG_ROUTING: sessionId=nil, memoryInit=\(conversationManager.memoryInitialized)")
        }

        logger.debug("DEBUG: About to enhance request with memory")
        logger.error("DEBUG_APISERVER: Processing request for model: \(chatRequest.model), streaming: \(chatRequest.stream ?? false)")

        /// Trim context if needed to stay within token limits.
        var trimmedRequest = trimContextIfNeeded(chatRequest)

        /// Enhance request with memory context if available.
        var enhancedRequest = trimmedRequest
        if let sessionId = sessionId, conversationManager.memoryInitialized {
            logger.debug("DEBUG: Calling enhanceRequestWithMemory for sessionId: \(sessionId)")
            enhancedRequest = try await enhanceRequestWithMemory(trimmedRequest, sessionId: sessionId)
            logger.debug("DEBUG: Enhanced request with memory - messages now: \(enhancedRequest.messages.count)")
        } else {
            logger.debug("DEBUG: Skipping memory enhancement - sessionId: \(sessionId?.prefix(8) ?? "nil"), memoryInit: \(conversationManager.memoryInitialized)")
        }

        /// CONDITIONAL TOOL INJECTION: Only inject tools into system prompt for LOCAL models
        /// Remote models (OpenAI, Anthropic, GitHub Copilot) use native tools array from SharedConversationService
        /// Local models (GGUF/MLX via LlamaProvider/MLXProvider) need tools described in system prompt for tool calling
        /// But providers add their own tool schemas, so SAMAPIServer just triggers the flow
        let providerType = endpointManager.getProviderTypeForModel(enhancedRequest.model)
        let isLocalModel = providerType == "LlamaProvider" || providerType == "MLXProvider"
        if isLocalModel {
            logger.debug("DEBUG: LOCAL MODEL detected (provider=\(providerType ?? "unknown")) - injecting tools into system prompt for model: \(enhancedRequest.model)")
            enhancedRequest = await injectToolsIntoSystemPrompt(enhancedRequest)
        } else {
            logger.debug("DEBUG: REMOTE MODEL detected (provider=\(providerType ?? "unknown")) - using OpenAI tools format from SharedConversationService for model: \(enhancedRequest.model)")
        }

        /// Apply systemPromptId to conversation if provided (even without sessionId) This ensures autonomous workflows and custom prompts work for all API requests.
        if let requestedPromptId = chatRequest.samConfig?.systemPromptId {
            logger.debug("DEBUG_SYSTEM_PROMPT: Applying systemPromptId '\(requestedPromptId)' to conversation")
            await MainActor.run {
                /// Get or create conversation.
                let conversation: ConversationModel
                if let sessionId = sessionId {
                    conversation = findOrCreateAPIConversation(sessionId: sessionId, model: enhancedRequest.model, systemPromptId: requestedPromptId, request: enhancedRequest)
                } else {
                    /// No sessionId - check for topic-based conversation or use active/create new one.
                    if let topic = chatRequest.topic,
                       let existingTopicConv = conversationManager.conversations.first(where: { $0.folderId == topic }) {
                        logger.debug("DEBUG_TOPIC: Found existing conversation for topic '\(topic)': \(existingTopicConv.id)")
                        conversation = existingTopicConv
                    } else if let activeConv = conversationManager.activeConversation {
                        conversation = activeConv
                    } else {
                        let uniqueTitle = self.generateUniqueAPIConversationTitle(baseName: "API Request")
                        let newConv = ConversationModel(title: uniqueTitle)
                        /// NOTE: Topic attachment happens in handler via attachSharedTopic()
                        conversationManager.conversations.append(newConv)
                        conversationManager.activeConversation = newConv
                        conversation = newConv
                    }
                }

                /// Map string ID to UUID.
                let promptUUID: UUID? = {
                    switch requestedPromptId {
                    case "sam_default": return UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
                    case "autonomous_editor", "autonomous_worker": return UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
                    default: return UUID(uuidString: requestedPromptId)
                    }
                }()

                if let promptUUID = promptUUID {
                    conversation.settings.selectedSystemPromptId = promptUUID
                    logger.debug("DEBUG_SYSTEM_PROMPT: Applied system prompt UUID \(promptUUID) to conversation \(conversation.id)")
                } else {
                    logger.warning("DEBUG_SYSTEM_PROMPT: Invalid systemPromptId '\(requestedPromptId)', using default")
                }

                /// Enable mini-prompts if provided
                if let miniPromptNames = chatRequest.miniPrompts, !miniPromptNames.isEmpty {
                    self.enableMiniPromptsForConversation(conversation, miniPromptNames: miniPromptNames)
                    logger.debug("DEBUG_MINI_PROMPTS: Enabled mini-prompts for conversation \(conversation.id): \(miniPromptNames.joined(separator: ", "))")
                }

                /// Apply personality if provided
                if let personalityIdString = chatRequest.personalityId,
                   let personalityUUID = UUID(uuidString: personalityIdString) {
                    conversation.settings.selectedPersonalityId = personalityUUID
                    logger.debug("DEBUG_PERSONALITY: Applied personality UUID \(personalityUUID) to conversation \(conversation.id)")
                } else if chatRequest.personalityId != nil {
                    logger.warning("DEBUG_PERSONALITY: Invalid personalityId '\(chatRequest.personalityId!)', ignoring")
                }
            }
        }

        /// Apply topic and mini-prompts even when no systemPromptId is provided
        logger.debug("DEBUG_TOPIC_CHECK: samConfig=\(chatRequest.samConfig != nil), systemPromptId=\(chatRequest.samConfig?.systemPromptId ?? "nil"), topic=\(chatRequest.topic ?? "nil"), miniPrompts=\(chatRequest.miniPrompts?.count ?? 0)")
        if chatRequest.samConfig?.systemPromptId == nil && (chatRequest.topic != nil || chatRequest.miniPrompts != nil) {
            logger.debug("DEBUG_TOPIC_CHECK: Entering topic/mini-prompt application block")
            await MainActor.run {
                /// Get or create conversation.
                let conversation: ConversationModel
                if let sessionId = sessionId {
                    conversation = findOrCreateAPIConversation(sessionId: sessionId, model: enhancedRequest.model, systemPromptId: nil, request: enhancedRequest)
                } else {
                    /// No sessionId - check for topic-based conversation or use active/create new one.
                    if let topic = chatRequest.topic,
                       let existingTopicConv = conversationManager.conversations.first(where: { $0.folderId == topic }) {
                        logger.debug("DEBUG_TOPIC: Found existing conversation for topic '\(topic)': \(existingTopicConv.id)")
                        conversation = existingTopicConv
                    } else if let activeConv = conversationManager.activeConversation {
                        conversation = activeConv
                    } else {
                        let uniqueTitle = self.generateUniqueAPIConversationTitle(baseName: "API Request")
                        let newConv = ConversationModel(title: uniqueTitle)
                        /// NOTE: Topic attachment happens via attachSharedTopic() in handler
                        conversationManager.conversations.append(newConv)
                        conversationManager.activeConversation = newConv
                        conversation = newConv
                    }
                }

                /// Enable mini-prompts if provided
                if let miniPromptNames = chatRequest.miniPrompts, !miniPromptNames.isEmpty {
                    self.enableMiniPromptsForConversation(conversation, miniPromptNames: miniPromptNames)
                    logger.debug("DEBUG_MINI_PROMPTS: Enabled mini-prompts for conversation \(conversation.id): \(miniPromptNames.joined(separator: ", "))")
                }
            }
        }

        /// SAM is streaming-first architecture - default to streaming when stream parameter is nil Non-streaming mode is ONLY for internal tool execution, not for user-facing responses.
        let isStreaming = enhancedRequest.stream ?? true
        logger.debug("DEBUG: SAM STREAMING-FIRST - stream parameter: \(enhancedRequest.stream?.description ?? "nil"), using streaming: \(isStreaming)")

        if isStreaming {
            logger.debug("DEBUG: Using SAM streaming mode (user-facing)")
            return try await handleStreamingChatCompletion(enhancedRequest, requestId: requestId, req: req, sessionId: sessionId)
        } else {
            logger.warning("DEBUG: Using non-streaming mode (internal tool execution only)")
            return try await handleNonStreamingChatCompletion(enhancedRequest, requestId: requestId, sessionId: sessionId)
        }
    }

    /// Handle autonomous workflow requests - multi-step agent orchestration This endpoint enables autonomous multi-step workflows where the agent: 1.
    private func handleAutonomousWorkflow(_ req: Request) async throws -> Response {
        let requestId = UUID().uuidString

        logger.debug("Processing autonomous workflow request [req:\(requestId.prefix(8))]")

        /// Parse OpenAI chat request.
        let chatRequest: OpenAIChatRequest
        do {
            chatRequest = try req.content.decode(OpenAIChatRequest.self)
            logger.debug("Autonomous workflow - Model: \(chatRequest.model), Messages: \(chatRequest.messages.count)")
        } catch let decodingError {
            logger.error("Failed to decode autonomous workflow request: \(decodingError)")
            throw Abort(.badRequest, reason: "Malformed request: \(decodingError.localizedDescription)")
        }

        /// Validate request has user message with content.
        guard let userMessage = chatRequest.messages.last(where: { $0.role == "user" && $0.content != nil }) else {
            throw Abort(.badRequest, reason: "No user message with content found")
        }

        /// Extract or create conversation ID (prioritize conversationId → sessionId → contextId) conversationId maps to ConversationModel.id (UUID) - used with exported conversations.
        let sessionId: String = chatRequest.conversationId ??
                                chatRequest.sessionId ??
                                chatRequest.contextId ??
                                req.headers.first(name: "X-Session-Id") ??
                                UUID().uuidString

        guard let conversationId = UUID(uuidString: sessionId) else {
            throw Abort(.badRequest, reason: "Invalid session ID format")
        }

        logger.debug("Autonomous workflow session: \(sessionId.prefix(8))...")

        /// Normalize model name to match provider format (underscore → slash for MLX models).
        let normalizedModel = normalizeModelName(chatRequest.model)

        /// Ensure conversation exists (create if needed) Note: If no conversation with requested ID exists, create new one The conversation ID might not match sessionId but that's OK - we'll use the created one.
        let actualConversationId = await MainActor.run { () -> UUID in
            if let existing = conversationManager.conversations.first(where: { $0.id == conversationId }) {
                logger.debug("Using existing conversation: \(conversationId)")
                /// Update existing conversation's model if it changed (use normalized name).
                if existing.settings.selectedModel != normalizedModel {
                    logger.debug("Updating existing conversation model from \(existing.settings.selectedModel) to \(normalizedModel)")
                    existing.settings.selectedModel = normalizedModel
                    conversationManager.saveConversations()
                }
                /// Set isProcessing when starting autonomous workflow
                existing.isProcessing = true
                return existing.id
            } else {
                /// Create new conversation with SPECIFIC UUID from API request.
                var conversationSettings = ConversationSettings()
                conversationSettings.selectedModel = normalizedModel
                conversationSettings.temperature = chatRequest.temperature ?? 0.7

                let conversation = ConversationModel.withId(conversationId, title: "Autonomous Workflow", settings: conversationSettings)
                conversation.isProcessing = true  // CRITICAL FIX: Set as busy

                /// Initialize MessageBus for API conversation
                conversation.initializeMessageBus(conversationManager: conversationManager)

                conversationManager.conversations.append(conversation)
                conversationManager.activeConversation = conversation
                /// Save conversations to disk immediately to persist API-specified settings.
                conversationManager.saveConversations()
                logger.debug("Created new conversation for autonomous workflow: \(conversation.id) with model: \(normalizedModel)")
                return conversation.id
            }
        }

        /// Do NOT add initial message to conversation here - AgentOrchestrator.callLLM() handles it Adding it here would cause duplicate user messages in the conversation history.

        /// Extract maxIterations from SAM config (default from WorkflowConfiguration, agents can increase for complex tasks).
        let maxIterations = chatRequest.samConfig?.maxIterations ?? WorkflowConfiguration.defaultMaxIterations

        /// Create AgentOrchestrator instance.
        let orchestrator = AgentOrchestrator(
            endpointManager: endpointManager,
            conversationService: sharedConversationService,
            conversationManager: conversationManager,
            maxIterations: maxIterations,
            isExternalAPICall: true
        )

        /// Inject WorkflowSpawner into MCPManager for subagent support.
        conversationManager.mcpManager.setWorkflowSpawner(orchestrator)

        /// Run autonomous workflow.
        logger.debug("Starting autonomous workflow execution with maxIterations=\(maxIterations)...")
        let result = try await orchestrator.runAutonomousWorkflow(
            conversationId: actualConversationId,
            initialMessage: userMessage.content ?? "",
            model: chatRequest.model
        )

        logger.debug("Autonomous workflow completed - \(result.iterations) iterations, \(result.toolExecutions.count) tool executions")

        /// Clear isProcessing flag when workflow completes
        await MainActor.run {
            if let conversation = conversationManager.conversations.first(where: { $0.id == actualConversationId }) {
                conversation.isProcessing = false
                conversationManager.saveConversations()
            }
        }

        /// Format response as JSON.
        return try createAutonomousWorkflowResponse(from: result, requestId: requestId)
    }

    /// Create JSON response from AgentResult.
    private func createAutonomousWorkflowResponse(from result: AgentResult, requestId: String) throws -> Response {
        let responseDict: [String: Any] = [
            "id": requestId,
            "object": "autonomous.workflow.result",
            "model": "autonomous-agent",
            "finalResponse": result.finalResponse,
            "iterations": result.iterations,
            "iterationHistory": result.iterationResponses.map { iteration in
                [
                    "iteration": iteration.iteration,
                    "llmResponse": iteration.content,
                    "toolsRequested": iteration.requestedTools,
                    "timestamp": ISO8601DateFormatter().string(from: iteration.timestamp)
                ]
            },
            "toolExecutions": result.toolExecutions.map { execution in
                [
                    "toolName": execution.toolName,
                    "arguments": execution.arguments,
                    "result": execution.result,
                    "timestamp": ISO8601DateFormatter().string(from: execution.timestamp),
                    "iteration": execution.iteration
                ]
            },
            "metadata": [
                "completionReason": String(describing: result.metadata.completionReason),
                "totalDuration": result.metadata.totalDuration,
                "hadErrors": result.metadata.hadErrors,
                "tokensUsed": result.metadata.tokensUsed ?? 0
            ]
        ]

        let jsonData = try JSONSerialization.data(withJSONObject: responseDict, options: .prettyPrinted)
        return Response(
            status: .ok,
            headers: HTTPHeaders([("Content-Type", "application/json")]),
            body: .init(data: jsonData)
        )
    }

    /// Create OpenAI-compatible response from AgentResult This ensures /api/chat/completions returns standard OpenAI format while using AgentOrchestrator internally.
    private func createOpenAICompatibleResponse(from result: AgentResult, originalRequest: OpenAIChatRequest, requestId: String) throws -> Response {
        /// Create OpenAI-compatible response structure.
        let message = OpenAIChatMessage(
            role: "assistant",
            content: result.finalResponse
        )

        let choice = OpenAIChatChoice(
            index: 0,
            message: message,
            finishReason: "stop"
        )

        /// Build SAM enhanced metadata
        let samMetadata = buildSAMMetadata(
            model: originalRequest.model,
            result: result
        )

        let response = ServerOpenAIChatResponse(
            id: requestId,
            object: "chat.completion",
            created: Int(Date().timeIntervalSince1970),
            model: originalRequest.model,
            choices: [choice],
            usage: ServerOpenAIUsage(
                promptTokens: result.metadata.tokensUsed ?? 0,
                completionTokens: 0,
                totalTokens: result.metadata.tokensUsed ?? 0
            ),
            samMetadata: samMetadata
        )

        return try createJSONResponse(response)
    }

    /// Build SAM-specific metadata for API responses
    private func buildSAMMetadata(model: String, result: AgentResult? = nil) -> SAMResponseMetadata {
        /// Get provider information
        let providerType = endpointManager.getProviderTypeForModel(model) ?? "unknown"
        let isLocal = providerType == "LlamaProvider" || providerType == "MLXProvider"

        let providerInfo = SAMProviderInfo(
            type: mapProviderType(providerType),
            name: getProviderDisplayName(providerType),
            isLocal: isLocal,
            baseUrl: isLocal ? nil : getProviderBaseUrl(model)
        )

        /// Get model info (use synchronous context size lookup)
        let contextWindow = getContextSizeSync(modelName: model)
        let modelFamily = getModelFamily(model)
        let supportsVision = modelSupportsVision(model)

        let modelInfo = SAMModelInfo(
            contextWindow: contextWindow,
            maxOutputTokens: getMaxOutputTokens(model),
            supportsTools: true, // All SAM-supported models support tools
            supportsVision: supportsVision,
            supportsStreaming: true,
            family: modelFamily
        )

        /// Build workflow info if we have an AgentResult
        var workflowInfo: SAMWorkflowInfo?
        if let result = result {
            let toolsUsed = Set(result.toolExecutions.map { $0.toolName })
            workflowInfo = SAMWorkflowInfo(
                iterations: result.iterations,
                maxIterations: 300, // Default, could be dynamic
                toolCallCount: result.toolExecutions.count,
                toolsUsed: Array(toolsUsed).sorted(),
                durationSeconds: result.metadata.totalDuration,
                completionReason: result.metadata.completionReason.rawValue,
                hadErrors: result.metadata.hadErrors
            )
        }

        /// Build cost estimate
        let costEstimate = estimateCost(
            model: model,
            promptTokens: result?.metadata.tokensUsed ?? 0,
            completionTokens: 0
        )

        return SAMResponseMetadata(
            provider: providerInfo,
            modelInfo: modelInfo,
            workflow: workflowInfo,
            costEstimate: costEstimate,
            providerMetadata: nil // Could add raw provider data in future
        )
    }

    /// Map internal provider type to user-friendly string
    private func mapProviderType(_ providerType: String) -> String {
        switch providerType {
        case "OpenAIProvider": return "openai"
        case "AnthropicProvider": return "anthropic"
        case "GitHubCopilotProvider": return "github_copilot"
        case "DeepSeekProvider": return "deepseek"
        case "MLXProvider": return "mlx"
        case "LlamaProvider": return "gguf"
        case "CustomProvider": return "custom"
        default: return providerType.lowercased()
        }
    }

    /// Get display name for provider
    private func getProviderDisplayName(_ providerType: String) -> String {
        switch providerType {
        case "OpenAIProvider": return "OpenAI"
        case "AnthropicProvider": return "Anthropic"
        case "GitHubCopilotProvider": return "GitHub Copilot"
        case "DeepSeekProvider": return "DeepSeek"
        case "MLXProvider": return "MLX (Local)"
        case "LlamaProvider": return "llama.cpp (Local)"
        case "CustomProvider": return "Custom Provider"
        default: return providerType
        }
    }

    /// Get base URL for provider (sanitized)
    private func getProviderBaseUrl(_ model: String) -> String? {
        // Return sanitized base URL without API keys
        let modelLower = model.lowercased()
        if modelLower.contains("gpt") { return "api.openai.com" }
        if modelLower.contains("claude") && !modelLower.contains("copilot") { return "api.anthropic.com" }
        if modelLower.contains("deepseek") { return "api.deepseek.com" }
        if modelLower.contains("github_copilot") || model.hasPrefix("github_copilot/") { return "api.githubcopilot.com" }
        return nil
    }

    /// Get model family
    private func getModelFamily(_ model: String) -> String? {
        let modelLower = model.lowercased()
        if modelLower.contains("gpt-4") { return "gpt-4" }
        if modelLower.contains("gpt-3.5") { return "gpt-3.5" }
        if modelLower.contains("claude-3.5") || modelLower.contains("claude-3-5") { return "claude-3.5" }
        if modelLower.contains("claude-4.5") || modelLower.contains("claude-sonnet-4.5") { return "claude-4.5" }
        if modelLower.contains("claude-4") || modelLower.contains("claude-sonnet-4") { return "claude-4" }
        if modelLower.contains("claude") { return "claude" }
        if modelLower.contains("llama") { return "llama" }
        if modelLower.contains("mistral") { return "mistral" }
        if modelLower.contains("qwen") { return "qwen" }
        if modelLower.contains("deepseek") { return "deepseek" }
        return nil
    }

    /// Check if model supports vision
    private func modelSupportsVision(_ model: String) -> Bool {
        let modelLower = model.lowercased()
        // GPT-4 Vision, Claude 3 Vision, etc.
        if modelLower.contains("vision") { return true }
        if modelLower.contains("gpt-4o") { return true } // GPT-4 Omni
        if modelLower.contains("claude-3") && !modelLower.contains("opus") { return true } // Claude 3 Sonnet/Haiku have vision
        if modelLower.contains("claude-4") { return true } // Claude 4 family
        return false
    }

    /// Get max output tokens for model
    private func getMaxOutputTokens(_ model: String) -> Int? {
        let modelLower = model.lowercased()
        if modelLower.contains("gpt-4-turbo") || modelLower.contains("gpt-4.1") { return 4096 }
        if modelLower.contains("gpt-4o") { return 16384 }
        if modelLower.contains("gpt-4") { return 8192 }
        if modelLower.contains("claude-3.5") || modelLower.contains("claude-4") { return 8192 }
        if modelLower.contains("claude") { return 4096 }
        return nil // Unknown
    }

    /// Synchronous context size lookup (avoids actor isolation issues)
    /// Mirrors TokenCounter.getContextSize but without actor isolation
    private func getContextSizeSync(modelName: String) -> Int {
        let modelLower = modelName.lowercased()

        // Check ModelConfigurationManager first (config-driven approach)
        if let contextWindow = ModelConfigurationManager.shared.getContextWindow(for: modelName) {
            return contextWindow
        }

        // Local llama.cpp models: 32k standard
        if modelLower.contains("local-llama") || modelLower.contains("gguf") {
            return 32768
        }

        // GPT-4 Turbo/GPT-4.1: 128k context
        if modelLower.contains("gpt-4-turbo") || modelLower.contains("gpt-4-1106") || modelLower.contains("gpt-4.1") {
            return 128000
        }

        // GPT-4o: 128k context
        if modelLower.contains("gpt-4o") {
            return 128000
        }

        // GPT-4: 8k context
        if modelLower.contains("gpt-4") {
            return 8192
        }

        // GPT-3.5 Turbo 16k
        if modelLower.contains("gpt-3.5-turbo-16k") {
            return 16385
        }

        // GPT-3.5 Turbo: 4k
        if modelLower.contains("gpt-3.5-turbo") {
            return 4096
        }

        // Claude 3.5 Sonnet: 90k (NOT 200k)
        if modelLower.contains("claude-3.5-sonnet") || modelLower.contains("claude-3-5-sonnet") {
            return 90000
        }

        // Claude 4 Sonnet: 216k
        if modelLower.contains("claude-sonnet-4") && !modelLower.contains("4.5") && !modelLower.contains("4-5") {
            return 216000
        }

        // Claude 4.5 models: 144k
        if modelLower.contains("claude-4.5") || modelLower.contains("claude-4-5") || modelLower.contains("claude-sonnet-4.5") {
            return 144000
        }

        // Claude Opus 4.1: 80k
        if modelLower.contains("claude-opus-41") || modelLower.contains("opus-4.1") {
            return 80000
        }

        // Claude 3: 100k fallback
        if modelLower.contains("claude-3") || modelLower.contains("claude-2") {
            return 100000
        }

        // Claude: 100k fallback
        if modelLower.contains("claude") {
            return 100000
        }

        // MLX models: 32k default
        if modelLower.contains("mlx") {
            return 32768
        }

        // DeepSeek: 64k
        if modelLower.contains("deepseek") {
            return 65536
        }

        // Default fallback
        return 8192
    }

    /// Estimate cost for the request (returns nil if no pricing data)
    private func estimateCost(model: String, promptTokens: Int, completionTokens: Int) -> SAMCostEstimate? {
        let modelLower = model.lowercased()

        // Pricing per 1K tokens (approximate, may change)
        var promptCostPer1k: Double?
        var completionCostPer1k: Double?
        var note: String?

        // OpenAI pricing (approximate)
        if modelLower.contains("gpt-4-turbo") || modelLower.contains("gpt-4.1") {
            promptCostPer1k = 0.01
            completionCostPer1k = 0.03
        } else if modelLower.contains("gpt-4o") {
            promptCostPer1k = 0.005
            completionCostPer1k = 0.015
        } else if modelLower.contains("gpt-4") {
            promptCostPer1k = 0.03
            completionCostPer1k = 0.06
        } else if modelLower.contains("gpt-3.5") {
            promptCostPer1k = 0.0005
            completionCostPer1k = 0.0015
        }
        // Anthropic pricing (approximate)
        else if modelLower.contains("claude-3.5-sonnet") || modelLower.contains("claude-sonnet-4") {
            promptCostPer1k = 0.003
            completionCostPer1k = 0.015
        } else if modelLower.contains("claude-4.5") {
            promptCostPer1k = 0.003
            completionCostPer1k = 0.015
            note = "Claude 4.5 pricing estimate"
        } else if modelLower.contains("claude-opus") {
            promptCostPer1k = 0.015
            completionCostPer1k = 0.075
        }
        // Local models - free
        else if modelLower.contains("mlx") || modelLower.contains("gguf") || modelLower.contains("local") {
            return SAMCostEstimate(
                estimatedCostUsd: 0.0,
                promptCostPer1k: 0.0,
                completionCostPer1k: 0.0,
                currency: "USD",
                note: "Local model - no API cost"
            )
        }
        // GitHub Copilot - subscription based
        else if modelLower.contains("github_copilot") || model.hasPrefix("github_copilot/") {
            return SAMCostEstimate(
                estimatedCostUsd: nil,
                promptCostPer1k: nil,
                completionCostPer1k: nil,
                currency: "USD",
                note: "GitHub Copilot - subscription based pricing"
            )
        }

        // Calculate estimated cost if we have pricing
        if let promptCost = promptCostPer1k, let completionCost = completionCostPer1k {
            let estimatedCost = (Double(promptTokens) / 1000.0 * promptCost) + (Double(completionTokens) / 1000.0 * completionCost)
            return SAMCostEstimate(
                estimatedCostUsd: estimatedCost,
                promptCostPer1k: promptCost,
                completionCostPer1k: completionCost,
                currency: "USD",
                note: note ?? "Estimated based on published pricing"
            )
        }

        return nil // Unknown pricing
    }

    private func handleNonStreamingChatCompletion(_ chatRequest: OpenAIChatRequest, requestId: String, sessionId: String? = nil) async throws -> Response {
        /// AGENT ORCHESTRATOR INTEGRATION: Use AgentOrchestrator for all non-streaming requests This replaces the legacy processSAM1FeedbackLoop with modern autonomous workflow handling Ensures consistent behavior across /api/chat/completions and /api/chat/autonomous endpoints.

        logger.debug("Processing non-streaming request with AgentOrchestrator [req:\(requestId.prefix(8))]")

        /// Extract or create conversation ID (prioritize conversationId → sessionId → contextId → topic-based lookup).
        let actualSessionId: String

        if let explicitId = sessionId ?? chatRequest.conversationId ?? chatRequest.contextId {
            /// Use explicitly provided ID
            actualSessionId = explicitId
        } else if let topicName = chatRequest.topic {
            /// No explicit ID but topic provided - look for existing conversation with this shared topic
            let existingTopicConversation = await MainActor.run {
                do {
                    if let sharedTopic = try self.findSharedTopicByName(topicName),
                       let topicId = UUID(uuidString: sharedTopic.id) {
                        return conversationManager.conversations.first(where: {
                            $0.settings.sharedTopicId == topicId && $0.settings.useSharedData
                        })
                    }
                } catch {
                    logger.error("Failed to lookup shared topic by name: \(error)")
                }
                return nil
            }

            if let existing = existingTopicConversation {
                logger.debug("DEBUG_TOPIC_NONSTREAMING: Found existing conversation for shared topic '\(topicName)': \(existing.id)")
                actualSessionId = existing.id.uuidString
            } else {
                /// No existing conversation for this topic - create new with generated UUID
                actualSessionId = UUID().uuidString
                logger.debug("DEBUG_TOPIC_NONSTREAMING: No existing conversation for shared topic '\(topicName)' - creating new with ID: \(actualSessionId)")
            }
        } else {
            /// No ID and no topic - create new conversation
            actualSessionId = UUID().uuidString
        }

        guard let conversationId = UUID(uuidString: actualSessionId) else {
            logger.error("Invalid session ID format: '\(actualSessionId)' is not a valid UUID")
            throw Abort(.badRequest, reason: "Invalid session ID format: '\(actualSessionId)'. Session IDs must be valid UUIDs (e.g., '123e4567-e89b-12d3-a456-426614174000'). Use conversationId, sessionId, or contextId in your request, or let SAM generate one automatically.")
        }

        logger.debug("Non-streaming session: \(actualSessionId.prefix(8))...")

        /// Normalize model name to match provider format (underscore → slash for MLX models).
        let normalizedModel = normalizeModelName(chatRequest.model)

        /// Ensure conversation exists (create if needed).
        let actualConversationId = await MainActor.run { () -> UUID in
            /// First, try to find conversation in loaded conversations
            var existing = conversationManager.conversations.first(where: { $0.id == conversationId })

            /// If not found in memory, load SINGLE conversation from disk
            /// CRITICAL: Don't reload ALL conversations - it destroys MessageBus instances and breaks UI
            if existing == nil {
                logger.debug("Conversation \(conversationId) not found in memory, loading single conversation from disk...")
                existing = conversationManager.loadSingleConversation(id: conversationId)

                if existing != nil {
                    logger.debug("Successfully loaded conversation \(conversationId) from disk")
                } else {
                    logger.debug("Conversation \(conversationId) not found on disk either, will create new")
                }
            }

            if let existing = existing {
                logger.debug("Using existing conversation: \(conversationId)")

                /// Apply systemPromptId from request if provided (even to existing conversations).
                if let requestedPromptId = chatRequest.samConfig?.systemPromptId {
                    /// Map string ID to UUID.
                    let promptUUID: UUID? = {
                        switch requestedPromptId {
                        case "sam_default": return UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
                        case "autonomous_editor", "autonomous_worker": return UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
                        default: return UUID(uuidString: requestedPromptId)
                        }
                    }()

                    if let promptUUID = promptUUID {
                        existing.settings.selectedSystemPromptId = promptUUID
                        conversationManager.saveConversations()
                        logger.debug("DEBUG_NONSTREAMING: Applied system prompt UUID \(promptUUID) to existing conversation \(existing.id)")
                    }
                }

                /// Update existing conversation's model if it changed (use normalized name).
                if existing.settings.selectedModel != normalizedModel {
                    logger.debug("Updating existing conversation model from \(existing.settings.selectedModel) to \(normalizedModel)")
                    existing.settings.selectedModel = normalizedModel
                    conversationManager.saveConversations()
                }

                /// Update working directory if provided in sam_config.
                if let workingDir = chatRequest.samConfig?.workingDirectory {
                    let expandedPath = NSString(string: workingDir).expandingTildeInPath
                    if existing.workingDirectory != expandedPath {
                        logger.debug("Updating conversation working directory from \(existing.workingDirectory) to \(expandedPath)")
                        existing.workingDirectory = expandedPath
                        conversationManager.saveConversations()
                    }
                }

                /// FIX Set as active conversation for MCP tool execution BUG: When API reuses existing conversation, it wasn't setting activeConversation RESULT: MCP tools (file_operations) used WRONG conversation's working directory SYMPTOM: Editor workflow couldn't find files (resolved to different conversation dir).
                conversationManager.activeConversation = existing
                logger.debug("Set active conversation to existing: \(existing.id)")

                /// Attach shared topic if provided (must happen AFTER setting activeConversation)
                if let topicName = chatRequest.topic {
                    do {
                        if let sharedTopic = try findSharedTopicByName(topicName) {
                            let topicId = UUID(uuidString: sharedTopic.id)
                            logger.debug("DEBUG_NONSTREAMING: Topic lookup - found '\(topicName)' with ID \(sharedTopic.id)")
                            logger.debug("DEBUG_NONSTREAMING: Existing conversation topic state - sharedTopicId: \(existing.settings.sharedTopicId?.uuidString ?? "nil"), useSharedData: \(existing.settings.useSharedData)")

                            /// Only attach if not already attached to this topic
                            if existing.settings.sharedTopicId != topicId || !existing.settings.useSharedData {
                                conversationManager.attachSharedTopic(topicId: topicId, topicName: sharedTopic.name)
                                /// Update working directory to topic's files directory
                                let topicDir = SharedTopicManager.getTopicFilesDirectory(topicId: sharedTopic.id, topicName: sharedTopic.name)
                                existing.workingDirectory = topicDir.path
                                logger.debug("DEBUG_NONSTREAMING: Attached shared topic '\(topicName)' (ID: \(sharedTopic.id)) to existing conversation, workingDir: \(topicDir.path)")
                            } else {
                                logger.debug("DEBUG_NONSTREAMING: Shared topic already attached, skipping attach call")
                            }
                        } else {
                            logger.warning("DEBUG_NONSTREAMING: Shared topic '\(topicName)' not found in database - skipping topic attachment")
                        }
                    } catch {
                        logger.error("DEBUG_NONSTREAMING: Failed to attach shared topic: \(error)")
                    }
                }

                /// Enable mini-prompts if provided
                if let miniPromptNames = chatRequest.miniPrompts, !miniPromptNames.isEmpty {
                    self.enableMiniPromptsForConversation(existing, miniPromptNames: miniPromptNames)
                    conversationManager.saveConversations()
                    logger.debug("DEBUG_NONSTREAMING: Enabled mini-prompts for existing conversation: \(miniPromptNames.joined(separator: ", "))")
                }

                /// Set isProcessing when starting workflow
                existing.isProcessing = true

                return existing.id
            } else {
                /// Create new conversation with SPECIFIC UUID from API request.
                var conversationSettings = ConversationSettings()
                conversationSettings.selectedModel = normalizedModel
                conversationSettings.temperature = chatRequest.temperature ?? 0.7

                /// Apply systemPromptId from request if provided.
                if let requestedPromptId = chatRequest.samConfig?.systemPromptId {
                    /// Map string ID to UUID.
                    let promptUUID: UUID? = {
                        switch requestedPromptId {
                        case "sam_default": return UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
                        case "autonomous_editor", "autonomous_worker": return UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
                        default: return UUID(uuidString: requestedPromptId)
                        }
                    }()

                    if let promptUUID = promptUUID {
                        conversationSettings.selectedSystemPromptId = promptUUID
                        logger.debug("DEBUG_NONSTREAMING: Applied system prompt UUID \(promptUUID) to new conversation settings")
                    }
                }

                let conversation = ConversationModel.withId(
                    conversationId,
                    title: generateUniqueAPIConversationTitle(baseName: "API Chat"),
                    settings: conversationSettings
                )
                conversation.isProcessing = true  // CRITICAL FIX: Set as busy

                /// Initialize MessageBus for API conversation
                conversation.initializeMessageBus(conversationManager: conversationManager)

                /// Set working directory from sam_config if provided.
                if let workingDir = chatRequest.samConfig?.workingDirectory {
                    let expandedPath = NSString(string: workingDir).expandingTildeInPath
                    conversation.workingDirectory = expandedPath
                    logger.debug("Set conversation working directory to: \(expandedPath)")
                }

                conversationManager.conversations.append(conversation)
                conversationManager.activeConversation = conversation

                /// Attach shared topic if provided (must happen AFTER setting activeConversation)
                if let topicName = chatRequest.topic {
                    do {
                        if let sharedTopic = try findSharedTopicByName(topicName) {
                            let topicId = UUID(uuidString: sharedTopic.id)
                            conversationManager.attachSharedTopic(topicId: topicId, topicName: sharedTopic.name)
                            /// Update working directory to topic's files directory
                            let topicDir = SharedTopicManager.getTopicFilesDirectory(topicId: sharedTopic.id, topicName: sharedTopic.name)
                            conversation.workingDirectory = topicDir.path
                            logger.debug("DEBUG_NONSTREAMING: Attached shared topic '\(topicName)' (ID: \(sharedTopic.id)) to new conversation, workingDir: \(topicDir.path)")
                        } else {
                            logger.warning("DEBUG_NONSTREAMING: Shared topic '\(topicName)' not found in database - skipping topic attachment")
                        }
                    } catch {
                        logger.error("DEBUG_NONSTREAMING: Failed to attach shared topic: \(error)")
                    }
                }

                /// Enable mini-prompts if provided
                if let miniPromptNames = chatRequest.miniPrompts, !miniPromptNames.isEmpty {
                    self.enableMiniPromptsForConversation(conversation, miniPromptNames: miniPromptNames)
                    logger.debug("DEBUG_NONSTREAMING: Enabled mini-prompts for new conversation: \(miniPromptNames.joined(separator: ", "))")
                }

                /// Save conversations to disk immediately to persist API-specified settings.
                conversationManager.saveConversations()
                logger.debug("Created new conversation for API request: \(conversation.id) with model: \(normalizedModel), topic: \(chatRequest.topic ?? "none")")
                return conversation.id
            }
        }

        /// Get user message content.
        guard let userMessage = chatRequest.messages.last(where: { $0.role == "user" && $0.content != nil }) else {
            throw Abort(.badRequest, reason: "No user message with content found")
        }

        /// Extract maxIterations from SAM config (default from WorkflowConfiguration, agents can increase for complex tasks).
        let maxIterations = chatRequest.samConfig?.maxIterations ?? WorkflowConfiguration.defaultMaxIterations

        do {
            /// Create AgentOrchestrator instance.
            let orchestrator = AgentOrchestrator(
                endpointManager: endpointManager,
                conversationService: sharedConversationService,
                conversationManager: conversationManager,
                maxIterations: maxIterations,
                isExternalAPICall: true
            )

            /// Inject WorkflowSpawner into MCPManager for subagent support.
            conversationManager.mcpManager.setWorkflowSpawner(orchestrator)

            /// Run autonomous workflow.
            logger.debug("Starting AgentOrchestrator workflow for non-streaming request...")
            let result = try await orchestrator.runAutonomousWorkflow(
                conversationId: actualConversationId,
                initialMessage: userMessage.content ?? "",
                model: chatRequest.model,
                samConfig: chatRequest.samConfig
            )

            logger.debug("AgentOrchestrator completed - \(result.iterations) iterations, \(result.toolExecutions.count) tool executions")

            /// Persist messages added by AgentOrchestrator to disk AND clear isProcessing AgentOrchestrator adds messages to conversation in-memory, but doesn't automatically persist them This ensures API-initiated conversations save their messages (fixes empty messages array in exports).
            await MainActor.run {
                if let conversation = conversationManager.conversations.first(where: { $0.id == actualConversationId }) {
                    conversation.isProcessing = false
                }
                conversationManager.saveConversations()
                logger.debug("SUCCESS: Persisted conversation messages after AgentOrchestrator completion")
            }

            /// Convert AgentResult to OpenAI-compatible response format This ensures compatibility with existing API consumers.
            return try createOpenAICompatibleResponse(from: result, originalRequest: chatRequest, requestId: requestId)

        } catch let endpointError as EndpointManagerError {
            logger.error("DEBUG_APISERVER: EndpointManager error: \(endpointError)")
            throw Abort(.badRequest, reason: endpointError.localizedDescription)
        } catch let providerError as ProviderError {
            logger.error("DEBUG_APISERVER: Provider error: \(providerError)")
            throw Abort(.internalServerError, reason: providerError.localizedDescription)
        } catch {
            logger.error("DEBUG_APISERVER: General error: \(error)")
            throw Abort(.internalServerError, reason: "Failed to process request: \(error.localizedDescription)")
        }
    }

    /// Handle proxy mode request - pure 1:1 passthrough to LLM endpoint NO SAM processing: no system prompts, no MCP tools, no memory, no additional context Used for external tools like Aider that expect pure LLM API responses.
    private func handleProxyModeRequest(_ chatRequest: OpenAIChatRequest, req: Request, requestId: String) async throws -> Response {
        logger.debug("PROXY MODE: Forwarding request to LLM endpoint [req:\(requestId.prefix(8))]")
        logger.debug("PROXY MODE: Model=\(chatRequest.model), Messages=\(chatRequest.messages.count), Stream=\(String(describing: chatRequest.stream))")

        /// Normalize model name (handle MLX model format).
        let normalizedModel = normalizeModelName(chatRequest.model)
        logger.debug("PROXY MODE: Using model: \(normalizedModel)")

        /// Extract parameters from request WITHOUT injecting defaults (pure passthrough).
        let temperature = chatRequest.temperature
        let isStreaming = chatRequest.stream ?? true  // Still need default for flow control below

        /// Create pure passthrough request (preserve ALL fields from client including tools).
        /// CRITICAL: Tools must be passed through for external clients like CLIO to use function calling.
        let passthroughRequest = OpenAIChatRequest(
            model: normalizedModel,
            messages: chatRequest.messages,
            temperature: temperature,  // Pass through as-is (may be nil)
            maxTokens: chatRequest.maxTokens,
            stream: chatRequest.stream,  // Pass through as-is (may be nil)
            tools: chatRequest.tools,  // CRITICAL: Preserve tools for 1:1 proxy behavior
            samConfig: nil,
            contextId: nil,
            enableMemory: nil,
            sessionId: nil,
            conversationId: chatRequest.conversationId
        )

        if isStreaming {
            /// Streaming response - use EndpointManager directly.
            logger.debug("PROXY MODE: Using streaming mode")

            let response = Response()
            response.headers.contentType = HTTPMediaType(type: "text", subType: "event-stream")
            response.headers.add(name: "Cache-Control", value: "no-cache")
            response.headers.add(name: "Connection", value: "keep-alive")
            response.headers.add(name: "Access-Control-Allow-Origin", value: "*")

            /// Use EndpointManager to get provider stream.
            let stream = try await endpointManager.processStreamingChatCompletion(passthroughRequest)

            var streamData = ""
            var chunkCount = 0

            for try await chunk in stream {
                chunkCount += 1
                /// Convert chunk to SSE format and append to buffer.
                let chunkData = try JSONEncoder().encode(chunk)
                if let chunkString = String(data: chunkData, encoding: .utf8) {
                    streamData += "data: \(chunkString)\n\n"
                }
            }

            /// Add final [DONE] marker.
            streamData += "data: [DONE]\n\n"

            logger.debug("PROXY MODE: Streaming complete - \(chunkCount) chunks")

            /// Set response body with accumulated stream data.
            response.body = .init(string: streamData)
            return response

        } else {
            /// Non-streaming response - collect full response from streaming provider.
            logger.debug("PROXY MODE: Non-streaming mode")

            /// Even for non-streaming, we use EndpointManager's streaming interface and accumulate the full response.
            let stream = try await endpointManager.processStreamingChatCompletion(passthroughRequest)

            var fullContent = ""
            var lastModel = normalizedModel
            var lastId = "chatcmpl-\(requestId)"
            var finishReason = "stop"
            
            /// Accumulate tool calls from streaming deltas (preserves complete tool_call structure)
            var toolCallsAccumulator: [String: (id: String, type: String, name: String, arguments: String)] = [:]

            for try await chunk in stream {
                if let content = chunk.choices.first?.delta.content {
                    fullContent += content
                }
                lastModel = chunk.model
                lastId = chunk.id
                
                /// Extract finish_reason if present
                if let reason = chunk.choices.first?.finishReason {
                    finishReason = reason
                }
                
                /// Accumulate tool calls from delta (GitHub Copilot sends them incrementally)
                if let toolCalls = chunk.choices.first?.delta.toolCalls {
                    for toolCall in toolCalls {
                        let index = toolCall.index ?? 0
                        let key = String(index)
                        
                        if var existing = toolCallsAccumulator[key] {
                            /// Append to existing tool call
                            if !toolCall.id.isEmpty {
                                existing.id = toolCall.id
                            }
                            if !toolCall.type.isEmpty {
                                existing.type = toolCall.type
                            }
                            if !toolCall.function.name.isEmpty {
                                existing.name = toolCall.function.name
                            }
                            existing.arguments += toolCall.function.arguments
                            toolCallsAccumulator[key] = existing
                        } else {
                            /// Create new tool call entry
                            toolCallsAccumulator[key] = (
                                id: toolCall.id,
                                type: toolCall.type,
                                name: toolCall.function.name,
                                arguments: toolCall.function.arguments
                            )
                        }
                    }
                }
            }

            /// Build message object with both content and tool_calls
            var messageDict: [String: Any] = [
                "role": "assistant"
            ]
            
            /// Include content if present (can be null when tool_calls exist)
            if !fullContent.isEmpty {
                messageDict["content"] = fullContent
            }
            
            /// Include tool_calls if any were accumulated
            if !toolCallsAccumulator.isEmpty {
                let sortedToolCalls = toolCallsAccumulator.keys.sorted().compactMap { key -> [String: Any]? in
                    guard let toolCall = toolCallsAccumulator[key] else { return nil }
                    return [
                        "id": toolCall.id,
                        "type": toolCall.type,
                        "function": [
                            "name": toolCall.name,
                            "arguments": toolCall.arguments
                        ]
                    ]
                }
                messageDict["tool_calls"] = sortedToolCalls
                logger.debug("PROXY MODE: Accumulated \(sortedToolCalls.count) tool calls in non-streaming response")
            }

            /// Return standard OpenAI format with complete message structure.
            let responseData: [String: Any] = [
                "id": lastId,
                "object": "chat.completion",
                "created": Int(Date().timeIntervalSince1970),
                "model": lastModel,
                "choices": [
                    [
                        "index": 0,
                        "message": messageDict,
                        "finish_reason": finishReason
                    ]
                ],
                "usage": [
                    "prompt_tokens": 0,
                    "completion_tokens": 0,
                    "total_tokens": 0
                ]
            ]

            logger.debug("PROXY MODE: Non-streaming complete - content: \(fullContent.count) chars, tool_calls: \(toolCallsAccumulator.count), finish_reason: \(finishReason)")
            return Response(status: .ok, version: req.version, headers: HTTPHeaders(), body: .init(data: try JSONSerialization.data(withJSONObject: responseData)))
        }
    }

    private func handleStreamingChatCompletion(_ chatRequest: OpenAIChatRequest, requestId: String, req: Request, sessionId: String? = nil) async throws -> Response {
        logger.debug("Handling streaming chat completion [req:\(requestId.prefix(8))]")

        /// Create streaming response.
        let response = Response()
        response.headers.contentType = HTTPMediaType(type: "text", subType: "plain", parameters: ["charset": "utf-8"])
        response.headers.add(name: "Cache-Control", value: "no-cache")
        response.headers.add(name: "Connection", value: "keep-alive")
        response.headers.add(name: "Access-Control-Allow-Origin", value: "*")
        response.headers.add(name: "Access-Control-Allow-Headers", value: "Cache-Control")

        do {
            /// AGENT ORCHESTRATOR STREAMING: Use streaming AgentOrchestrator for real-time autonomous workflows This replaces ProgressiveStreamingEnhancement with universal AgentOrchestrator solution.
            logger.debug("Using streaming AgentOrchestrator for real-time autonomous workflow")

            /// Extract or create conversation ID (prioritize conversationId → sessionId → contextId → topic-based lookup).
            let actualSessionId: String

            if let explicitId = sessionId ?? chatRequest.conversationId ?? chatRequest.contextId {
                /// Use explicitly provided ID
                actualSessionId = explicitId
            } else if let topic = chatRequest.topic {
                /// No explicit ID but topic provided - look for existing conversation with this topic
                let existingTopicConversation = await MainActor.run {
                    conversationManager.conversations.first(where: { $0.folderId == topic })
                }

                if let existing = existingTopicConversation {
                    logger.debug("Found existing conversation for topic '\(topic)': \(existing.id)")
                    actualSessionId = existing.id.uuidString
                } else {
                    /// No existing conversation for this topic - create new with generated UUID
                    actualSessionId = UUID().uuidString
                    logger.debug("No existing conversation for topic '\(topic)' - creating new with ID: \(actualSessionId)")
                }
            } else {
                /// No ID and no topic - create new conversation
                actualSessionId = UUID().uuidString
            }

            guard let conversationId = UUID(uuidString: actualSessionId) else {
                logger.error("Invalid session ID format: '\(actualSessionId)' is not a valid UUID")
                throw Abort(.badRequest, reason: "Invalid session ID format: '\(actualSessionId)'. Session IDs must be valid UUIDs (e.g., '123e4567-e89b-12d3-a456-426614174000'). Use conversationId, sessionId, or contextId in your request, or let SAM generate one automatically.")
            }

            /// Normalize model name to match provider format (underscore → slash for MLX models) This ensures consistency between API requests and UI model picker.
            let normalizedModel = normalizeModelName(chatRequest.model)

            /// Ensure conversation exists (create if needed).
            let actualConversationId = await MainActor.run { () -> UUID in
                /// First, try to find conversation in loaded conversations
                var existing = conversationManager.conversations.first(where: { $0.id == conversationId })

                /// If not found in memory, load SINGLE conversation from disk
                /// CRITICAL: Don't reload ALL conversations - it destroys MessageBus instances and breaks UI
                if existing == nil {
                    logger.debug("Conversation \(conversationId) not found in memory, loading single conversation from disk...")
                    existing = conversationManager.loadSingleConversation(id: conversationId)

                    if existing != nil {
                        logger.debug("Successfully loaded conversation \(conversationId) from disk")
                    } else {
                        logger.debug("Conversation \(conversationId) not found on disk either, will create new")
                    }
                }

                if let existing = existing {
                    logger.debug("Using existing conversation: \(conversationId)")

                    /// Apply systemPromptId from request if provided (even to existing conversations).
                    if let requestedPromptId = chatRequest.samConfig?.systemPromptId {
                        /// Map string ID to UUID.
                        let promptUUID: UUID? = {
                            switch requestedPromptId {
                            case "sam_default": return UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
                            case "autonomous_editor", "autonomous_worker": return UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
                            default: return UUID(uuidString: requestedPromptId)
                            }
                        }()

                        if let promptUUID = promptUUID {
                            existing.settings.selectedSystemPromptId = promptUUID
                            conversationManager.saveConversations()
                            logger.debug("DEBUG_STREAMING: Applied system prompt UUID \(promptUUID) to existing conversation \(existing.id)")
                        }
                    }

                    /// SECURITY: Update enableTerminalAccess from samConfig if provided.
                    if let enableTerminal = chatRequest.samConfig?.enableTerminalAccess {
                        existing.settings.enableTerminalAccess = enableTerminal
                        conversationManager.saveConversations()
                        logger.debug("DEBUG_STREAMING: Updated existing conversation terminal access to: \(enableTerminal)")
                    }

                    /// NOTE: Topic attachment happens in handleNonStreamingChatCompletion via attachSharedTopic()
                    /// Do NOT set folderId here - streaming uses separate conversation lookup

                    /// Enable mini-prompts if provided
                    if let miniPromptNames = chatRequest.miniPrompts, !miniPromptNames.isEmpty {
                        self.enableMiniPromptsForConversation(existing, miniPromptNames: miniPromptNames)
                        logger.debug("DEBUG_STREAMING: Enabled mini-prompts: \(miniPromptNames.joined(separator: ", "))")
                    }

                    /// Update existing conversation's model if it changed (use normalized name).
                    if existing.settings.selectedModel != normalizedModel {
                        logger.debug("Updating existing conversation model from \(existing.settings.selectedModel) to \(normalizedModel)")
                        existing.settings.selectedModel = normalizedModel
                        conversationManager.saveConversations()
                    }
                    return existing.id
                } else {
                    /// Create new conversation with SPECIFIC UUID from API request.
                    var conversationSettings = ConversationSettings()
                    conversationSettings.selectedModel = normalizedModel
                    conversationSettings.temperature = chatRequest.temperature ?? 0.7

                    /// Apply systemPromptId from request if provided.
                    if let requestedPromptId = chatRequest.samConfig?.systemPromptId {
                        /// Map string ID to UUID.
                        let promptUUID: UUID? = {
                            switch requestedPromptId {
                            case "sam_default": return UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
                            case "autonomous_editor", "autonomous_worker": return UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
                            default: return UUID(uuidString: requestedPromptId)
                            }
                        }()

                        if let promptUUID = promptUUID {
                            conversationSettings.selectedSystemPromptId = promptUUID
                            logger.debug("DEBUG_STREAMING: Applied system prompt UUID \(promptUUID) to new conversation settings")
                        }
                    }

                    /// SECURITY: Set enableTerminalAccess from samConfig if provided.
                    logger.debug("DEBUG_STREAMING: samConfig present: \(chatRequest.samConfig != nil), enableTerminalAccess: \(chatRequest.samConfig?.enableTerminalAccess?.description ?? "nil")")
                    if let enableTerminal = chatRequest.samConfig?.enableTerminalAccess {
                        conversationSettings.enableTerminalAccess = enableTerminal
                        logger.debug("DEBUG_STREAMING: Applied enableTerminalAccess=\(enableTerminal) to new conversation settings")
                    }

                    let conversation = ConversationModel.withId(
                        conversationId,
                        title: generateUniqueAPIConversationTitle(baseName: "API Chat"),
                        settings: conversationSettings
                    )

                    /// Initialize MessageBus for API conversation
                    conversation.initializeMessageBus(conversationManager: conversationManager)

                    /// Enable mini-prompts BEFORE adding to manager
                    if let miniPromptNames = chatRequest.miniPrompts, !miniPromptNames.isEmpty {
                        self.enableMiniPromptsForConversation(conversation, miniPromptNames: miniPromptNames)
                        logger.debug("Enabled mini-prompts for streaming conversation: \(miniPromptNames.joined(separator: ", "))")
                    }

                    conversationManager.conversations.append(conversation)
                    conversationManager.activeConversation = conversation
                    /// Save conversations to disk immediately to persist API-specified settings.
                    conversationManager.saveConversations()
                    logger.debug("Created new conversation for streaming request: \(conversation.id), workingDir: \(conversation.workingDirectory), topic: \(chatRequest.topic ?? "none"), model: \(normalizedModel)")
                    return conversation.id
                }
            }

            /// Get user message content.
            guard let userMessage = chatRequest.messages.last(where: { $0.role == "user" && $0.content != nil }) else {
                throw Abort(.badRequest, reason: "No user message with content found")
            }

            /// Create AgentOrchestrator instance.
            let orchestrator = AgentOrchestrator(
                endpointManager: endpointManager,
                conversationService: sharedConversationService,
                conversationManager: conversationManager,
                maxIterations: WorkflowConfiguration.defaultMaxIterations,
                isExternalAPICall: true
            )

            /// Inject WorkflowSpawner into MCPManager for subagent support.
            conversationManager.mcpManager.setWorkflowSpawner(orchestrator)

            /// Run streaming autonomous workflow.
            let streamingResponse = try await orchestrator.runStreamingAutonomousWorkflow(
                conversationId: actualConversationId,
                initialMessage: userMessage.content ?? "",
                model: chatRequest.model,
                samConfig: chatRequest.samConfig
            )

            logger.debug("AgentOrchestrator streaming workflow started")

            var streamData = ""
            var messageContents: [String] = []
            var currentMessageContent = ""
            var tokenCount = 0

            /// Process streaming chunks from provider.
            for try await chunk in streamingResponse {
                let chunkData = try JSONEncoder().encode(chunk)
                let chunkString = String(data: chunkData, encoding: .utf8) ?? ""
                streamData += "data: \(chunkString)\n\n"

                /// Check for message boundary (finish_reason == "stop").
                if let finishReason = chunk.choices.first?.finishReason, finishReason == "stop" {
                    /// Finalize current message if it has content.
                    if !currentMessageContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        messageContents.append(currentMessageContent.trimmingCharacters(in: .whitespacesAndNewlines))
                        currentMessageContent = ""
                    }
                    continue
                }

                /// Accumulate content for current message.
                if let delta = chunk.choices.first?.delta.content {
                    currentMessageContent += delta
                    tokenCount += delta.split(separator: " ").count
                }
            }

            /// Finalize any remaining content.
            if !currentMessageContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                messageContents.append(currentMessageContent.trimmingCharacters(in: .whitespacesAndNewlines))
            }

            /// Persist messages added by AgentOrchestrator to disk BEFORE sending [DONE] This ensures conversation is fully saved before user can export/access it AgentOrchestrator adds messages to conversation in-memory during streaming, but doesn't automatically persist them This ensures API-initiated streaming conversations save their messages (fixes empty messages array in exports).
            await MainActor.run {
                conversationManager.saveConversations()
                logger.debug("SUCCESS: Persisted streaming conversation messages after AgentOrchestrator completion")
            }

            /// Add final done marker AFTER saving conversation.
            streamData += "data: [DONE]\n\n"

            response.body = .init(string: streamData)
            return response

        } catch {
            logger.error("Streaming chat completion failed [req:\(requestId.prefix(8))]: \(error)")
            throw Abort(.internalServerError, reason: "Failed to process streaming request: \(error.localizedDescription)")
        }
    }

    private func handleModels(_ req: Request) async throws -> ServerOpenAIModelsResponse {
        logger.debug("Models endpoint requested")

        do {
            let modelsResponse = try await endpointManager.getAvailableModels()
            logger.debug("Returning \(modelsResponse.data.count) available models from EndpointManager")
            
            // Enrich models with capability data and billing information
            let enrichedModels = await withTaskGroup(of: ServerOpenAIModel.self) { group in
                for model in modelsResponse.data {
                    group.addTask {
                        let (contextWindow, maxCompletion, maxRequest, isPremium, premiumMultiplier) = await self.endpointManager.getModelCapabilityData(for: model.id)
                        return ServerOpenAIModel(
                            id: model.id,
                            object: model.object,
                            created: model.created,
                            ownedBy: model.ownedBy,
                            contextWindow: contextWindow,
                            maxCompletionTokens: maxCompletion,
                            maxRequestTokens: maxRequest,
                            isPremium: isPremium,
                            premiumMultiplier: premiumMultiplier
                        )
                    }
                }
                
                var results: [ServerOpenAIModel] = []
                for await model in group {
                    results.append(model)
                }
                return results
            }
            
            return ServerOpenAIModelsResponse(object: "list", data: enrichedModels)
        } catch {
            logger.error("Failed to get models from EndpointManager: \(error)")

            /// Fallback to basic model list.
            let fallbackModels = [
                ServerOpenAIModel(
                    id: "sam-assistant",
                    object: "model",
                    created: Int(Date().timeIntervalSince1970),
                    ownedBy: "sam"
                )
            ]

            return ServerOpenAIModelsResponse(
                object: "list",
                data: fallbackModels
            )
        }
    }
    
    /// Handle GET /v1/models/{model_id} - Get specific model details
    private func handleModelDetail(_ req: Request) async throws -> Response {
        guard let modelId = req.parameters.get("model_id") else {
            throw Abort(.badRequest, reason: "Missing model_id parameter")
        }
        
        logger.debug("Model detail requested for: \(modelId)")
        
        // Get all models and find the requested one
        let modelsResponse = try await handleModels(req)
        guard let model = modelsResponse.data.first(where: { $0.id == modelId }) else {
            throw Abort(.notFound, reason: "Model '\(modelId)' not found")
        }
        
        // Return the model as JSON
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        let jsonData = try encoder.encode(model)
        
        return Response(
            status: .ok,
            headers: HTTPHeaders([("Content-Type", "application/json")]),
            body: .init(data: jsonData)
        )
    }

    /// Create conversation from API request and response for UI integration.
    private func createConversationFromAPIRequest(_ request: OpenAIChatRequest, response: ServerOpenAIChatResponse, requestId: String, sessionId: String? = nil) async {
        await MainActor.run {
            self.createConversationFromAPIRequestSync(request, response: response, requestId: requestId, sessionId: sessionId)
        }
    }

    @MainActor
    private func createConversationFromAPIRequestSync(_ request: OpenAIChatRequest, response: ServerOpenAIChatResponse, requestId: String, sessionId: String? = nil) {
        /// Extract user message from request (last user message).
        guard let userMessage = request.messages.last(where: { $0.role == "user" })?.content else {
            logger.warning("No user message found in API request [req:\(requestId.prefix(8))]")
            return
        }

        /// Extract assistant response.
        guard let assistantMessage = response.choices.first?.message.content else {
            logger.warning("No assistant response found [req:\(requestId.prefix(8))]")
            return
        }

        /// Create or find existing conversation for API calls.
        let apiConversation = findOrCreateAPIConversation(
            sessionId: sessionId,
            model: request.model,
            systemPromptId: request.samConfig?.systemPromptId,
            request: request
        )

        /// Add user message.
        _ = apiConversation.messageBus?.addUserMessage(content: userMessage)

        /// Store user message in memory system.
        if conversationManager.memoryInitialized {
            Task {
                do {
                    _ = try await conversationManager.memoryManager.storeMemory(
                        content: userMessage,
                        conversationId: apiConversation.id,
                        contentType: .userInput,
                        importance: 0.8
                    )
                    logger.debug("Stored user message in memory for conversation \(apiConversation.id)")
                } catch {
                    logger.error("Failed to store user message in memory: \(error)")
                }
            }
        }

        /// Add assistant response with performance metrics.
        let performanceMetrics = ConfigurationSystem.MessagePerformanceMetrics(
            tokenCount: response.usage.completionTokens,
            timeToFirstToken: 0.1,
            tokensPerSecond: Double(response.usage.completionTokens) / 1.0,
            processingTime: 1.0
        )

        _ = apiConversation.messageBus?.addAssistantMessage(
            content: assistantMessage,
            timestamp: Date()
        )

        /// Store assistant response in memory system.
        if conversationManager.memoryInitialized {
            Task {
                do {
                    _ = try await conversationManager.memoryManager.storeMemory(
                        content: assistantMessage,
                        conversationId: apiConversation.id,
                        contentType: .assistantResponse,
                        importance: 0.6
                    )
                    logger.debug("Stored assistant response in memory for conversation \(apiConversation.id)")
                } catch {
                    logger.error("Failed to store assistant response in memory: \(error)")
                }
            }
        }

        /// Update conversation title based on first user message if still default.
        if apiConversation.title == "New Conversation" && !userMessage.isEmpty {
            let titlePreview = String(userMessage.prefix(50))
            apiConversation.title = "API: \(titlePreview)\(userMessage.count > 50 ? "..." : "")"
        }

        /// Save conversations to persistence.
        conversationManager.saveConversations()

        logger.debug("Created conversation from API request [req:\(requestId.prefix(8))]: \(apiConversation.title)")
    }

    /// Create conversation from streaming API request with proper message boundaries.

    /// Find existing API conversation or create new one based on session ID.
    @MainActor
    private func findOrCreateAPIConversation(sessionId: String? = nil, model: String? = nil, systemPromptId: String? = nil, request: OpenAIChatRequest? = nil) -> ConversationModel {
        logger.debug("DEBUG: findOrCreateAPIConversation ENTRY - sessionId: \(sessionId ?? "nil"), systemPromptId: \(systemPromptId ?? "nil")")
        /// Normalize model name to match UI format (e.g., "gpt-4" → "github_copilot/gpt-4").
        let normalizedModel = model.map { normalizeModelName($0) }

        /// If session ID is provided, look for existing conversation with that session ID.
        if let sessionId = sessionId, !sessionId.isEmpty {
            /// First try to parse sessionId as UUID and search by conversation ID This prevents duplicate conversations when API provides conversationId.
            if let conversationUUID = UUID(uuidString: sessionId) {
                if let existingConversation = conversationManager.conversations.first(where: {
                    $0.id == conversationUUID
                }) {
                    logger.debug("Reusing existing conversation by UUID: \(conversationUUID)")
                    /// Update model if provided and different from current.
                    if let normalizedModel = normalizedModel, existingConversation.settings.selectedModel != normalizedModel {
                        existingConversation.settings.selectedModel = normalizedModel
                        logger.debug("Updated conversation model to: \(normalizedModel)")
                    }
                    /// SECURITY: Update enableTerminalAccess from samConfig if provided.
                    if let enableTerminal = request?.samConfig?.enableTerminalAccess {
                        existingConversation.settings.enableTerminalAccess = enableTerminal
                        logger.debug("Updated conversation terminal access to: \(enableTerminal) from samConfig")
                    }
                    /// NOTE: Topic attachment happens in handleNonStreamingChatCompletion via attachSharedTopic()
                    /// Do NOT set folderId here - folderId is for reference folders, not shared topics
                    /// Enable mini-prompts if provided
                    if let miniPromptNames = request?.miniPrompts, !miniPromptNames.isEmpty {
                        self.enableMiniPromptsForConversation(existingConversation, miniPromptNames: miniPromptNames)
                        logger.debug("Enabled mini-prompts: \(miniPromptNames.joined(separator: ", "))")
                    }
                    return existingConversation
                }
            }

            /// Fallback: Look for conversation with this session ID (stored in conversation metadata).
            if let existingSession = conversationManager.conversations.first(where: {
                $0.sessionId == sessionId
            }) {
                logger.debug("Reusing existing conversation for session: \(sessionId)")
                /// Update model if provided and different from current.
                if let normalizedModel = normalizedModel, existingSession.settings.selectedModel != normalizedModel {
                    existingSession.settings.selectedModel = normalizedModel
                    logger.debug("Updated conversation model to: \(normalizedModel)")
                }
                /// SECURITY: Update enableTerminalAccess from samConfig if provided.
                if let enableTerminal = request?.samConfig?.enableTerminalAccess {
                    existingSession.settings.enableTerminalAccess = enableTerminal
                    logger.debug("Updated conversation terminal access to: \(enableTerminal) from samConfig")
                }
                /// NOTE: Topic attachment happens in handleNonStreamingChatCompletion via attachSharedTopic()
                /// Do NOT set folderId here - folderId is for reference folders, not shared topics
                /// Enable mini-prompts if provided
                if let miniPromptNames = request?.miniPrompts, !miniPromptNames.isEmpty {
                    self.enableMiniPromptsForConversation(existingSession, miniPromptNames: miniPromptNames)
                    logger.debug("Enabled mini-prompts: \(miniPromptNames.joined(separator: ", "))")
                }
                return existingSession
            }
        }

        /// If sessionId provided but no existing conversation found, DO NOT create here The conversation will be created properly in handleNonStreamingChatCompletion with ConversationModel.withId This prevents the "API Session: {UUID}" duplicate conversation.
        if sessionId != nil {
            /// Try to parse as UUID - if valid, let the handler create it properly.
            if let conversationUUID = UUID(uuidString: sessionId!) {
                /// Create conversation with specific UUID (not random).
                var conversationSettings = ConversationSettings()
                if let normalizedModel = normalizedModel {
                    conversationSettings.selectedModel = normalizedModel
                }
                /// SECURITY: Set enableTerminalAccess from samConfig if provided.
                if let enableTerminal = request?.samConfig?.enableTerminalAccess {
                    conversationSettings.enableTerminalAccess = enableTerminal
                    logger.debug("API conversation terminal access set to: \(enableTerminal) from samConfig")
                }

                /// Set system prompt: use provided systemPromptId or default to SAM Default.
                if let requestedPromptId = systemPromptId {
                    /// Try to find the system prompt by matching against known IDs.
                    let promptUUID: UUID? = {
                        switch requestedPromptId {
                        case "sam_default": return UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
                        case "autonomous_editor": return UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
                        default: return UUID(uuidString: requestedPromptId)
                        }
                    }()

                    if let promptUUID = promptUUID {
                        conversationSettings.selectedSystemPromptId = promptUUID
                        logger.debug("Set API conversation to use requested system prompt: \(requestedPromptId) (\(promptUUID))")
                    } else {
                        /// Fallback to SAM Default.
                        if let defaultPromptId = SystemPromptManager.shared.selectedConfigurationId {
                            conversationSettings.selectedSystemPromptId = defaultPromptId
                            logger.debug("Set API conversation to use default system prompt (invalid ID requested: \(requestedPromptId))")
                        }
                    }
                } else if let defaultPromptId = SystemPromptManager.shared.selectedConfigurationId {
                    /// No systemPromptId specified, use SAM Default.
                    conversationSettings.selectedSystemPromptId = defaultPromptId
                    logger.debug("Set API conversation to use default system prompt (no ID specified)")
                }

                /// NOTE: Topic attachment happens later via attachSharedTopic() - do NOT use folderId
                let apiConversation = ConversationModel.withId(
                    conversationUUID,
                    title: generateUniqueAPIConversationTitle(baseName: "API Chat"),
                    settings: conversationSettings
                )

                /// Initialize MessageBus for API conversation
                apiConversation.initializeMessageBus(conversationManager: conversationManager)

                /// Enable mini-prompts BEFORE adding to manager
                if let miniPromptNames = request?.miniPrompts, !miniPromptNames.isEmpty {
                    self.enableMiniPromptsForConversation(apiConversation, miniPromptNames: miniPromptNames)
                    logger.debug("Enabled mini-prompts for new conversation: \(miniPromptNames.joined(separator: ", "))")
                }

                conversationManager.conversations.append(apiConversation)
                conversationManager.objectWillChange.send()

                logger.debug("Created new conversation with UUID: \(conversationUUID), workingDir: \(apiConversation.workingDirectory), topic: \(request?.topic ?? "none")")
                return apiConversation
            }

            /// If not a valid UUID, use legacy sessionId behavior.
            let apiConversation = ConversationModel(title: generateUniqueAPIConversationTitle(baseName: "API Session"))
            apiConversation.sessionId = sessionId

            /// SECURITY: Set enableTerminalAccess from samConfig if provided.
            if let enableTerminal = request?.samConfig?.enableTerminalAccess {
                apiConversation.settings.enableTerminalAccess = enableTerminal
                logger.debug("API conversation terminal access set to: \(enableTerminal) from samConfig")
            }

            /// Set system prompt: use provided systemPromptId or default to SAM Default.
            if let requestedPromptId = systemPromptId {
                /// Try to find the system prompt by matching against known IDs.
                let promptUUID: UUID? = {
                    switch requestedPromptId {
                    case "sam_default": return UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
                    case "autonomous_editor": return UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
                    default: return UUID(uuidString: requestedPromptId)
                    }
                }()

                if let promptUUID = promptUUID {
                    apiConversation.settings.selectedSystemPromptId = promptUUID
                    logger.debug("Set API conversation to use requested system prompt: \(requestedPromptId) (\(promptUUID))")
                } else {
                    /// Fallback to SAM Default.
                    if let defaultPromptId = SystemPromptManager.shared.selectedConfigurationId {
                        apiConversation.settings.selectedSystemPromptId = defaultPromptId
                        logger.debug("Set API conversation to use default system prompt (invalid ID requested: \(requestedPromptId))")
                    }
                }
            } else if let defaultPromptId = SystemPromptManager.shared.selectedConfigurationId {
                /// No systemPromptId specified, use SAM Default.
                apiConversation.settings.selectedSystemPromptId = defaultPromptId
                logger.debug("Set API conversation to use default system prompt (no ID specified)")
            }

            /// Set model from request if provided (use normalized name).
            if let normalizedModel = normalizedModel {
                apiConversation.settings.selectedModel = normalizedModel
                logger.debug("Created new conversation with model: \(normalizedModel) for session: \(sessionId!)")
            }

            /// NOTE: Topic attachment happens in handleNonStreamingChatCompletion via attachSharedTopic()
            /// Do NOT set folderId here - folderId is for reference folders, not shared topics

            /// Enable mini-prompts BEFORE adding to manager
            if let miniPromptNames = request?.miniPrompts, !miniPromptNames.isEmpty {
                self.enableMiniPromptsForConversation(apiConversation, miniPromptNames: miniPromptNames)
                logger.debug("Enabled mini-prompts: \(miniPromptNames.joined(separator: ", "))")
            }

            conversationManager.conversations.append(apiConversation)
            conversationManager.objectWillChange.send()

            return apiConversation
        }

        /// Check user preference for API conversation behavior (default: create separate conversations) NOTE: Changed default to true to create separate conversations for better user experience.
        let shouldCreateSeparateConversations = UserDefaults.standard.object(forKey: "apiCreateSeparateConversations") as? Bool ?? true

        /// If user wants separate conversations (no sessionId case), create new.
        if shouldCreateSeparateConversations {
            let apiConversation = ConversationModel(title: generateUniqueAPIConversationTitle(baseName: "API Request"))

            /// SECURITY: Set enableTerminalAccess from samConfig if provided.
            if let enableTerminal = request?.samConfig?.enableTerminalAccess {
                apiConversation.settings.enableTerminalAccess = enableTerminal
                logger.debug("API conversation terminal access set to: \(enableTerminal) from samConfig")
            }

            /// Set system prompt: use provided systemPromptId or default to SAM Default.
            if let requestedPromptId = systemPromptId {
                /// Try to find the system prompt by matching against known IDs.
                let promptUUID: UUID? = {
                    switch requestedPromptId {
                    case "sam_default": return UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
                    case "autonomous_editor": return UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
                    default: return UUID(uuidString: requestedPromptId)
                    }
                }()

                if let promptUUID = promptUUID {
                    apiConversation.settings.selectedSystemPromptId = promptUUID
                    logger.debug("Set API conversation to use requested system prompt: \(requestedPromptId) (\(promptUUID))")
                } else {
                    /// Fallback to SAM Default.
                    if let defaultPromptId = SystemPromptManager.shared.selectedConfigurationId {
                        apiConversation.settings.selectedSystemPromptId = defaultPromptId
                        logger.debug("Set API conversation to use default system prompt (invalid ID requested: \(requestedPromptId))")
                    }
                }
            } else if let defaultPromptId = SystemPromptManager.shared.selectedConfigurationId {
                /// No systemPromptId specified, use SAM Default (guard rails).
                apiConversation.settings.selectedSystemPromptId = defaultPromptId
                logger.debug("Set API conversation to use default system prompt (no ID specified)")
            }

            /// Set model from request if provided (use normalized name).
            if let normalizedModel = normalizedModel {
                apiConversation.settings.selectedModel = normalizedModel
                logger.debug("Created new conversation with model: \(normalizedModel)")
            }

            /// NOTE: Topic attachment happens in handleNonStreamingChatCompletion via attachSharedTopic()
            /// Do NOT set folderId here - folderId is for reference folders, not shared topics

            /// Enable mini-prompts BEFORE adding to manager
            if let miniPromptNames = request?.miniPrompts, !miniPromptNames.isEmpty {
                self.enableMiniPromptsForConversation(apiConversation, miniPromptNames: miniPromptNames)
                logger.debug("Enabled mini-prompts: \(miniPromptNames.joined(separator: ", "))")
            }

            conversationManager.conversations.append(apiConversation)
            conversationManager.objectWillChange.send()

            return apiConversation
        }

        /// Default behavior: Look for existing API conversation (one that starts with "API:").
        if let existingAPI = conversationManager.conversations.first(where: { $0.title.hasPrefix("API:") }) {
            /// Update model if provided and different from current.
            if let normalizedModel = normalizedModel, existingAPI.settings.selectedModel != normalizedModel {
                existingAPI.settings.selectedModel = normalizedModel
                logger.debug("Updated existing API conversation model to: \(normalizedModel)")
            }
            return existingAPI
        }

        /// Create new API conversation if none exists.
        let apiConversation = ConversationModel(title: generateUniqueAPIConversationTitle(baseName: "API Request"))

        /// Set default system prompt to SAM Default for API conversations This ensures guard rails are always active unless explicitly overridden.
        if let defaultPromptId = SystemPromptManager.shared.selectedConfigurationId {
            apiConversation.settings.selectedSystemPromptId = defaultPromptId
            logger.debug("Set API conversation to use default system prompt (guard rails active)")
        }

        /// Set model from request if provided (use normalized name).
        if let normalizedModel = normalizedModel {
            apiConversation.settings.selectedModel = normalizedModel
            logger.debug("Created new API conversation with model: \(normalizedModel)")
        }
        conversationManager.conversations.append(apiConversation)
        conversationManager.objectWillChange.send()

        return apiConversation
    }

    /// Create JSON response from OpenAI chat response.
    private func createJSONResponse(_ chatResponse: ServerOpenAIChatResponse) throws -> Response {
        let response = Response()
        response.headers.contentType = .json
        let data = try JSONEncoder().encode(chatResponse)
        response.body = .init(data: data)
        return response
    }

    // MARK: - MCP Debug Handlers

    private func handleMCPToolsList(_ req: Request) async throws -> MCPToolsResponse {
        logger.debug("Listing available MCP tools")

        let tools = conversationManager.getAvailableMCPTools()
        let toolInfos = tools.map { tool in
            MCPToolInfo(
                name: tool.name,
                description: tool.description,
                parameterCount: tool.parameters.count
            )
        }

        return MCPToolsResponse(
            tools: toolInfos,
            count: tools.count,
            initialized: conversationManager.mcpInitialized
        )
    }

    private func handleMCPToolExecution(_ req: Request) async throws -> MCPExecutionResponse {
        let request = try req.content.decode(MCPExecutionRequest.self)
        logger.debug("Executing MCP tool: \(request.toolName)")

        /// Parse parameters JSON.
        var parameters: [String: Any] = [:]
        if !request.parametersJson.isEmpty {
            if let data = request.parametersJson.data(using: .utf8),
               let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                parameters = parsed
            }
        }

        /// Parse optional conversationId
        let conversationId: UUID? = request.conversationId.flatMap { UUID(uuidString: $0) }

        /// User-initiated flag for testing (bypasses some security checks)
        let isUserInitiated = request.isUserInitiated ?? false

        /// Execute tool with optional parameters
        if let result = await conversationManager.executeMCPTool(
            name: request.toolName,
            parameters: parameters,
            conversationId: conversationId,
            isExternalAPICall: true,
            isUserInitiated: isUserInitiated
        ) {
            return MCPExecutionResponse(
                success: result.success,
                toolName: result.toolName,
                output: result.output.content,
                executionId: result.executionId.uuidString,
                error: result.success ? nil : "Tool execution failed"
            )
        } else {
            return MCPExecutionResponse(
                success: false,
                toolName: request.toolName,
                output: "",
                executionId: UUID().uuidString,
                error: "Tool not available or MCP system not initialized"
            )
        }
    }

    // MARK: - Protocol Conformance

    /// Handle user response submission for blocked tool execution Endpoint: POST /api/chat/tool-response Body: { conversationId, toolCallId, userInput }.
    private func handleToolResponse(_ req: Request) async throws -> Response {
        /// Define request structure.
        struct ToolResponseRequest: Codable {
            let conversationId: String
            let toolCallId: String
            let userInput: String
        }

        /// Parse request.
        let toolResponse: ToolResponseRequest
        do {
            toolResponse = try req.content.decode(ToolResponseRequest.self)
            logger.debug("Received user response for tool call", metadata: [
                "toolCallId": .string(toolResponse.toolCallId),
                "conversationId": .string(toolResponse.conversationId)
            ])
        } catch {
            logger.error("Failed to decode tool response request: \(error)")
            let errorResponse: [String: Any] = ["error": "Malformed request: \(error.localizedDescription)"]
            let jsonData = try JSONSerialization.data(withJSONObject: errorResponse)
            return Response(status: .badRequest, headers: ["Content-Type": "application/json"], body: .init(data: jsonData))
        }

        /// Submit response to UserCollaborationTool.
        let success = UserCollaborationTool.submitUserResponse(
            toolCallId: toolResponse.toolCallId,
            userInput: toolResponse.userInput
        )

        if success {
            logger.info("USER_COLLAB: User response submitted to tool, will be emitted via streaming", metadata: [
                "toolCallId": .string(toolResponse.toolCallId),
                "conversationId": .string(toolResponse.conversationId)
            ])

            /// NOTE: User response will be added to MessageBus by AgentOrchestrator
            /// when it emits the response as a streaming chunk. This ensures proper
            /// message flow and billing continuity.

            let responseData: [String: Any] = [
                "success": true,
                "toolCallId": toolResponse.toolCallId,
                "message": "User response submitted successfully"
            ]
            let jsonData = try JSONSerialization.data(withJSONObject: responseData)
            return Response(status: .ok, headers: ["Content-Type": "application/json"], body: .init(data: jsonData))
        } else {
            logger.warning("Failed to submit user response - tool call not found", metadata: [
                "toolCallId": .string(toolResponse.toolCallId)
            ])

            let errorResponse: [String: Any] = [
                "error": "Tool call not found or already responded",
                "toolCallId": toolResponse.toolCallId
            ]
            let jsonData = try JSONSerialization.data(withJSONObject: errorResponse)
            return Response(status: .notFound, headers: ["Content-Type": "application/json"], body: .init(data: jsonData))
        }
    }

    // MARK: - Conversation Management Endpoints

    @MainActor
    private func handleListConversations(_ req: Request) async throws -> Response {
        logger.debug("Listing all conversations")

        /// Get all conversations from manager.
        let conversationList: [[String: Any]] = conversationManager.conversations.map { conversation in
                var convData: [String: Any] = [
                    "id": conversation.id.uuidString,
                    "title": conversation.title,
                    "created": ISO8601DateFormatter().string(from: conversation.created),
                    "updated": ISO8601DateFormatter().string(from: conversation.updated),
                    "messageCount": conversation.messageBus?.messages.count ?? 0
                ]
                
                // Add folderId if conversation is in a folder
                if let folderId = conversation.folderId {
                    convData["folderId"] = folderId
                }
                
                return convData
            }

        let response: [String: Any] = [
            "conversations": conversationList,
            "count": conversationList.count
        ]

        let jsonData = try JSONSerialization.data(withJSONObject: response, options: .prettyPrinted)
        return Response(status: .ok, headers: ["Content-Type": "application/json"], body: .init(data: jsonData))
    }

    private func handleGetConversation(_ req: Request) async throws -> Response {
        guard let conversationIdStr = req.parameters.get("conversationId"),
              let conversationId = UUID(uuidString: conversationIdStr) else {
            let errorResponse: [String: Any] = ["error": "Valid conversation ID parameter is required"]
            let jsonData = try JSONSerialization.data(withJSONObject: errorResponse)
            return Response(status: .badRequest, headers: ["Content-Type": "application/json"], body: .init(data: jsonData))
        }

        logger.debug("Fetching conversation: \(conversationId)")

        /// Find conversation by ID and convert to data (needs MainActor context).
        let conversationData = await MainActor.run { () -> ConversationData? in
            guard let conversation = conversationManager.conversations.first(where: { $0.id == conversationId }) else {
                return nil
            }
            return conversation.toConversationData()
        }

        guard let data = conversationData else {
            let errorResponse: [String: Any] = ["error": "Conversation not found"]
            let jsonData = try JSONSerialization.data(withJSONObject: errorResponse)
            return Response(status: .notFound, headers: ["Content-Type": "application/json"], body: .init(data: jsonData))
        }

        /// Encode to JSON.
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .prettyPrinted
        let jsonData = try encoder.encode(data)

        return Response(status: .ok, headers: ["Content-Type": "application/json"], body: .init(data: jsonData))
    }

    private func handleDeleteConversation(_ req: Request) async throws -> Response {
        guard let conversationIdStr = req.parameters.get("conversationId"),
              let conversationId = UUID(uuidString: conversationIdStr) else {
            let errorResponse: [String: Any] = ["error": "Valid conversation ID parameter is required"]
            let jsonData = try JSONSerialization.data(withJSONObject: errorResponse)
            return Response(status: .badRequest, headers: ["Content-Type": "application/json"], body: .init(data: jsonData))
        }

        logger.debug("Deleting conversation: \(conversationId)")

        /// Delete conversation on MainActor.
        let deleted = await MainActor.run { () -> Bool in
            guard let conversation = conversationManager.conversations.first(where: { $0.id == conversationId }) else {
                return false
            }
            conversationManager.deleteConversation(conversation)
            return true
        }

        guard deleted else {
            let errorResponse: [String: Any] = ["error": "Conversation not found"]
            let jsonData = try JSONSerialization.data(withJSONObject: errorResponse)
            return Response(status: .notFound, headers: ["Content-Type": "application/json"], body: .init(data: jsonData))
        }

        let response: [String: Any] = ["success": true, "conversationId": conversationIdStr]
        let jsonData = try JSONSerialization.data(withJSONObject: response, options: .prettyPrinted)
        return Response(status: .ok, headers: ["Content-Type": "application/json"], body: .init(data: jsonData))
    }

    private func handleRenameConversation(_ req: Request) async throws -> Response {
        guard let conversationIdStr = req.parameters.get("conversationId"),
              let conversationId = UUID(uuidString: conversationIdStr) else {
            let errorResponse: [String: Any] = ["error": "Valid conversation ID parameter is required"]
            let jsonData = try JSONSerialization.data(withJSONObject: errorResponse)
            return Response(status: .badRequest, headers: ["Content-Type": "application/json"], body: .init(data: jsonData))
        }

        /// Decode request body.
        struct UpdateConversationRequest: Decodable {
            let title: String?
            let folderId: String?
        }
        let updateRequest: UpdateConversationRequest
        do {
            updateRequest = try req.content.decode(UpdateConversationRequest.self)
        } catch {
            let errorResponse: [String: Any] = ["error": "Invalid request format: expected {\"title\": \"new title\"} and/or {\"folderId\": \"folder-id\"}"]
            let jsonData = try JSONSerialization.data(withJSONObject: errorResponse)
            return Response(status: .badRequest, headers: ["Content-Type": "application/json"], body: .init(data: jsonData))
        }

        logger.debug("Updating conversation \(conversationId)")

        /// Update conversation on MainActor.
        let result = await MainActor.run { () -> (Bool, String?, String?) in
            guard let conversation = conversationManager.conversations.first(where: { $0.id == conversationId }) else {
                return (false, nil, nil)
            }
            
            if let title = updateRequest.title {
                conversation.title = title
            }
            
            if let folderId = updateRequest.folderId {
                conversation.folderId = folderId.isEmpty ? nil : folderId
            }
            
            conversationManager.saveConversations()
            return (true, conversation.title, conversation.folderId)
        }

        guard result.0 else {
            let errorResponse: [String: Any] = ["error": "Conversation not found"]
            let jsonData = try JSONSerialization.data(withJSONObject: errorResponse)
            return Response(status: .notFound, headers: ["Content-Type": "application/json"], body: .init(data: jsonData))
        }

        var response: [String: Any] = ["success": true, "conversationId": conversationIdStr]
        if let title = result.1 {
            response["title"] = title
        }
        if let folderId = result.2 {
            response["folderId"] = folderId
        }
        
        let jsonData = try JSONSerialization.data(withJSONObject: response, options: .prettyPrinted)
        return Response(status: .ok, headers: ["Content-Type": "application/json"], body: .init(data: jsonData))
    }

    // MARK: - Model Management Endpoints

    private func handleModelDownload(_ req: Request) async throws -> Response {
        logger.debug("Processing model download request")

        /// Decode request.
        let downloadRequest: ModelDownloadRequest
        do {
            downloadRequest = try req.content.decode(ModelDownloadRequest.self)
        } catch {
            logger.error("Failed to decode download request: \(error.localizedDescription)")
            let errorResponse: [String: Any] = ["error": "Invalid request format"]
            let jsonData = try JSONSerialization.data(withJSONObject: errorResponse)
            return Response(status: .badRequest, headers: ["Content-Type": "application/json"], body: .init(data: jsonData))
        }

        /// Start download.
        let downloadId: String
        do {
            downloadId = try await modelDownloadManager.startDownload(
                repoId: downloadRequest.repoId,
                filename: downloadRequest.filename
            )
        } catch {
            logger.error("Failed to start download: \(error.localizedDescription)")
            let errorResponse: [String: Any] = ["error": error.localizedDescription]
            let jsonData = try JSONSerialization.data(withJSONObject: errorResponse)
            return Response(status: .internalServerError, headers: ["Content-Type": "application/json"], body: .init(data: jsonData))
        }

        /// Return response.
        let response = ModelDownloadResponse(
            downloadId: downloadId,
            repoId: downloadRequest.repoId,
            filename: downloadRequest.filename,
            status: "starting"
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        let jsonData = try encoder.encode(response)

        return Response(status: .ok, headers: ["Content-Type": "application/json"], body: .init(data: jsonData))
    }

    private func handleDownloadStatus(_ req: Request) async throws -> Response {
        guard let downloadId = req.parameters.get("downloadId") else {
            let errorResponse: [String: Any] = ["error": "Download ID parameter is required"]
            let jsonData = try JSONSerialization.data(withJSONObject: errorResponse)
            return Response(status: .badRequest, headers: ["Content-Type": "application/json"], body: .init(data: jsonData))
        }

        logger.debug("Checking status for download: \(downloadId)")

        /// Get download status.
        guard let downloadTask = await MainActor.run(body: {
            modelDownloadManager.getDownloadStatus(downloadId: downloadId)
        }) else {
            let errorResponse: [String: Any] = ["error": "Download not found"]
            let jsonData = try JSONSerialization.data(withJSONObject: errorResponse)
            return Response(status: .notFound, headers: ["Content-Type": "application/json"], body: .init(data: jsonData))
        }

        /// Build status response.
        let statusResponse = ModelDownloadStatus(
            downloadId: downloadTask.id,
            status: downloadTask.status,
            progress: downloadTask.progress,
            bytesDownloaded: downloadTask.bytesDownloaded,
            totalBytes: downloadTask.totalBytes,
            downloadSpeed: nil,
            eta: nil,
            error: downloadTask.status == "failed" ? "Download failed" : nil
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        let jsonData = try encoder.encode(statusResponse)

        return Response(status: .ok, headers: ["Content-Type": "application/json"], body: .init(data: jsonData))
    }

    private func handleCancelDownload(_ req: Request) async throws -> Response {
        guard let downloadId = req.parameters.get("downloadId") else {
            let errorResponse: [String: Any] = ["error": "Download ID parameter is required"]
            let jsonData = try JSONSerialization.data(withJSONObject: errorResponse)
            return Response(status: .badRequest, headers: ["Content-Type": "application/json"], body: .init(data: jsonData))
        }

        logger.debug("Cancelling download: \(downloadId)")

        /// Cancel download.
        await MainActor.run {
            modelDownloadManager.cancelDownload(downloadId: downloadId)
        }

        let response = ModelDownloadCancelResponse(
            downloadId: downloadId,
            status: "cancelled",
            message: "Download cancelled successfully"
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        let jsonData = try encoder.encode(response)

        return Response(status: .ok, headers: ["Content-Type": "application/json"], body: .init(data: jsonData))
    }

    // MARK: - Prompt Discovery Endpoints

    /// Handle GET /api/prompts/system - list all system prompts available Returns array of system prompts with id, name, and description Used by agents to discover available prompts for run_subagent tool.
    private func handleListSystemPrompts(_ req: Request) async throws -> Response {
        logger.debug("Listing system prompts")

        /// Get all system prompts from manager (defaults + user-created).
        let systemPromptManager = SystemPromptManager.shared
        let allPrompts = await MainActor.run {
            systemPromptManager.allConfigurations
        }

        /// Map to simple response format.
        let promptList = allPrompts.map { prompt in
            [
                "id": prompt.id.uuidString,
                "name": prompt.name,
                "description": prompt.description ?? ""
            ]
        }

        let response = ["prompts": promptList]
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        let jsonData = try encoder.encode(response)

        return Response(status: .ok, headers: ["Content-Type": "application/json"], body: .init(data: jsonData))
    }

    /// Handle GET /api/topics - list all available topic folders from reference/ directory
    private func handleListTopics(_ req: Request) async throws -> Response {
        logger.debug("Listing available shared topics")

        do {
            /// Get topics from database
            let sharedTopics = try sharedTopicManager.listTopics()

            /// Map to API response format
            let topics = sharedTopics.map { topic in
                [
                    "id": topic.id,
                    "name": topic.name,
                    "description": topic.description ?? ""
                ]
            }

            let response = ["topics": topics]
            let encoder = JSONEncoder()
            encoder.outputFormatting = .prettyPrinted
            let jsonData = try encoder.encode(response)

            return Response(status: .ok, headers: ["Content-Type": "application/json"], body: .init(data: jsonData))
        } catch {
            logger.error("Failed to list shared topics: \(error)")
            let errorResponse: [String: Any] = ["error": error.localizedDescription]
            let jsonData = try JSONSerialization.data(withJSONObject: errorResponse)
            return Response(status: .internalServerError, headers: ["Content-Type": "application/json"], body: .init(data: jsonData))
        }
    }

    /// Helper method to look up SharedTopic by name
    private func findSharedTopicByName(_ topicName: String) throws -> SharedTopic? {
        let topics = try sharedTopicManager.listTopics()
        return topics.first(where: { $0.name == topicName })
    }

    /// Handle GET /api/prompts/mini - list all mini-prompts available Returns array of mini-prompts with id, name, and content Used by agents to discover available contextual prompts.
    private func handleListMiniPrompts(_ req: Request) async throws -> Response {
        logger.debug("Listing mini-prompts")

        /// Get all mini-prompts from manager.
        let miniPromptManager = MiniPromptManager.shared
        let allMiniPrompts = await MainActor.run {
            miniPromptManager.miniPrompts
        }

        /// Map to response format.
        let promptList = allMiniPrompts.map { prompt in
            [
                "id": prompt.id.uuidString,
                "name": prompt.name,
                "content": prompt.content
            ]
        }

        let response = ["prompts": promptList]
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        let jsonData = try encoder.encode(response)

        return Response(status: .ok, headers: ["Content-Type": "application/json"], body: .init(data: jsonData))
    }

    /// Handle GET /api/personalities - list all available personalities
    /// Returns array of personalities with id, name, description, category, and isDefault
    /// Used by web interface and external agents to discover personality options
    private func handleListPersonalities(_ req: Request) async throws -> Response {
        logger.debug("Listing personalities")

        /// Get all personalities from manager (defaults + user-created).
        let personalityManager = PersonalityManager.shared
        let allPersonalities = await MainActor.run {
            personalityManager.getAllPersonalities()
        }

        /// Map to simple response format.
        let personalityList = allPersonalities.map { personality in
            [
                "id": personality.id.uuidString,
                "name": personality.name,
                "description": personality.description,
                "category": personality.category.rawValue,
                "isDefault": personality.isDefault
            ] as [String: Any]
        }

        let response = ["personalities": personalityList]
        let jsonData = try JSONSerialization.data(withJSONObject: response, options: .prettyPrinted)

        return Response(status: .ok, headers: ["Content-Type": "application/json"], body: .init(data: jsonData))
    }

    /// Handle GET /api/preferences - return user's default preferences
    /// Returns default model, system prompt, and personality selections
    private func handleGetPreferences(_ req: Request) async throws -> Response {
        logger.debug("Getting user preferences")

        let defaultModel = UserDefaults.standard.string(forKey: "defaultModel") ?? ""
        let defaultSystemPromptId = UserDefaults.standard.string(forKey: "defaultSystemPromptId") ?? "00000000-0000-0000-0000-000000000001"
        let defaultPersonalityId = UserDefaults.standard.string(forKey: "defaultPersonalityId") ?? "00000000-0000-0000-0000-000000000001"

        let response: [String: Any] = [
            "defaultModel": defaultModel,
            "defaultSystemPromptId": defaultSystemPromptId,
            "defaultPersonalityId": defaultPersonalityId
        ]

        let jsonData = try JSONSerialization.data(withJSONObject: response, options: .prettyPrinted)
        return Response(status: .ok, headers: ["Content-Type": "application/json"], body: .init(data: jsonData))
    }

    /// Handle GET /api/github-copilot/quota - return GitHub Copilot quota information
    /// Returns current usage and entitlement for GitHub Copilot models
    /// Prioritizes CopilotUserAPI for richer data, falls back to header-based tracking
    private func handleGetGitHubCopilotQuota(_ req: Request) async throws -> Response {
        logger.debug("Getting GitHub Copilot quota information")

        // Check for force refresh query parameter
        let forceRefresh = req.url.query?.contains("refresh=true") ?? false
        
        // Try CopilotUserAPI first (richer data, pre-request check)
        do {
            let token = try await CopilotTokenStore.shared.getCopilotToken()
            let userResponse = try await CopilotUserAPIClient.shared.fetchUser(token: token, forceRefresh: forceRefresh)
            
            if let premium = userResponse.premiumQuota {
                let response: [String: Any] = [
                    "available": true,
                    "source": "user_api",
                    "login": userResponse.login ?? "unknown",
                    "plan": userResponse.copilotPlan ?? "unknown",
                    "entitlement": premium.entitlement,
                    "used": premium.used,
                    "remaining": premium.remaining,
                    "percentUsed": premium.percentUsed,
                    "percentRemaining": premium.percentRemaining,
                    "overageCount": premium.overageCount ?? 0,
                    "overagePermitted": premium.overagePermitted ?? false,
                    "unlimited": premium.unlimited,
                    "resetDate": userResponse.quotaResetDateUTC ?? "unknown"
                ]
                let jsonData = try JSONSerialization.data(withJSONObject: response, options: .prettyPrinted)
                return Response(status: .ok, headers: ["Content-Type": "application/json"], body: .init(data: jsonData))
            }
        } catch {
            logger.debug("CopilotUserAPI unavailable, falling back to header-based quota: \(error.localizedDescription)")
        }
        
        // Fall back to header-based quota info
        guard let quotaInfo = endpointManager.getGitHubCopilotQuotaInfo() else {
            let response: [String: Any] = ["available": false, "reason": "No quota information available. Make an API call first or authenticate with GitHub."]
            let jsonData = try JSONSerialization.data(withJSONObject: response, options: .prettyPrinted)
            return Response(status: .ok, headers: ["Content-Type": "application/json"], body: .init(data: jsonData))
        }

        let percentUsed = 100.0 - quotaInfo.percentRemaining

        var response: [String: Any] = [
            "available": true,
            "source": "response_headers",
            "entitlement": quotaInfo.entitlement,
            "used": quotaInfo.used,
            "percentUsed": percentUsed,
            "percentRemaining": quotaInfo.percentRemaining,
            "resetDate": quotaInfo.resetDate
        ]
        
        // Include enhanced fields if available
        if let login = quotaInfo.login {
            response["login"] = login
        }
        if let plan = quotaInfo.copilotPlan {
            response["plan"] = plan
        }
        if let overageCount = quotaInfo.overageCount {
            response["overageCount"] = overageCount
        }

        let jsonData = try JSONSerialization.data(withJSONObject: response, options: .prettyPrinted)
        return Response(status: .ok, headers: ["Content-Type": "application/json"], body: .init(data: jsonData))
    }

    // MARK: - Folder Management Endpoints

    /// Folder response structure for API
    private struct FolderResponse: Codable, Sendable {
        let id: String
        let name: String
        let color: String
        let icon: String
        let isCollapsed: Bool
    }

    /// Handle GET /api/folders - list all folders
    private func handleListFolders(_ req: Request) async throws -> Response {
        logger.debug("Listing folders")

        let folders = await MainActor.run {
            folderManager.folders.map { folder in
                FolderResponse(
                    id: folder.id,
                    name: folder.name,
                    color: folder.color ?? "",
                    icon: folder.icon ?? "",
                    isCollapsed: folder.isCollapsed
                )
            }
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        let jsonData = try encoder.encode(["folders": folders])
        return Response(status: .ok, headers: ["Content-Type": "application/json"], body: .init(data: jsonData))
    }

    /// Handle POST /api/folders - create a new folder
    private func handleCreateFolder(_ req: Request) async throws -> Response {
        logger.debug("Creating folder")

        struct CreateFolderRequest: Codable {
            var name: String
            var color: String?
            var icon: String?
        }

        let createRequest = try req.content.decode(CreateFolderRequest.self)

        let folder = await MainActor.run {
            folderManager.createFolder(name: createRequest.name, color: createRequest.color, icon: createRequest.icon)
        }

        let response = FolderResponse(
            id: folder.id,
            name: folder.name,
            color: folder.color ?? "",
            icon: folder.icon ?? "",
            isCollapsed: folder.isCollapsed
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        let jsonData = try encoder.encode(response)
        return Response(status: .ok, headers: ["Content-Type": "application/json"], body: .init(data: jsonData))
    }

    /// Handle PATCH /api/folders/:folderId - update folder
    private func handleUpdateFolder(_ req: Request) async throws -> Response {
        guard let folderId = req.parameters.get("folderId") else {
            throw Abort(.badRequest, reason: "Missing folder ID")
        }

        logger.debug("Updating folder: \(folderId)")

        struct UpdateFolderRequest: Codable {
            var name: String?
            var color: String?
            var icon: String?
            var isCollapsed: Bool?
        }

        let updateRequest = try req.content.decode(UpdateFolderRequest.self)

        let updated = await MainActor.run { () -> Bool in
            guard var folder = folderManager.getFolder(by: folderId) else {
                return false
            }

            if let name = updateRequest.name {
                folder.name = name
            }
            if let color = updateRequest.color {
                folder.color = color
            }
            if let icon = updateRequest.icon {
                folder.icon = icon
            }
            if let isCollapsed = updateRequest.isCollapsed {
                folder.isCollapsed = isCollapsed
            }

            folderManager.updateFolder(folder)
            return true
        }

        guard updated else {
            throw Abort(.notFound, reason: "Folder not found")
        }

        return Response(status: .ok, headers: ["Content-Type": "application/json"], body: .init(string: "{\"success\": true}"))
    }

    /// Handle DELETE /api/folders/:folderId - delete folder
    private func handleDeleteFolder(_ req: Request) async throws -> Response {
        guard let folderId = req.parameters.get("folderId") else {
            throw Abort(.badRequest, reason: "Missing folder ID")
        }

        logger.debug("Deleting folder: \(folderId)")

        await MainActor.run {
            folderManager.deleteFolder(folderId)
        }

        return Response(status: .ok, headers: ["Content-Type": "application/json"], body: .init(string: "{\"success\": true}"))
    }

    // MARK: - Model Management

    private func handleListInstalledModels(_ req: Request) async throws -> Response {
        logger.debug("Listing installed models")

        /// Get installed models from manager.
        let installedModels = await MainActor.run {
            modelDownloadManager.installedModels.map { model in
                InstalledModelInfo(
                    id: model.id,
                    name: model.name,
                    provider: model.provider ?? "unknown",
                    path: model.path,
                    sizeBytes: model.sizeBytes,
                    quantization: model.quantization
                )
            }
        }

        let response = InstalledModelsResponse(models: installedModels)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        let jsonData = try encoder.encode(response)

        return Response(status: .ok, headers: ["Content-Type": "application/json"], body: .init(data: jsonData))
    }

    // MARK: - Tool Result Retrieval

    /// Handle GET /api/tool_result - retrieve persisted tool result chunks Query parameters: - conversationId (required): Conversation owning the result - toolCallId (required): Tool call identifier - offset (optional): Character offset to start reading from (default: 0) - length (optional): Number of characters to read (default: 8192, max: 32768) Returns JSON with chunk content and pagination metadata.
    private func handleGetToolResult(_ req: Request) async throws -> Response {
        logger.debug("Tool result retrieval requested")

        /// Extract query parameters.
        guard let conversationIdString = try? req.query.get(String.self, at: "conversationId"),
              let conversationId = UUID(uuidString: conversationIdString) else {
            throw Abort(.badRequest, reason: "Missing or invalid conversationId query parameter")
        }

        guard let toolCallId = try? req.query.get(String.self, at: "toolCallId") else {
            throw Abort(.badRequest, reason: "Missing toolCallId query parameter")
        }

        let offset = (try? req.query.get(Int.self, at: "offset")) ?? 0
        let requestedLength = (try? req.query.get(Int.self, at: "length")) ?? 8192

        /// Enforce maximum chunk size.
        let maxChunkSize = 32_768
        let length = min(requestedLength, maxChunkSize)

        logger.debug("Retrieving tool result: conversationId=\(conversationId), toolCallId=\(toolCallId), offset=\(offset), length=\(length)")

        /// SECURITY: Verify conversation exists and user has access For now, we trust the conversationId (no user authentication) In production, this should check user session and conversation ownership.

        /// Retrieve chunk from storage.
        do {
            let chunk = try toolResultStorage.retrieveChunk(
                toolCallId: toolCallId,
                conversationId: conversationId,
                offset: offset,
                length: length
            )

            /// Format response.
            let response: [String: Any] = [
                "toolCallId": chunk.toolCallId,
                "offset": chunk.offset,
                "length": chunk.length,
                "totalLength": chunk.totalLength,
                "content": chunk.content,
                "nextOffset": chunk.nextOffset as Any,
                "hasMore": chunk.hasMore,
                "metadata": [
                    "mimeType": "text/plain"
                ]
            ]

            let jsonData = try JSONSerialization.data(withJSONObject: response, options: .prettyPrinted)
            return Response(
                status: .ok,
                headers: ["Content-Type": "application/json"],
                body: .init(data: jsonData)
            )

        } catch ToolResultStorageError.resultNotFound(let toolCallId) {
            logger.warning("Tool result not found: \(toolCallId)")
            throw Abort(.notFound, reason: "Tool result not found: \(toolCallId)")

        } catch ToolResultStorageError.invalidOffset(let offset, let totalLength) {
            logger.warning("Invalid offset: \(offset) for result with length \(totalLength)")
            throw Abort(.badRequest, reason: "Invalid offset \(offset) (total length: \(totalLength))")

        } catch {
            logger.error("Failed to retrieve tool result: \(error)")
            throw Abort(.internalServerError, reason: "Failed to retrieve tool result: \(error.localizedDescription)")
        }
    }

    // MARK: - Model Name Normalization

    /// Normalize model name to match provider format
    /// Handles two cases:
    /// 1. Model names with provider prefix already (e.g., "github_copilot/gpt-4.1") - return as-is
    /// 2. Model names without prefix (e.g., "gpt-4") - try to match with known providers
    /// 
    /// IMPORTANT: Do NOT transform underscores within model names that already have provider prefixes.
    /// Example: "github_copilot/gpt-4.1" should stay "github_copilot/gpt-4.1", NOT become "github/copilot/gpt-4.1"
    private func normalizeModelName(_ modelName: String) -> String {
        /// If model already has a slash (provider/model format), return as-is
        /// This preserves model names like "github_copilot/gpt-4.1" exactly
        if modelName.contains("/") {
            return modelName
        }

        /// Model lacks provider prefix - try to match with known providers
        /// This handles API requests like "gpt-4" that need to become "github_copilot/gpt-4" for UI.
        let modelWithoutPrefix = modelName

        /// Check each provider type to see if this model belongs to it
        /// Priority order: github_copilot, openai, anthropic, deepseek, custom.
        let providerPrefixes = [
            "github_copilot",
            "openai",
            "anthropic",
            "deepseek",
            "custom"
        ]

        for prefix in providerPrefixes {
            let prefixedModel = "\(prefix)/\(modelWithoutPrefix)"
            /// Check if this prefixed model matches any known models
            /// This is a simple heuristic - could be enhanced with actual model registry lookup.
            if prefix == "github_copilot" && (modelWithoutPrefix.hasPrefix("gpt-") || modelWithoutPrefix.hasPrefix("o1")) {
                logger.debug("Normalized model '\(modelName)' → '\(prefixedModel)' (matched GitHub Copilot pattern)")
                return prefixedModel
            } else if prefix == "openai" && (modelWithoutPrefix.hasPrefix("gpt-") || modelWithoutPrefix.hasPrefix("o1")) {
                logger.debug("Normalized model '\(modelName)' → '\(prefixedModel)' (matched OpenAI pattern)")
                return prefixedModel
            } else if prefix == "anthropic" && modelWithoutPrefix.hasPrefix("claude-") {
                logger.debug("Normalized model '\(modelName)' → '\(prefixedModel)' (matched Anthropic pattern)")
                return prefixedModel
            } else if prefix == "deepseek" && modelWithoutPrefix.hasPrefix("deepseek-") {
                logger.debug("Normalized model '\(modelName)' → '\(prefixedModel)' (matched DeepSeek pattern)")
                return prefixedModel
            }
        }

        /// If no provider matched, return original model name as-is (might be a local model)
        logger.debug("Model '\(modelName)' doesn't match known provider patterns, using as-is")
        return modelName
    }

    /// Enable mini-prompts for a conversation by name
    @MainActor
    private func enableMiniPromptsForConversation(_ conversation: ConversationModel, miniPromptNames: [String]) {
        let miniPromptManager = MiniPromptManager.shared
        let allMiniPrompts = miniPromptManager.miniPrompts

        for name in miniPromptNames {
            if let miniPrompt = allMiniPrompts.first(where: { $0.name.lowercased() == name.lowercased() }) {
                conversation.enabledMiniPromptIds.insert(miniPrompt.id)
                logger.debug("Enabled mini-prompt '\(name)' for conversation \(conversation.id)")
            } else {
                logger.warning("Mini-prompt '\(name)' not found, skipping")
            }
        }
    }

    // MARK: - Shared Topics API Handlers

    /// Response model for shared topic
    private struct SharedTopicResponse: Codable {
        let id: String
        let name: String
        let description: String?
    }

    /// Handle GET /api/shared-topics - list all shared topics
    private func handleListSharedTopics(_ req: Request) async throws -> Response {
        logger.debug("Listing shared topics")

        let topics = try sharedTopicManager.listTopics()

        let responses = topics.map { topic in
            SharedTopicResponse(
                id: topic.id,
                name: topic.name,
                description: topic.description
            )
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        let jsonData = try encoder.encode(["topics": responses])
        return Response(status: .ok, headers: ["Content-Type": "application/json"], body: .init(data: jsonData))
    }

    /// Handle POST /api/shared-topics - create a new shared topic
    private func handleCreateSharedTopic(_ req: Request) async throws -> Response {
        logger.debug("Creating shared topic")

        struct CreateTopicRequest: Codable {
            var name: String
            var description: String?
        }

        let createRequest = try req.content.decode(CreateTopicRequest.self)

        let topic = try sharedTopicManager.createTopic(
            name: createRequest.name,
            description: createRequest.description
        )

        let response = SharedTopicResponse(
            id: topic.id,
            name: topic.name,
            description: topic.description
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        let jsonData = try encoder.encode(response)
        return Response(status: .ok, headers: ["Content-Type": "application/json"], body: .init(data: jsonData))
    }

    /// Handle PATCH /api/shared-topics/:topicId - update shared topic
    private func handleUpdateSharedTopic(_ req: Request) async throws -> Response {
        guard let topicIdString = req.parameters.get("topicId"),
              let topicId = UUID(uuidString: topicIdString) else {
            throw Abort(.badRequest, reason: "Invalid topic ID")
        }

        logger.debug("Updating shared topic: \(topicIdString)")

        struct UpdateTopicRequest: Codable {
            var name: String?
            var description: String?
        }

        let updateRequest = try req.content.decode(UpdateTopicRequest.self)

        // Get current topic to preserve fields not being updated
        let topics = try sharedTopicManager.listTopics()
        guard let currentTopic = topics.first(where: { $0.id == topicIdString }) else {
            throw Abort(.notFound, reason: "Topic not found")
        }

        let newName = updateRequest.name ?? currentTopic.name
        let newDescription = updateRequest.description ?? currentTopic.description

        try sharedTopicManager.updateTopic(
            id: topicId,
            name: newName,
            description: newDescription
        )

        return Response(status: .ok, headers: ["Content-Type": "application/json"], body: .init(string: "{\"success\": true}"))
    }

    /// Handle DELETE /api/shared-topics/:topicId - delete shared topic
    private func handleDeleteSharedTopic(_ req: Request) async throws -> Response {
        guard let topicIdString = req.parameters.get("topicId"),
              let topicId = UUID(uuidString: topicIdString) else {
            throw Abort(.badRequest, reason: "Invalid topic ID")
        }

        logger.debug("Deleting shared topic: \(topicIdString)")

        try sharedTopicManager.deleteTopic(id: topicId)

        return Response(status: .ok, headers: ["Content-Type": "application/json"], body: .init(string: "{\"success\": true}"))
    }

    /// Handle POST /v1/conversations/:conversationId/attach-topic - attach conversation to shared topic
    private func handleAttachSharedTopic(_ req: Request) async throws -> Response {
        guard let conversationId = req.parameters.get("conversationId") else {
            throw Abort(.badRequest, reason: "Missing conversation ID")
        }

        logger.debug("Attaching shared topic to conversation: \(conversationId)")

        struct AttachTopicRequest: Codable {
            var topicId: String
        }

        let attachRequest = try req.content.decode(AttachTopicRequest.self)
        guard let topicUUID = UUID(uuidString: attachRequest.topicId) else {
            throw Abort(.badRequest, reason: "Invalid topic ID format")
        }

        // Verify topic exists
        let topics = try sharedTopicManager.listTopics()
        guard let topic = topics.first(where: { $0.id == attachRequest.topicId }) else {
            throw Abort(.notFound, reason: "Topic not found")
        }

        // Attach topic to conversation via ConversationManager
        await MainActor.run {
            if let conversation = conversationManager.conversations.first(where: { $0.id.uuidString == conversationId }) {
                conversationManager.attachSharedTopic(topicId: topicUUID, topicName: topic.name)
                logger.debug("Attached topic \(topic.name) to conversation \(conversationId)")
            } else {
                logger.warning("Conversation \(conversationId) not found")
            }
        }

        return Response(status: .ok, headers: ["Content-Type": "application/json"], body: .init(string: "{\"success\": true}"))
    }

    /// Handle POST /v1/conversations/:conversationId/detach-topic - detach conversation from shared topic
    private func handleDetachSharedTopic(_ req: Request) async throws -> Response {
        guard let conversationId = req.parameters.get("conversationId") else {
            throw Abort(.badRequest, reason: "Missing conversation ID")
        }

        logger.debug("Detaching shared topic from conversation: \(conversationId)")

        // Detach topic via ConversationManager
        await MainActor.run {
            if conversationManager.conversations.contains(where: { $0.id.uuidString == conversationId }) {
                conversationManager.attachSharedTopic(topicId: nil, topicName: nil)
                logger.debug("Detached topic from conversation \(conversationId)")
            } else {
                logger.warning("Conversation \(conversationId) not found")
            }
        }

        return Response(status: .ok, headers: ["Content-Type": "application/json"], body: .init(string: "{\"success\": true}"))
    }

    // MARK: - Mini-Prompt Management API Handlers

    /// Response model for mini-prompt
    private struct MiniPromptResponse: Codable {
        let id: String
        let name: String
        let content: String
        let createdAt: String
        let modifiedAt: String
        let displayOrder: Int
    }

    /// Handle POST /api/mini-prompts - create a new mini-prompt
    private func handleCreateMiniPrompt(_ req: Request) async throws -> Response {
        logger.debug("Creating mini-prompt")

        struct CreateMiniPromptRequest: Codable {
            var name: String
            var content: String
            var displayOrder: Int?
        }

        let createRequest = try req.content.decode(CreateMiniPromptRequest.self)

        let miniPrompt = MiniPrompt(
            name: createRequest.name,
            content: createRequest.content,
            displayOrder: createRequest.displayOrder ?? 0
        )

        await MainActor.run {
            MiniPromptManager.shared.addPrompt(miniPrompt)
        }

        let formatter = ISO8601DateFormatter()
        let response = MiniPromptResponse(
            id: miniPrompt.id.uuidString,
            name: miniPrompt.name,
            content: miniPrompt.content,
            createdAt: formatter.string(from: miniPrompt.createdAt),
            modifiedAt: formatter.string(from: miniPrompt.modifiedAt),
            displayOrder: miniPrompt.displayOrder
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        let jsonData = try encoder.encode(response)
        return Response(status: .ok, headers: ["Content-Type": "application/json"], body: .init(data: jsonData))
    }

    /// Handle PATCH /api/mini-prompts/:promptId - update mini-prompt
    private func handleUpdateMiniPrompt(_ req: Request) async throws -> Response {
        guard let promptIdString = req.parameters.get("promptId"),
              let promptId = UUID(uuidString: promptIdString) else {
            throw Abort(.badRequest, reason: "Invalid prompt ID")
        }

        logger.debug("Updating mini-prompt: \(promptIdString)")

        struct UpdateMiniPromptRequest: Codable {
            var name: String?
            var content: String?
            var displayOrder: Int?
        }

        let updateRequest = try req.content.decode(UpdateMiniPromptRequest.self)

        let updated = await MainActor.run { () -> Bool in
            guard let prompt = MiniPromptManager.shared.miniPrompts.first(where: { $0.id == promptId }) else {
                return false
            }

            var updatedPrompt = prompt
            if let name = updateRequest.name {
                updatedPrompt.name = name
            }
            if let content = updateRequest.content {
                updatedPrompt.content = content
            }
            if let displayOrder = updateRequest.displayOrder {
                updatedPrompt.displayOrder = displayOrder
            }
            updatedPrompt.modifiedAt = Date()

            MiniPromptManager.shared.updatePrompt(updatedPrompt)
            return true
        }

        guard updated else {
            throw Abort(.notFound, reason: "Mini-prompt not found")
        }

        return Response(status: .ok, headers: ["Content-Type": "application/json"], body: .init(string: "{\"success\": true}"))
    }

    /// Handle DELETE /api/mini-prompts/:promptId - delete mini-prompt
    private func handleDeleteMiniPrompt(_ req: Request) async throws -> Response {
        guard let promptIdString = req.parameters.get("promptId"),
              let promptId = UUID(uuidString: promptIdString) else {
            throw Abort(.badRequest, reason: "Invalid prompt ID")
        }

        logger.debug("Deleting mini-prompt: \(promptIdString)")

        await MainActor.run {
            MiniPromptManager.shared.deletePrompt(id: promptId)
        }

        return Response(status: .ok, headers: ["Content-Type": "application/json"], body: .init(string: "{\"success\": true}"))
    }
}
