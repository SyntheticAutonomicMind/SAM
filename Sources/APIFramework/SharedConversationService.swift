// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import Foundation
import ConversationEngine
import MCPFramework
import Logging

@MainActor
public class SharedConversationService: ObservableObject {
    private let logger = Logging.Logger(label: "com.sam.sharedservice")

    private let conversationManager: ConversationManager

    public init(conversationManager: ConversationManager) {
        self.conversationManager = conversationManager
        logger.debug("SharedConversationService initialized")
    }

    /// Inject available MCP tools into the request for both UI and API consistency MCP Tool Injection System - CRITICAL BRIDGE BETWEEN SAM AND EXTERNAL LLM PROVIDERS ARCHITECTURE PURPOSE: This method bridges SAM's internal MCP (Model Context Protocol) tool ecosystem with external LLM providers like GitHub Copilot.
    public func injectMCPToolsIntoRequest(_ request: OpenAIChatRequest) async -> OpenAIChatRequest {
        logger.debug("SHARED_SERVICE: Starting MCP tool injection")

        /// Get available MCP tools from ConversationManager.
        let availableTools = conversationManager.getAvailableMCPTools()

        logger.debug("SHARED_SERVICE: Found \(availableTools.count) available MCP tools")

        /// Filter out user_collaboration tool for external API calls. User collaboration requires interactive UI (SSE events, user input) which external APIs cannot provide. This includes: - Any request with isExternalAPICall=true (set by caller) - Autonomous Worker mode (system prompt UUID 00000000-0000-0000-0000-000000000002). For internal SAM usage (UI-based conversations), user_collaboration works normally.
        let shouldFilterUserCollaboration = request.samConfig?.isExternalAPICall == true || {
            if let systemPromptId = request.samConfig?.systemPromptId {
                let autonomousWorkerUUID = "00000000-0000-0000-0000-000000000002"
                return systemPromptId == "autonomous_editor" || systemPromptId == "autonomous_worker" || systemPromptId == autonomousWorkerUUID
            }
            return false
        }()


        var filteredTools = availableTools

        if shouldFilterUserCollaboration {
            logger.debug("SHARED_SERVICE: Filtering user_collaboration (isExternalAPICall=\(request.samConfig?.isExternalAPICall == true), autonomous mode)")
            filteredTools = filteredTools.filter { $0.name != "user_collaboration" }
            logger.debug("SHARED_SERVICE: Filtered \(availableTools.count) -> \(filteredTools.count) tools")
        }


        /// ALWAYS INJECT ALL TOOLS - Dynamic injection causes performance issues Models need full tool context to function properly Previous experiment with dynamic injection showed: - Llama-2-7B: Completely broken (garbage output) - Qwen models: Worked but slower - GPT-4: Worked but added latency Conclusion: Always send all tools for consistent, fast behavior.

        logger.info("TOOL_INJECTION: Injecting \(filteredTools.count) tools for model \(request.model)")

        for tool in filteredTools {
            logger.debug("SHARED_SERVICE: Available tool: \(tool.name)")
        }

        /// If no tools available or tools already defined in request, return as-is.
        if filteredTools.isEmpty || request.tools != nil {
            logger.debug("SHARED_SERVICE: No tool injection needed (available: \(filteredTools.count), existing: \(request.tools?.count ?? 0))")
            return request
        }

        /// Check if MCP tools are explicitly disabled via samConfig This allows pre-loading and other special requests to opt-out of tool injection.
        logger.debug("SHARED_SERVICE: Checking samConfig.mcpToolsEnabled: \(request.samConfig?.mcpToolsEnabled?.description ?? "nil")")
        if let mcpToolsEnabled = request.samConfig?.mcpToolsEnabled, !mcpToolsEnabled {
            logger.debug("SHARED_SERVICE: MCP tools explicitly disabled via samConfig (mcpToolsEnabled=false)")
            return request
        }

        /// Convert MCP tools to OpenAI tool definitions.
        let openAITools = filteredTools.map { mcpTool in
            /// Convert MCP parameter definitions to OpenAI format.
            let properties = mcpTool.parameters.reduce(into: [String: [String: Any]]()) { result, param in
                let (paramName, paramDef) = param

                let description = paramDef.description

                var paramSpec: [String: Any] = [
                    "type": paramDef.type.description,
                    "description": description
                ]

                if let enumValues = paramDef.enumValues {
                    paramSpec["enum"] = enumValues
                }

                /// Handle array types with arrayElementType (GitHub Copilot requires "items" property).
                if case .array = paramDef.type, let arrayElementType = paramDef.arrayElementType {
                    paramSpec["items"] = convertMCPParameterTypeToOpenAI(arrayElementType)
                }

                result[paramName] = paramSpec
            }

            let requiredParams = mcpTool.parameters.compactMap { param in
                param.value.required ? param.key : nil
            }

            let openAIParameters: [String: Any] = [
                "type": "object",
                "properties": properties,
                "required": requiredParams
            ]

            return OpenAITool(
                type: "function",
                function: OpenAIFunction(
                    name: mcpTool.name,
                    description: mcpTool.description,
                    parameters: openAIParameters
                )
            )
        }

        logger.debug("SHARED_SERVICE: Injecting \(openAITools.count) MCP tools into request for model: \(request.model)")

        /// Debug: Log tool injection details.
        for (index, tool) in openAITools.enumerated() {
            logger.debug("SHARED_SERVICE: Injecting tool \(index + 1): \(tool.function.name)")
        }

        /// Create enhanced request with MCP tools.
        let enhancedRequest = OpenAIChatRequest(
            model: request.model,
            messages: request.messages,
            temperature: request.temperature,
            topP: request.topP,
            repetitionPenalty: request.repetitionPenalty,
            maxTokens: request.maxTokens,
            stream: request.stream,
            tools: openAITools,
            samConfig: request.samConfig,
            contextId: request.contextId,
            enableMemory: request.enableMemory,
            sessionId: request.sessionId,
            conversationId: request.conversationId,
            statefulMarker: request.statefulMarker,
            iterationNumber: request.iterationNumber
        )

        /// Debug: Log final request details.
        logger.debug("SHARED_SERVICE: Enhanced request created - Model: \(enhancedRequest.model), Tools: \(enhancedRequest.tools?.count ?? 0), Stream: \(String(describing: enhancedRequest.stream))")
        if let lastMessage = enhancedRequest.messages.last,
           let content = lastMessage.content {
            logger.debug("SHARED_SERVICE: Last message content: \(String(content.prefix(100)))")
        }

        return enhancedRequest
    }

    /// Convert MCPParameterType to OpenAI JSON schema format This handles the conversion of complex MCP types (arrays, objects) to proper OpenAI tool definitions.
    private func convertMCPParameterTypeToOpenAI(_ paramType: MCPParameterType) -> [String: Any] {
        switch paramType {
        case .string:
            return ["type": "string"]

        case .integer:
            return ["type": "integer"]

        case .boolean:
            return ["type": "boolean"]

        case .number:
            return ["type": "number"]

        case .array:
            return ["type": "array"]

        case .object(let properties):
            /// Convert object properties to OpenAI format.
            let openAIProperties = properties.reduce(into: [String: [String: Any]]()) { result, property in
                let (propName, propDef) = property
                var propSpec: [String: Any] = [
                    "type": propDef.type.description,
                    "description": propDef.description
                ]

                if let enumValues = propDef.enumValues {
                    propSpec["enum"] = enumValues
                }

                /// Handle nested arrays/objects recursively.
                if case .array = propDef.type, let arrayElementType = propDef.arrayElementType {
                    propSpec["items"] = convertMCPParameterTypeToOpenAI(arrayElementType)
                }

                result[propName] = propSpec
            }

            /// Get required properties for this object.
            let requiredProps = properties.compactMap { prop in
                prop.value.required ? prop.key : nil
            }

            var objectSchema: [String: Any] = [
                "type": "object",
                "properties": openAIProperties
            ]

            if !requiredProps.isEmpty {
                objectSchema["required"] = requiredProps
            }

            return objectSchema
        }
    }
}
