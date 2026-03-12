// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import Foundation
import Logging
import ConversationEngine
import MCPFramework
import ConfigurationSystem

// MARK: - Tool Execution

extension AgentOrchestrator {

    /// Parses todo list from manage_todo_list tool result Extracts structured todo items for autonomous execution.
    func parseTodoList(from toolResult: String) -> [TodoItem] {
        logger.debug("parseTodoList: Attempting to parse todo list from tool result")

        var todos: [TodoItem] = []

        /// The tool returns a formatted string, but we need to call manage_todo_list with operation=read to get the actual structured data.

        let lines = toolResult.components(separatedBy: "\n")
        var currentId: Int?
        var currentTitle: String?
        var currentDescription: String?
        var currentStatus: String = "not-started"

        for line in lines {
            let trimmedLine = line.trimmingCharacters(in: .whitespaces)

            /// Detect status sections.
            if trimmedLine.contains("NOT STARTED:") {
                currentStatus = "not-started"
                continue
            } else if trimmedLine.contains("IN PROGRESS:") {
                currentStatus = "in-progress"
                continue
            } else if trimmedLine.contains("COMPLETED:") {
                currentStatus = "completed"
                continue
            }

            /// Parse todo items (format: " 1.
            if let regex = try? NSRegularExpression(pattern: #"^\s*(\d+)\.\s+(.+)$"#, options: []),
               let match = regex.firstMatch(in: line, options: [], range: NSRange(line.startIndex..., in: line)) {

                /// Save previous todo if exists.
                if let id = currentId, let title = currentTitle {
                    todos.append(TodoItem(
                        id: id,
                        title: title,
                        description: currentDescription ?? "",
                        status: currentStatus
                    ))
                }

                /// Extract new todo.
                if let idRange = Range(match.range(at: 1), in: line),
                   let titleRange = Range(match.range(at: 2), in: line) {
                    currentId = Int(line[idRange])
                    currentTitle = String(line[titleRange])
                    currentDescription = nil
                }
            }
            /// Parse description lines (format: " → Description").
            else if trimmedLine.hasPrefix("→") {
                let desc = trimmedLine.dropFirst(1).trimmingCharacters(in: .whitespaces)
                currentDescription = (currentDescription ?? "") + desc
            }
        }

        /// Save last todo.
        if let id = currentId, let title = currentTitle {
            todos.append(TodoItem(
                id: id,
                title: title,
                description: currentDescription ?? "",
                status: currentStatus
            ))
        }

        logger.debug("parseTodoList: Parsed \(todos.count) todo items")
        return todos
    }

    // MARK: - Properties

    /// Filters internal markers from response text before displaying to user.
    func filterInternalMarkersNoTrim(from text: String) -> String {
        /// Match JSON status markers on their own lines
        let jsonLinePattern = try? NSRegularExpression(
            pattern: #"^\s*\{\s*"status"\s*:\s*"(stop|continue|complete)"\s*\}\s*$"#,
            options: [.caseInsensitive]
        )

        var outputLines: [String] = []
        let lines = text.components(separatedBy: .newlines)
        for line in lines {
            /// Filter JSON status markers
            if let regex = jsonLinePattern {
                let nsLine = line as NSString
                let range = NSRange(location: 0, length: nsLine.length)
                if regex.firstMatch(in: line, options: [], range: range) != nil {
                    continue
                }
            }

            /// Filter session naming markers
            if line.contains("<!--session:") && line.contains("-->") {
                continue
            }

            outputLines.append(line)
        }

        /// Reconstruct preserving newline separators.
        return outputLines.joined(separator: "\n")
    }

    struct ToolStreamingContext {
        let continuation: AsyncThrowingStream<ServerOpenAIChatStreamChunk, Error>.Continuation
        let requestId: String
        let created: Int
        let model: String
    }

    /// Executes tool calls and returns results.
    /// UNIFIED PATH: If `streaming` is non-nil, emits tool-card chunks for the UI.
    /// CRITICAL: Respects tool metadata for blocking/serial execution.
    func executeToolCalls(
        _ toolCalls: [ToolCall],
        iteration: Int,
        conversationId: UUID?,
        streaming: ToolStreamingContext? = nil
    ) async throws -> [ToolExecution] {
        logger.error("TOOL_EXEC_INPUT: count=\(toolCalls.count) ids=\(toolCalls.map { $0.id }.joined(separator: ",")) names=\(toolCalls.map { $0.name }.joined(separator: ","))")
        logger.info("executeToolCalls: Executing \(toolCalls.count) tools with metadata-driven execution control")

        /// Separate tools by execution requirements - Blocking tools: MUST complete before workflow continues (user_collaboration, user_collaboration) - Serial tools: Execute one-at-a-time but don't block workflow - Parallel tools: Can execute concurrently.

        var blockingToolCalls: [ToolCall] = []
        var serialToolCalls: [ToolCall] = []
        var parallelToolCalls: [ToolCall] = []

        /// Classify each tool based on metadata.
        for toolCall in toolCalls {
            if let tool = conversationManager.mcpManager.getToolByName(toolCall.name) {
                /// Check tool metadata.
                let requiresBlocking = tool.requiresBlocking
                let requiresSerial = tool.requiresSerial

                if requiresBlocking {
                    blockingToolCalls.append(toolCall)
                    logger.info("TOOL_CLASSIFICATION: \(toolCall.name) -> BLOCKING")
                } else if requiresSerial {
                    serialToolCalls.append(toolCall)
                    logger.info("TOOL_CLASSIFICATION: \(toolCall.name) → SERIAL")
                } else {
                    parallelToolCalls.append(toolCall)
                    logger.debug("TOOL_CLASSIFICATION: \(toolCall.name) → PARALLEL")
                }
            } else {
                /// Tool not found - treat as parallel (will fail safely).
                parallelToolCalls.append(toolCall)
                logger.warning("TOOL_CLASSIFICATION: \(toolCall.name) → PARALLEL (tool not found in registry)")
            }
        }

        var allExecutions: [ToolExecution] = []

        logger.error("TOOL_CLASSIFICATION_RESULT: blocking=\(blockingToolCalls.count) serial=\(serialToolCalls.count) parallel=\(parallelToolCalls.count)")

        /// Execute BLOCKING tools FIRST (serially, await each) These tools MUST complete before anything else runs Example: user_collaboration (wait for user).
        if !blockingToolCalls.isEmpty {
            logger.info("BLOCKING_PHASE_START: Executing \(blockingToolCalls.count) blocking tools serially")

            for (index, toolCall) in blockingToolCalls.enumerated() {
                logger.info("BLOCKING_TOOL_EXECUTE: [\(index + 1)/\(blockingToolCalls.count)] \(toolCall.name) - workflow BLOCKED until complete")

                let execution = try await executeSingleToolWithStreaming(
                    toolCall,
                    iteration: iteration,
                    streaming: streaming,
                    conversationId: conversationId
                )

                allExecutions.append(execution)
                logger.info("BLOCKING_TOOL_COMPLETE: \(toolCall.name) - workflow can now continue")
            }

            logger.info("BLOCKING_PHASE_COMPLETE: All blocking tools finished, workflow continues")
        }

        /// Execute SERIAL tools (one-at-a-time, but workflow continues).
        if !serialToolCalls.isEmpty {
            logger.info("SERIAL_PHASE_START: Executing \(serialToolCalls.count) serial tools")

            for toolCall in serialToolCalls {
                let execution = try await executeSingleToolWithStreaming(
                    toolCall,
                    iteration: iteration,
                    streaming: streaming,
                    conversationId: conversationId
                )
                allExecutions.append(execution)
            }

            logger.info("SERIAL_PHASE_COMPLETE: All serial tools finished")
        }

        /// Execute PARALLEL tools (concurrently for performance).
        if !parallelToolCalls.isEmpty {
            if let streaming {
                logger.debug("PARALLEL_PHASE_START: Executing \(parallelToolCalls.count) parallel tools concurrently")

                let parallelExecutions = try await executeParallelToolsWithStreaming(
                    parallelToolCalls,
                    iteration: iteration,
                    continuation: streaming.continuation,
                    requestId: streaming.requestId,
                    created: streaming.created,
                    model: streaming.model,
                    conversationId: conversationId
                )

                allExecutions.append(contentsOf: parallelExecutions)
                logger.debug("PARALLEL_PHASE_COMPLETE: All parallel tools finished")
            } else {
                logger.debug("PARALLEL_PHASE_START: Executing \(parallelToolCalls.count) parallel tools (non-streaming)")

                let conversationIdForTools = conversationId

                let parallelExecutions = await withTaskGroup(of: (Int, ToolExecution).self) { group in
                    for (index, toolCall) in parallelToolCalls.enumerated() {
                        let toolCallId = toolCall.id
                        let toolCallName = toolCall.name
                        let toolCallArguments = SendableArguments(value: toolCall.arguments)

                        group.addTask { @Sendable in
                            let startTime = Date()

                            if let result = await self.conversationManager.executeMCPTool(
                                name: toolCallName,
                                parameters: toolCallArguments.value,
                                toolCallId: toolCallId,
                                conversationId: conversationIdForTools,
                                isExternalAPICall: self.isExternalAPICall,
                                iterationController: self
                            ) {
                                let execution = ToolExecution(
                                    toolCallId: toolCallId,
                                    toolName: toolCallName,
                                    arguments: toolCallArguments.value,
                                    result: result.output.content,
                                    success: result.success,
                                    timestamp: startTime,
                                    iteration: iteration
                                )
                                return (index, execution)
                            }

                            let execution = ToolExecution(
                                toolCallId: toolCallId,
                                toolName: toolCallName,
                                arguments: toolCallArguments.value,
                                result: "ERROR: Tool '\(toolCallName)' not found or execution failed",
                                success: false,
                                timestamp: startTime,
                                iteration: iteration
                            )
                            return (index, execution)
                        }
                    }

                    var indexedExecutions: [(Int, ToolExecution)] = []
                    for await result in group {
                        indexedExecutions.append(result)
                    }
                    indexedExecutions.sort { $0.0 < $1.0 }
                    return indexedExecutions.map { $0.1 }
                }

                allExecutions.append(contentsOf: parallelExecutions)
                logger.debug("PARALLEL_PHASE_COMPLETE: All parallel tools finished (non-streaming)")
            }
        }

        logger.info("TOOL_EXECUTION_COMPLETE: All \(toolCalls.count) tools finished (blocking:\(blockingToolCalls.count), serial:\(serialToolCalls.count), parallel:\(parallelToolCalls.count))")
        return allExecutions
    }


    /// Execute a single tool.
    /// If `streaming` is non-nil, streams tool-card events; otherwise runs silently.
    func executeSingleToolWithStreaming(
        _ toolCall: ToolCall,
        iteration: Int,
        streaming: ToolStreamingContext?,
        conversationId: UUID?
    ) async throws -> ToolExecution {
        let toolPerfStart = CFAbsoluteTimeGetCurrent()
        defer {
            InternalOperationMonitor.shared.record("AgentOrchestrator.executeSingleToolWithStreaming",
                                            duration: CFAbsoluteTimeGetCurrent() - toolPerfStart)
        }

        logger.error("SINGLE_TOOL_START: name=\(toolCall.name) id=\(toolCall.id)")
        let startTime = Date()

        let toolMessageId = UUID()
          if streaming != nil,
              let conversationId = conversationId,
           let conversation = conversationManager.conversations.first(where: { $0.id == conversationId }) {

            guard conversation.messageBus != nil else {
                logger.error("TOOL_EXEC_ERROR: MessageBus is nil for conversation id=\(conversation.id.uuidString.prefix(8))")
                throw NSError(domain: "AgentOrchestrator", code: -2,
                              userInfo: [NSLocalizedDescriptionKey: "MessageBus not initialized"])
            }

            let registry = ToolDisplayInfoRegistry.shared
            let toolDetails = registry.getToolDetails(for: toolCall.name, arguments: toolCall.arguments)

            conversation.messageBus?.addToolMessage(
                id: toolMessageId,
                name: toolCall.name,
                status: .running,
                details: "",  /// Will be updated after execution completes
                detailsArray: toolDetails,
                icon: getToolIcon(toolCall.name),
                toolCallId: toolCall.id
            )

            logger.debug("MESSAGEBUS_CREATE_TOOL: Created tool message id=\(toolMessageId.uuidString.prefix(8)) for tool=\(toolCall.name) executionId=\(toolCall.id.prefix(8))")
        } else if streaming != nil {
            logger.warning("TOOL_EXEC_WARNING: Conversation not found for id=\(conversationId?.uuidString.prefix(8) ?? "nil"), tool message not created in MessageBus")
        }

        /// Show tool starting.
        let toolDetail = extractToolActionDetail(toolCall)
        let actionDescription = toolDetail.isEmpty ? getUserFriendlyActionDescription(toolCall.name, toolDetail) : toolDetail

        if let streaming, !actionDescription.isEmpty {
            let progressMessage = "SUCCESS: \(actionDescription)..."

            let registry = ToolDisplayInfoRegistry.shared
            let toolDetails = registry.getToolDetails(for: toolCall.name, arguments: toolCall.arguments)
            let toolIcon: String? = getToolIcon(toolCall.name)

            let progressChunk = ServerOpenAIChatStreamChunk(
                id: streaming.requestId,
                object: "chat.completion.chunk",
                created: streaming.created,
                model: streaming.model,
                choices: [OpenAIChatStreamChoice(
                    index: 0,
                    delta: OpenAIChatDelta(content: progressMessage + "\n"),
                    finishReason: nil
                )],
                isToolMessage: true,
                toolName: toolCall.name,
                toolIcon: toolIcon,
                toolStatus: "running",
                toolDetails: toolDetails,
                toolExecutionId: toolCall.id,
                messageId: toolMessageId  /// Pass messageId to chunk for ChatWidget correlation
            )

            logger.debug("TOOL_CHUNK_YIELD: toolName=\(toolCall.name), status=running")
            logger.debug("TOOL_PROGRESS_MESSAGE_YIELDED: tool=\(toolCall.name) content=\(progressMessage.prefix(50)) isToolMessage=true")

            streaming.continuation.yield(progressChunk)
        }

        /// EXECUTE SYNCHRONOUSLY - THIS BLOCKS UNTIL COMPLETE.
        logger.debug("TOOL_EXECUTION_START: \(toolCall.name) - awaiting completion")

        if let result = await self.conversationManager.executeMCPTool(
            name: toolCall.name,
            parameters: toolCall.arguments,
            toolCallId: toolCall.id,
            conversationId: conversationId,
            isExternalAPICall: self.isExternalAPICall,
                        iterationController: self
        ) {
            let duration = Date().timeIntervalSince(startTime)
            logger.info("TOOL_EXECUTION_COMPLETE: \(toolCall.name) after \(String(format: "%.2f", duration))s")

            /// Update tool status in MessageBus after execution completes
            if streaming != nil,
               let conversationId = conversationId,
               let conversation = conversationManager.conversations.first(where: { $0.id == conversationId }) {
                conversation.messageBus?.updateToolStatus(
                    id: toolMessageId,
                    status: result.success ? .success : .error,
                    duration: duration,
                    details: result.output.content
                )
                logger.debug("MESSAGEBUS_UPDATE_TOOL: Updated tool message id=\(toolMessageId.uuidString.prefix(8)) status=\(result.success ? "success" : "error")")
            }

            if let streaming {
                /// Emit completion chunk with result metadata for UI display
                let completionChunk = ServerOpenAIChatStreamChunk(
                    id: streaming.requestId,
                    object: "chat.completion.chunk",
                    created: streaming.created,
                    model: streaming.model,
                    choices: [OpenAIChatStreamChoice(
                        index: 0,
                        delta: OpenAIChatDelta(content: ""),
                        finishReason: nil
                    )],
                    isToolMessage: true,
                    toolName: toolCall.name,
                    toolIcon: self.getToolIcon(toolCall.name),
                    toolStatus: result.success ? "success" : "error",
                    toolDetails: nil,
                    parentToolName: nil,
                    toolExecutionId: toolCall.id,
                    toolMetadata: result.metadata.additionalContext,
                    messageId: toolMessageId  /// Include messageId for completion chunk
                )
                streaming.continuation.yield(completionChunk)
            }

            /// Process progress events.
            for event in result.progressEvents {
                if event.eventType == .toolStarted, let message = event.message, let streaming {
                    let progressChunk = ServerOpenAIChatStreamChunk(
                        id: streaming.requestId,
                        object: "chat.completion.chunk",
                        created: streaming.created,
                        model: streaming.model,
                        choices: [OpenAIChatStreamChoice(
                            index: 0,
                            delta: OpenAIChatDelta(content: message + "\n"),
                            finishReason: nil
                        )],
                        isToolMessage: true,
                        toolName: event.toolName,
                        toolIcon: self.getToolIcon(event.toolName),
                        toolStatus: event.status ?? "running",
                        toolDisplayData: event.display as? ToolDisplayData,
                        toolDetails: event.details,
                        parentToolName: event.parentToolName,
                        toolExecutionId: toolCall.id,
                        messageId: toolMessageId  /// Include messageId for sub-tool chunks
                    )
                    streaming.continuation.yield(progressChunk)
                }

                /// Stream .userMessage progressEvents (MODERN: ToolDisplayData only)
                if event.eventType == .userMessage {
                    guard let streaming else { continue }
                    guard let displayData = event.display as? ToolDisplayData,
                          let summary = displayData.summary, !summary.isEmpty else {
                        logger.warning("PROGRESS_EVENT_SKIP: userMessage missing ToolDisplayData.summary")
                        continue
                    }

                    let messageContent = "Thinking: \(summary)"
                    logger.info("PROGRESS_EVENT_STREAM: eventType=userMessage toolName=\(event.toolName) content.prefix=\(messageContent.prefix(50))")

                    /// CRITICAL: Create message in MessageBus BEFORE yielding chunk
                    /// This ensures MessageBus is the single source of truth for message creation
                    let messageId = UUID()
                    if let conversationId = conversationId,
                       let conversation = conversationManager.conversations.first(where: { $0.id == conversationId }) {
                        conversation.messageBus?.addThinkingMessage(
                            id: messageId,
                            reasoningContent: summary,
                            showReasoning: true
                        )
                        logger.debug("MESSAGEBUS_CREATE: Created thinking message id=\(messageId.uuidString.prefix(8)) in MessageBus")
                    } else {
                        logger.warning("MESSAGEBUS_CREATE: Could not find conversation for id=\(conversationId?.uuidString.prefix(8) ?? "nil")")
                    }

                    let userMessageChunk = ServerOpenAIChatStreamChunk(
                        id: streaming.requestId,
                        object: "chat.completion.chunk",
                        created: streaming.created,
                        model: streaming.model,
                        choices: [OpenAIChatStreamChoice(
                            index: 0,
                            delta: OpenAIChatDelta(
                                role: "assistant",
                                content: messageContent + "\n"
                            ),
                            finishReason: nil
                        )],
                        isToolMessage: true,
                        toolName: event.toolName,
                        toolIcon: displayData.icon ?? self.getToolIcon(event.toolName),
                        toolStatus: event.status ?? "success",
                        toolDisplayData: displayData,
                        toolDetails: event.details,
                        parentToolName: event.parentToolName,
                        toolExecutionId: toolCall.id,
                        messageId: messageId  /// Pass messageId to chunk for UI correlation
                    )
                    logger.debug("PROGRESS_EVENT_CHUNK: chunk.toolName=\(userMessageChunk.toolName ?? "nil") chunk.isToolMessage=\(userMessageChunk.isToolMessage ?? false) messageId=\(messageId.uuidString.prefix(8))")
                    streaming.continuation.yield(userMessageChunk)
                    await Task.yield()
                }
            }

            return ToolExecution(
                toolCallId: toolCall.id,
                toolName: toolCall.name,
                arguments: toolCall.arguments,
                result: result.output.content,
                success: result.success,
                timestamp: startTime,
                iteration: iteration
            )
        } else {
            logger.error("TOOL_EXECUTION_FAILED: Tool '\(toolCall.name)' returned nil")

            return ToolExecution(
                toolCallId: toolCall.id,
                toolName: toolCall.name,
                arguments: toolCall.arguments,
                result: "Error: Tool execution failed",
                success: false,
                timestamp: startTime,
                iteration: iteration
            )
        }
    }

    /// Execute multiple tools in parallel (existing parallel execution logic).
    func executeParallelToolsWithStreaming(
        _ toolCalls: [ToolCall],
        iteration: Int,
        continuation: AsyncThrowingStream<ServerOpenAIChatStreamChunk, Error>.Continuation,
        requestId: String,
        created: Int,
        model: String,
        conversationId: UUID?
    ) async throws -> [ToolExecution] {
        logger.error("PARALLEL_TOOLS_START: count=\(toolCalls.count) ids=\(toolCalls.map { $0.id }.joined(separator: ","))")

        /// CRITICAL: Create tool messages in MessageBus for parallel execution BEFORE yielding chunks
        /// This ensures ChatWidget can track each tool via messageId
        /// Use executionId → toolMessageId mapping for tracking multiple tools
        var toolMessagesByExecutionId: [String: UUID] = [:]

        if let conversationId = conversationId,
           let conversation = conversationManager.conversations.first(where: { $0.id == conversationId }) {

            for toolCall in toolCalls {
                let toolMessageId = UUID()

                let registry = ToolDisplayInfoRegistry.shared
                let toolDetails = registry.getToolDetails(for: toolCall.name, arguments: toolCall.arguments)

                conversation.messageBus?.addToolMessage(
                    id: toolMessageId,
                    name: toolCall.name,
                    status: .running,
                    details: "",  /// Will be updated after execution
                    detailsArray: toolDetails,
                    icon: getToolIcon(toolCall.name),
                    toolCallId: toolCall.id
                )

                toolMessagesByExecutionId[toolCall.id] = toolMessageId
                logger.debug("MESSAGEBUS_CREATE_TOOL: Created tool message id=\(toolMessageId.uuidString.prefix(8)) for parallel tool=\(toolCall.name) executionId=\(toolCall.id.prefix(8))")
            }
        } else {
            logger.warning("PARALLEL_TOOLS_WARNING: Conversation not found for id=\(conversationId?.uuidString.prefix(8) ?? "nil"), tool messages not created in MessageBus")
        }

        /// Show all tools starting.
        for toolCall in toolCalls {
            let toolDetail = extractToolActionDetail(toolCall)
            let actionDescription = toolDetail.isEmpty ? getUserFriendlyActionDescription(toolCall.name, toolDetail) : toolDetail

            if !actionDescription.isEmpty {
                let progressMessage = "SUCCESS: \(actionDescription)..."

                let registry = ToolDisplayInfoRegistry.shared
                let toolDetails = registry.getToolDetails(for: toolCall.name, arguments: toolCall.arguments)
                let toolIcon: String? = getToolIcon(toolCall.name)

                /// Get messageId for this tool execution
                let toolMessageId = toolMessagesByExecutionId[toolCall.id]

                let progressChunk = ServerOpenAIChatStreamChunk(
                    id: requestId,
                    object: "chat.completion.chunk",
                    created: created,
                    model: model,
                    choices: [OpenAIChatStreamChoice(
                        index: 0,
                        delta: OpenAIChatDelta(content: progressMessage + "\n"),
                        finishReason: nil
                    )],
                    isToolMessage: true,
                    toolName: toolCall.name,
                    toolIcon: toolIcon,
                    toolStatus: "running",
                    toolDetails: toolDetails,
                    toolExecutionId: toolCall.id,
                    messageId: toolMessageId  /// Include messageId for parallel tool tracking
                )

                let ts = Date().timeIntervalSince1970
                let microseconds = Int(ts * 1_000_000)
                logger.error("TS:\(microseconds) CHUNK_YIELD: toolName=\(toolCall.name), actionDesc=\(actionDescription), isToolMessage=true, toolId=\(toolCall.id)")

                continuation.yield(progressChunk)

                /// Signal that a tool card is pending for this execution
                await MainActor.run {
                    self.toolCardsPending.insert(toolCall.id)
                    let tsPending = Date().timeIntervalSince1970
                    let microPending = Int(tsPending * 1_000_000)
                    self.logger.error("TS:\(microPending) PENDING: Added execution ID: \(toolCall.id)")
                }
            }
        }

        /// Give the async stream time to deliver chunks to UI before waiting
        /// Brief sleep ensures chunks reach the for-await loop in ChatWidget
        try? await Task.sleep(nanoseconds: 50_000_000) // 50ms

        /// CRITICAL: Force MainActor to process pending UI updates BEFORE waiting
        /// This ensures SwiftUI has a chance to render tool cards
        /// Without this, SwiftUI won't render until we're done with the task
        await MainActor.run { }  // Empty closure forces context switch
        await Task.yield()  // Yield to allow SwiftUI rendering
        await MainActor.run { }  // Second yield for safety
        await Task.yield()

        /// Wait for UI to acknowledge all tool cards are ready
        /// This ensures cards appear before execution starts
        /// Timeout after 3s to prevent deadlock (UI async stream can take 3s to process chunks)
        let allToolIds = Set(toolCalls.map { $0.id })
        if !allToolIds.isEmpty {
            logger.debug("TOOL_CARD_WAIT: Waiting for \(allToolIds.count) tool cards to be acknowledged")
            let startTime = Date()
            let timeout: TimeInterval = 3.0 // 3 seconds

            while await MainActor.run(body: { !allToolIds.isSubset(of: self.toolCardsReady) }) {
                /// Check timeout
                if Date().timeIntervalSince(startTime) > timeout {
                    let acknowledged = await MainActor.run { self.toolCardsReady }
                    logger.warning("TOOL_CARD_TIMEOUT: UI didn't acknowledge cards within 3s (acknowledged: \(acknowledged.count)/\(allToolIds.count)), proceeding anyway")
                    break
                }

                /// CRITICAL: Yield to MainActor frequently to allow SwiftUI rendering
                /// This gives SwiftUI opportunities to process the render queue
                await MainActor.run { }  /// Force context switch to MainActor
                try? await Task.sleep(nanoseconds: 10_000_000) // 10ms
                await Task.yield()  /// Yield to allow rendering
            }

        /// Clear pending/ready sets for next batch
        await MainActor.run {
            self.toolCardsPending.removeAll()
            self.toolCardsReady.removeAll()
        }

        let tsReady = Date().timeIntervalSince1970
        let microReady = Int(tsReady * 1_000_000)
        logger.error("TS:\(microReady) READY: UI acknowledged \(allToolIds.count) tool cards, proceeding with execution")

        /// CRITICAL: Give SwiftUI time to actually RENDER the cards after messages array is updated
        /// ACK happens when message is added to array, but rendering is async
        /// 200ms ensures cards are visible before execution starts
        try? await Task.sleep(nanoseconds: 200_000_000) // 200ms
        logger.debug("TOOL_CARDS_RENDERED: Waited 200ms for SwiftUI rendering, starting execution now")
    }

        /// Capture conversationId and toolMessagesByExecutionId for use in task group
        let conversationIdForTools = conversationId
        let toolMessagesForTasks = toolMessagesByExecutionId  /// Capture as constant for Sendable safety

        /// Now execute all tools in parallel using withTaskGroup (ORIGINAL LOGIC).
        return await withTaskGroup(of: (Int, ToolExecution).self) { group in
            var executions: [ToolExecution] = []

            for (index, toolCall) in toolCalls.enumerated() {
                let toolCallId = toolCall.id  /// Capture id before async task to avoid actor isolation issues
                let toolCallName = toolCall.name  /// Capture name as well
                let toolCallArguments = SendableArguments(value: toolCall.arguments)  /// Wrap in Sendable container
                let toolCallsCount = toolCalls.count  /// Capture count for logging

                group.addTask { @Sendable in
                    let tsExecute = Date().timeIntervalSince1970
                    let microExecute = Int(tsExecute * 1_000_000)
                    await MainActor.run {
                        self.logger.error("TS:\(microExecute) EXECUTE: index=\(index) name=\(toolCallName) id=\(toolCallId)")
                    }
                    let startTime = Date()
                    await MainActor.run {
                        self.logger.debug("executeToolCalls: Executing tool \(index + 1)/\(toolCallsCount) '\(toolCallName)' (id: \(toolCallId))")
                    }

                    /// Execute via ConversationManager.executeMCPTool() CRITICAL: Pass toolCall.id so tools can use LLM's tool call ID instead of generating their own Pass toolCall.id so tools can use the LLM's tool call ID.
                    /// CRITICAL (Task 19): Pass conversationId from session to prevent data leakage
                    if let result = await self.conversationManager.executeMCPTool(
                        name: toolCallName,
                        parameters: toolCallArguments.value,
                        toolCallId: toolCallId,
                        conversationId: conversationIdForTools,
                        isExternalAPICall: self.isExternalAPICall,
                        iterationController: self
                    ) {
                        let duration = Date().timeIntervalSince(startTime)

                        /// Update tool status in MessageBus after execution completes
                        if let conversationId = conversationIdForTools,
                           let toolMessageId = toolMessagesForTasks[toolCallId] {
                            let conversation = await MainActor.run {
                                self.conversationManager.conversations.first(where: { $0.id == conversationId })
                            }
                            if let conversation = conversation {
                                await MainActor.run {
                                    conversation.messageBus?.updateToolStatus(
                                        id: toolMessageId,
                                        status: result.success ? .success : .error,
                                        duration: duration,
                                        details: result.output.content
                                    )
                                    self.logger.debug("MESSAGEBUS_UPDATE_TOOL: Updated parallel tool message id=\(toolMessageId.uuidString.prefix(8)) status=\(result.success ? "success" : "error")")
                                }
                            }
                        }

                        /// Log progress events count.
                        await MainActor.run {
                            self.logger.debug("TOOL_RESULT_DEBUG: tool=\(toolCallName), progressEvents=\(result.progressEvents.count), success=\(result.success)")
                        }

                        /// Process progress events from tool execution Yield chunks for each sub-tool execution with parent context.
                        for event in result.progressEvents {
                            await MainActor.run {
                                self.logger.debug("PROGRESS_EVENT: \(event.eventType) - tool: \(event.toolName), parent: \(event.parentToolName ?? "none")")
                            }

                            /// Yield progress chunk for sub-tool execution.
                            if event.eventType == .toolStarted, let message = event.message {
                                let toolMessageId = toolMessagesForTasks[toolCallId]
                                let progressChunk = ServerOpenAIChatStreamChunk(
                                    id: requestId,
                                    object: "chat.completion.chunk",
                                    created: created,
                                    model: model,
                                    choices: [OpenAIChatStreamChoice(
                                        index: 0,
                                        delta: OpenAIChatDelta(content: message + "\n"),
                                        finishReason: nil
                                    )],
                                    isToolMessage: true,
                                    toolName: event.toolName,
                                    toolIcon: self.getToolIcon(event.toolName),
                                    toolStatus: event.status ?? "running",
                                    toolDetails: event.details,
                                    parentToolName: event.parentToolName,
                                    toolExecutionId: toolCallId,
                                    messageId: toolMessageId  /// Include messageId for sub-tool tracking
                                )
                                continuation.yield(progressChunk)
                            }

                            /// Handle user-facing messages (MODERN: ToolDisplayData only)
                            if event.eventType == .userMessage {
                                guard let displayData = event.display as? ToolDisplayData,
                                      let summary = displayData.summary, !summary.isEmpty else {
                                    await MainActor.run {
                                        self.logger.warning("PROGRESS_EVENT_SKIP_PARALLEL: userMessage missing ToolDisplayData.summary")
                                    }
                                    continue
                                }

                                let messageContent = "Thinking: \(summary)"

                                await MainActor.run {
                                    self.logger.info("USER_MESSAGE_CHUNK_EMIT: tool=\(event.toolName), contentLength=\(messageContent.count), first50=\"\(String(messageContent.prefix(50)))\"")
                                }

                                let userMessageChunk = ServerOpenAIChatStreamChunk(
                                    id: requestId,
                                    object: "chat.completion.chunk",
                                    created: created,
                                    model: model,
                                    choices: [OpenAIChatStreamChoice(
                                        index: 0,
                                        delta: OpenAIChatDelta(
                                            role: "assistant",
                                            content: messageContent + "\n"
                                        ),
                                        finishReason: nil
                                    )],
                                    isToolMessage: true,
                                    toolName: event.toolName,
                                    toolIcon: displayData.icon ?? self.getToolIcon(event.toolName),
                                    toolStatus: event.status ?? "success",
                                    toolDisplayData: displayData,
                                    toolDetails: event.details,
                                    parentToolName: event.parentToolName,
                                    toolExecutionId: toolCallId
                                )
                                continuation.yield(userMessageChunk)

                                await MainActor.run {
                                    self.logger.info("USER_MESSAGE_CHUNK_YIELDED: Successfully emitted userMessage chunk to client")
                                }

                                /// Force immediate flush for first message visibility Without this, userMessage chunks can be buffered until next yield.
                                await Task.yield()
                            }
                        }

                        /// Log what the tool result content is.
                        await MainActor.run {
                            self.logger.debug("DEBUG_TOOL_RESULT: Tool '\(toolCallName)' result type: \(type(of: result.output.content)), isEmpty: \(result.output.content.isEmpty), count: \(result.output.content.count)")
                            self.logger.debug("DEBUG_TOOL_RESULT: Tool '\(toolCallName)' result value: '\(result.output.content)'")
                            self.logger.debug("executeToolCalls: Tool '\(toolCallName)' succeeded in \(String(format: "%.2f", duration))s, emitted \(result.progressEvents.count) progress events")
                        }

                        let execution = ToolExecution(
                            toolCallId: toolCallId,
                            toolName: toolCallName,
                            arguments: toolCallArguments.value,
                            result: result.output.content,
                            success: result.success,
                            timestamp: startTime,
                            iteration: iteration
                        )

                        return (index, execution)
                    } else {
                        /// Tool not found or execution failed.
                        await MainActor.run {
                            self.logger.error("executeToolCalls: Tool '\(toolCallName)' returned nil (not found or failed)")
                        }

                        /// Create execution with error result.
                        let execution = ToolExecution(
                            toolCallId: toolCallId,
                            toolName: toolCallName,
                            arguments: toolCallArguments.value,
                            result: "ERROR: Tool '\(toolCallName)' not found or execution failed",
                            success: false,
                            timestamp: Date(),
                            iteration: iteration
                        )
                        return (index, execution)
                    }
                }
            }

            /// Collect results in original order.
            var indexedExecutions: [(Int, ToolExecution)] = []
            for await result in group {
                indexedExecutions.append(result)
            }

            /// Sort by original index to preserve tool call order.
            indexedExecutions.sort { $0.0 < $1.0 }
            executions = indexedExecutions.map { $0.1 }

            logger.debug("executeToolCalls: Completed \(executions.count)/\(toolCalls.count) tool executions in PARALLEL")

            /// Tool results are NOT sent as visible chunks They go into conversation history for the LLM but don't create UI messages The tool progress messages ("SUCCESS: Researching...") already show in tool cards Sending raw JSON results would clutter the UI with machine-readable data.

            return executions
        }
    }



    /// Format tool execution progress message with details about what each tool is doing.
    func formatToolExecutionProgress(_ toolCalls: [ToolCall]) -> String {
        if toolCalls.count == 1 {
            let tool = toolCalls[0]
            let detail = extractToolActionDetail(tool)
            /// If detail is empty, use user-friendly tool name.
            let actionDescription = detail.isEmpty ? getUserFriendlyActionDescription(tool.name, detail) : detail
            return "SUCCESS: \(actionDescription)"
        } else {
            /// Multiple tools - batch identical actions to avoid repetition Group by action description.
            var actionCounts: [String: Int] = [:]
            var actionOrder: [String] = []

            for tool in toolCalls {
                let detail = extractToolActionDetail(tool)
                let actionDescription = detail.isEmpty ? getUserFriendlyActionDescription(tool.name, detail) : detail

                /// Track first occurrence order.
                if actionCounts[actionDescription] == nil {
                    actionOrder.append(actionDescription)
                }
                actionCounts[actionDescription, default: 0] += 1
            }

            /// Format with counts for repeated actions.
            let formattedActions = actionOrder.map { action in
                let count = actionCounts[action]!
                return count > 1 ? "\(action) (\(count)x)" : action
            }.joined(separator: ", ")

            return "SUCCESS: \(formattedActions)"
        }
    }

    /// Convert technical tool names to user-friendly action descriptions.
    func getUserFriendlyActionDescription(_ toolName: String, _ detail: String) -> String {
        /// If detail already contains a descriptive action, don't add tool name.
        if !detail.isEmpty {
            /// Detail already contains the action description (e.g., "creating todo list") Just return empty string so we use only the detail.
            return ""
        }

        /// Map tool names to user-friendly actions Note: Consolidated tools (memory_operations, web_operations, etc.) are handled by ToolDisplayInfoRegistry.
        switch toolName {
        case "user_collaboration":
            /// Don't show generic message - specific collaboration message is emitted separately.
            return ""

        default:
            /// For unknown tools, format the name nicely.
            return toolName.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    /// Get SF Symbol icon for tool (used by progress event processing) Generate user-friendly message for tool execution Returns nil if no user message should be shown.
    nonisolated func generateUserMessageForTool(_ toolName: String, arguments: [String: Any]) -> String? {
        /// Extract common parameters.
        let query = arguments["query"] as? String
        let url = arguments["url"] as? String
        let filePath = arguments["filePath"] as? String
        let path = arguments["path"] as? String
        let command = arguments["command"] as? String
        let operation = arguments["operation"] as? String

        /// Generate message based on tool and operation.
        switch toolName.lowercased() {
        case "web_operations":
            guard let op = operation else { return "Performing web operation" }
            switch op {
            case "research":
                return query.map { "Researching the web for: \($0)" } ?? "Researching the web"
            case "retrieve":
                return query.map { "Retrieving stored research for: \($0)" } ?? "Retrieving research"
            case "web_search":
                return query.map { "Searching the web for: \($0)" } ?? "Searching the web"
            case "serpapi":
                let engine = arguments["engine"] as? String ?? "search engine"
                return query.map { "Searching \(engine) for: \($0)" } ?? "Performing search"
            case "scrape":
                return url.map { "Scraping content from: \($0)" } ?? "Scraping webpage"
            case "fetch":
                return url.map { "Fetching content from: \($0)" } ?? "Fetching webpage"
            default:
                return nil
            }

        case "document_operations":
            guard let op = operation else { return "Performing document operation" }
            switch op {
            case "document_import":
                if let p = path {
                    let filename = (p as NSString).lastPathComponent
                    return "Importing document: \(filename)"
                }
                return "Importing document"
            case "document_create":
                let format = arguments["format"] as? String ?? "document"
                if let filename = arguments["filename"] as? String {
                    return "Creating \(format.uppercased()) document: \(filename)"
                }
                return "Creating new \(format.uppercased()) document"
            case "get_doc_info":
                return "Getting document information"
            default:
                return nil
            }

        case "file_operations":
            guard let op = operation else { return "Performing file operation" }
            switch op {
            case "read_file":
                if let fp = filePath {
                    let filename = (fp as NSString).lastPathComponent
                    return "Reading file: \(filename)"
                }
                return "Reading file"
            case "create_file":
                if let fp = filePath {
                    let filename = (fp as NSString).lastPathComponent
                    return "Creating file: \(filename)"
                }
                return "Creating new file"
            case "replace_string", "multi_replace_string":
                if let fp = filePath {
                    let filename = (fp as NSString).lastPathComponent
                    return "Editing file: \(filename)"
                }
                return "Editing file"
            case "rename_file":
                if let oldPath = arguments["oldPath"] as? String,
                   let newPath = arguments["newPath"] as? String {
                    let oldName = (oldPath as NSString).lastPathComponent
                    let newName = (newPath as NSString).lastPathComponent
                    return "Renaming: \(oldName) → \(newName)"
                }
                return "Renaming file"
            case "delete_file":
                if let fp = filePath {
                    let filename = (fp as NSString).lastPathComponent
                    return "Deleting file: \(filename)"
                }
                return "Deleting file"
            case "list_dir":
                if let p = path {
                    let dirName = (p as NSString).lastPathComponent
                    return "Listing directory: \(dirName)"
                }
                return "Listing directory"
            case "file_search":
                return query.map { "Searching for files: \($0)" } ?? "Searching for files"
            case "grep_search":
                return query.map { "Searching code for: \($0)" } ?? "Searching code"
            case "semantic_search":
                return query.map { "Semantic search: \($0)" } ?? "Performing semantic search"
            default:
                return nil
            }

        case "memory_operations":
            guard let op = operation else { return "Performing memory operation" }
            switch op {
            case "search_memory":
                return query.map { "Searching memory for: \($0)" } ?? "Searching memory"
            case "store_memory":
                if let content = arguments["content"] as? String {
                    let preview = content.prefix(50)
                    return "Storing in memory: \(preview)..."
                }
                return "Storing in memory"
            default:
                return nil
            }

        default:
            /// No user message for other tools.
            return nil
        }
    }

    nonisolated func getToolIcon(_ toolName: String) -> String {
        switch toolName.lowercased() {
        // Document tools
        case "document_create", "document_create_mcp", "document_create_tool", "create_document":
            return "doc.badge.plus"
        case "document_import", "document_import_mcp":
            return "doc.badge.arrow.up"
        case "document_operations", "document_operations_mcp", "import_document", "search_documents":
            return "doc.text"

        // Web & Research
        case "web_research", "web_research_mcp", "web_search", "researching", "research_query":
            return "globe.badge.chevron.backward"
        case "web_operations", "web_operations_mcp":
            return "network"
        case "fetch", "fetch_webpage":
            return "arrow.down.doc"
        case "scrape", "web_scraping":
            return "doc.text.magnifyingglass"

        // File Operations
        case "read_file", "file_read", "file_operations":
            return "doc.plaintext"
        case "create_file", "file_write", "write_file":
            return "doc.badge.plus"
        case "delete_file", "file_delete":
            return "trash"
        case "rename_file":
            return "pencil.and.list.clipboard"
        case "list_dir", "list", "create_directory", "create_dir":
            return "folder"
        case "get_changed_files", "git_commit":
            return "arrow.triangle.2.circlepath"

        // Code Operations
        case "replace_string_in_file", "multi_replace_string_in_file", "edit_file":
            return "arrow.left.arrow.right"
        case "insert_edit":
            return "text.insert"
        case "apply_patch":
            return "bandage"
        case "grep_search", "file_search":
            return "magnifyingglass.circle"
        case "semantic_search":
            return "brain"
        case "list_code_usages":
            return "list.bullet.indent"

        // Memory & Data
        case "vectorrag_add_document":
            return "doc.badge.arrow.up"
        case "vectorrag_query", "memory", "memory_operations", "search_memory":
            return "doc.text.magnifyingglass"
        case "vectorrag_list_documents":
            return "list.bullet.rectangle"
        case "vectorrag_delete_document":
            return "trash.circle"

        // Tasks & Management
        case "create_and_run_task", "run_task":
            return "play.circle"
        case "manage_todo_list", "manage_todos", "todo_operations":
            return "list.clipboard"

        // Math & Calculations
        case "math_operations", "calculate", "convert":
            return "function"

        // User Interaction
        case "user_collaboration", "collaborate":
            return "person.2.badge.gearshape"


        // Testing
        case "run_tests", "runtests":
            return "checkmark.seal"
        case "test_failure":
            return "xmark.seal"

        // MCP Server & Advanced
        case "mcp_server_operations", "list_mcp_servers", "start_mcp_server":
            return "server.rack"
        case "ui_operations", "open_simple_browser":
            return "safari"
        case "run_sam_command":
            return "command"

        // Default fallback
        default:
            return "wrench.and.screwdriver"
        }
    }

    /// Extract action detail from tool call arguments Extract action detail from tool call arguments Returns a human-readable description of what the tool is doing.
    func extractToolActionDetail(_ toolCall: ToolCall) -> String {
        /// PROTOCOL-BASED: Check if tool has registered display info provider.
        let registry = ToolDisplayInfoRegistry.shared
        if let displayInfo = registry.getDisplayInfo(for: toolCall.name, arguments: toolCall.arguments) {
            return displayInfo
        }

        /// SMART FALLBACK: Extract details from common argument patterns.
        let args = toolCall.arguments

        /// Check for query/search arguments.
        if let query = args["query"] as? String {
            return query.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        /// Check for file-related arguments.
        if let filePath = args["filePath"] as? String {
            let filename = (filePath as NSString).lastPathComponent
            return filename
        }

        if let filename = args["filename"] as? String {
            if let format = args["format"] as? String {
                return "\(format.uppercased()): \(filename)"
            }
            return filename
        }

        if let path = args["path"] as? String {
            let filename = (path as NSString).lastPathComponent
            return filename
        }

        if let output_path = args["output_path"] as? String {
            let filename = (output_path as NSString).lastPathComponent
            return filename
        }

        /// Check for URL arguments.
        if let url = args["url"] as? String {
            if let host = URL(string: url)?.host {
                return host
            }
            return url
        }

        if let urls = args["urls"] as? [String], !urls.isEmpty {
            if urls.count == 1, let url = urls.first {
                if let host = URL(string: url)?.host {
                    return host
                }
                return url
            }
            let hosts = urls.prefix(2).compactMap { URL(string: $0)?.host }
            if !hosts.isEmpty {
                let hostsText = hosts.joined(separator: ", ")
                return urls.count > 2 ? "\(hostsText), +\(urls.count - 2) more" : hostsText
            }
        }

        /// Check for command arguments.
        if let command = args["command"] as? String {
            let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.count > 60 ? String(trimmed.prefix(57)) + "..." : trimmed
        }

        /// Check for content arguments.
        if let content = args["content"] as? String {
            if let format = args["format"] as? String {
                let preview = content.prefix(40).trimmingCharacters(in: .whitespacesAndNewlines)
                return "\(format.uppercased()): \(preview)..."
            }
            let preview = content.prefix(50).trimmingCharacters(in: .whitespacesAndNewlines)
            return content.count > 50 ? preview + "..." : preview
        }

        /// Check for operation-specific patterns.
        if let operation = args["operation"] as? String {
            /// Format operation name nicely.
            let formatted = operation
                .replacingOccurrences(of: "_", with: " ")
                .capitalized
            return formatted
        }

        /// No useful details found.
        return ""
    }

    /// Adds tool execution results to conversation history.
    @MainActor
    func addToolResultsToConversation(
        conversationId: UUID,
        toolResults: [ToolExecution]
    ) async throws {
        logger.debug("addToolResultsToConversation: Formatting \(toolResults.count) tool results")

        /// Format tool results as a summary message In future: Should use OpenAI's role="tool" format with tool_call_id For now: Format as clear user message summarizing tool results.
        var summary = "Tool execution results:\n\n"

        for (index, execution) in toolResults.enumerated() {
            summary += "\(index + 1). Tool: \(execution.toolName)\n"
            summary += "   Result: \(execution.result)\n\n"
        }

        logger.debug("addToolResultsToConversation: Formatted summary (\(summary.count) chars)")

        /// Add to conversation via ConversationManager Find conversation by ID in conversations array.
        if let conversation = conversationManager.conversations.first(where: { $0.id == conversationId }) {
            conversation.messageBus?.addAssistantMessage(
                id: UUID(),
                content: summary,
                timestamp: Date()
            )
            /// MessageBus handles persistence automatically
            logger.debug("addToolResultsToConversation: Successfully added tool results to conversation")
        } else {
            logger.error("addToolResultsToConversation: ERROR - Conversation \(conversationId.uuidString) not found")
            /// Don't throw - continue workflow even if we couldn't persist.
        }
    }

    /// Detect if agent is mid-workflow (needs continuation) or completing simple task. Analyzes message content for continuation signals and checks if agent explicitly stated work is complete.
    func detectMidWorkflowState(
        response: String,
        internalMessages: [OpenAIChatMessage],
        toolsExecuted: Bool
    ) -> Bool {
        let lowercasedResponse = response.lowercased()

        /// HEURISTIC 1: Check for continuation signals in response.
        let continuationSignals = [
            "next i will", "then i will", "i will now",
            "step 1", "step 2", "first,", "second,",
            "now that i", "after", "once",
            "moving forward", "next step"
        ]
        let hasContinuationSignal = continuationSignals.contains { signal in
            lowercasedResponse.contains(signal)
        }

        /// HEURISTIC 2: Check if agent explicitly said work is complete.
        let completionSignals = [
            "work complete", "task complete", "finished",
            "completed", "done", "all set",
            "successfully created", "successfully completed"
        ]
        let hasCompletionSignal = completionSignals.contains { signal in
            lowercasedResponse.contains(signal)
        }

        /// HEURISTIC 3: Check user's request for multi-step indicators.
        let userRequest = (internalMessages.first { $0.role == "user" }?.content ?? "").lowercased()
        let multiStepKeywords = [
            " and ", " then ", "first", "after that",
            "research", "analyze", "create", "generate"
        ]
        let isMultiStepRequest = multiStepKeywords.filter { keyword in
            userRequest.contains(keyword)
        }.count >= 2

        if hasCompletionSignal {
            return false
        }

        if hasContinuationSignal {
            return true
        }

        if isMultiStepRequest && toolsExecuted {
            return true
        }

        return false
    }

}
