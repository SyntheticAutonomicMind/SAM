// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import SwiftUI
import Foundation
import Logging
import MCPFramework

/// Notification for terminal session reset
extension Notification.Name {
    static let terminalSessionReset = Notification.Name("terminalSessionReset")
}

/// Embedded terminal view with command execution and output display Black background, green text, classic terminal aesthetic.
public struct TerminalView: View {
    @ObservedObject var terminalManager: TerminalManager
    @State private var commandInput = ""
    @State private var autoScroll = true
    @Binding var isVisible: Bool

    private let logger = Logging.Logger(label: "com.sam.ui.TerminalView")

    /// Initialize terminal view with an existing terminal manager.
    public init(terminalManager: TerminalManager, isVisible: Binding<Bool>) {
        self.terminalManager = terminalManager
        _isVisible = isVisible
    }

    public var body: some View {
        VStack(spacing: 0) {
            /// Header.
            HStack {
                Image(systemName: "terminal")
                    .foregroundColor(.green)
                Text("Terminal")
                    .font(.headline)
                    .foregroundColor(.primary)

                Spacer()

                /// Current directory display.
                Text(terminalManager.displayCurrentDirectory)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(.green)
                    .lineLimit(1)
                    .help(terminalManager.currentDirectory)

                Spacer()

                /// Reset button.
                Button(action: { resetTerminal() }) {
                    Image(systemName: "arrow.clockwise")
                        .foregroundColor(.blue)
                }
                .buttonStyle(.plain)
                .help("Reset Terminal")

                /// Close button.
                Button(action: { isVisible = false }) {
                    Image(systemName: "xmark")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help("Close Terminal")
            }
            .padding(8)
            .background(Color(NSColor.controlBackgroundColor))

            Divider()

            /// Terminal content with loading overlay
            ZStack {
                /// xterm.js terminal emulator with PTY integration.
                XTermTerminalView(
                    sessionId: terminalManager.sessionId,
                    terminalManager: terminalManager
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .id(terminalManager.sessionId)
                .opacity(terminalManager.isResetting ? 0.3 : 1.0)

                /// Loading overlay when resetting
                if terminalManager.isResetting {
                    VStack(spacing: 16) {
                        ProgressView()
                            .scaleEffect(1.5)
                            .progressViewStyle(.circular)

                        Text("Resetting terminal...")
                            .font(.system(.body, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                    .padding()
                    .background(Color(NSColor.windowBackgroundColor).opacity(0.9))
                    .cornerRadius(8)
                }
            }
        }
        .frame(minHeight: 200, idealHeight: 400, maxHeight: 600)
    }

    private func executeCommand() {
        guard !commandInput.isEmpty else { return }
        logger.debug("Executing command: \(commandInput)")
        terminalManager.executeCommandSync(commandInput)
        commandInput = ""
    }

    private func resetTerminal() {
        logger.debug("Resetting terminal via UI button")

        /// Use the same reset logic as directory changes
        /// This ensures consistent behavior across all reset scenarios
        terminalManager.resetSessionForNewDirectory(terminalManager.currentDirectory)
    }
}

/// Individual terminal line with styling.
struct TerminalLineView: View {
    let line: TerminalLine

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            /// Timestamp (optional).
            if let timestamp = line.timestamp {
                Text(timestamp, style: .time)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundColor(.secondary)
                    .frame(width: 60, alignment: .leading)
            }

            /// Line content with color.
            Text(line.content)
                .font(.system(.body, design: .monospaced))
                .foregroundColor(line.color)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Data Models

/// Represents a single line of terminal output.
struct TerminalLine: Identifiable {
    let id = UUID()
    let content: String
    let color: Color
    let timestamp: Date?

    init(content: String, color: Color = .white, timestamp: Date? = nil) {
        self.content = content
        self.color = color
        self.timestamp = timestamp
    }
}

// MARK: - Terminal Manager

/// Terminal manager that handles command execution and output display Conforms to TerminalCommandExecutor protocol for MCP integration.
@MainActor
public class TerminalManager: NSObject, ObservableObject, TerminalCommandExecutor {
    @Published var outputLines: [TerminalLine] = []
    @Published var currentDirectory: String
    @Published var isExecuting = false
    @Published var sessionId: String?
    @Published var isResetting = false  // New: Track terminal reset state

    /// Reference to terminal view for AI agent access.
    weak var terminalView: XTermWebView?

    private let conversationId: String
    private var process: Process?
    private let logger = Logging.Logger(label: "com.sam.terminal.TerminalManager")

    /// Display-friendly current directory (abbreviated with ~).
    var displayCurrentDirectory: String {
        if currentDirectory.hasPrefix(NSHomeDirectory()) {
            return currentDirectory.replacingOccurrences(of: NSHomeDirectory(), with: "~")
        }
        return currentDirectory
    }

    public init(workingDirectory: String, conversationId: String) {
        self.currentDirectory = workingDirectory
        self.conversationId = conversationId
        super.init()
        setupTerminal()
    }

    public func setupTerminal() {
        /// Ensure working directory exists.
        ensureDirectoryExists(currentDirectory)

        /// Create PTY session with conversationId as sessionId This allows AI agents to automatically know their session ID!.
        do {
            let (sessionId, ttyName) = try PTYSessionManager.shared.createSession(
                conversationId: conversationId,
                workingDirectory: currentDirectory,
                environment: ProcessInfo.processInfo.environment
            )
            self.sessionId = sessionId
            logger.debug("Created PTY session for conversation \(conversationId): \(sessionId) (TTY: \(ttyName))")

            /// Send reset -Q to initialize terminal cleanly
            Task {
                try? await Task.sleep(nanoseconds: 100_000_000)  // 100ms for shell to start
                do {
                    try PTYSessionManager.shared.sendInput(sessionId: sessionId, input: "reset -Q\r")
                    logger.debug("Sent reset -Q to new terminal session")
                } catch {
                    logger.error("Failed to send reset -Q: \(error)")
                }
            }
        } catch {
            /// CRITICAL: Even if PTY creation fails, set sessionId to conversationId
            /// This allows agent to still access the session ID via KVC
            /// Agent will create/reuse PTY session using this ID
            self.sessionId = conversationId
            logger.error("Failed to create PTY session, using conversationId as sessionId fallback: \(error)")
        }
    }

    private func ensureDirectoryExists(_ path: String) {
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false

        if !fileManager.fileExists(atPath: path, isDirectory: &isDirectory) {
            do {
                try fileManager.createDirectory(
                    atPath: path,
                    withIntermediateDirectories: true,
                    attributes: nil
                )
                logger.debug("Created working directory: \(path)")
            } catch {
                logger.error("Failed to create working directory: \(error)")
            }
        }
    }

    /// Execute a command in the terminal (accessible via Objective-C runtime for MCP integration) Execute command synchronously (for UI button clicks).
    public func executeCommandSync(_ command: String) {
        /// Synchronous version for UI - returns immediately.
        Task {
            _ = await executeCommand(command)
        }
    }

    /// Execute command asynchronously and return output (TerminalCommandExecutor protocol) This version sends command to the shared PTY terminal and waits for output.
    public func executeCommand(_ command: String) async -> String {
        /// Trace execute entry.
        logger.critical("DEBUG_TRACE: TerminalView.executeCommand ENTRY - command=\(command)")

        guard let sessionId = sessionId else {
            logger.error("No PTY session available")
            return "ERROR: Terminal not initialized"
        }

        logger.debug("Executing command in shared terminal: \(command)")

        do {
            /// Get current output length before sending command.
            let (_, startIndex) = try await PTYSessionManager.shared.getOutput(sessionId: sessionId, fromIndex: 0)

            /// About to send input.
            logger.critical("DEBUG_TRACE: About to call PTYSessionManager.sendInput - command=\(command)")

            /// Send command to PTY (same terminal user sees).
            try PTYSessionManager.shared.sendInput(sessionId: sessionId, input: command + "\r")

            logger.critical("DEBUG_TRACE: PTYSessionManager.sendInput returned successfully")

            /// Wait for command to execute and produce output Poll for new output with timeout.
            var attempts = 0
            var newOutput = ""

            while attempts < 100 {
                try await Task.sleep(nanoseconds: 100_000_000)

                let (output, endIndex) = try await PTYSessionManager.shared.getOutput(sessionId: sessionId, fromIndex: startIndex)

                /// Check if we got new output.
                if !output.isEmpty && endIndex > startIndex {
                    newOutput = output

                    /// Check if command completed (new prompt appeared).
                    if output.contains("$") && output.split(separator: "\n").count > 1 {
                        break
                    }
                }

                attempts += 1
            }

            logger.debug("Command completed, output: \(newOutput.count) chars")
            return newOutput

        } catch {
            logger.error("Failed to execute command: \(error)")
            return "ERROR: \(error.localizedDescription)"
        }
    }

    /// Get current terminal buffer contents (for AI agents).
    public func getTerminalBuffer() async -> String {
        guard let terminalView = terminalView else {
            logger.warning("Terminal view not available")
            return ""
        }

        return await withCheckedContinuation { continuation in
            terminalView.getTerminalBuffer { buffer in
                continuation.resume(returning: buffer)
            }
        }
    }

    private func addOutput(_ output: String, color: Color) {
        /// Split by newlines and add each line.
        let lines = output.split(separator: "\n", omittingEmptySubsequences: false)
        for line in lines where !line.isEmpty {
            outputLines.append(TerminalLine(
                content: String(line),
                color: color,
                timestamp: nil
            ))
        }
    }

    func clearOutput() {
        outputLines.removeAll()
        setupTerminal()
        logger.debug("Terminal output cleared")
    }

    /// Update working directory (called when conversation's working directory changes).
    func updateWorkingDirectory(_ newDirectory: String) {
        currentDirectory = newDirectory
        ensureDirectoryExists(newDirectory)
        outputLines.append(TerminalLine(
            content: "Working directory changed to: \(displayCurrentDirectory)",
            color: .yellow,
            timestamp: Date()
        ))
        logger.debug("Working directory updated to: \(newDirectory)")
    }

    /// Reset terminal session with new working directory
    /// Changes directory and sends reset command to clear terminal display
    @objc public func resetSessionForNewDirectory(_ newDirectory: String) {
        logger.debug("Resetting terminal for new directory: \(newDirectory)")

        /// Set resetting state FIRST (shows loading indicator)
        isResetting = true

        /// Perform reset asynchronously to allow UI to update
        Task { @MainActor in
            /// Small delay to let UI show loading overlay
            try? await Task.sleep(nanoseconds: 50_000_000)  // 50ms

            /// Update current directory
            currentDirectory = newDirectory
            ensureDirectoryExists(newDirectory)

            /// Send cd command to change directory
            guard let sessionId = sessionId else {
                logger.error("No session ID for terminal reset")
                isResetting = false
                return
            }

            do {
                /// Change to new directory
                try PTYSessionManager.shared.sendInput(sessionId: sessionId, input: "cd \"\(newDirectory)\"\r")

                /// Wait briefly for cd to complete
                try await Task.sleep(nanoseconds: 100_000_000)  // 100ms

                /// Send reset -Q command to clear terminal display quietly
                try PTYSessionManager.shared.sendInput(sessionId: sessionId, input: "reset -Q\r")

                logger.debug("Terminal reset to directory: \(displayCurrentDirectory)")
            } catch {
                logger.error("Failed to reset terminal: \(error)")
            }

            /// Clear resetting state
            try? await Task.sleep(nanoseconds: 200_000_000)  // 200ms for reset to complete
            isResetting = false
        }
    }

    deinit {
        process?.terminate()
    }
}
