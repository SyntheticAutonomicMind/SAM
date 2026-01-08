// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import AppKit
import Foundation
import Sparkle
import ConversationEngine
import APIFramework

class AppDelegate: NSObject, NSApplicationDelegate, SPUUpdaterDelegate {
    private(set) var updaterController: SPUStandardUpdaterController!
    private var windowFrameObserver: NSObjectProtocol?
    private var configuredWindows: Set<ObjectIdentifier> = []

    /// Shared instance for accessing updater from Commands.
    nonisolated(unsafe) static weak var shared: AppDelegate?

    // MARK: - Bug #3: Reference to ConversationManager for cleanup
    weak var conversationManager: ConversationManager?

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

        /// Initialize Sparkle updater with delegate for logging.
        /// Note: Even in DEBUG, we set startingUpdater=true so manual checks work.
        updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: self,
            userDriverDelegate: nil
        )
        
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
}
