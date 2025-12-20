// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import SwiftUI
import MCPFramework
@preconcurrency import Sparkle
import AppKit

struct SAMCommands: Commands {
    var body: some Commands {
        /// Application Menu - Add Preferences and Check for Updates.
        CommandGroup(after: .appInfo) {
            #if DEBUG
            /// In DEBUG builds, Sparkle is initialized but manual checks are allowed.
            Button("Check for Updates… (Debug)") {
                NSLog("Check for Updates clicked in DEBUG build")
                if let appDelegate = AppDelegate.shared {
                    NSLog("AppDelegate.shared found, checking for updates...")
                    appDelegate.updater.checkForUpdates()
                } else {
                    NSLog("ERROR: Could not get AppDelegate.shared")
                }
            }
            #else
            Button("Check for Updates…") {
                NSLog("Check for Updates clicked")
                if let appDelegate = AppDelegate.shared {
                    NSLog("AppDelegate.shared found, checking for updates...")
                    appDelegate.updater.checkForUpdates()
                } else {
                    NSLog("ERROR: Could not get AppDelegate.shared")
                }
            }
            #endif

            Divider()

            Button("Preferences…") {
                NotificationCenter.default.post(name: .showPreferences, object: nil)
            }
            .keyboardShortcut(",", modifiers: .command)
        }

        /// File Menu.
        CommandGroup(replacing: .newItem) {
            Button("New Conversation") {
                NotificationCenter.default.post(name: .newConversation, object: nil)
            }
            .keyboardShortcut("n", modifiers: .command)

            Divider()

            Menu("Conversation") {
                Button("Rename…") {
                    NotificationCenter.default.post(name: .renameConversation, object: nil)
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])

                Button("Duplicate") {
                    NotificationCenter.default.post(name: .duplicateConversation, object: nil)
                }
                .keyboardShortcut("d", modifiers: [.command, .shift])

                Divider()

                Button("Convert to Shared Topic…") {
                    NotificationCenter.default.post(name: .convertToSharedTopic, object: nil)
                }
                .keyboardShortcut("t", modifiers: [.command, .shift])

                Divider()

                Button("Export…") {
                    NotificationCenter.default.post(name: .exportConversation, object: nil)
                }
                .keyboardShortcut("e", modifiers: [.command, .shift])

                Button("Print…") {
                    NotificationCenter.default.post(name: .printConversation, object: nil)
                }
                .keyboardShortcut("p", modifiers: .command)

                Divider()

                Button("Clear") {
                    NotificationCenter.default.post(name: .clearConversation, object: nil)
                }
                .keyboardShortcut("k", modifiers: .command)

                Button("Delete") {
                    NotificationCenter.default.post(name: .deleteConversation, object: nil)
                }
                .keyboardShortcut(.delete, modifiers: .command)
            }

            Divider()

            Button("Delete All Conversations…") {
                NotificationCenter.default.post(name: .deleteAllConversations, object: nil)
            }
            .keyboardShortcut(.delete, modifiers: [.command, .option])
        }

        /// Edit Menu.
        CommandGroup(after: .pasteboard) {
            Divider()

            Button("Find in Conversations…") {
                NotificationCenter.default.post(name: .showGlobalSearch, object: nil)
            }
            .keyboardShortcut("f", modifiers: .command)
        }

        /// View Menu - Navigation shortcuts.
        CommandGroup(before: .toolbar) {
            Menu("Navigate") {
                Button("Scroll to Top") {
                    NotificationCenter.default.post(name: .scrollToTop, object: nil)
                }
                .keyboardShortcut(.home, modifiers: .command)

                Button("Scroll to Bottom") {
                    NotificationCenter.default.post(name: .scrollToBottom, object: nil)
                }
                .keyboardShortcut(.end, modifiers: .command)

                Divider()

                Button("Page Up") {
                    NotificationCenter.default.post(name: .pageUp, object: nil)
                }
                .keyboardShortcut(.pageUp, modifiers: [])

                Button("Page Down") {
                    NotificationCenter.default.post(name: .pageDown, object: nil)
                }
                .keyboardShortcut(.pageDown, modifiers: [])
            }

            Divider()
        }

        /// Help Menu.
        CommandGroup(replacing: .help) {
            Button("Welcome Screen") {
                NotificationCenter.default.post(name: .showWelcome, object: nil)
            }

            Button("What's New") {
                NotificationCenter.default.post(name: .showWhatsNew, object: nil)
            }

            Divider()

            Button("SAM User Guide") {
                NotificationCenter.default.post(name: .showHelp, object: nil)
            }
            .keyboardShortcut("/", modifiers: [.command, .shift])

            Button("API Reference") {
                NotificationCenter.default.post(name: .showAPIReference, object: nil)
            }
            .keyboardShortcut("a", modifiers: [.command, .option])
        }
    }
}
