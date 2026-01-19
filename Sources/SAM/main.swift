// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import SwiftUI
import UserInterface
import APIFramework
import ConversationEngine
import MCPFramework
import ConfigurationSystem
import StableDiffusionIntegration
import Logging
import AppKit

struct SAMRewrittenApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    private let logger = Logger(label: "com.syntheticautonomicmind.sam.App")

    /// StateObjects for dependency management.
    @StateObject private var conversationManager = ConversationManager()
    @StateObject private var endpointManager: EndpointManager
    @StateObject private var sharedConversationService: SharedConversationService
    @StateObject private var apiServer: SAMAPIServer

    init() {
        /// Configure logging first thing.
        SAMRewrittenApp.configureLoggingFromUserDefaults()

        /// Initialize the shared ConversationManager first (without EndpointManager).
        let sharedConversationManager = ConversationManager()
        _conversationManager = StateObject(wrappedValue: sharedConversationManager)

        /// Initialize SharedConversationService with ConversationManager.
        let sharedService = SharedConversationService(conversationManager: sharedConversationManager)
        _sharedConversationService = StateObject(wrappedValue: sharedService)

        /// Initialize EndpointManager with the shared ConversationManager.
        let endpointMgr = EndpointManager(conversationManager: sharedConversationManager)
        _endpointManager = StateObject(wrappedValue: endpointMgr)

        /// Initialize API server with the same shared instances including SharedConversationService.
        let apiServerInstance = SAMAPIServer(conversationManager: sharedConversationManager, endpointManager: endpointMgr, sharedConversationService: sharedService)
        _apiServer = StateObject(wrappedValue: apiServerInstance)

        /// Inject dependencies after initialization to resolve circular dependencies.
        sharedConversationManager.injectAIProvider(endpointMgr)
        sharedConversationManager.injectSystemPromptManager(SystemPromptManager.shared)
        sharedService.injectEndpointManager(endpointMgr)

        /// Create and inject advanced tools factory for MCP system.
        self.createAndInjectAdvancedToolsFactory(into: sharedConversationManager, endpointManager: endpointMgr)

        /// Inject Stable Diffusion tool refresh handler.
        self.injectStableDiffusionRefreshHandler(into: sharedConversationManager)

        /// Initialize ALICE provider from saved settings (must be done early for tool registration).
        /// This is done in a task because it's async, but on MainActor.
        Task { @MainActor in
            ALICEProvider.initializeFromDefaults()
        }

        /// Log build configuration for verification (Priority 3 - verify Release mode flags).
        BuildConfiguration.logBuildMode()

        /// BUG #3: Inject ConversationManager into AppDelegate for cleanup on termination.
        /// This is done in next run loop to ensure AppDelegate is fully initialized.
        DispatchQueue.main.async { [weak appDelegate] in
            appDelegate?.conversationManager = sharedConversationManager
            appDelegate?.endpointManager = endpointMgr
        }

        /// Debug logging only in debug builds.
        #if DEBUG
        let timestamp = Date()
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss Z"

        logger.debug("=== SAM Debug Output ===")
        logger.debug("Launch Time: \(formatter.string(from: timestamp))")
        logger.debug("System: \(ProcessInfo.processInfo.operatingSystemVersionString)")
        logger.debug("User: \(ProcessInfo.processInfo.fullUserName) (\(ProcessInfo.processInfo.userName))")

        logger.debug("SAM initialized")
        logger.debug("Main interface initialized")
        #endif
    }

    /// Create advanced tools factory and inject into ConversationManager's MCP system This is done here to avoid circular dependencies between modules.
    private func createAndInjectAdvancedToolsFactory(into conversationManager: ConversationManager, endpointManager: EndpointManager) {
        /// Create async factory closure that generates advanced MCP tools.
        let advancedToolsFactory: () async -> [any MCPTool] = { [unowned conversationManager] in
            #if DEBUG
            let logger = Logger(label: "com.syntheticautonomicmind.sam.Factory")
            logger.debug("FACTORY: Advanced tools factory called")
            #endif

            /// Create tools on MainActor since WebResearchService requires it.
            return await MainActor.run {
                let webResearchService = WebResearchService(
                    vectorRAGService: conversationManager.vectorRAGService,
                    conversationManager: conversationManager
                )

                /// Create memory adapter for web operations retrieve functionality.
                let memoryAdapter = MemoryManagerAdapter(
                    memoryManager: conversationManager.memoryManager,
                    vectorRAGService: conversationManager.vectorRAGService
                )

                var tools: [any MCPTool] = []

                /// CONSOLIDATED TOOLS (39 → 9 tools) Each consolidated tool delegates to existing implementations.

                /// Web operations (4→1): web_research + web_search + web_scraping + fetch_webpage NOW INCLUDES: retrieve operation for accessing stored research from memory.
                tools.append(WebOperationsTool(
                    webResearchService: webResearchService,
                    memoryManager: memoryAdapter
                ))

                /// Document operations (3→1): document_import + document_create + get_doc_info.
                let documentImportSystem = DocumentImportSystem(conversationManager: conversationManager)
                let documentGenerator = DocumentGenerator()
                tools.append(DocumentOperationsTool(documentImportSystem: documentImportSystem, documentGenerator: documentGenerator))

                /// File operations (14→1): Consolidated file_read + file_search + file_write Read (4): read_file + list_dir + get_errors + get_search_results Search (4): file_search + grep_search + semantic_search + list_usages Write (6): create_file + replace_string + multi_replace_string + insert_edit + rename_file + apply_patch.
                tools.append(FileOperationsTool())

                /// Terminal operations (5→1): run_in_terminal + get_output + last_command + selection + create_directory.
                tools.append(TerminalOperationsTool())

                /// Build & version control (6→1): create_and_run_task + run_task + get_task_output + git_commit + get_changed_files + run_sam_command.
                let buildVCTool = BuildVersionControlTool()
                tools.append(buildVCTool)

                /// Image generation: Stable Diffusion (conditionally registered if models available).
                let sdModelManager = StableDiffusionModelManager()
                let installedSDModels = sdModelManager.listInstalledModels()

                /// Check for ALICE remote models too.
                let hasAliceModels = ALICEProvider.shared?.isHealthy == true && ALICEProvider.shared?.availableModels.isEmpty == false

                if !installedSDModels.isEmpty || hasAliceModels {
                    let sdService = StableDiffusionService()
                    let pythonService = PythonDiffusersService()
                    let upscalingService = UpscalingService()
                    let orchestrator = StableDiffusionOrchestrator(
                        coreMLService: sdService,
                        pythonService: pythonService,
                        upscalingService: upscalingService
                    )
                    let loraManager = LoRAManager()
                    let imageGenTool = ImageGenerationTool(orchestrator: orchestrator, modelManager: sdModelManager, loraManager: loraManager)
                    tools.append(imageGenTool)
                    #if DEBUG
                    let aliceModelCount = ALICEProvider.shared?.availableModels.count ?? 0
                    logger.debug("FACTORY: image_generation tool registered (\(installedSDModels.count) local + \(aliceModelCount) ALICE models)")
                    #endif
                } else {
                    #if DEBUG
                    logger.debug("FACTORY: image_generation tool SKIPPED (no Stable Diffusion models installed)")
                    #endif
                }

                /// User Collaboration Protocol - enables mid-stream user interaction.
                tools.append(UserCollaborationTool())

                /// Register ToolDisplayInfoProviders for all consolidated tools This enables protocol-based display info extraction (replacing hardcoded switch in AgentOrchestrator).
                let registry = ToolDisplayInfoRegistry.shared
                registry.register("memory_operations", provider: MemoryOperationsTool.self)
                registry.register("web_operations", provider: WebOperationsTool.self)
                registry.register("document_operations", provider: DocumentOperationsTool.self)
                registry.register("file_operations", provider: FileOperationsTool.self)
                registry.register("terminal_operations", provider: TerminalOperationsTool.self)
                registry.register("build_and_version_control", provider: BuildVersionControlTool.self)

                #if DEBUG
                let toolNames = tools.map { $0.name }.joined(separator: ", ")
                logger.debug("FACTORY: Returning \(tools.count) CONSOLIDATED tools: \(toolNames)")
                logger.debug("CONSOLIDATION COMPLETE: 39 tools → \(tools.count) tools (token reduction: ~71%)")
                logger.debug("DISPLAY INFO: Registered \(6) display info providers for protocol-based extraction")
                #endif

                return tools
            }

            /// CONSOLIDATION NOTES: Original tool count: 39 advanced tools + 3 builtin = 42 total Consolidated: 9 advanced tools + 3 builtin = 12 total Reduction: 71% fewer tools (42 → 12) Token savings: ~67% in system prompt All original functionality preserved via delegation pattern Deprecated tools moved to DeprecatedTools/ directories.
        }

        /// Inject the factory into the MCP manager.
        conversationManager.mcpManager.setAdvancedToolsFactory(advancedToolsFactory)

        #if DEBUG
        logger.debug("Advanced tools factory injected into MCP system")
        #endif
    }

    /// Inject Stable Diffusion tool refresh handler into ConversationManager Separate method to avoid self-capture issues in init().
    private func injectStableDiffusionRefreshHandler(into conversationManager: ConversationManager) {
        conversationManager.stableDiffusionToolRefreshHandler = { [weak conversationManager] in
            await MainActor.run {
                guard let conversationManager = conversationManager else { return }

                /// Check if tool already registered.
                if conversationManager.mcpManager.getToolByName("image_generation") != nil {
                    logger.debug("SD_REFRESH: image_generation tool already registered")
                    return
                }

                /// Check for installed SD models (local or ALICE remote).
                let sdModelManager = StableDiffusionModelManager()
                let installedModels = sdModelManager.listInstalledModels()
                let hasAliceModels = ALICEProvider.shared?.isHealthy == true && ALICEProvider.shared?.availableModels.isEmpty == false

                guard !installedModels.isEmpty || hasAliceModels else {
                    logger.info("SD_REFRESH: No Stable Diffusion models installed yet")
                    return
                }

                let aliceModelCount = ALICEProvider.shared?.availableModels.count ?? 0
                logger.info("SD_REFRESH: Found \(installedModels.count) local + \(aliceModelCount) ALICE model(s), registering image_generation tool")

                /// Create services and tool.
                let sdService = StableDiffusionService()
                let pythonService = PythonDiffusersService()
                let upscalingService = UpscalingService()
                let orchestrator = StableDiffusionOrchestrator(
                    coreMLService: sdService,
                    pythonService: pythonService,
                    upscalingService: upscalingService
                )
                let loraManager = LoRAManager()
                let imageGenTool = ImageGenerationTool(orchestrator: orchestrator, modelManager: sdModelManager, loraManager: loraManager)

                /// Register tool with MCPManager.
                conversationManager.mcpManager.registerTool(imageGenTool, name: "image_generation")
                logger.info("SD_REFRESH: Successfully registered image_generation tool - now available without restart!")
            }
        }
    }

    var body: some Scene {
        WindowGroup("Synthetic Autonomic Mind") {
            MainWindowView()
                .environmentObject(conversationManager)
                .environmentObject(endpointManager)
                .environmentObject(sharedConversationService)
                .environmentObject(apiServer)
                .onAppear {
                    #if DEBUG
                    logger.debug("Main window appeared")
                    logger.debug("Main window: Interface loaded successfully")
                    #endif

                    /// Register notification observer for SD model installation.
                    NotificationCenter.default.addObserver(
                        forName: .stableDiffusionModelInstalled,
                        object: nil,
                        queue: .main
                    ) { [weak conversationManager] _ in
                        Task { @MainActor in
                            conversationManager?.refreshStableDiffusionTool()
                        }
                    }

                    /// Initialize API server if enabled in preferences.
                    if UserDefaults.standard.bool(forKey: "enableAPIServer") {
                        Task {
                            do {
                                try await apiServer.startServer()
                                #if DEBUG
                                logger.info("API Server started successfully")
                                #endif
                            } catch {
                                logger.error("Failed to start API server: \(error)")
                            }
                        }
                    }
                }
        }
        .defaultSize(width: 600, height: 800)
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified(showsTitle: true))
        .commands {
            SAMCommands()
        }
    }

    // MARK: - Logging Configuration

    private static var loggingConfigured = false

    private static func configureLoggingFromUserDefaults() {
        /// Guard against multiple bootstrap calls (swift-log only allows one).
        guard !loggingConfigured else { return }
        loggingConfigured = true

        /// Read log level from UserDefaults.
        let levelString = UserDefaults.standard.string(forKey: "logLevel") ?? "Info"

        /// Convert to Logger.Level.
        let logLevel: Logger.Level
        switch levelString {
        case "Error":
            logLevel = .error

        case "Warning":
            logLevel = .warning

        case "Info":
            logLevel = .info

        case "Debug":
            logLevel = .debug

        default:
            logLevel = .info
        }

        /// Set the initial log level for DynamicLogHandler.
        DynamicLogHandler.currentLogLevel = logLevel

        /// Bootstrap swift-log with DynamicLogHandler for runtime log level changes.
        LoggingSystem.bootstrap { label in
            DynamicLogHandler(label: label)
        }
    }
}

/// Traditional main function for executable target.
SAMRewrittenApp.main()
