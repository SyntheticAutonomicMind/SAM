// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import SwiftUI
import AppKit
import UserInterface
import ConversationEngine
import APIFramework
import ConfigurationSystem
import SecurityFramework
import MCPFramework
import Logging

/// Owns and restores SAM's main window.
///
/// On macOS 13+ (and especially 15.6), when the sole `WindowGroup` scene's window
/// is closed (red traffic-light / Cmd+W), AppKit destroys the scene and
/// `applicationShouldHandleReopen` returning `true` no longer causes SwiftUI
/// to re-create the `WindowGroup`. The result: there is no way to bring SAM's
/// window back without relaunching the app.
///
/// To make the window reliably restorable we keep an explicit reference to the
/// main `NSWindow` and recreate it from the SwiftUI `MainWindowView` via an
/// `NSHostingController` when reopen is requested and no main window exists.
///
/// This is the same mechanism AppKit uses for its own restore-on-reopen
/// behavior; relying on it directly sidesteps the SwiftUI `WindowGroup`
/// recreation regression.
@MainActor
final class SAMMainWindowManager: NSObject, ObservableObject {
    static let shared = SAMMainWindowManager()

    private let logger = Logger(label: "com.sam.winrestore")

    /// The currently-visible main window, if any.
    private(set) weak var window: NSWindow?

    /// The window's saved frame (persisted by AppKit's autosave name).
    private let autosaveName = "SAMMainWindow"

    /// The dependencies required to host `MainWindowView`.
    ///
    /// These are injected from the `App` (which owns the `@StateObject`s) during
    /// `applicationDidFinishLaunching` via the weak refs already on
    /// `AppDelegate`.
    weak var conversationManager: ConversationManager?
    weak var endpointManager: EndpointManager?
    weak var sharedConversationService: SharedConversationService?
    weak var credentialStore: CredentialStore?

    /// Font scale read from UserDefaults; cached at window creation time.
    private var fontSizeScale: Double {
        UserDefaults.standard.double(forKey: "fontSizeScale")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    private override init() {
        super.init()
        observeWindowClosures()
    }

    // MARK: - Public API

    /// Called by `AppDelegate.applicationShouldHandleReopen` and the Dock-menu
    /// "New Window" action. Ensures a main window is visible: if we already
    /// own one, bring it forward; otherwise adopt any visible SAM window that
    /// AppKit created (e.g. during first-launch loading-screen transition) or
    /// create a fresh one.
    @MainActor
    func restoreMainWindow() {
        logger.info("restoreMainWindow invoked; windows=\(NSApp.windows.count)")

        // Snapshot all visible, titled SAM windows *first*, before any mutation.
        let samWindows = NSApp.windows.filter { $0.isVisible && $0.title == "Synthetic Autonomic Mind" }
        logger.debug("visible SAM titled windows: \(samWindows.count)")

        // If we already own a visible window, just bring it forward.
        if let existing = window, existing.isVisible {
            logger.info("Owned main window already visible (0x\(String(Int(bitPattern: ObjectIdentifier(existing)), radix: 16))); making key/front")
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        // Adopt an existing visible SAM window created by the WindowGroup
        // (or any other path) instead of spawning a duplicate.
        if let existing = samWindows.first {
            let prev = window
            window = existing
            logger.info("Adopted existing visible SAM window as main 0x\(String(Int(bitPattern: ObjectIdentifier(existing)), radix: 16)) (prev: \(String(describing: prev)))")
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        createMainWindow()
    }

    /// Creates a fresh main window hosting `MainWindowView`.
    @MainActor
    private func createMainWindow() {
        logger.info("Creating new main window")

        guard let conversationManager,
              let endpointManager,
              let sharedConversationService,
              let credentialStore else {
            logger.error("Cannot create main window: dependencies not injected (boot may be incomplete)")
            // Still activate so the dock icon highlights; the next reopen will retry.
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let content = MainWindowView()
            .environmentObject(conversationManager)
            .environmentObject(endpointManager)
            .environmentObject(sharedConversationService)
            .environmentObject(credentialStore)
            .environment(\.fontSizeScale, FontManager.resolvedScale(from: fontSizeScale))

        let hosting = NSHostingController(rootView: content)

        let window = NSWindow(contentViewController: hosting)
        window.title = "Synthetic Autonomic Mind"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.isReleasedWhenClosed = false        // we manage the reference; don't let AppKit dealloc it
        window.isRestorable = true
        window.setFrameAutosaveName(autosaveName) // restore saved size/position across launches
        window.backgroundColor = .windowBackgroundColor
        window.level = .normal

        // Keep a strong reference so the window survives after resigning main.
        self.window = window

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        logger.info("Main window created and shown 0x\(String(Int(bitPattern: ObjectIdentifier(window)), radix: 16))")
    }

    // MARK: - Lifecycle observation

    private func observeWindowClosures() {
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            // Only clear our reference when OUR main window closes (matched by
            // identity, not title/autosave name). This avoids conflating our
            // recreated window with the SwiftUI WindowGroup's window during
            // first launch.
            guard let window = notification.object as? NSWindow else { return }
            // Only clear our reference when OUR main window closes (matched by
            // identity, not title/autosave name). This avoids conflating our
            // recreated window with the SwiftUI WindowGroup's window during
            // first launch.
            guard let ours = self?.window else {
                self?.logger.debug("willClose for window NOT owned by us 0x\(String(Int(bitPattern: ObjectIdentifier(window)), radix: 16)); ignoring")
                return
            }
            guard window === ours else {
                self?.logger.debug("willClose for window 0x\(String(Int(bitPattern: ObjectIdentifier(window)), radix: 16)) != our 0x\(String(Int(bitPattern: ObjectIdentifier(ours)), radix: 16)); ignoring")
                return
            }
            self?.window = nil
            self?.logger.info("Main window closed; reference cleared 0x\(String(Int(bitPattern: ObjectIdentifier(window)), radix: 16))")
        }
    }

    /// Inject dependencies once the App has initialized its StateObjects.
    @MainActor
    func inject(conversationManager: ConversationManager,
                endpointManager: EndpointManager,
                sharedConversationService: SharedConversationService,
                credentialStore: CredentialStore) {
        self.conversationManager = conversationManager
        self.endpointManager = endpointManager
        self.sharedConversationService = sharedConversationService
        self.credentialStore = credentialStore
    }
}
