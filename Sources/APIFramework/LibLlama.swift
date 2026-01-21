// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import Foundation
import llama
import Logging
import Metal

// MARK: - Logging

private let llamaLogger = Logging.Logger(label: "com.sam.llama.LibLlama")

// MARK: - Errors

enum LlamaError: Error {
    case couldNotInitializeContext
    case modelNotFound(String)
    case invalidModelPath(String)
    case generationFailed(String)
    case generationTimeout
    case tokenLimitExceeded
    case contextLimitReached
}

// MARK: - Global Cleanup

/// Call llama backend free at app termination
/// CRITICAL: Must be called exactly once, AFTER all LlamaContext instances are deallocated
public func llamaBackendCleanup() {
    llamaLogger.info("APP_SHUTDOWN: Freeing llama.cpp backend resources")
    llama_backend_free()
}

// MARK: - Helper Methods

func llama_batch_clear(_ batch: inout llama_batch) {
    batch.n_tokens = 0
}

func llama_batch_add(_ batch: inout llama_batch, _ id: llama_token, _ pos: llama_pos, _ seq_ids: [llama_seq_id], _ logits: Bool) {
    batch.token[Int(batch.n_tokens)] = id
    batch.pos[Int(batch.n_tokens)] = pos
    batch.n_seq_id[Int(batch.n_tokens)] = Int32(seq_ids.count)

    /// Use safe optional binding instead of force-unwrap batch.seq_id can be nil if memory allocation failed during llama_batch_init Force-unwrap (!) causes crash - use if-let pattern from llama.cpp Swift examples.
    if let seq_id_ptr = batch.seq_id[Int(batch.n_tokens)] {
        for i in 0..<seq_ids.count {
            seq_id_ptr[Int(i)] = seq_ids[i]
        }
    } else {
        llamaLogger.error("CRITICAL: batch.seq_id[\(batch.n_tokens)] is nil - batch may not be properly initialized")
        /// This should never happen if batch_init succeeded, but handle gracefully rather than crashing.
    }

    batch.logits[Int(batch.n_tokens)] = logits ? 1 : 0
    batch.n_tokens += 1
}

// MARK: - Llama Context

/// Thread-safe llama.cpp context wrapper using Swift Actor.
actor LlamaContext {
    /// Properties needed for deinit cleanup - marked nonisolated(unsafe) for access in deinit
    private nonisolated(unsafe) var model: OpaquePointer
    private nonisolated(unsafe) var context: OpaquePointer
    private var vocab: OpaquePointer
    private nonisolated(unsafe) var sampling: UnsafeMutablePointer<llama_sampler>
    private nonisolated(unsafe) var batch: llama_batch
    private var tokens_list: [llama_token]
    var is_done: Bool = false

    /// Temporary storage for invalid C chars during processing.
    private var temporary_invalid_cchars: [CChar]

    /// Current position in context.
    var n_cur: Int32 = 0
    var n_decode: Int32 = 0

    /// Cancellation flag - set to true to abort generation.
    private var isCancelled: Bool = false

    /// Performance tracking.
    private var generationStartTime: Date?
    private var tokensGenerated: Int = 0

    /// Accumulated text for text-based EOG detection.
    /// Some models generate EOG tokens as text instead of special tokens.
    private var accumulatedText: String = ""

    /// Max tokens limit for generation (set before calling completion_loop).
    /// This is the actual limit for how many tokens to generate, separate from context size.
    var maxTokensLimit: Int = 4096

    /// Context size limit (for safety checks).
    private let contextSize: Int32

    /// Batch size (for llama_batch_init - should be small, NOT full context).
    private let batchSize: Int32

    // MARK: - Lifecycle

    init(model: OpaquePointer, context: OpaquePointer, contextSize: Int32, batchSize: Int32) {
        self.model = model
        self.context = context
        self.contextSize = contextSize
        self.batchSize = batchSize
        self.tokens_list = []

        /// Initialize batch with BATCH SIZE, not full context size Using full context (32k) causes massive memory allocation and crashes Batch size should be 512-2048 for prompt processing efficiency.
        self.batch = llama_batch_init(batchSize, 0, 1)
        self.temporary_invalid_cchars = []

        /// Initialize sampling chain with reasonable defaults.
        let sparams = llama_sampler_chain_default_params()
        self.sampling = llama_sampler_chain_init(sparams)
        llama_sampler_chain_add(self.sampling, llama_sampler_init_temp(0.7))
        llama_sampler_chain_add(self.sampling, llama_sampler_init_dist(UInt32(Date().timeIntervalSince1970)))

        vocab = llama_model_get_vocab(model)

        llamaLogger.info("LlamaContext initialized successfully with context size: \(contextSize)")
    }

    /// Get the context size for this model.
    public func getContextSize() -> Int {
        return Int(contextSize)
    }

    deinit {
        llamaLogger.info("LlamaContext deinit: Cleaning up resources")
        
        /// Free resources in the correct order (inverse of allocation)
        /// Do NOT call llama_backend_free() here - it should only be called once at app shutdown
        /// See AppDelegate.applicationWillTerminate() for global cleanup
        
        llama_sampler_free(sampling)
        llama_batch_free(batch)
        llama_free(context)
        llama_model_free(model)
        
        llamaLogger.info("LlamaContext cleaned up successfully")
    }

    // MARK: - Factory Method

    /// Detect quantization type from model filename or metadata Returns estimated bytes per token for KV cache based on quantization.
    private static func estimateBytesPerToken(modelPath: String, model: OpaquePointer) -> UInt64 {
        let filename = (modelPath as NSString).lastPathComponent.uppercased()

        /// Detect quantization from filename (common GGUF naming patterns) Q2_K, Q3_K_S, Q3_K_M, Q3_K_L, Q4_0, Q4_1, Q4_K_S, Q4_K_M, Q5_0, Q5_1, Q5_K_S, Q5_K_M, Q6_K, Q8_0, F16, F32.
        var bytesPerToken: UInt64

        if filename.contains("Q2_K") || filename.contains("Q2-K") {
            bytesPerToken = 192
        } else if filename.contains("Q3_K") || filename.contains("Q3-K") {
            bytesPerToken = 256
        } else if filename.contains("Q4_K") || filename.contains("Q4_0") || filename.contains("Q4_1") || filename.contains("Q4-K") {
            bytesPerToken = 384
        } else if filename.contains("Q5_K") || filename.contains("Q5_0") || filename.contains("Q5_1") || filename.contains("Q5-K") {
            bytesPerToken = 448
        } else if filename.contains("Q6_K") || filename.contains("Q6-K") {
            bytesPerToken = 512
        } else if filename.contains("Q8_0") || filename.contains("Q8-0") {
            bytesPerToken = 640
        } else if filename.contains("F16") || filename.contains("FP16") {
            bytesPerToken = 1024
        } else if filename.contains("F32") || filename.contains("FP32") {
            bytesPerToken = 2048
        } else {
            /// Default to Q4 estimate if unknown.
            bytesPerToken = 384
            llamaLogger.warning("Unknown quantization type in \(filename), assuming Q4 (~384 bytes/token)")
        }

        llamaLogger.info("Detected quantization from filename: \(filename) -> \(bytesPerToken) bytes/token estimate")
        return bytesPerToken
    }

    /// Get Metal GPU memory limit for KV cache calculations Returns available GPU memory in bytes.
    private static func getMetalMemoryLimit() -> UInt64 {
        #if targetEnvironment(simulator)
        /// Simulator doesn't have real GPU, return conservative estimate.
        return 2 * 1024 * 1024 * 1024
        #else
        guard let device = MTLCreateSystemDefaultDevice() else {
            llamaLogger.warning("Could not access Metal device, using conservative GPU memory estimate")
            return 4 * 1024 * 1024 * 1024
        }

        /// Get recommended max working set size (available GPU memory).
        let recommendedMaxWorkingSetSize = device.recommendedMaxWorkingSetSize
        llamaLogger.info("Metal device: \(device.name), recommended max working set: \(recommendedMaxWorkingSetSize / (1024*1024*1024))GB")

        return recommendedMaxWorkingSetSize
        #endif
    }

    /// Get model file size in bytes.
    private static func getModelFileSize(path: String) -> UInt64 {
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: path)
            if let fileSize = attributes[.size] as? UInt64 {
                llamaLogger.info("Model file size: \(fileSize / (1024*1024*1024))GB (\(path))")
                return fileSize
            }
        } catch {
            llamaLogger.warning("Could not get model file size: \(error.localizedDescription)")
        }

        /// Fallback: Estimate based on quantization (8B model estimates).
        let filename = (path as NSString).lastPathComponent.uppercased()
        if filename.contains("Q2") {
            return 2 * 1024 * 1024 * 1024
        } else if filename.contains("Q3") {
            return 3 * 1024 * 1024 * 1024
        } else if filename.contains("Q4") {
            return 4 * 1024 * 1024 * 1024
        } else if filename.contains("Q5") {
            return 5 * 1024 * 1024 * 1024
        } else if filename.contains("Q6") {
            return 6 * 1024 * 1024 * 1024
        } else if filename.contains("Q8") {
            return 8 * 1024 * 1024 * 1024
        } else if filename.contains("F16") {
            return 16 * 1024 * 1024 * 1024
        }

        return 4 * 1024 * 1024 * 1024
    }

    /// Calculate optimal batch size based on model size, GPU memory, and context PRIORITY 2 OPTIMIZATION: Adaptive batch sizing for better performance.
    private static func calculateOptimalBatchSize(
        modelSize: UInt64,
        availableGPUMemory: UInt64,
        contextSize: Int32
    ) -> Int32 {
        let modelSizeGB = modelSize / (1024*1024*1024)

        // Rule 1: Larger models need smaller batches to fit in GPU cache
        let baseBatch: Int32
        if modelSizeGB >= 40 {      // 70B+ models
            baseBatch = 512
            llamaLogger.info("BATCH_SIZE: Large model (>=40GB), using batch=512")
        } else if modelSizeGB >= 20 {  // 30B-70B models
            baseBatch = 1024
            llamaLogger.info("BATCH_SIZE: Medium model (20-40GB), using batch=1024")
        } else if modelSizeGB >= 8 {   // 7B-30B models
            baseBatch = 2048
            llamaLogger.info("BATCH_SIZE: Small model (8-20GB), using batch=2048")
        } else {                    // <7B models
            baseBatch = 4096
            llamaLogger.info("BATCH_SIZE: Tiny model (<8GB), using batch=4096")
        }

        // Rule 2: Clamp to available memory (conservative estimate to prevent OOM)
        // Assume ~512KB per batch entry as safety margin
        let maxBatchFromMemory = Int32(availableGPUMemory / (512 * 1024))

        // Rule 3: Never exceed context size
        let finalBatch = min(baseBatch, min(maxBatchFromMemory, contextSize))

        llamaLogger.info("BATCH_SIZE: Final calculated batch=\(finalBatch) (base=\(baseBatch), mem_limit=\(maxBatchFromMemory), ctx_limit=\(contextSize))")

        return finalBatch
    }

    /// Calculate optimal thread counts for prompt processing vs token generation PRIORITY 4 OPTIMIZATION: Adaptive threading for better CPU utilization.
    private static func calculateOptimalThreads(
        modelSize: UInt64,
        totalCores: Int
    ) -> (promptThreads: Int32, generationThreads: Int32) {
        let modelSizeGB = modelSize / (1024*1024*1024)

        // Prompt processing: Use ALL available cores (batch processing benefits from parallelism)
        let promptThreads = max(1, totalCores - 1)  // Leave 1 for OS

        // Token generation: Adjust based on model size
        // Smaller models: more threads (compute-bound)
        // Larger models: fewer threads (memory bandwidth-bound)
        let genThreads: Int
        if modelSizeGB >= 40 {
            // 70B models: Limited by memory bandwidth, not compute
            genThreads = min(4, totalCores / 2)
            llamaLogger.info("THREAD_COUNT: Large model (>=40GB), gen_threads=\(genThreads)")
        } else if modelSizeGB >= 20 {
            // 30B models: Moderate parallelism
            genThreads = min(8, (totalCores * 2) / 3)
            llamaLogger.info("THREAD_COUNT: Medium model (20-40GB), gen_threads=\(genThreads)")
        } else {
            // 7B models: Can benefit from high parallelism
            genThreads = min(12, totalCores - 2)
            llamaLogger.info("THREAD_COUNT: Small model (<20GB), gen_threads=\(genThreads)")
        }

        llamaLogger.info("THREAD_COUNT: Final threads - prompt=\(promptThreads), generation=\(genThreads) (total_cores=\(totalCores))")

        return (Int32(promptThreads), Int32(genThreads))
    }

    static func create_context(path: String) throws -> LlamaContext {
        llamaLogger.info("Creating LlamaContext from path: \(path)")

        llama_backend_init()
        var model_params = llama_model_default_params()

        #if targetEnvironment(simulator)
        model_params.n_gpu_layers = 0
        llamaLogger.warning("Running on simulator, forcing n_gpu_layers = 0")
        #else
        /// Use Metal acceleration on real devices.
        model_params.n_gpu_layers = 999
        #endif

        /// PERFORMANCE: Enable mmap for faster model loading and memory efficiency.
        model_params.use_mmap = true

        /// PERFORMANCE: Keep model in RAM to prevent swapping (LMStudio "Keep model in memory").
        model_params.use_mlock = true

        let model = llama_model_load_from_file(path, model_params)
        guard let model else {
            llamaLogger.error("Could not load model at \(path)")
            throw LlamaError.modelNotFound(path)
        }

        /// Get model's training context size (e.g., 32768 for Qwen2.5-Coder).
        let model_ctx_train = llama_model_n_ctx_train(model)
        llamaLogger.info("Model training context size: \(model_ctx_train)")

        /// Calculate safe context size based on available RAM and model quantization.
        let physicalMemory = ProcessInfo.processInfo.physicalMemory
        let reservedMemory: UInt64 = 4 * 1024 * 1024 * 1024
        let availableMemory = physicalMemory > reservedMemory ? physicalMemory - reservedMemory : physicalMemory / 2

        /// Detect quantization and get appropriate bytes per token estimate.
        let bytesPerToken = estimateBytesPerToken(modelPath: path, model: model)

        /// Calculate max context tokens that fit in available RAM.
        let maxContextFromRAM = Int32(availableMemory / bytesPerToken)

        /// Check Metal GPU memory availability.
        let metalMemoryLimit = getMetalMemoryLimit()
        let modelSize = getModelFileSize(path: path)

        /// Estimate KV cache memory requirement for context KV cache uses 2 * n_embd * n_layers * context_size * sizeof(float16) For 8B models: ~4096 embd * 32 layers * context * 2 bytes = ~262KB per token Simplified: Use bytes_per_token estimate which accounts for quantization.
        let kvCachePerToken = bytesPerToken

        /// Calculate max context that fits in GPU memory.
        let availableGPUMemory = metalMemoryLimit > (modelSize + 1024*1024*1024)
            ? metalMemoryLimit - modelSize - 1024*1024*1024
            : metalMemoryLimit / 4

        let maxContextFromGPU = Int32(availableGPUMemory / kvCachePerToken)

        /// Use minimum of: model max, RAM limit, and GPU limit.
        var n_ctx = min(model_ctx_train, min(maxContextFromRAM, maxContextFromGPU))

        /// Safety: Clamp to reasonable range (4k-32k for most models).
        let minContext: Int32 = 4096
        let maxContext: Int32 = 32768
        let originalCtx = n_ctx
        n_ctx = max(minContext, min(n_ctx, maxContext))

        if originalCtx != n_ctx {
            llamaLogger.warning("WARNING: CONTEXT_CLAMPED: Adjusted context from \(originalCtx) to \(n_ctx) (min=\(minContext), max=\(maxContext))")
        }

        llamaLogger.error("LLAMA_CONTEXT_DEBUG: selected_ctx=\(n_ctx), model_max=\(model_ctx_train), ram_limit=\(maxContextFromRAM), gpu_limit=\(maxContextFromGPU)")
        llamaLogger.error("LLAMA_MEMORY_DEBUG: available_ram=\(availableMemory/(1024*1024*1024))GB, available_gpu=\(availableGPUMemory/(1024*1024*1024))GB, model_size=\(modelSize/(1024*1024*1024))GB, bytes_per_token=\(bytesPerToken)")
        llamaLogger.info("Context calculation: model_max=\(model_ctx_train), ram_limit=\(maxContextFromRAM), gpu_limit=\(maxContextFromGPU), selected=\(n_ctx)")
        llamaLogger.info("Memory: available_ram=\(availableMemory/(1024*1024*1024))GB, available_gpu=\(availableGPUMemory/(1024*1024*1024))GB, model_size=\(modelSize/(1024*1024*1024))GB, bytes_per_token=\(bytesPerToken), total_ram=\(physicalMemory/(1024*1024*1024))GB)")

        /// PRIORITY 2 OPTIMIZATION: Adaptive batch sizing based on model characteristics.
        let n_batch = calculateOptimalBatchSize(
            modelSize: modelSize,
            availableGPUMemory: availableGPUMemory,
            contextSize: n_ctx
        )

        /// PRIORITY 4 OPTIMIZATION: Adaptive threading based on CPU cores and model size.
        let totalCores = ProcessInfo.processInfo.processorCount
        let (promptThreads, generationThreads) = calculateOptimalThreads(
            modelSize: modelSize,
            totalCores: totalCores
        )
        llamaLogger.info("Using adaptive threads: prompt=\(promptThreads), generation=\(generationThreads) (total_cores=\(totalCores))")

        var ctx_params = llama_context_default_params()
        ctx_params.n_ctx = UInt32(n_ctx)
        ctx_params.n_batch = UInt32(n_batch)
        ctx_params.n_threads = promptThreads           // Used for prompt evaluation
        ctx_params.n_threads_batch = generationThreads  // Used for token generation

        /// CRITICAL FIX: Explicitly initialize samplers to NULL to prevent segfault
        /// Recent llama.cpp versions validate sampler chains during context init.
        /// If samplers field contains garbage/uninitialized values, llama_sampler_chain_get
        /// will dereference invalid pointers. We don't use backend samplers, so set to NULL.
        ctx_params.samplers = nil
        ctx_params.n_samplers = 0

        /// PERFORMANCE: Offload KV cache to GPU (LMStudio "Offload KV Cache to GPU") This stores the key/value cache on GPU instead of CPU RAM Dramatically improves performance for long contexts.
        ctx_params.offload_kqv = true

        llamaLogger.info("SUCCESS: PERFORMANCE_OPTIMIZATIONS: mmap=true, mlock=true, offload_kqv=true (KV cache on GPU)")

        let context = llama_init_from_model(model, ctx_params)
        guard let context else {
            llamaLogger.error("Could not initialize context from model")
            throw LlamaError.couldNotInitializeContext
        }

        llamaLogger.info("SUCCESS: BATCH_SIZE_FIX: Using batch_size=\(n_batch) (NOT context_size=\(n_ctx)) to prevent crash")

        return LlamaContext(model: model, context: context, contextSize: n_ctx, batchSize: n_batch)
    }

    // MARK: - Model Information

    func model_info() -> String {
        let result = UnsafeMutablePointer<Int8>.allocate(capacity: 256)
        result.initialize(repeating: Int8(0), count: 256)
        defer {
            result.deallocate()
        }

        let nChars = llama_model_desc(model, result, 256)
        let bufferPointer = UnsafeBufferPointer(start: result, count: Int(nChars))
        var swiftString = ""
        for char in bufferPointer {
            swiftString.append(Character(UnicodeScalar(UInt8(char))))
        }
        return swiftString
    }

    func model_meta_info() -> String {
        let result = UnsafeMutablePointer<Int8>.allocate(capacity: 256)
        result.initialize(repeating: Int8(0), count: 256)
        defer {
            result.deallocate()
        }

        let nChars = llama_model_meta_val_str(model, "general.description", result, 256)
        let bufferPointer = UnsafeBufferPointer(start: result, count: Int(nChars))
        var swiftString = ""
        for char in bufferPointer {
            swiftString.append(Character(UnicodeScalar(UInt8(char))))
        }
        return swiftString
    }

    // MARK: - Text Generation

    func completion_init(text: String) {
        tokens_list = tokenize(text: text, add_bos: true)
        temporary_invalid_cchars = []

        /// Clear KV cache before each new completion Without this, llama.cpp fails with "sequence positions remain consecutive" error because it thinks sequence 0 already has tokens from previous request Use llama_memory_seq_rm with positions -1 to -1 to clear entire sequence.
        let memory = llama_get_memory(context)
        _ = llama_memory_seq_rm(memory, 0, -1, -1)

        /// Reset completion state.
        is_done = false
        n_decode = 0
        n_cur = 0
        accumulatedText = ""

        /// Start performance tracking.
        generationStartTime = Date()
        tokensGenerated = 0

        let n_ctx = llama_n_ctx(context)
        let estimatedOutputTokens = min(maxTokensLimit, 4096)  /// Estimate for KV cache planning
        let n_kv_req = tokens_list.count + estimatedOutputTokens

        llamaLogger.info("Context size: \(n_ctx), required KV: \(n_kv_req)")

        if n_kv_req > n_ctx {
            llamaLogger.error("Required context \(n_kv_req) exceeds available \(n_ctx)")
        }

        /// Process prompt in batches if it exceeds batch size batch was initialized with batchSize (2048), but prompt might be larger Need to decode in chunks to avoid overflow.
        llamaLogger.info("Processing prompt with \(tokens_list.count) tokens, batch_size=\(batchSize)")

        /// Adaptive batch sizing based on prompt length and context capacity The crash occurs when KV cache runs out of memory slots Root cause: Processing large prompts (8611 tokens) exhausts KV cache after 2 batches Solution: Reduce batch size dynamically when approaching context limits.

        let maxContextTokens = Int32(contextSize)
        var tokenIndex = 0
        var consecutiveDecodeFailures = 0
        let maxConsecutiveFailures = 3

        while tokenIndex < tokens_list.count {
            /// Check for cancellation during prompt processing.
            if isCancelled {
                llamaLogger.info("PROMPT_PROCESSING_CANCELLED: Stopping during prompt ingestion")
                is_done = true
                return
            }

            /// Monitor how much context we've used tokenIndex represents current position = how many tokens already in KV cache.
            let tokensProcessed = Int32(tokenIndex)
            let remainingContext = maxContextTokens - tokensProcessed
            let contextUsagePercent = maxContextTokens > 0 ? (Double(tokensProcessed) / Double(maxContextTokens)) * 100.0 : 0.0

            /// If we're approaching context limit, stop before crash.
            if contextUsagePercent > 95.0 || remainingContext < 100 {
                llamaLogger.error("KV_CACHE_NEARLY_EXHAUSTED: \(String(format: "%.1f", contextUsagePercent))% used, stopping to prevent crash")
                llamaLogger.error("Prompt too long (\(tokens_list.count) tokens) for context window (\(maxContextTokens) tokens)")
                is_done = true
                return
            }

            llama_batch_clear(&batch)

            /// Determine how many tokens to process in this batch.
            let remainingTokens = tokens_list.count - tokenIndex
            var tokensInThisBatch = min(remainingTokens, Int(batchSize))

            /// ADAPTIVE BATCH SIZING: Reduce batch size when approaching context limit This prevents the "no memory slot" error by processing smaller chunks.
            if contextUsagePercent > 70.0 {
                /// Gradually reduce batch size from 100% at 70% usage to 25% at 95% usage.
                let reduction_factor = max(0.25, 1.0 - ((contextUsagePercent - 70.0) / 25.0) * 0.75)
                tokensInThisBatch = max(1, Int(Double(tokensInThisBatch) * reduction_factor))
            }

            /// Safety check: Don't exceed remaining context.
            tokensInThisBatch = min(tokensInThisBatch, Int(remainingContext) - 100)
            if tokensInThisBatch <= 0 {
                llamaLogger.error("Cannot fit more tokens in context, stopping")
                is_done = true
                return
            }

            /// Add tokens for this batch.
            for i in 0..<tokensInThisBatch {
                let token = tokens_list[tokenIndex + i]
                let position = Int32(tokenIndex + i)

                /// Only request logits for the LAST token of the ENTIRE prompt.
                let isLastTokenOfPrompt = (tokenIndex + i == tokens_list.count - 1)
                llama_batch_add(&batch, token, position, [0], isLastTokenOfPrompt)
            }

            /// Decode this batch with error handling.
            let decodeResult = llama_decode(context, batch)
            if decodeResult != 0 {
                consecutiveDecodeFailures += 1
                llamaLogger.error("Failed to decode prompt batch at token \(tokenIndex), result=\(decodeResult), failures=\(consecutiveDecodeFailures)")

                /// If we hit multiple consecutive failures, stop to prevent crash.
                if consecutiveDecodeFailures >= maxConsecutiveFailures {
                    llamaLogger.error("DECODE_FAILURE_LIMIT: Hit \(maxConsecutiveFailures) consecutive failures, stopping")
                    is_done = true
                    return
                }

                /// Try smaller batch size on next iteration.
                if tokensInThisBatch > 1 {
                    llamaLogger.info("Retrying with smaller batch size")
                    continue
                } else {
                    /// Can't make batch smaller, must stop.
                    llamaLogger.error("Cannot reduce batch size further, stopping")
                    is_done = true
                    return
                }
            }

            /// Success - reset failure counter.
            consecutiveDecodeFailures = 0
            tokenIndex += tokensInThisBatch
            llamaLogger.info("Processed prompt batch: \(tokenIndex)/\(tokens_list.count) tokens")
        }

        n_cur = Int32(tokens_list.count)
    }

    func completion_loop() -> String {
        /// Check for cancellation FIRST before any processing.
        if isCancelled {
            llamaLogger.info("GENERATION_CANCELLED: Stopping token generation")
            is_done = true
            return ""
        }

        var new_token_id: llama_token = 0

        /// Sample the next token - CRITICAL: Use batch position, not absolute context position After llama_batch_clear + llama_batch_add, batch.n_tokens is the number of tokens in THIS batch (usually 1) The batch contains tokens at their absolute positions via llama_batch_add(..., n_cur, ...) But llama_sampler_sample wants the INDEX within the batch, which is batch.n_tokens - 1.
        /// FIX: After prompt processing, we need to sample from index -1 (the last logits computed)
        /// For first token after prompt, batch.n_tokens may be large from prompt processing
        let sampleIndex = batch.n_tokens > 0 ? batch.n_tokens - 1 : -1
        new_token_id = llama_sampler_sample(sampling, context, sampleIndex)

        /// Check for end of generation (using vocab instead of model).
        let vocab = llama_model_get_vocab(model)
        let isEOGToken = llama_vocab_is_eog(vocab, new_token_id)

        /// DEBUG: Log when we sample potential EOG-related tokens (every 100 tokens to reduce spam)
        if tokensGenerated % 100 == 0 || isEOGToken {
            llamaLogger.info("TOKEN_SAMPLE: id=\(new_token_id), isEOG=\(isEOGToken), generated=\(tokensGenerated)/\(maxTokensLimit)")
        }

        if isEOGToken {
            llamaLogger.info("EOG_TOKEN_DETECTED: token_id=\(new_token_id) at position \(tokensGenerated)")
            is_done = true
            let new_token_str = String(cString: temporary_invalid_cchars + [0])
            temporary_invalid_cchars.removeAll()
            return new_token_str
        }

        if tokensGenerated >= maxTokensLimit {
            llamaLogger.info("MAX_TOKENS_REACHED: Generated \(tokensGenerated) tokens (limit: \(maxTokensLimit))")
            is_done = true
            let new_token_str = String(cString: temporary_invalid_cchars + [0])
            temporary_invalid_cchars.removeAll()
            return new_token_str
        }

        /// Check if we're approaching context limit (stop at 90% to be safe).
        let contextLimit = Int32(Float(contextSize) * 0.9)
        if n_cur >= contextLimit {
            llamaLogger.error("ERROR: CONTEXT_LIMIT: Approaching context limit (\(n_cur)/\(contextSize)), stopping generation")
            is_done = true
            return ""
        }

        /// Convert token to text.
        let new_token_cchars = token_to_piece(token: new_token_id)
        temporary_invalid_cchars.append(contentsOf: new_token_cchars)
        let new_token_str: String

        if let string = String(validatingUTF8: temporary_invalid_cchars + [0]) {
            temporary_invalid_cchars.removeAll()
            new_token_str = string
        } else if (0 ..< temporary_invalid_cchars.count).contains(where: {$0 != 0 && String(validatingUTF8: Array(temporary_invalid_cchars.suffix($0)) + [0]) != nil}) {
            let string = String(cString: temporary_invalid_cchars + [0])
            temporary_invalid_cchars.removeAll()
            new_token_str = string
        } else {
            new_token_str = ""
        }

        /// Text-based EOG detection fallback.
        /// Some models generate EOG tokens as text (multiple tokens spelling out '<|im_end|>')
        /// instead of the single special token. Detect this and stop generation.
        accumulatedText += new_token_str
        if accumulatedText.contains("<|im_end|>") ||
           accumulatedText.contains("<|endoftext|>") ||
           accumulatedText.contains("</s>") {
            llamaLogger.info("TEXT_EOG_DETECTED: Found EOG pattern in generated text at position \(tokensGenerated)")
            is_done = true
            /// Return text up to and including the EOG marker
            return new_token_str
        }

        /// Keep only last 50 chars for EOG detection to avoid memory growth
        if accumulatedText.count > 50 {
            accumulatedText = String(accumulatedText.suffix(50))
        }

        /// Prepare next batch.
        llama_batch_clear(&batch)
        llama_batch_add(&batch, new_token_id, n_cur, [0], true)

        n_decode += 1
        n_cur += 1
        tokensGenerated += 1

        /// Decode next token - CRITICAL: Handle failures properly.
        let decode_result = llama_decode(context, batch)
        if decode_result != 0 {
            llamaLogger.error("ERROR: DECODE_FAILED: llama_decode returned \(decode_result) at position \(n_cur)")

            /// Stop generation immediately on decode failure.
            is_done = true
            return ""
        }

        return new_token_str
    }

    // MARK: - Performance Metrics

    /// Get current generation performance statistics Returns (tokens_per_second, total_time_seconds, tokens_generated).
    func getPerformanceMetrics() -> (tokensPerSecond: Double, totalTime: Double, tokensGenerated: Int) {
        guard let startTime = generationStartTime else {
            return (0.0, 0.0, 0)
        }

        let totalTime = Date().timeIntervalSince(startTime)
        let tokensPerSecond = totalTime > 0 ? Double(tokensGenerated) / totalTime : 0.0

        return (tokensPerSecond, totalTime, tokensGenerated)
    }

    /// Set the maximum tokens limit for generation.
    /// This should be called before completion_init() to control how many tokens are generated.
    func setMaxTokensLimit(_ limit: Int) {
        maxTokensLimit = limit
    }

    func clear() {
        tokens_list.removeAll()
        temporary_invalid_cchars.removeAll()

        /// Reset position tracking - critical for conversation switching.
        n_cur = 0
        n_decode = 0

        /// Reset batch state.
        batch.n_tokens = 0

        /// Clear memory and KV cache.
        llama_memory_clear(llama_get_memory(context), true)

        /// Reset cancellation flag.
        isCancelled = false
    }

    /// Cancel ongoing generation - stops completion_loop() on next iteration CRITICAL: This allows stop button to immediately halt GPU-intensive generation.
    func cancel() {
        llamaLogger.info("CANCEL_REQUESTED: Setting cancellation flag")
        isCancelled = true
        is_done = true
    }

    /// Reset generation state without clearing KV cache Use this when starting a new generation in the same conversation.
    func resetGeneration() {
        tokens_list.removeAll()
        temporary_invalid_cchars.removeAll()
        n_decode = 0
        is_done = false
        isCancelled = false
    }

    // MARK: - KV Cache State Save/Restore (OPTIMIZATION PRIORITY 1)

    /// Save current KV cache state for per-conversation caching.
    func saveState() throws -> LlamaProvider.KVCacheState {
        /// Get size needed for state data.
        let stateSize = llama_state_get_size(context)

        /// Allocate buffer for state data.
        var stateBuffer = Data(count: stateSize)

        /// Get state data.
        let copiedSize = stateBuffer.withUnsafeMutableBytes { bufferPtr in
            llama_state_get_data(context, bufferPtr.baseAddress!.assumingMemoryBound(to: UInt8.self), stateSize)
        }

        guard copiedSize == stateSize else {
            throw LlamaError.generationFailed("Failed to save state: expected \(stateSize) bytes, got \(copiedSize)")
        }

        /// Create cache state with current position and tokens.
        let cacheState = LlamaProvider.KVCacheState(
            stateData: stateBuffer,
            tokens: tokens_list,
            nCur: n_cur,
            nDecode: n_decode
        )

        return cacheState
    }

    /// Restore KV cache state from saved data.
    func restoreState(_ cacheState: LlamaProvider.KVCacheState) throws {
        /// Restore state data.
        let restoredSize = cacheState.stateData.withUnsafeBytes { bufferPtr in
            llama_state_set_data(context, bufferPtr.baseAddress!.assumingMemoryBound(to: UInt8.self), cacheState.stateData.count)
        }

        guard restoredSize == cacheState.stateData.count else {
            throw LlamaError.generationFailed("Failed to restore state: expected \(cacheState.stateData.count) bytes, got \(restoredSize)")
        }

        /// Restore position and tokens.
        tokens_list = cacheState.tokens
        n_cur = cacheState.nCur
        n_decode = cacheState.nDecode

        /// Reset generation flags.
        is_done = false
        isCancelled = false
    }

    // MARK: - Tokenization

    private func tokenize(text: String, add_bos: Bool) -> [llama_token] {
        let utf8Count = text.utf8.count
        let n_tokens = utf8Count + (add_bos ? 1 : 0) + 1
        let tokens = UnsafeMutablePointer<llama_token>.allocate(capacity: n_tokens)
        let tokenCount = llama_tokenize(vocab, text, Int32(utf8Count), tokens, Int32(n_tokens), add_bos, false)

        var swiftTokens: [llama_token] = []
        for i in 0..<tokenCount {
            swiftTokens.append(tokens[Int(i)])
        }

        tokens.deallocate()
        return swiftTokens
    }

    private func token_to_piece(token: llama_token) -> [CChar] {
        let result = UnsafeMutablePointer<Int8>.allocate(capacity: 8)
        result.initialize(repeating: Int8(0), count: 8)
        defer {
            result.deallocate()
        }
        let nTokens = llama_token_to_piece(vocab, token, result, 8, 0, false)

        if nTokens < 0 {
            let newResult = UnsafeMutablePointer<Int8>.allocate(capacity: Int(-nTokens))
            newResult.initialize(repeating: Int8(0), count: Int(-nTokens))
            defer {
                newResult.deallocate()
            }
            let nNewTokens = llama_token_to_piece(vocab, token, newResult, -nTokens, 0, false)
            let bufferPointer = UnsafeBufferPointer(start: newResult, count: Int(nNewTokens))
            return Array(bufferPointer)
        } else {
            let bufferPointer = UnsafeBufferPointer(start: result, count: Int(nTokens))
            return Array(bufferPointer)
        }
    }

    // MARK: - Chat Template Formatting

    /// Format messages using llama.cpp's chat template system This ensures proper formatting with system prompts, roles, and special tokens.
    func format_chat(messages: [(role: String, content: String)]) -> String {
        /// Convert to llama_chat_message array.
        let chatMessages: [llama_chat_message] = messages.map { msg in
            llama_chat_message(
                role: strdup(msg.role),
                content: strdup(msg.content)
            )
        }

        defer {
            /// Free allocated strings.
            for msg in chatMessages {
                free(UnsafeMutablePointer(mutating: msg.role))
                free(UnsafeMutablePointer(mutating: msg.content))
            }
        }

        /// Calculate buffer size (2x total message content as recommended).
        let totalChars = messages.reduce(0) { $0 + $1.content.count + $1.role.count }
        let bufferSize = max(2048, totalChars * 2)

        /// Allocate buffer.
        let buffer = UnsafeMutablePointer<CChar>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }
        buffer.initialize(repeating: 0, count: bufferSize)

        /// Apply chat template (nil = use model's default template).
        let resultSize = llama_chat_apply_template(
            nil,
            chatMessages,
            chatMessages.count,
            true,
            buffer,
            Int32(bufferSize)
        )

        if resultSize < 0 {
            llamaLogger.error("Failed to apply chat template")
            /// Fallback to simple formatting.
            return messages.map { "\($0.role): \($0.content)" }.joined(separator: "\n\n") + "\nassistant:"
        }

        if resultSize > bufferSize {
            llamaLogger.warning("Chat template result truncated: needed \(resultSize) but only have \(bufferSize)")
        }

        let formatted = String(cString: buffer)
        return formatted
    }
}
