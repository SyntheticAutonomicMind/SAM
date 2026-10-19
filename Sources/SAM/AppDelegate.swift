// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import AppKit
import Foundation
import Sparkle
import UserInterface
import ConversationEngine
import APIFramework
import ConfigurationSystem
import SecurityFramework
import MCPFramework
import Logging

class AppDelegate: NSObject, NSApplicationDelegate, SPUUpdaterDelegate {
    private(set) var updaterController: SPUStandardUpdaterController!
    nonisolated(unsafe) private var windowFrameObserver: NSObjectProtocol?
    private var configuredWindows: Set<ObjectIdentifier> = []
    private let logger = Logger(label: "com.sam.appdelegate")

    /// Shared instance for accessing updater from Commands.
    nonisolated(unsafe) static weak var shared: AppDelegate?

    // MARK: - Bug #3: Reference to ConversationManager for cleanup
    weak var conversationManager: ConversationManager?
    /// STRONG reference to prevent premature deallocation during app termination.
    /// SwiftUI view hierarchy may tear down before applicationWillTerminate fires,
    /// causing weak references to be nil when cleanup runs.
    var endpointManager: EndpointManager?

    override init() {
        super.init()
        AppDelegate.shared = self
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        /// Configure application to appear in dock.
        NSApp.setActivationPolicy(.regular)

        /// Load saved Copilot tokens if available
        Task { @MainActor in
            try? await CopilotTokenStore.shared.loadTokens()
        }

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
        logger.info("Sparkle updater initialized with startingUpdater=true (DEBUG build, manual checks enabled)")
        #else
        logger.info("Sparkle updater initialized with startingUpdater=true (RELEASE build)")
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
        logger.info("SPARKLE: Found valid update: \(item.displayVersionString) (build \(item.versionString))")
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: Error) {
        logger.warning("SPARKLE: Did not find update. Error: \(error.localizedDescription)")
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        logger.info("SPARKLE: Did not find update (no error)")
    }

    func updater(_ updater: SPUUpdater, didFinishLoading appcast: SUAppcast) {
        logger.info("SPARKLE: Finished loading appcast with \(appcast.items.count) items")
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        /// Keep app running when last window is closed (standard macOS behavior).
        return false
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        return true
    }

    // MARK: - Window Restoration

    /// Restores the main window after it has been closed.
    ///
    /// Because `applicationShouldTerminateAfterLastWindowClosed` returns `false`,
    /// SAM keeps running (and stays in the Dock) when its window is closed.
    ///
    /// On macOS 13+ (and especially 15.6), simply returning `true` here is no
    /// longer sufficient to re-create the SwiftUI `WindowGroup` scene once its
    /// sole window has been closed. We therefore delegate to
    /// `SAMMainWindowManager`, which maintains an explicit `NSWindow`
    /// reference and recreates it via an `NSHostingController(MainWindowView())`
    /// when no main window is visible.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        logger.info("Reopen requested — hasVisibleWindows: \(hasVisibleWindows)")
        SAMMainWindowManager.shared.restoreMainWindow()
        return true
    }

    // MARK: - Dock Menu

    /// Builds the Dock (right-click) menu so users can restore the main window
    /// after closing it, without quitting and relaunching SAM.
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu(title: "SAM")

        let newWindow = NSMenuItem(title: "New Window", action: #selector(dockNewWindow), keyEquivalent: "")
        newWindow.target = self
        menu.addItem(newWindow)

        menu.addItem(.separator())

        let newConversation = NSMenuItem(title: "New Conversation", action: #selector(dockNewConversation), keyEquivalent: "")
        newConversation.target = self
        menu.addItem(newConversation)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit", action: #selector(NSApp.terminate), keyEquivalent: "q")
        quit.target = nil
        menu.addItem(quit)

        return menu
    }

    /// Restores (or creates) the main window from the Dock menu.
    @objc private func dockNewWindow() {
        logger.debug("Dock menu: New Window selected")
        SAMMainWindowManager.shared.restoreMainWindow()
    }

    /// Creates a new conversation from the Dock menu.
    @objc private func dockNewConversation() {
        logger.debug("Dock menu: New Conversation selected")
        NSApp.activate(ignoringOtherApps: true)
        NotificationCenter.default.post(name: .newConversation, object: nil)
    }

    // MARK: - Bug #3: App Termination Cleanup

    func applicationWillTerminate(_ notification: Notification) {
        /// Ensure all pending conversation saves complete before app exits.
        conversationManager?.cleanup()

        /// CRASH FIX: llama.cpp's ggml_metal_device_free asserts that residual sets are empty,
        /// but they aren't after normal usage. This is a known llama.cpp issue:
        /// https://github.com/ggml-org/llama.cpp/pull/17869
        ///
        /// Calling _exit(0) skips C++ static destructors entirely, avoiding the crash.
        /// The OS reclaims all resources (GPU buffers, memory, file handles) on process exit.
        /// Conversation data is already saved above.
        ///
        /// We cannot use llama_free/llama_model_free/llama_backend_free to prevent this because
        /// the Metal residual sets persist regardless. Async cleanup also deadlocks because
        /// applicationWillTerminate is synchronous and blocking the main thread.
        _exit(0)
    }

    // MARK: - Window Frame Persistence

    private func setupWindowFramePersistence() {
        /// Observe window did become main so we can attach the autosave name
        /// (once per window), letting AppKit restore/persist its frame.
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

        /// Set autosave name so AppKit remembers and restores the main window's
        /// frame across launches automatically.
        window.setFrameAutosaveName("SAMMainWindow")

        /// We intentionally do NOT manually restore a saved frame here. The
        /// previous implementation stored the frame in "SAMMainWindowFrame"
        /// (UserDefaults) and re-applied it from a `didBecomeMain` observer —
        /// which fires when the window is clicked — causing the window to jump
        /// to an older saved location on every click. AppKit's
        /// `setFrameAutosaveName` above already persists and restores the frame
        /// reliably and only does so once (at window creation), so it is now the
        /// sole source of truth for window position.
    }

    deinit {
        if let observer = windowFrameObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }
    
    // MARK: - API Token Management
    
    /// Initialize or retrieve API token for secure API access.
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
