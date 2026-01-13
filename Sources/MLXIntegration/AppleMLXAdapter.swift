// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

/// AppleMLXAdapter.swift SAM Adapter that connects our local model infrastructure to Apple's MLXLLM library Converts local model paths to Apple's ModelConfiguration and handles loading.

import Foundation
import Hub
import Tokenizers
import MLX
import MLXNN
import MLXRandom
import MLXLLM
import MLXLMCommon
import Logging

public struct MLXTextChunk: Sendable {
    public let text: String
    public let isComplete: Bool

    public init(text: String, isComplete: Bool = false) {
        self.text = text
        self.isComplete = isComplete
    }
}

/// Adapter that bridges SAM's local model management with Apple's MLXLLM library.
@MainActor
public class AppleMLXAdapter {
    private let logger = Logger(label: "AppleMLXAdapter")
    private let typeRegistry = LLMTypeRegistry.shared

    /// Cache loaded models to avoid reloading.
    private var loadedModels: [String: any LanguageModel] = [:]
    private var loadedTokenizers: [String: Tokenizer] = [:]

    /// Performance monitoring (optional, disabled by default).
    private var performanceMonitor: MLXPerformanceMonitor?
    public var enablePerformanceMonitoring: Bool = false {
        didSet {
            if enablePerformanceMonitoring {
                performanceMonitor = MLXPerformanceMonitor()
                logger.info("Performance monitoring ENABLED - will track CPU/GPU usage")
            } else {
                performanceMonitor = nil
                logger.info("Performance monitoring DISABLED")
            }
        }
    }

    public init() {
        logger.debug("AppleMLXAdapter initialized with Apple's LLMTypeRegistry")
    }

    /// Load a model from a local directory using Apple's MLXLLM infrastructure.
    public func loadModel(from localPath: URL) async throws -> (model: any LanguageModel, tokenizer: Tokenizer) {
        let modelId = localPath.lastPathComponent

        /// Check cache first.
        if let cachedModel = loadedModels[modelId],
           let cachedTokenizer = loadedTokenizers[modelId] {
            logger.debug("CACHE_HIT: Using cached model \(modelId)")
            return (cachedModel, cachedTokenizer)
        }

        logger.debug("Loading model from local path: \(localPath.path)")

        /// GGUF Detection: Check if this is a GGUF model.
        let ggufFiles = (try? FileManager.default.contentsOfDirectory(at: localPath, includingPropertiesForKeys: nil))?.filter {
            $0.pathExtension == "gguf"
        } ?? []

        if !ggufFiles.isEmpty {
            logger.debug("GGUF_DETECTED: Found \(ggufFiles.count) .gguf file(s): \(ggufFiles.map { $0.lastPathComponent }.joined(separator: ", "))")
            logger.debug("GGUF_LOADING: Using GGUF loading path (not safetensors)")
            return try await loadGGUFModel(from: ggufFiles[0], modelId: modelId, modelDirectory: localPath)
        }

        logger.debug("SAFETENSORS_DETECTED: Using standard MLX safetensors loading path")

        /// Step 1: Load config.json to determine model type.
        let configPath = localPath.appendingPathComponent("config.json")
        guard FileManager.default.fileExists(atPath: configPath.path) else {
            throw AdapterError.configNotFound(localPath.path)
        }

        let configData = try Data(contentsOf: configPath)
        let baseConfig = try JSONDecoder().decode(BaseConfiguration.self, from: configData)

        logger.debug("Detected model type: \(baseConfig.modelType)")

        /// Step 2: Create model using Apple's type registry.
        let model: any LanguageModel
        do {
            model = try typeRegistry.createModel(configuration: configPath, modelType: baseConfig.modelType)
            logger.debug("Created \(baseConfig.modelType) model using Apple's registry")
            
            // 🔍 INVESTIGATION: Log model type
            logger.debug("🔍 MODEL TYPE: \(type(of: model))")
            
            // Read config again to log dimensions
            if let configDict = try? JSONSerialization.jsonObject(with: configData) as? [String: Any] {
                logger.debug("🔍 CONFIG FROM FILE", metadata: [
                    "hidden_size": "\(configDict["hidden_size"] as? Int ?? -1)",
                    "num_attention_heads": "\(configDict["num_attention_heads"] as? Int ?? -1)",
                    "num_key_value_heads": "\(configDict["num_key_value_heads"] as? Int ?? -1)",
                    "file": "\(configPath.path)"
                ])
            }
        } catch {
            logger.error("Failed to create model with type '\(baseConfig.modelType)': \(error)")
            throw AdapterError.modelCreationFailed(baseConfig.modelType, error.localizedDescription)
        }

        /// Step 3: Load weights using Apple's loadWeights function.
        do {
            try MLXLMCommon.loadWeights(
                modelDirectory: localPath,
                model: model,
                perLayerQuantization: baseConfig.perLayerQuantization
            )
            logger.debug("Loaded weights for \(baseConfig.modelType) model")
        } catch {
            logger.error("Failed to load weights: \(error)")
            throw AdapterError.weightsLoadingFailed(error.localizedDescription)
        }

        /// Step 4: Load tokenizer from LOCAL files (not HuggingFace API).
        let tokenizer: Tokenizer
        do {
            /// Load tokenizer config and data from local files.
            let tokenizerConfigPath = localPath.appending(path: "tokenizer_config.json")
            let tokenizerDataPath = localPath.appending(path: "tokenizer.json")

            guard FileManager.default.fileExists(atPath: tokenizerConfigPath.path()) else {
                throw AdapterError.tokenizerLoadingFailed("tokenizer_config.json not found at \(tokenizerConfigPath.path())")
            }
            guard FileManager.default.fileExists(atPath: tokenizerDataPath.path()) else {
                throw AdapterError.tokenizerLoadingFailed("tokenizer.json not found at \(tokenizerDataPath.path())")
            }

            logger.debug("Loading tokenizer from local files: \(tokenizerConfigPath.path())")

            /// Parse local JSON files using Config's Codable conformance.
            let configData = try Data(contentsOf: tokenizerConfigPath)
            let tokenizerConfig = try JSONDecoder().decode(Config.self, from: configData)

            let dataContent = try Data(contentsOf: tokenizerDataPath)
            let tokenizerData = try JSONDecoder().decode(Config.self, from: dataContent)

            /// Use AutoTokenizer to create tokenizer from local configs.
            tokenizer = try AutoTokenizer.from(tokenizerConfig: tokenizerConfig, tokenizerData: tokenizerData, strict: false)
            logger.debug("Successfully loaded tokenizer from local files (no HuggingFace API)")
        } catch {
            logger.error("Failed to load tokenizer: \(error)")
            throw AdapterError.tokenizerLoadingFailed(error.localizedDescription)
        }

        /// Cache the loaded model and tokenizer.
        loadedModels[modelId] = model
        loadedTokenizers[modelId] = tokenizer

        logger.debug("Successfully loaded model \(modelId) using Apple's MLXLLM")
        return (model, tokenizer)
    }

    /// Load a GGUF format model using MLX's native GGUF support This is called when .gguf files are detected instead of .safetensors.
    private func loadGGUFModel(from ggufPath: URL, modelId: String, modelDirectory: URL) async throws -> (model: any LanguageModel, tokenizer: Tokenizer) {
        logger.debug("GGUF_LOADER: Loading GGUF model from \(ggufPath.lastPathComponent)")

        /// GGUF loading requires Swift/C++ bridge to MLX GGUF loader Implementation blocked pending Steps 3-4 from GGUF_IMPLEMENTATION_TRACKING.md.
        logger.error("GGUF_NOT_IMPLEMENTED: GGUF support requires Swift/C++ bridge to MLX GGUF loader")
        throw AdapterError.ggufNotImplemented(
            "GGUF model detected but loading not yet implemented. " +
            "Implementation requires bridge to MLX C++ load_gguf() function. " +
            "See GGUF_IMPLEMENTATION_TRACKING.md for implementation plan. " +
            "Model file: \(ggufPath.lastPathComponent)"
        )

        /// Future GGUF implementation steps: 1.
    }

    /// Enhance system message with explicit tool calling instructions for local models Local models (Qwen, etc.) need explicit instructions beyond chat template.
    private func enhanceSystemMessageWithToolInstructions(_ messages: [Message], tools: [ToolSpec]?) -> [Message] {
        guard let tools = tools, !tools.isEmpty else {
            return messages
        }

        var enhancedMessages = messages

        /// Build explicit tool instruction text with VERY clear examples.
        let toolInstruction = """


        # TOOL CALLING PROTOCOL FOR LOCAL MODELS

        You have access to tools. Use them when needed, then provide a final answer.

        ## STEP 1: To call a tool, respond with ONLY this (nothing else):

        <tool_call>
        {"name": "tool_name", "arguments": {...}}
        </tool_call>

        ## STEP 2: You'll receive tool results

        ## STEP 3: After receiving results:
        - If task is COMPLETE → Provide conversational response (NO tool call)
        - If more work needed → Call another tool (goto STEP 1)

        ## CRITICAL RULES:
        - Tool call response = ONLY the <tool_call>...</tool_call> (no other text)
        - Final response = ONLY conversational text (no tool calls)
        - DO NOT mix tool calls with explanatory text
        - DO NOT call same tool repeatedly unless results indicate need

        ## EXAMPLE 1 - Simple task:
        User: "What is 5+5?"
        You: "10"  (no tools needed)

        ## EXAMPLE 2 - Task requiring one tool:
        User: "Think about why cats purr"
        You: <tool_call>
        {"name": "think", "arguments": {"thoughts": "Analyzing cat purring behavior..."}}
        </tool_call>
        [System provides tool results]
        You: "Cats purr primarily for communication and self-soothing. Studies show..."

        ## EXAMPLE 3 - Task requiring multiple tools:
        User: "Create a todo with 2 tasks and complete them"
        You: <tool_call>
        {"name": "manage_todo_list", "arguments": {"operation": "write", "todoList": [...]}}
        </tool_call>
        [System provides results]
        You: <tool_call>
        {"name": "manage_todo_list", "arguments": {"operation": "write", "todoList": [{"id": 1, "status": "completed"}]}}
        </tool_call>
        [System provides results]
        You: "I've created and completed both tasks successfully."

        ## WRONG EXAMPLES:
        ERROR: "Let me create that. <tool_call>...</tool_call>"  (mixed text and tool)
        ERROR: Calling same tool 5+ times without checking results
        ERROR: Asking user for more info when you have what you need

        ## COMPLETION SIGNALS:
        - When you respond with ONLY text (no tool call) = you're done
        - Keep responses concise and helpful
        - Don't over-explain unless asked
        """

        /// Find system message or create one Message is [String: Any] dictionary with "role" and "content" keys.
        if let systemIndex = enhancedMessages.firstIndex(where: { ($0["role"] as? String) == "system" }) {
            /// Enhance existing system message.
            var systemMsg = enhancedMessages[systemIndex]
            let existingContent = systemMsg["content"] as? String ?? ""
            systemMsg["content"] = existingContent + toolInstruction
            enhancedMessages[systemIndex] = systemMsg
        } else {
            /// Add new system message with tool instructions.
            let systemMsg: Message = [
                "role": "system",
                "content": "You are a helpful AI assistant." + toolInstruction
            ]
            enhancedMessages.insert(systemMsg, at: 0)
        }

        return enhancedMessages
    }

    /// Generate text using Apple's model infrastructure - returns streaming chunks CRITICAL FIX: Tracks previously generated tokens to avoid duplication Only yields NEW tokens (incremental deltas) matching remote provider behavior ARCHITECTURE FIX: Uses tokenizer.applyChatTemplate() to apply model's built-in chat_template.
    public func generateStream(
        model: any LanguageModel,
        tokenizer: Tokenizer,
        messages: [Message],
        tools: [ToolSpec]? = nil,
        cache: [KVCache]? = nil,
        maxTokens: Int = 512,
        temperature: Float = 0.8,
        topP: Float = 0.95,
        repetitionPenalty: Float? = 1.1,
        repetitionContextSize: Int = 20,
        kvBits: Int? = nil,
        kvGroupSize: Int = 64,
        quantizedKVStart: Int = 0,
        maxKVSize: Int? = nil,
        modelId: String = "mlx-local",
        hideThinking: Bool = false
    ) -> AsyncThrowingStream<MLXTextChunk, Error> {

        return AsyncThrowingStream<MLXTextChunk, Error> { continuation in
            Task {
                do {
                    logger.debug("Starting text generation with Apple's model")

                    /// DON'T pass tools to applyChatTemplate - causes system prompt bleeding **The problem**: When tools passed to applyChatTemplate: - Some chat templates inject tool definitions directly into prompt - This causes system prompt content to leak into assistant responses - Model gets confused between instructions and conversation **The solution**: Tools in system message content only - MLXProvider handles tool formatting in system message - applyChatTemplate just formats conversation structure - Clean separation: system message = instructions, chat = conversation **VERIFIED**: mlx-swift-examples Chat.swift does NOT pass tools to template Tool definitions should be in system message content (handled by MLXProvider).

                    /// Pass add_generation_prompt=true to append <|im_start|>assistant\n Without this, Qwen2.5 doesn't know to generate a response and echoes system prompt Chat template has: {%- if add_generation_prompt %} {{- '<|im_start|>assistant\n' %}} {%- endif %}.
                    let additionalContext = ["add_generation_prompt": true]
                    let inputTokens = try tokenizer.applyChatTemplate(messages: messages, tools: nil, additionalContext: additionalContext)
                    logger.debug("Chat template applied with add_generation_prompt=true, tokenized to \(inputTokens.count) tokens")

                    /// Decode the input tokens to see what chat template produced.
                    let decodedInput = tokenizer.decode(tokens: inputTokens)
                    logger.debug("CHAT_TEMPLATE_DEBUG: Input prompt after template: \(decodedInput.prefix(500))")

                    /// Create input.
                    let input = LMInput(tokens: MLXArray(inputTokens))

                    /// Create model context.
                    let modelConfig = ModelConfiguration(id: modelId)
                    let context = ModelContext(
                        configuration: modelConfig,
                        model: model,
                        processor: StandInUserInputProcessor(),
                        tokenizer: tokenizer
                    )

                    /// Generate tokens using Apple's generate function with AsyncSequence **Why AsyncSequence**: Apple MLX uses modern Swift concurrency - Returns AsyncSequence<GenerateResult> (stream of tokens) - NOT callback-based API (old pattern) - Enables natural for-await-in loop for token streaming **VERIFIED**: mlx-swift-examples Chat.swift lines 101-115 uses AsyncSequence pattern CRITICAL: Use AsyncSequence pattern, NOT callback-based API.
                    let parameters = GenerateParameters(
                        maxTokens: maxTokens,
                        maxKVSize: maxKVSize,
                        kvBits: kvBits,
                        kvGroupSize: kvGroupSize,
                        quantizedKVStart: quantizedKVStart,
                        temperature: temperature,
                        topP: topP,
                        repetitionPenalty: repetitionPenalty,
                        repetitionContextSize: repetitionContextSize
                    )

                    /// Accumulate full response for debugging.
                    var fullResponse = ""
                    var tokenCount = 0

                    /// PERFORMANCE MONITORING: Start session if enabled.
                    performanceMonitor?.beginSession()

                    /// STATE MACHINE: Accumulate <think>...</think> blocks across streaming chunks Problem: Regex can't match multi-line patterns when content arrives token-by-token Solution: Buffer content when inside <think> tag, format when complete block received.
                    var thinkingBuffer = ""
                    var insideThinkTag = false

                    /// CORRECT STREAMING API: AsyncSequence pattern from reference implementation HYBRID KV CACHE: Pass cache to generate() to reuse cached key/value tensors.
                    for await item in try MLXLMCommon.generate(
                        input: input,
                        cache: cache,
                        parameters: parameters,
                        context: context
                    ) {
                        switch item {
                        case .chunk(let text):
                            fullResponse += text
                            tokenCount += 1

                            /// PERFORMANCE MONITORING: Record each token and sample CPU every 10 tokens.
                            if let monitor = performanceMonitor {
                                monitor.recordToken()
                                if tokenCount % 10 == 0 {
                                    monitor.sampleCPUUsage()

                                    /// Check GPU utilization periodically.
                                    let gpuUtil = monitor.checkGPUUtilization()
                                    if let warning = gpuUtil.warning {
                                        logger.warning("PERF_WARNING at token \(tokenCount): \(warning)")
                                    }
                                }
                            }

                            /// STATE MACHINE: Process <think> tags across streaming chunks.
                            var processedText = text

                            /// Check if we're entering a <think> tag.
                            if text.contains("<think>") && !insideThinkTag {
                                insideThinkTag = true
                                thinkingBuffer = ""

                                /// Extract any content BEFORE <think> tag and yield it.
                                if let thinkStartRange = text.range(of: "<think>") {
                                    let beforeThink = String(text[..<thinkStartRange.lowerBound])
                                    if !beforeThink.isEmpty {
                                        let chunk = MLXTextChunk(text: beforeThink, isComplete: false)
                                        continuation.yield(chunk)
                                    }
                                    /// Start accumulating from <think> onwards.
                                    thinkingBuffer = String(text[thinkStartRange.lowerBound...])
                                    processedText = ""
                                }
                            }

                            /// If inside <think> tag, accumulate content.
                            if insideThinkTag {
                                thinkingBuffer += processedText

                                /// Check if we've received the closing </think> tag.
                                if thinkingBuffer.contains("</think>") {
                                    /// Complete thinking block received.
                                    if let thinkEndRange = thinkingBuffer.range(of: "</think>") {
                                        let thinkContent = String(thinkingBuffer[..<thinkEndRange.upperBound])
                                        let afterThinkContent = String(thinkingBuffer[thinkEndRange.upperBound...])

                                        /// Format or hide the thinking block based on setting.
                                        if !hideThinking {
                                            /// Extract content between <think> and </think> and format it.
                                            if let thinkStartRange = thinkContent.range(of: "<think>"),
                                               let thinkEndRange = thinkContent.range(of: "</think>") {
                                                let contentRange = thinkStartRange.upperBound..<thinkEndRange.lowerBound
                                                let reasoning = String(thinkContent[contentRange])
                                                let formatted = "Thinking: \(reasoning.trimmingCharacters(in: .whitespacesAndNewlines))\n\n---\n\n"

                                                /// Yield formatted thinking block with divider.
                                                let thinkChunk = MLXTextChunk(text: formatted, isComplete: false)
                                                continuation.yield(thinkChunk)
                                            }
                                        }
                                        /// If hideThinking is true, we simply don't output anything for the think block.

                                        /// Exit thinking mode.
                                        insideThinkTag = false
                                        thinkingBuffer = ""

                                        /// Process any content after </think> tag.
                                        if !afterThinkContent.isEmpty {
                                            let chunk = MLXTextChunk(text: afterThinkContent, isComplete: false)
                                            continuation.yield(chunk)
                                        }
                                    }
                                }
                                /// Don't yield text while inside <think> block.
                            } else {
                                /// Not inside <think> tag - yield text normally.
                                if !processedText.isEmpty {
                                    let chunk = MLXTextChunk(text: processedText, isComplete: false)
                                    continuation.yield(chunk)
                                }
                            }

                        case .info(let info):
                            logger.debug("Generation stats: \(info.tokensPerSecond) tokens/sec, prompt time: \(info.promptTime)")

                        case .toolCall:
                            /// Tool calls are handled separately via ToolCallExtractor in MLXProvider.
                            break
                        }
                    }

                    logger.debug("Completed text generation with Apple's model")

                    /// If generation stopped while inside <think> tag, yield buffered content Problem: Model generates "<think>" then hits EOS without "</think>", parser buffers content forever Solution: Flush buffer when generation completes to prevent lost tool calls.
                    if insideThinkTag && !thinkingBuffer.isEmpty {
                        logger.warning("Generation stopped mid-<think> block - flushing \(thinkingBuffer.count) buffered chars")

                        /// Format or hide partial thinking block based on setting.
                        if !hideThinking {
                            /// Format partial thinking block with divider.
                            let formatted = "Thinking: \(thinkingBuffer.replacingOccurrences(of: "<think>", with: "").trimmingCharacters(in: .whitespacesAndNewlines))\n\n---\n\n"
                            let thinkChunk = MLXTextChunk(text: formatted, isComplete: false)
                            continuation.yield(thinkChunk)
                        }
                        /// If hideThinking is true, just discard the buffer.

                        insideThinkTag = false
                        thinkingBuffer = ""
                    }

                    /// Send final chunk to indicate completion.
                    let finalChunk = MLXTextChunk(text: "", isComplete: true)
                    continuation.yield(finalChunk)

                    /// PERFORMANCE MONITORING: End session and report if enabled.
                    if let monitor = performanceMonitor {
                        let report = monitor.endSession()

                        /// Log warning if CPU usage is suspiciously high.
                        if report.cpuUtilizationPercent > 70 {
                            logger.warning("HIGH_CPU_USAGE: \(String(format: "%.1f", report.cpuUtilizationPercent))% CPU during inference - possible CPU bottleneck")
                        }

                        /// Check for GPU problems.
                        if !report.gpuUtilization.isAvailable {
                            logger.error("NO_GPU_DETECTED: MLX running without Metal GPU - performance severely degraded")
                        } else if report.gpuUtilization.utilizationPercent < 10 && report.tokenCount > 20 {
                            logger.warning("LOW_GPU_USAGE: \(String(format: "%.1f", report.gpuUtilization.utilizationPercent))% GPU utilization - model may not be fully GPU-accelerated")
                        }
                    }

                    continuation.finish()

                } catch {
                    logger.error("Generation failed: \(error)")
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    /// Legacy method for non-streaming generation with chat template support Use generateStream() for proper streaming behavior.
    public func generate(
        model: any LanguageModel,
        tokenizer: Tokenizer,
        messages: [Message],
        tools: [ToolSpec]? = nil,
        maxTokens: Int = 512,
        temperature: Float = 0.7
    ) async throws -> String {
        logger.debug("Starting text generation with Apple's model")

        /// DON'T pass tools to applyChatTemplate - causes system prompt bleeding (See streaming path for full documentation of this issue) Tool definitions should be in system message content (handled by MLXProvider) VERIFIED: mlx-swift-examples Chat.swift does NOT pass tools to template.

        /// Pass add_generation_prompt=true to append <|im_start|>assistant\n Without this, Qwen2.5 doesn't know to generate a response and echoes system prompt.
        let additionalContext = ["add_generation_prompt": true]
        let inputTokens = try tokenizer.applyChatTemplate(messages: messages, tools: nil, additionalContext: additionalContext)
        logger.debug("Chat template applied with add_generation_prompt=true, tokenized to \(inputTokens.count) tokens")

        /// Create input.
        let input = LMInput(tokens: MLXArray(inputTokens))

        /// Create model context.
        let modelConfig = ModelConfiguration(id: "local-model")
        let context = ModelContext(
            configuration: modelConfig,
            model: model,
            processor: StandInUserInputProcessor(),
            tokenizer: tokenizer
        )

        /// Generate tokens using Apple's generate function CRITICAL FIX: tokens callback receives cumulative tokens, not incremental So we just need to capture the latest state, not append (which causes massive duplication).
        var generatedTokens: [Int] = []
        let parameters = GenerateParameters(maxTokens: maxTokens, temperature: temperature)

        _ = try MLXLMCommon.generate(
            input: input,
            parameters: parameters,
            context: context
        ) { tokens in
            /// Replace tokens array with latest cumulative state, don't append.
            generatedTokens = tokens
            return .more
        }

        logger.debug("Generated \(generatedTokens.count) tokens")

        /// Decode the generated tokens.
        let output = tokenizer.decode(tokens: generatedTokens)
        logger.debug("Generated response with Apple's model")

        return output
    }

    /// Clear cached models to free memory.
    public func clearCache() {
        loadedModels.removeAll()
        loadedTokenizers.removeAll()
        logger.debug("Cleared model cache")
    }
}

// MARK: - Error Types

public enum AdapterError: LocalizedError {
    case configNotFound(String)
    case tokenizerNotFound(String)
    case modelCreationFailed(String, String)
    case weightsLoadingFailed(String)
    case tokenizerLoadingFailed(String)
    case generationFailed(String)
    case ggufNotImplemented(String)

    public var errorDescription: String? {
        switch self {
        case .configNotFound(let path):
            return "config.json not found at: \(path)"

        case .tokenizerNotFound(let path):
            return "tokenizer.json not found at: \(path)"

        case .modelCreationFailed(let modelType, let error):
            return "Failed to create \(modelType) model: \(error)"

        case .weightsLoadingFailed(let error):
            return "Failed to load model weights: \(error)"

        case .tokenizerLoadingFailed(let error):
            return "Failed to load tokenizer: \(error)"

        case .generationFailed(let error):
            return "Generation failed: \(error)"

        case .ggufNotImplemented(let message):
            return "GGUF support not yet implemented: \(message)"
        }
    }
}
