// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import AppKit
import Foundation
import Sparkle
import ConversationEngine
import APIFramework
import ConfigurationSystem
import Logging

class AppDelegate: NSObject, NSApplicationDelegate, SPUUpdaterDelegate {
    private(set) var updaterController: SPUStandardUpdaterController!
    private var windowFrameObserver: NSObjectProtocol?
    private var configuredWindows: Set<ObjectIdentifier> = []
    private let logger = Logger(label: "com.sam.appdelegate")

    /// Shared instance for accessing updater from Commands.
    nonisolated(unsafe) static weak var shared: AppDelegate?

    // MARK: - Bug #3: Reference to ConversationManager for cleanup
    weak var conversationManager: ConversationManager?
    weak var endpointManager: EndpointManager?

    override init() {
        super.init()
        AppDelegate.shared = self
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        /// Configure application to appear in dock.
        NSApp.setActivationPolicy(.regular)

        /// Load saved Copilot tokens if available
        Task { @MainActor in
            try? CopilotTokenStore.shared.loadTokens()
        }
        
        /// Initialize API token for secure API access
        initializeAPIToken()

        /// Initialize Sparkle updater with delegate for logging.
        /// Note: Even in DEBUG, we set startingUpdater=true so manual checks work.
        updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: self,
            userDriverDelegate: nil
        )
        
        /// Set feed URL based on development updates preference
        updateFeedURL()
        
        /// Listen for development updates preference changes
        NotificationCenter.default.addObserver(
            forName: NSNotification.Name("developmentUpdatesPreferenceChanged"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.updateFeedURL()
        }
        
        #if DEBUG
        NSLog("Sparkle updater initialized with startingUpdater=true (DEBUG build, manual checks enabled)")
        #else
        NSLog("Sparkle updater initialized with startingUpdater=true (RELEASE build)")
        #endif

        /// Set up window frame persistence.
        setupWindowFramePersistence()
    }

    /// Expose updater for menu integration.
    var updater: SPUUpdater {
        return updaterController.updater
    }

    // MARK: - SPUUpdaterDelegate

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        NSLog("SPARKLE: Found valid update: \(item.displayVersionString) (build \(item.versionString))")
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: Error) {
        NSLog("SPARKLE: Did not find update. Error: \(error.localizedDescription)")
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        NSLog("SPARKLE: Did not find update (no error)")
    }

    func updater(_ updater: SPUUpdater, didFinishLoading appcast: SUAppcast) {
        NSLog("SPARKLE: Finished loading appcast with \(appcast.items.count) items")
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        /// Keep app running when last window is closed (standard macOS behavior).
        return false
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        return true
    }

    // MARK: - Bug #3: App Termination Cleanup

    func applicationWillTerminate(_ notification: Notification) {
        /// Ensure all pending conversation saves complete before app exits.
        conversationManager?.cleanup()

        /// Unload all local models to prevent Metal resource cleanup crashes.
        /// Use a semaphore to block until cleanup completes.
        if let manager = endpointManager {
            let semaphore = DispatchSemaphore(value: 0)
            Task {
                await manager.cleanup()
                semaphore.signal()
            }
            /// Wait up to 5 seconds for cleanup to complete.
            _ = semaphore.wait(timeout: .now() + 5.0)
        }
        
        /// CRITICAL: Free llama.cpp backend resources after all models are unloaded
        /// This must be called exactly ONCE at app termination, after all LlamaContext
        /// instances are deallocated. Calling it in LlamaContext.deinit causes crashes
        /// when multiple contexts exist or when Metal resources aren't ready to be freed.
        llamaBackendCleanup()
    }

    // MARK: - Window Frame Persistence

    private func setupWindowFramePersistence() {
        /// Observe window did become main to restore and persist frame.
        windowFrameObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeMainNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let window = notification.object as? NSWindow else { return }
            self?.configureWindowPersistence(window)
        }
    }

    private func configureWindowPersistence(_ window: NSWindow) {
        /// Only configure each window ONCE Previously, this ran every time window became main, causing frame to reset.
        let windowID = ObjectIdentifier(window)
        guard !configuredWindows.contains(windowID) else {
            return
        }

        /// Only persist frame for main application window Skip file panels, sheets, and other auxiliary windows.
        guard !window.isSheet else {
            return
        }

        /// Skip NSPanel windows (like file dialogs).
        if window is NSPanel {
            return
        }

        /// Only persist if this looks like the main content window.
        guard window.contentViewController != nil else {
            return
        }

        // MARK: - this window as configured
        configuredWindows.insert(windowID)

        /// Set autosave name for automatic frame persistence This tells macOS to save/restore window frame automatically.
        window.setFrameAutosaveName("SAMMainWindow")

        /// Restore saved frame if available (ONLY on first configuration).
        if let frameString = UserDefaults.standard.string(forKey: "SAMMainWindowFrame"),
           !frameString.isEmpty {
            let frame = NSRectFromString(frameString)
            if frame != .zero {
                window.setFrame(frame, display: true, animate: false)
            }
        }

        /// Save frame whenever it changes (only for this specific window).
        NotificationCenter.default.addObserver(
            forName: NSWindow.didResizeNotification,
            object: window,
            queue: .main
        ) { notification in
            guard let window = notification.object as? NSWindow else { return }
            /// Double-check this is still the main window.
            guard window.frameAutosaveName == "SAMMainWindow" else { return }
            let frameString = NSStringFromRect(window.frame)
            UserDefaults.standard.set(frameString, forKey: "SAMMainWindowFrame")
        }

        NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification,
            object: window,
            queue: .main
        ) { notification in
            guard let window = notification.object as? NSWindow else { return }
            /// Double-check this is still the main window.
            guard window.frameAutosaveName == "SAMMainWindow" else { return }
            let frameString = NSStringFromRect(window.frame)
            UserDefaults.standard.set(frameString, forKey: "SAMMainWindowFrame")
        }
    }

    deinit {
        if let observer = windowFrameObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }
    
    // MARK: - API Token Management
    
    /// Initialize or retrieve API token for secure API access.
    /// 
    /// This method ensures that a secure random token exists in UserDefaults for API authentication.
    /// The token is generated on first launch and persists across app restarts.
    private func initializeAPIToken() {
        let tokenKey = "samAPIToken"
        
        // Check if token already exists
        if let existingToken = UserDefaults.standard.string(forKey: tokenKey), !existingToken.isEmpty {
            logger.info("API token already exists in UserDefaults")
            return
        }
        
        // Generate new secure token
        let token = generateSecureToken()
        
        // Store in UserDefaults
        UserDefaults.standard.set(token, forKey: tokenKey)
        UserDefaults.standard.synchronize()
        logger.info("Generated and stored new API token in UserDefaults")
    }
    
    /// Generate a secure random token for API authentication.
    ///
    /// The token format is two UUIDs concatenated with a hyphen, providing
    /// sufficient entropy for secure API access control.
    ///
    /// - Returns: A secure random token string
    private func generateSecureToken() -> String {
        return "\(UUID().uuidString)-\(UUID().uuidString)"
    }
    
    /// Update Sparkle feed URL based on development updates preference
    private func updateFeedURL() {
        let developmentEnabled = UserDefaults.standard.bool(forKey: "developmentUpdatesEnabled")
        let feedURL = developmentEnabled ? AppcastURLs.development : AppcastURLs.stable
        
        updaterController.updater.setFeedURL(feedURL)
        
        logger.info("Sparkle feed URL updated to: \(developmentEnabled ? "development" : "stable") (\(feedURL.absoluteString))")
        
        // Check for updates immediately after switching feeds
        if developmentEnabled {
            logger.info("Development updates enabled - checking for updates")
            updaterController.updater.checkForUpdatesInBackground()
        }
    }
}
