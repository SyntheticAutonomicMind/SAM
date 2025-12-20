// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import Foundation
import MCPFramework
import Logging
import CoreGraphics
import AppKit
import StableDiffusion
import APIFramework

/// MCP tool for AI image generation using Stable Diffusion
public class ImageGenerationTool: MCPTool, @unchecked Sendable {
    public let name = "image_generation"

    private let orchestrator: StableDiffusionOrchestrator
    private let modelManager: StableDiffusionModelManager
    private let loraManager: LoRAManager
    private let logger = Logger(label: "com.sam.mcp.ImageGeneration")

    public var description: String {
        /// Build available models list dynamically with type classification
        let localModels = modelManager.listInstalledModels()

        /// Also get ALICE remote models if available (use assumeIsolated for @unchecked Sendable tool)
        var allModels = localModels
        if let aliceProvider = ALICEProvider.shared {
            let (isHealthy, aliceModels) = MainActor.assumeIsolated {
                (aliceProvider.isHealthy, aliceProvider.availableModels)
            }
            if isHealthy {
                let remoteModels = aliceModels.map { alice in
                    StableDiffusionModelManager.createRemoteModelInfo(
                        aliceModelId: alice.id,
                        displayName: alice.displayName,
                        isSDXL: alice.isSDXL
                    )
                }
                allModels.append(contentsOf: remoteModels)
            }
        }

        let modelsList: String

        /// Track which engines are available across all models
        var hasCoreMLModels = false
        var hasPythonModels = false
        var hasAliceModels = false

        if allModels.isEmpty {
            modelsList = "\nNo models installed. Download from Preferences → Stable Diffusion or connect ALICE remote server.\n"
        } else {
            let modelsText = allModels.map { model in
                let nameLower = model.name.lowercased()
                let pipelineLower = model.pipelineType.lowercased()
                let modelType = nameLower.contains("zimage") || pipelineLower.contains("zimage") ? "Z-Image" :
                               (nameLower.contains("xl") || nameLower.contains("sdxl") ? "SDXL" : "SD1.5")

                /// Track available engines
                if model.hasCoreML { hasCoreMLModels = true }
                if model.hasSafeTensors { hasPythonModels = true }
                if model.isRemote { hasAliceModels = true }

                /// Show available engines for each model
                let engines = model.availableEngines.joined(separator: ", ")
                let location = model.isRemote ? " [ALICE]" : ""
                return "- \(model.id) [\(modelType)]\(location) (engines: \(engines))"
            }.joined(separator: "\n")
            modelsList = "\nMODELS:\n\(modelsText)\n"
        }

        /// Build available LoRAs list dynamically with model compatibility
        let loras = MainActor.assumeIsolated { loraManager.availableLoRAs }
        let lorasList: String

        if loras.isEmpty || !hasPythonModels {
            lorasList = ""
        } else {
            let lorasText = loras.prefix(10).map { lora -> String in  // Limit to 10 to control token usage
                let triggers = lora.triggerWords.isEmpty ? "" : " triggers: \(lora.triggerWords.joined(separator: ", "))"
                let compat = lora.baseModel == "Unknown" ? "any" : lora.baseModel
                return "- \(lora.filename) [\(compat)]\(triggers)"
            }.joined(separator: "\n")
            let moreNote = loras.count > 10 ? "\n  (\(loras.count - 10) more - use operation='list_loras' for full list)" : ""
            lorasList = "\nLORAs (Python engine, use lora_paths):\n\(lorasText)\(moreNote)\n"
        }

        /// Build engine documentation based on available engines
        var engineParts: [String] = []
        var schedulerParts: [String] = []

        if hasCoreMLModels {
            engineParts.append("'coreml' (fast, limited schedulers)")
            schedulerParts.append("- CoreML: 'dpm++_karras' (default), 'pndm'")
        }
        if hasPythonModels {
            engineParts.append("'python' (full features, LoRA)")
            schedulerParts.append("- Python: 'euler' (recommended for SDXL), 'dpm++_karras' (recommended for SD 1.5), 'euler_a', 'ddim', 'pndm', 'lms'")
        }
        if hasAliceModels {
            engineParts.append("'alice' (remote GPU server)")
            schedulerParts.append("- ALICE: 'ddim' (default), 'euler', 'euler_a', 'dpm++_karras'")
        }

        let engineInfo: String
        if !engineParts.isEmpty {
            let pythonNote = hasPythonModels ? "\nPYTHON-ONLY: lora_paths, lora_weights, input_image, strength, device" : ""
            let aliceNote = hasAliceModels ? "\nALICE: Remote models marked [ALICE] - uses 'alice' engine automatically" : ""
            engineInfo = """

            ENGINES: \(engineParts.joined(separator: " | "))
            NOTE: Check model's available engines - not all models support all engines.

            SCHEDULER COMPATIBILITY:
            \(schedulerParts.joined(separator: "\n"))\(pythonNote)\(aliceNote)
            """
        } else {
            engineInfo = ""
        }

        return """
        Generate CREATIVE/ARTISTIC images (photos, artwork, illustrations) using Stable Diffusion.
        NOT for charts, diagrams, or data visualization - use Mermaid markdown for those.

        OPERATIONS:
        - generate (default): Create images from prompts
        - list_loras: Get full list of installed LoRAs with compatibility info
        \(modelsList)\(lorasList)
        MODEL REQUIREMENTS (CRITICAL):
        - SD1.5: 512x512, steps 20-50, guidance 5-15
        - SDXL: 1024x1024, steps 25-60, guidance 5-12
        - Z-Image: 1024x1024, steps 4-8 ONLY, guidance MUST BE 0, use SHORT prompts
        \(engineInfo)
        RESOLUTION OPTIONS (choose ONE method):
        1. PRESETS (easiest): preset='sd15_square', 'sd15_portrait', 'sd15_landscape', 'sdxl_square', 'sdxl_portrait', 'sdxl_landscape', 'sdxl_ultrawide', '720p', '1080p', '1024x768', '1296x800'
        2. ASPECT RATIO: aspect_ratio='1:1', '3:4', '4:3', '16:9', '9:16', '21:9' (auto-calculates optimal dimensions)
        3. EXPLICIT: width=512, height=768 (advanced, must be divisible by 8)
        
        UPSCALING: upscale=true, upscale_model='general'|'anime'|'general_x2'

        Images auto-display. Don't use markdown image syntax.
        """
    }

    public var parameters: [String: MCPToolParameter] {
        [
            "operation": MCPToolParameter(
                type: .string,
                description: "Operation: 'generate' (default) or 'list_loras' for full LoRA list",
                required: false
            ),
            "prompt": MCPToolParameter(
                type: .string,
                description: "Detailed text description of the image to generate. Be specific and descriptive. Example: 'a serene mountain landscape at sunset with snow-capped peaks and a calm lake reflecting the orange sky, photorealistic style'",
                required: false  // Not required when using list_loras operation
            ),
            "negative_prompt": MCPToolParameter(
                type: .string,
                description: "Things to avoid in the image (optional). Example: 'blurry, low quality, distorted, ugly, bad anatomy'. Default: empty",
                required: false
            ),
            "steps": MCPToolParameter(
                type: .integer,
                description: "Number of inference steps. Z-Image models: 4-8 steps (default: 8). Standard SD models: 20-100 steps (default: 25). More steps = higher quality but slower. Example: 8 for z-image, 25 for SD models",
                required: false
            ),
            "guidance_scale": MCPToolParameter(
                type: .integer,
                description: "How closely to follow the prompt. Z-Image models: must be 0 (no CFG). Standard SD models: 1-20 (default: 8). Higher values stick closer to prompt. Example: 0 for z-image, 8 for SD models",
                required: false
            ),
            "seed": MCPToolParameter(
                type: .integer,
                description: "Random seed for reproducibility. Use -1 for random (default). Same seed with same prompt generates same image. Example: 42 or -1",
                required: false
            ),
            "image_count": MCPToolParameter(
                type: .integer,
                description: "Number of images to generate (1-4). Generates multiple variations of the same prompt. Default: 1. Example: 2",
                required: false
            ),
            "model": MCPToolParameter(
                type: .string,
                description: "Name of the Stable Diffusion model to use (see tool description for available models). If not specified, uses the first available model.",
                required: false
            ),
            "engine": MCPToolParameter(
                type: .string,
                description: "Generation engine: 'coreml' (fast, Apple Silicon, limited schedulers) or 'python' (slower, more features/schedulers). Default: 'coreml'. Choose engine BEFORE choosing scheduler.",
                required: false
            ),
            "scheduler": MCPToolParameter(
                type: .string,
                description: "Sampling scheduler. MUST match engine. CoreML: 'dpm++_karras' (default), 'pndm'. Python: 'euler' (recommended for SDXL), 'dpm++_karras' (default), 'euler_a', 'ddim', 'pndm', 'lms'. Wrong engine/scheduler combo will fail.",
                required: false
            ),
            "use_karras": MCPToolParameter(
                type: .boolean,
                description: "Use Karras sigma schedule with DPM++ (CoreML only) for improved quality. Default: true. Example: true",
                required: false
            ),
            "upscale": MCPToolParameter(
                type: .boolean,
                description: "Enable upscaling after generation. Default: false. Increases resolution 2x or 4x depending on model. Example: true",
                required: false
            ),
            "upscale_model": MCPToolParameter(
                type: .string,
                description: "Upscaling model: 'general' (default, 4x), 'anime' (4x for anime art), 'general_x2' (2x for faster upscaling). Example: 'general'",
                required: false
            ),
            "device": MCPToolParameter(
                type: .string,
                description: "Compute device (PYTHON ENGINE ONLY): 'auto' (default), 'mps' (Apple Silicon GPU), 'cpu' (slower but works for large models). CoreML engine ignores this parameter. Example: 'auto'",
                required: false
            ),
            "width": MCPToolParameter(
                type: .integer,
                description: "Image width in pixels. SD 1.5 models: 512 (default). SDXL models: 1024 (default). Z-Image models: 1024 (default). Must be divisible by 8. Alternative: use aspect_ratio or preset. Example: 512, 768, 1024",
                required: false
            ),
            "height": MCPToolParameter(
                type: .integer,
                description: "Image height in pixels. SD 1.5 models: 512 (default). SDXL models: 1024 (default). Z-Image models: 1024 (default). Must be divisible by 8. Alternative: use aspect_ratio or preset. Example: 512, 768, 1024",
                required: false
            ),
            "aspect_ratio": MCPToolParameter(
                type: .string,
                description: "Aspect ratio as ratio string (alternative to width/height). Examples: '1:1' (square), '3:4' (portrait), '4:3' (landscape), '16:9' (widescreen), '9:16' (vertical video), '21:9' (ultrawide). Dimensions auto-calculated based on model type and rounded to multiples of 8.",
                required: false
            ),
            "preset": MCPToolParameter(
                type: .string,
                description: "Named resolution preset (alternative to width/height/aspect_ratio). SD1.5: 'sd15_square', 'sd15_portrait', 'sd15_landscape'. SDXL: 'sdxl_square', 'sdxl_portrait', 'sdxl_landscape', 'sdxl_wide', 'sdxl_ultrawide'. Automatically uses optimal dimensions for selected model.",
                required: false
            ),
            "lora_paths": MCPToolParameter(
                type: .array,
                description: "Array of LoRA filenames (PYTHON ENGINE ONLY). Use filenames from LORAs list in description. Path auto-resolved. Example: ['style.safetensors']",
                required: false,
                arrayElementType: .string
            ),
            "lora_weights": MCPToolParameter(
                type: .array,
                description: "Array of weights for each LoRA (0.0-1.0, default 1.0 for each). Example: [0.8, 1.0]",
                required: false,
                arrayElementType: .string
            )
        ]
    }

    public init(orchestrator: StableDiffusionOrchestrator, modelManager: StableDiffusionModelManager, loraManager: LoRAManager) {
        self.orchestrator = orchestrator
        self.modelManager = modelManager
        self.loraManager = loraManager
    }

    // MARK: - Resolution Helper Functions

    /// Round dimension to nearest multiple of 8 (required for Stable Diffusion VAE)
    private func roundToMultiple(_ value: Int, multiple: Int = 8) -> Int {
        return ((value + multiple - 1) / multiple) * multiple
    }

    /// Calculate dimensions from aspect ratio string (e.g., "16:9", "3:4")
    private func dimensionsFromAspectRatio(_ aspectRatio: String, modelType: String) -> (width: Int, height: Int)? {
        let components = aspectRatio.split(separator: ":").compactMap { Int($0) }
        guard components.count == 2, components[0] > 0, components[1] > 0 else {
            return nil
        }

        let widthRatio = components[0]
        let heightRatio = components[1]

        /// Determine base resolution from model type
        let baseResolution: Int
        if modelType.lowercased().contains("xl") || modelType.lowercased().contains("flux") || modelType.lowercased().contains("sd3") {
            baseResolution = 1024
        } else if modelType.lowercased().contains("21") {
            baseResolution = 768
        } else {
            baseResolution = 512  // SD 1.5 default
        }

        /// Calculate dimensions maintaining aspect ratio
        let isLandscape = widthRatio > heightRatio
        let width: Int
        let height: Int

        if isLandscape {
            width = baseResolution
            height = (baseResolution * heightRatio) / widthRatio
        } else if heightRatio > widthRatio {
            height = baseResolution
            width = (baseResolution * widthRatio) / heightRatio
        } else {
            /// Square aspect ratio
            width = baseResolution
            height = baseResolution
        }

        /// Round to multiples of 8
        return (roundToMultiple(width), roundToMultiple(height))
    }

    /// Get dimensions from named preset
    private func dimensionsFromPreset(_ preset: String) -> (width: Int, height: Int)? {
        switch preset.lowercased() {
        /// SD 1.5 presets (512 base)
        case "sd15_square": return (512, 512)
        case "sd15_portrait": return (512, 768)
        case "sd15_landscape": return (768, 512)
        case "sd15_wide": return (896, 512)
        case "sd15_tall": return (512, 896)

        /// SDXL presets (1024 base) - comprehensive list
        case "sdxl_square": return (1024, 1024)
        case "sdxl_portrait": return (832, 1216)
        case "sdxl_tall_portrait": return (768, 1344)
        case "sdxl_ultra_portrait": return (640, 1536)
        case "sdxl_landscape": return (1216, 832)
        case "sdxl_wide_landscape": return (1344, 768)
        case "sdxl_ultrawide": return (1536, 640)
        case "sdxl_1152": return (1152, 896)
        case "sdxl_896": return (896, 1152)

        /// Common resolutions (auto-rounded to multiples of 8)
        case "720p": return (1280, 720)
        case "1080p": return (1920, 1080)
        case "4k": return (3840, 2160)
        case "768x768": return (768, 768)
        case "1024x768": return (1024, 768)
        case "1296x800": return (1296, 800)

        default: return nil
        }
    }

    public func execute(parameters: [String: Any], context: MCPExecutionContext) async -> MCPToolResult {
        logger.debug("Executing image generation tool")

        /// Check for list_loras operation first
        let operation = (parameters["operation"] as? String) ?? "generate"

        if operation == "list_loras" {
            return listLoRAsOperation()
        }

        guard let prompt = parameters["prompt"] as? String, !prompt.isEmpty else {
            return MCPToolResult(
                success: false,
                output: MCPOutput(content: """
                    ERROR: Missing or empty 'prompt' parameter

                    Required: prompt (string, detailed description of image to generate)
                    Example: {"prompt": "a serene mountain landscape at sunset"}

                    TIP: Be specific and descriptive for best results
                    """, mimeType: "text/plain"),
                toolName: name
            )
        }

        let negativePrompt = parameters["negative_prompt"] as? String
        let requestedModel = parameters["model"] as? String
        let inputImage = parameters["input_image"] as? String
        let strength = (parameters["strength"] as? Double) ?? 0.75
        let deviceStr = (parameters["device"] as? String) ?? "auto"
        let seed = (parameters["seed"] as? Int) ?? -1
        let imageCount = (parameters["image_count"] as? Int) ?? 1
        let requestedWidth = parameters["width"] as? Int
        let requestedHeight = parameters["height"] as? Int

        /// NOTE: steps and guidance_scale defaults depend on model type
        /// These will be set after model selection based on z-image detection

        /// Read user preferences for defaults
        let userDefaultEngine = UserDefaults.standard.string(forKey: "sd_default_engine") ?? "coreml"
        let userDefaultScheduler = UserDefaults.standard.string(forKey: "sd_default_scheduler") ?? "dpm++_karras"
        let userDefaultModel = UserDefaults.standard.string(forKey: "sd_default_model")
        let userEnableUpscaling = UserDefaults.standard.bool(forKey: "sd_enable_upscaling")
        let userUpscaleModel = UserDefaults.standard.string(forKey: "sd_upscale_model") ?? "general"

        /// Read ALICE settings from user defaults
        let aliceBaseURL = UserDefaults.standard.string(forKey: "alice_base_url")
        let aliceApiKey = UserDefaults.standard.string(forKey: "alice_api_key")

        /// Parse engine parameter (use user preference if not specified)
        let engineStr = (parameters["engine"] as? String) ?? userDefaultEngine
        let engine: GenerationEngine
        switch engineStr.lowercased() {
        case "coreml", "core-ml":
            engine = .coreML
        case "python", "diffusers":
            engine = .python
        case "alice", "remote":
            engine = .alice
        default:
            return MCPToolResult(
                success: false,
                output: MCPOutput(content: "ERROR: Invalid engine '\(engineStr)'. Use 'coreml', 'python', or 'alice'", mimeType: "text/plain"),
                toolName: name
            )
        }

        /// Parse scheduler parameter (use user preference if not specified)
        let schedulerStr = (parameters["scheduler"] as? String) ?? userDefaultScheduler
        var scheduler: UnifiedScheduler
        switch schedulerStr.lowercased() {
        case "dpm++", "dpmpp", "dpm", "dpm++_karras":
            scheduler = .dpmppKarras
        case "dpm++_2m_sde_karras", "dpm++_sde_karras", "dpm2m_sde_karras":
            scheduler = .dpmppSDEKarras
        case "dpm++_2m", "dpm++_2m_karras", "dpm2m_karras":
            scheduler = .dpmppKarras
        case "dpm++_sde":
            scheduler = .dpmppSDE
        case "euler_a", "euler_ancestral":
            scheduler = .eulerAncestral
        case "euler":
            scheduler = .euler
        case "ddim":
            scheduler = .ddim
        case "ddim_uniform":
            scheduler = .ddimUniform
        case "pndm":
            scheduler = .pndm
        case "lms":
            scheduler = .lms
        default:
            return MCPToolResult(
                success: false,
                output: MCPOutput(content: """
                    ERROR: Invalid scheduler '\(schedulerStr)'

                    Valid schedulers by engine:
                    CoreML: 'dpm++_karras', 'pndm'
                    Python: 'dpm++_sde_karras', 'dpm++_karras', 'dpm++_sde', 'euler_a', 'euler', 'ddim', 'ddim_uniform', 'pndm', 'lms'
                    ALICE: 'ddim', 'euler', 'euler_a', 'dpm++_karras', 'dpm++_sde_karras', 'pndm', 'lms'
                    """, mimeType: "text/plain"),
                toolName: name
            )
        }

        /// Auto-fallback: If scheduler not compatible with engine, use engine default
        /// This prevents the common error where agents pick Python schedulers with CoreML engine
        var schedulerWasCorrected = false
        let originalScheduler = scheduler
        if !scheduler.isAvailable(for: engine) {
            schedulerWasCorrected = true
            switch engine {
            case .coreML:
                scheduler = .dpmppKarras  // CoreML default
            case .python:
                scheduler = .dpmppSDEKarras  // Python default
            case .alice:
                scheduler = .ddim  // ALICE default
            }
            logger.warning("Scheduler '\(originalScheduler.displayName)' not available for \(engine.displayName), auto-selected '\(scheduler.displayName)'")
        }

        /// Parse upscaling parameters (use user preferences if not specified)
        let upscaleModelStr = (parameters["upscale_model"] as? String) ?? userUpscaleModel
        let shouldUpscale = upscaleModelStr.lowercased() != "none" && ((parameters["upscale"] as? Bool) ?? userEnableUpscaling)
        let upscaleModel: UpscalingService.UpscaleModel

        /// Only parse upscale model if upscaling is enabled
        if shouldUpscale {
            switch upscaleModelStr.lowercased() {
            case "general", "general_x4", "4x":
                upscaleModel = .general
            case "anime", "anime_x4":
                upscaleModel = .anime
            case "general_x2", "2x":
                upscaleModel = .generalX2
            default:
                return MCPToolResult(
                    success: false,
                    output: MCPOutput(content: "ERROR: Invalid upscale_model '\(upscaleModelStr)'. Use 'general', 'anime', 'general_x2', or 'none'", mimeType: "text/plain"),
                    toolName: name
                )
            }
        } else {
            /// Use default model (won't be used if shouldUpscale is false)
            upscaleModel = .general
        }

        let upscaleFactor = upscaleModel == .generalX2 ? 2 : 4

        /// Get safety setting from user preferences (transparent to LLM)
        let disableSafety = UserDefaults.standard.bool(forKey: "imageGenerationDisableSafety")
        logger.info("NSFW safety: \(disableSafety ? "disabled" : "enabled") (from user preferences)")

        /// Validate model-independent parameters
        guard (1...4).contains(imageCount) else {
            return MCPToolResult(
                success: false,
                output: MCPOutput(content: "ERROR: image_count must be between 1 and 4 (provided: \(imageCount))", mimeType: "text/plain"),
                toolName: name
            )
        }

        /// NOTE: steps validation moved after model selection (different models have different constraints)

        /// Check if models are installed (local or remote via ALICE)
        let localModels = await MainActor.run { modelManager.listInstalledModels() }
        let hasAliceModels = await MainActor.run {
            ALICEProvider.shared?.isHealthy == true && ALICEProvider.shared?.availableModels.isEmpty == false
        }

        if localModels.isEmpty && !hasAliceModels {
            return MCPToolResult(
                success: false,
                output: MCPOutput(content: """
                    ERROR: No Stable Diffusion models available

                    To generate images, you need either:

                    Option 1 - Install a local model:
                    1. Open SAM Preferences (⌘,)
                    2. Go to "Stable Diffusion" section
                    3. Click "Download" for a model
                    4. Wait for installation to complete

                    Option 2 - Connect to ALICE remote server:
                    1. Open SAM Preferences (⌘,)
                    2. Go to "Stable Diffusion" > "Settings" tab
                    3. Enter your ALICE server URL
                    4. Click "Test" to connect

                    The user has been informed they need to set up Stable Diffusion.
                    DO NOT proceed with image generation.
                    """, mimeType: "text/plain"),
                toolName: name
            )
        }

        /// Variables for steps and guidanceScale (declared here for error handler access)
        var steps: Int = 25  // Default for SD models
        var guidanceScale: Float = 8.0  // Default for SD models
        var isZImage: Bool = false

        do {
            /// Get remote models from ALICE (if configured)
            var remoteModels: [StableDiffusionModelManager.ModelInfo] = []
            if let aliceProvider = await MainActor.run(body: { ALICEProvider.shared }),
               await aliceProvider.isHealthy {
                let aliceModels = await MainActor.run { aliceProvider.availableModels }
                remoteModels = aliceModels.map { alice in
                    StableDiffusionModelManager.createRemoteModelInfo(
                        aliceModelId: alice.id,
                        displayName: alice.displayName,
                        isSDXL: alice.isSDXL
                    )
                }
            }

            /// Combine local and remote models
            let installedModels = await MainActor.run {
                modelManager.listAllModels(aliceModels: remoteModels)
            }

            /// Determine which model to use (priority: parameter > user preference > first available)
            let selectedModelName = requestedModel ?? userDefaultModel
            let currentModel: StableDiffusionModelManager.ModelInfo

            if let modelName = selectedModelName {
                /// Try to find the requested/preferred model
                /// If user specified alice engine, prefer ALICE models with same base name
                var found: StableDiffusionModelManager.ModelInfo?

                if engine == .alice {
                    /// Prefer remote models when alice engine is explicitly requested
                    found = installedModels.first(where: { model in
                        model.isRemote && (
                            model.name.lowercased().contains(modelName.lowercased()) ||
                            model.id.lowercased().contains(modelName.lowercased()) ||
                            (model.aliceModelId?.lowercased().contains(modelName.lowercased()) ?? false)
                        )
                    })
                }

                /// Fallback to any matching model
                if found == nil {
                    found = installedModels.first(where: {
                        $0.name.lowercased() == modelName.lowercased() ||
                        $0.id.lowercased() == modelName.lowercased() ||
                        $0.name.lowercased().contains(modelName.lowercased()) ||
                        $0.id.lowercased().contains(modelName.lowercased())
                    })
                }

                if let found = found {
                    currentModel = found
                } else {
                    /// Requested model not found - error (don't fall back)
                    let availableModels = installedModels.map { model in
                        let location = model.isRemote ? "[ALICE]" : "[Local]"
                        return "- \(model.name) \(location)"
                    }.joined(separator: "\n")
                    return MCPToolResult(
                        success: false,
                        output: MCPOutput(content: """
                            ERROR: Model not found: \(modelName)

                            Available models:
                            \(availableModels)

                            Please select one of the available models.
                            """, mimeType: "text/plain"),
                        toolName: name
                    )
                }
            } else {
                /// No model specified - use first available
                /// If alice engine requested, prefer first ALICE model
                var firstModel: StableDiffusionModelManager.ModelInfo?

                if engine == .alice {
                    firstModel = installedModels.first(where: { $0.isRemote })
                }

                if firstModel == nil {
                    firstModel = installedModels.first
                }

                guard let model = firstModel else {
                    return MCPToolResult(
                        success: false,
                        output: MCPOutput(content: "ERROR: No models available", mimeType: "text/plain"),
                        toolName: name
                    )
                }
                currentModel = model
            }

            /// Validate engine is available for selected model and auto-fallback if needed
            var engine = engine  /// Make engine mutable for potential fallback
            var engineWasCorrected = false
            let originalEngine = engine

            /// Check engine availability based on model type
            let engineAvailable: Bool
            if currentModel.isRemote {
                /// Remote models only support alice engine
                engineAvailable = engine == .alice
            } else {
                /// Local models support coreml/python based on file availability
                engineAvailable = (engine == .coreML && currentModel.hasCoreML) ||
                                  (engine == .python && currentModel.hasSafeTensors) ||
                                  (engine == .alice && aliceBaseURL != nil)
            }

            if !engineAvailable {
                /// Auto-fallback to an available engine
                if currentModel.isRemote {
                    /// Remote model - must use alice engine
                    engine = .alice
                    engineWasCorrected = true
                    logger.warning("Model '\(currentModel.name)' is remote, auto-selected 'alice' engine")
                } else if currentModel.hasCoreML {
                    engine = .coreML
                    engineWasCorrected = true
                    logger.warning("Engine '\(originalEngine.rawValue)' not available for model '\(currentModel.name)', auto-selected 'coreml'")
                } else if currentModel.hasSafeTensors {
                    engine = .python
                    engineWasCorrected = true
                    logger.warning("Engine '\(originalEngine.rawValue)' not available for model '\(currentModel.name)', auto-selected 'python'")
                } else {
                    /// Model has no valid engines (shouldn't happen but handle gracefully)
                    return MCPToolResult(
                        success: false,
                        output: MCPOutput(content: """
                            ERROR: Model '\(currentModel.name)' has no compatible generation engines.

                            Available engines for this model: \(currentModel.availableEngines.joined(separator: ", "))

                            The model may be corrupted or incomplete. Try re-downloading it.
                            """, mimeType: "text/plain"),
                        toolName: name
                    )
                }

                /// Also update scheduler if it's incompatible with the new engine
                if !scheduler.isAvailable(for: engine) {
                    let oldScheduler = scheduler
                    switch engine {
                    case .coreML:
                        scheduler = .dpmppKarras
                    case .python:
                        scheduler = .dpmppSDEKarras
                    case .alice:
                        scheduler = .ddim
                    }
                    schedulerWasCorrected = true
                    logger.warning("Scheduler '\(oldScheduler.displayName)' not available for \(engine.displayName), auto-selected '\(scheduler.displayName)'")
                }
            }

            /// Detect model type and set appropriate defaults
            isZImage = currentModel.pipelineType.lowercased().contains("zimage")

            /// Apply model-specific defaults (can be overridden by parameters)
            if isZImage {
                /// Z-Image defaults: 8 steps, 0 guidance (no CFG)
                steps = (parameters["steps"] as? Int) ?? 8
                let guidanceScaleInt = (parameters["guidance_scale"] as? Int) ?? 0
                guidanceScale = Float(guidanceScaleInt)

                /// Validate z-image constraints
                guard (4...50).contains(steps) else {
                    return MCPToolResult(
                        success: false,
                        output: MCPOutput(content: "ERROR: For Z-Image models, steps must be between 4 and 50 (provided: \(steps)). Recommended: 4-8 steps.", mimeType: "text/plain"),
                        toolName: name
                    )
                }

                guard guidanceScale == 0.0 else {
                    return MCPToolResult(
                        success: false,
                        output: MCPOutput(content: "ERROR: For Z-Image models, guidance_scale must be 0 (no classifier-free guidance). Provided: \(guidanceScale)", mimeType: "text/plain"),
                        toolName: name
                    )
                }
            } else {
                /// Standard SD defaults: 25 steps, 8 guidance
                steps = (parameters["steps"] as? Int) ?? 25
                let guidanceScaleInt = (parameters["guidance_scale"] as? Int) ?? 8
                guidanceScale = Float(guidanceScaleInt)

                /// Validate standard SD constraints
                guard (20...100).contains(steps) else {
                    return MCPToolResult(
                        success: false,
                        output: MCPOutput(content: "ERROR: For standard Stable Diffusion models, steps must be between 20 and 100 (provided: \(steps))", mimeType: "text/plain"),
                        toolName: name
                    )
                }

                guard (1.0...20.0).contains(guidanceScale) else {
                    return MCPToolResult(
                        success: false,
                        output: MCPOutput(content: "ERROR: For standard Stable Diffusion models, guidance_scale must be between 1.0 and 20.0 (provided: \(guidanceScale))", mimeType: "text/plain"),
                        toolName: name
                    )
                }
            }

            /// Log generation parameters
            logger.info("Generating image", metadata: [
                "engine": .string(engine.rawValue),
                "scheduler": .string(scheduler.rawValue),
                "prompt": .string(prompt),
                "steps": .stringConvertible(steps),
                "guidance": .stringConvertible(guidanceScale),
                "count": .stringConvertible(imageCount),
                "upscale": .stringConvertible(shouldUpscale),
                "model": .string(currentModel.name),
                "isZImage": .stringConvertible(isZImage)
            ])

            /// Determine image dimensions with priority: preset > aspect_ratio > width/height > model defaults
            let (defaultWidth, defaultHeight) = determineImageSize(for: currentModel)
            var finalWidth: Int
            var finalHeight: Int

            /// Check for preset parameter first
            if let preset = parameters["preset"] as? String,
               let presetDimensions = dimensionsFromPreset(preset) {
                finalWidth = presetDimensions.width
                finalHeight = presetDimensions.height
                logger.debug("Using preset '\(preset)': \(finalWidth)x\(finalHeight)")
            }
            /// Check for aspect_ratio parameter
            else if let aspectRatio = parameters["aspect_ratio"] as? String,
                    let aspectDimensions = dimensionsFromAspectRatio(aspectRatio, modelType: currentModel.pipelineType) {
                finalWidth = aspectDimensions.width
                finalHeight = aspectDimensions.height
                logger.debug("Using aspect ratio '\(aspectRatio)': \(finalWidth)x\(finalHeight)")
            }
            /// Fall back to explicit width/height or model defaults
            else {
                finalWidth = requestedWidth ?? defaultWidth
                finalHeight = requestedHeight ?? defaultHeight
            }

            /// Always round to multiples of 8 (VAE requirement)
            let originalWidth = finalWidth
            let originalHeight = finalHeight
            finalWidth = roundToMultiple(finalWidth)
            finalHeight = roundToMultiple(finalHeight)

            if originalWidth != finalWidth || originalHeight != finalHeight {
                logger.info("Rounded dimensions from \(originalWidth)x\(originalHeight) to \(finalWidth)x\(finalHeight) (SD requires multiples of 8)")
            }

            let width = finalWidth
            let height = finalHeight

            /// Get CoreML path from ModelInfo (for CoreML engine)
            let modelPath = (engine == .coreML) ? currentModel.path : nil

            /// Parse LoRA parameters (Python engine only)
            var loraPaths: [String]?
            var loraWeights: [Double]?
            if engine == .python {
                if let paths = parameters["lora_paths"] as? [String] {
                    /// Get available LoRAs once for resolution
                    let availableLoras = await MainActor.run { loraManager.availableLoRAs }

                    /// Resolve filenames to full paths (user can provide just filename)
                    loraPaths = paths.map { path in
                        /// If path is just a filename (no /), resolve from LoRA directory
                        if !path.contains("/") {
                            let filename = path.hasSuffix(".safetensors") ? path : "\(path).safetensors"
                            if let lora = availableLoras.first(where: { $0.filename == filename }) {
                                logger.debug("Resolved LoRA '\(path)' to '\(lora.path.path)'")
                                return lora.path.path
                            }
                            /// Fallback: construct path from directory
                            let resolvedPath = loraManager.loraDirectory.appendingPathComponent(filename).path
                            logger.debug("Constructed LoRA path: '\(resolvedPath)'")
                            return resolvedPath
                        }
                        return path
                    }
                }
                if let weights = parameters["lora_weights"] as? [Double] {
                    loraWeights = weights
                } else if let weights = parameters["lora_weights"] as? [NSNumber] {
                    loraWeights = weights.map { $0.doubleValue }
                }
            }

            /// Create generation configuration
            /// NOTE: Use currentModel.id for modelName - this is the directory name
            /// (e.g., "paint-journey-v2" not "Paint Journey V2")
            /// Both CoreML and Python engines need the actual directory name
            let config = StableDiffusionOrchestrator.GenerationConfig(
                prompt: prompt,
                negativePrompt: negativePrompt,
                modelName: currentModel.id,
                modelPath: modelPath,
                scheduler: scheduler,
                steps: steps,
                guidanceScale: guidanceScale,
                width: width,
                height: height,
                seed: seed == -1 ? nil : seed,
                imageCount: imageCount,
                engine: engine,
                enableUpscaling: shouldUpscale,
                upscaleModel: upscaleModel,
                upscaleFactor: upscaleFactor,
                workingDirectory: context.workingDirectory,
                inputImage: inputImage,
                strength: strength,
                device: deviceStr,
                loraPaths: loraPaths,
                loraWeights: loraWeights,
                aliceBaseURL: aliceBaseURL,
                aliceApiKey: aliceApiKey,
                aliceModelId: currentModel.aliceModelId
            )

            /// Generate images using orchestrator
            let result = try await orchestrator.generateImages(config: config)
            let images = result.images
            let savedPaths = result.imagePaths.map { $0.path }

            guard !images.isEmpty else {
                throw GenerationError.failedToSaveImage
            }

            let firstImage = images[0]
            var additionalContext: [String: String] = [
                "imagePaths": savedPaths.joined(separator: ","),
                "imageType": "stable-diffusion",
                "prompt": prompt,
                "negativePrompt": negativePrompt ?? "",
                "steps": String(steps),
                "guidanceScale": String(guidanceScale),
                "seed": String(seed),
                "imageCount": String(images.count),
                "width": String(firstImage.width),
                "height": String(firstImage.height),
                "engine": engine.rawValue,
                "scheduler": scheduler.rawValue,
                "upscaled": String(shouldUpscale),
                "upscaleModel": shouldUpscale ? upscaleModel.rawValue : ""
            ]

            /// Add metadata from orchestrator result
            for (key, value) in result.metadata {
                additionalContext[key] = String(describing: value)
            }

            /// Create LLM-focused output content (matching standard tool pattern)
            let fileList = savedPaths.enumerated().map { index, path in
                let url = URL(fileURLWithPath: path)
                return "\(index + 1). \(url.lastPathComponent) - \(path)"
            }.joined(separator: "\n")

            /// Build generation details string
            let upscaleInfo = shouldUpscale ? "\n- Upscaled: Yes (using \(upscaleModel.rawValue) model, \(upscaleFactor)x)" : ""

            /// Include engine and scheduler correction notices if applicable
            var correctionNotes = ""
            if engineWasCorrected {
                correctionNotes += "\n\nNOTE: Engine was auto-corrected from '\(originalEngine.rawValue)' to '\(engine.rawValue)' because the model '\(currentModel.name)' only supports: \(currentModel.availableEngines.joined(separator: ", "))."
            }
            if schedulerWasCorrected {
                correctionNotes += "\n\nNOTE: Scheduler was auto-corrected from '\(originalScheduler.displayName)' to '\(scheduler.displayName)' for \(engine.displayName) engine compatibility."
            }

            /// LLM-focused output: Tell agent image was displayed, provide params for asking user
            let llmContent = """
            SUCCESS: Generated and displayed \(images.count) image\(images.count > 1 ? "s" : "") to the user.

            The image\(images.count > 1 ? "s have" : " has") been automatically displayed in the chat interface.

            Generation Parameters:
            - Prompt: \(prompt)
            - Negative Prompt: \(negativePrompt ?? "none")
            - Model: \(currentModel.name)
            - Engine: \(engine.displayName)
            - Steps: \(steps)
            - Guidance Scale: \(guidanceScale)
            - Seed: \(seed == -1 ? "random" : String(seed))
            - Scheduler: \(scheduler.displayName)
            - Resolution: \(firstImage.width)×\(firstImage.height)\(upscaleInfo)
            - Images Generated: \(images.count)\(correctionNotes)

            You can now ask the user if the image\(images.count > 1 ? "s match" : " matches") their expectations or if they'd like any adjustments.

            File location\(images.count > 1 ? "s" : ""):
            \(fileList)
            """

            /// Post notification for UI to display images
            /// This triggers the streaming workflow to emit an SSE event
            /// ChatWidget will receive the event and create a message with contentParts
            logger.debug("IMAGE_GEN_TOOL: Posting imageDisplay notification", metadata: [
                "imageCount": .stringConvertible(savedPaths.count),
                "toolCallId": .string(context.toolCallId ?? "none"),
                "paths": .string(savedPaths.joined(separator: ", "))
            ])

            ToolNotificationCenter.shared.postImageDisplay(
                toolCallId: context.toolCallId ?? UUID().uuidString,
                imagePaths: savedPaths,
                prompt: prompt,
                conversationId: context.conversationId
            )

            logger.debug("IMAGE_GEN_TOOL: Notification posted")

            return MCPToolResult(
                toolName: name,
                success: true,
                output: MCPOutput(
                    content: llmContent,
                    mimeType: "text/plain"
                ),
                metadata: MCPResultMetadata(additionalContext: additionalContext)
            )

        } catch {
            logger.error("Image generation failed: \(error.localizedDescription)")
            return MCPToolResult(
                success: false,
                output: MCPOutput(content: """
                    ERROR: Image generation failed

                    Reason: \(error.localizedDescription)

                    Prompt: \(prompt)
                    Steps: \(steps)
                    Guidance: \(guidanceScale)

                    TIP: Try reducing steps or adjusting guidance_scale
                    """, mimeType: "text/plain"),
                toolName: name
            )
        }
    }

    /// Determine image size based on model type
    private func determineImageSize(for model: StableDiffusionModelManager.ModelInfo) -> (width: Int, height: Int) {
        /// SDXL models use 1024x1024, SD 1.5 models use 512x512
        if model.name.lowercased().contains("xl") {
            return (1024, 1024)
        } else {
            return (512, 512)
        }
    }

    /// Sanitize filename by removing/replacing special characters
    private func sanitizeFilename(_ name: String) -> String {
        return name
            .replacingOccurrences(of: "[^a-zA-Z0-9]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    /// List all available LoRAs with full details
    private func listLoRAsOperation() -> MCPToolResult {
        let loras = MainActor.assumeIsolated { loraManager.availableLoRAs }

        if loras.isEmpty {
            return MCPToolResult(
                success: true,
                output: MCPOutput(content: """
                    No LoRAs installed.

                    To add LoRAs:
                    1. Open SAM Preferences → Stable Diffusion
                    2. Browse CivitAI LoRAs and download
                    3. Or manually copy .safetensors files to:
                       ~/Library/Caches/sam/models/stable-diffusion/loras/
                    """, mimeType: "text/plain"),
                toolName: name
            )
        }

        var output = "INSTALLED LORAS (\(loras.count) total):\n\n"

        for lora in loras {
            let compat = lora.baseModel == "Unknown" ? "any (unknown base)" : lora.baseModel
            let triggers = lora.triggerWords.isEmpty ? "none specified" : lora.triggerWords.joined(separator: ", ")

            output += """
            - \(lora.filename)
              Compatibility: \(compat)
              Trigger words: \(triggers)

            """
        }

        output += """

        USAGE:
        - Python engine required for LoRAs (engine: "python")
        - Pass filename to lora_paths: ["\(loras.first?.filename ?? "style.safetensors")"]
        - Optionally set lora_weights: [0.8] (default: 1.0)
        - Include trigger words in your prompt for best results
        - Match base model (SD1.5 LoRA with SD1.5 model)
        """

        return MCPToolResult(
            success: true,
            output: MCPOutput(content: output, mimeType: "text/plain"),
            toolName: name
        )
    }
}
