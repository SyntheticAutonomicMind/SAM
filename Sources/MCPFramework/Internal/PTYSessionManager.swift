// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import Foundation
import Darwin
import Logging

/// Manages persistent PTY terminal sessions Provides a basic terminal that: - Maintains persistent PTY sessions - Supports single pseudo-TTY per session - CP437 character set support - Command history accessible to agents and users - Bidirectional input/output Each session: - Has unique session ID - Runs bash shell in PTY - Captures all output (history buffer) - Accepts input commands - Persists until explicitly closed.
public class PTYSessionManager {
    public nonisolated(unsafe) static let shared = PTYSessionManager()

    private let logger = Logger(label: "com.sam.pty.SessionManager")
    private var sessions: [String: PTYSession] = [:]
    private let sessionsLock = NSLock()

    private init() {
        logger.debug("PTYSessionManager initialized")
    }

    /// Create a new PTY terminal session - Parameters: - conversationId: Conversation ID to associate with session (optional) - workingDirectory: Initial working directory (default: user home) - environment: Environment variables to set - Returns: Session ID and TTY name.
    public func createSession(
        conversationId: String? = nil,
        workingDirectory: String? = nil,
        environment: [String: String] = [:]
    ) throws -> (sessionId: String, ttyName: String) {
        /// Use conversation ID as session ID if provided, otherwise generate UUID.
        let sessionId = conversationId ?? UUID().uuidString

        /// Generate sequential TTY number based on session count.
        sessionsLock.lock()
        let ttyNumber = sessions.count + 1
        sessionsLock.unlock()

        let ttyName = "tty\(ttyNumber)"

        logger.debug("Creating PTY session: \(sessionId) (TTY: \(ttyName))")

        let session = try PTYSession(
            sessionId: sessionId,
            ttyName: ttyName,
            workingDirectory: workingDirectory ?? FileManager.default.homeDirectoryForCurrentUser.path,
            environment: environment,
            logger: logger
        )

        sessionsLock.lock()
        sessions[sessionId] = session
        sessionsLock.unlock()

        logger.debug("PTY session created: \(sessionId) → \(ttyName)")
        return (sessionId, ttyName)
    }

    /// Send input to a PTY session - Parameters: - sessionId: Session ID - input: Input text to send (will append newline if needed).
    public func sendInput(sessionId: String, input: String) throws {
        guard let session = getSession(sessionId) else {
            throw PTYSessionError.sessionNotFound(sessionId)
        }

        try session.sendInput(input)
    }

    /// Resize a PTY session - Parameters: - sessionId: Session ID - rows: New number of rows - cols: New number of columns.
    public func resizeSession(sessionId: String, rows: Int, cols: Int) throws {
        guard let session = getSession(sessionId) else {
            throw PTYSessionError.sessionNotFound(sessionId)
        }

        try session.resize(rows: UInt16(rows), cols: UInt16(cols))
    }

    /// Get output from a PTY session - Parameters: - sessionId: Session ID - fromIndex: Start reading from this index in history (default: 0) - Returns: Output text and current end index.
    public func getOutput(sessionId: String, fromIndex: Int = 0) async throws -> (output: String, endIndex: Int) {
        guard let session = getSession(sessionId) else {
            throw PTYSessionError.sessionNotFound(sessionId)
        }

        return await session.getOutput(fromIndex: fromIndex)
    }

    /// Get full history for a session - Parameter sessionId: Session ID - Returns: Full session history.
    public func getHistory(sessionId: String) async throws -> String {
        guard let session = getSession(sessionId) else {
            throw PTYSessionError.sessionNotFound(sessionId)
        }

        return await session.getFullHistory()
    }

    /// List all active sessions - Returns: Array of session IDs with metadata.
    public func listSessions() -> [(id: String, created: Date, workingDir: String)] {
        sessionsLock.lock()
        defer { sessionsLock.unlock() }

        return sessions.map { (id: $0.key, created: $0.value.created, workingDir: $0.value.workingDirectory) }
    }

    /// Close a PTY session - Parameter sessionId: Session ID.
    public func closeSession(sessionId: String) throws {
        guard let session = getSession(sessionId) else {
            throw PTYSessionError.sessionNotFound(sessionId)
        }

        sessionsLock.lock()
        sessions.removeValue(forKey: sessionId)
        sessionsLock.unlock()

        session.close()
        logger.debug("PTY session closed: \(sessionId)")
    }

    /// Close all sessions.
    public func closeAllSessions() {
        sessionsLock.lock()
        let allSessions = Array(sessions.values)
        sessions.removeAll()
        sessionsLock.unlock()

        for session in allSessions {
            session.close()
        }

        logger.debug("All PTY sessions closed")
    }

    /// Kill all processes running in a session (including descendants)
    /// This is useful when resetting a terminal during active workflows
    public func killAllSessionProcesses(sessionId: String) throws {
        guard let session = getSession(sessionId) else {
            throw PTYSessionError.sessionNotFound(sessionId)
        }

        session.killAllProcesses()
        logger.debug("Killed all processes in session: \(sessionId)")
    }

    private func getSession(_ sessionId: String) -> PTYSession? {
        sessionsLock.lock()
        defer { sessionsLock.unlock() }
        return sessions[sessionId]
    }
}

// MARK: - PTY Session Buffer Actor

/// Actor to manage PTY session output buffer in a thread-safe manner.
private actor PTYBufferActor {
    private var buffer: String = ""

    func append(_ text: String) -> (oldCount: Int, newCount: Int) {
        let oldCount = buffer.count
        buffer += text
        let newCount = buffer.count
        return (oldCount, newCount)
    }

    func getOutput(fromIndex: Int) -> (output: String, endIndex: Int) {
        let startIndex = buffer.index(buffer.startIndex, offsetBy: min(fromIndex, buffer.count), limitedBy: buffer.endIndex) ?? buffer.startIndex
        let output = String(buffer[startIndex...])
        return (output, buffer.count)
    }

    func getFullHistory() -> String {
        return buffer
    }
}

// MARK: - PTY Session

/// Single PTY terminal session.
private class PTYSession {
    let sessionId: String
    let ttyName: String
    let created: Date
    let workingDirectory: String
    let logger: Logger

    private var masterFd: Int32 = -1
    private var childPid: pid_t = -1
    private let bufferActor = PTYBufferActor()
    nonisolated(unsafe) private var isRunning = true
    private var readTask: Task<Void, Never>?

    init(
        sessionId: String,
        ttyName: String,
        workingDirectory: String,
        environment: [String: String],
        logger: Logger
    ) throws {
        self.sessionId = sessionId
        self.ttyName = ttyName
        self.created = Date()
        self.workingDirectory = workingDirectory
        self.logger = logger

        try startPTY(workingDirectory: workingDirectory, environment: environment)
    }

    private func startPTY(workingDirectory: String, environment: [String: String]) throws {
        /// Get current terminal settings as base.
        var termios = Darwin.termios()
        _ = Darwin.tcgetattr(STDIN_FILENO, &termios)

        /// Configure proper terminal flags for interactive shell Input flags.
        termios.c_iflag |= Darwin.tcflag_t(ICRNL)
        termios.c_iflag |= Darwin.tcflag_t(IXON)
        termios.c_iflag &= ~Darwin.tcflag_t(IXOFF)

        /// Output flags.
        termios.c_oflag |= Darwin.tcflag_t(OPOST)
        termios.c_oflag |= Darwin.tcflag_t(ONLCR)

        /// Control flags.
        termios.c_cflag |= Darwin.tcflag_t(CREAD)
        termios.c_cflag |= Darwin.tcflag_t(CS8)
        termios.c_cflag |= Darwin.tcflag_t(HUPCL)

        /// Local flags - CRITICAL for interactive shell.
        termios.c_lflag |= Darwin.tcflag_t(ECHO)
        termios.c_lflag |= Darwin.tcflag_t(ECHOE)
        termios.c_lflag |= Darwin.tcflag_t(ECHOK)
        termios.c_lflag |= Darwin.tcflag_t(ECHONL)
        termios.c_lflag |= Darwin.tcflag_t(ICANON)
        termios.c_lflag |= Darwin.tcflag_t(ISIG)
        termios.c_lflag |= Darwin.tcflag_t(IEXTEN)

        /// Control characters.
        termios.c_cc.0 = 4
        termios.c_cc.1 = 28
        termios.c_cc.2 = 127
        termios.c_cc.3 = 21
        termios.c_cc.4 = 3
        termios.c_cc.5 = 28
        termios.c_cc.6 = 26

        /// Get window size.
        var windowSize = Darwin.winsize()
        _ = Darwin.ioctl(STDIN_FILENO, TIOCGWINSZ, &windowSize)

        /// Default to reasonable size if not available.
        if windowSize.ws_col == 0 {
            windowSize.ws_col = 80
        }
        if windowSize.ws_row == 0 {
            windowSize.ws_row = 24
        }

        /// Fork with PTY.
        var master: Int32 = -1
        let pid = Darwin.forkpty(&master, nil, &termios, &windowSize)

        guard pid >= 0 else {
            throw PTYSessionError.forkFailed(errno)
        }

        if pid == 0 {
            /// Child process - run user's default shell.

            /// Change to working directory.
            Darwin.chdir(workingDirectory)

            /// Set environment.
            Darwin.setenv("TERM", "xterm-256color", 1)
            Darwin.setenv("LANG", "en_US.UTF-8", 1)
            for (key, value) in environment {
                Darwin.setenv(key, value, 1)
            }

            /// Use user's default shell, fall back to bash.
            let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/bash"
            let args = [shell, "-il"]
            let cArgs = args.map { strdup($0) } + [nil]
            defer { cArgs.forEach { free($0) } }

            Darwin.execv(shell, cArgs)

            /// If exec fails, exit.
            Darwin.exit(127)
        }

        /// Parent process.
        self.masterFd = master
        self.childPid = pid

        logger.debug("PTY session started - PID: \(pid), FD: \(master)")

        /// Set master FD to non-blocking.
        var flags = Darwin.fcntl(master, F_GETFL, 0)
        flags |= O_NONBLOCK
        _ = Darwin.fcntl(master, F_SETFL, flags)

        /// Start reading output asynchronously.
        startReadingOutput()
    }

    private func startReadingOutput() {
        let capturedMasterFd = masterFd
        let capturedSessionId = sessionId
        let capturedLogger = logger
        let capturedBufferActor = bufferActor

        readTask = Task {
            var buffer = [UInt8](repeating: 0, count: 4096)

            while !Task.isCancelled {
                let bytesRead = Darwin.read(capturedMasterFd, &buffer, buffer.count)

                if bytesRead > 0 {
                    capturedLogger.debug("PTYSession: Read \(bytesRead) bytes from masterFd")
                    if let output = String(bytes: buffer[0..<bytesRead], encoding: .utf8) {
                        /// Append to buffer via actor.
                        let (oldCount, newCount) = await capturedBufferActor.append(output)
                        capturedLogger.debug("PTYSession: Appended \(output.count) chars to buffer (was \(oldCount), now \(newCount))")
                    }
                } else if bytesRead == 0 {
                    /// EOF - process has exited.
                    capturedLogger.debug("PTY session \(capturedSessionId) process exited")
                    break
                } else if errno == EAGAIN || errno == EWOULDBLOCK {
                    /// No data available, wait a bit.
                    try? await Task.sleep(nanoseconds: 10_000_000)
                } else if errno != EINTR {
                    /// Read error.
                    capturedLogger.error("PTY session \(capturedSessionId) read error: \(errno)")
                    break
                }
            }

            capturedLogger.debug("PTY session \(capturedSessionId) read loop ended")
        }
    }

    func sendInput(_ input: String) throws {
        guard isRunning else {
            throw PTYSessionError.sessionClosed
        }

        /// Send input AS-IS - don't add newlines!.
        let bytesWritten = input.utf8CString.withUnsafeBufferPointer { buffer in
            /// Don't write the null terminator.
            Darwin.write(masterFd, buffer.baseAddress, buffer.count - 1)
        }

        if bytesWritten < 0 {
            throw PTYSessionError.writeFailed(errno)
        }

        logger.debug("Sent input to session \(sessionId): \(input)")
    }

    func resize(rows: UInt16, cols: UInt16) throws {
        guard isRunning else {
            throw PTYSessionError.sessionClosed
        }

        var windowSize = Darwin.winsize()
        windowSize.ws_row = rows
        windowSize.ws_col = cols
        windowSize.ws_xpixel = 0
        windowSize.ws_ypixel = 0

        let result = Darwin.ioctl(masterFd, UInt(TIOCSWINSZ), &windowSize)
        if result < 0 {
            throw PTYSessionError.writeFailed(errno)
        }

        logger.debug("Resized PTY session \(sessionId) to \(rows)x\(cols)")
    }

    func getOutput(fromIndex: Int) async -> (output: String, endIndex: Int) {
        let (output, endIndex) = await bufferActor.getOutput(fromIndex: fromIndex)
        logger.debug("PTYSession.getOutput: fromIndex=\(fromIndex), returning output.count=\(output.count), endIndex=\(endIndex)")
        return (output, endIndex)
    }

    func getFullHistory() async -> String {
        return await bufferActor.getFullHistory()
    }

    func close() {
        isRunning = false
        readTask?.cancel()

        if masterFd >= 0 {
            Darwin.close(masterFd)
            masterFd = -1
        }

        if childPid > 0 {
            /// First try SIGTERM for graceful shutdown.
            Darwin.kill(childPid, SIGTERM)

            /// Wait briefly for child to exit.
            var status: Int32 = 0
            let result = Darwin.waitpid(childPid, &status, WNOHANG)

            /// If still running, force kill with SIGKILL.
            if result == 0 {
                usleep(100000)
                let stillRunning = Darwin.waitpid(childPid, &status, WNOHANG)
                if stillRunning == 0 {
                    logger.debug("PTY session \(sessionId) - child didn't exit, sending SIGKILL")
                    Darwin.kill(childPid, SIGKILL)
                    Darwin.waitpid(childPid, &status, 0)
                }
            }

            childPid = -1
        }

        logger.debug("PTY session \(sessionId) closed")
    }

    /// Kill all processes in this session's process tree
    /// This forcefully terminates the shell and all descendant processes
    func killAllProcesses() {
        guard childPid > 0 else {
            logger.warning("Cannot kill processes - invalid shell PID")
            return
        }

        logger.debug("Killing all processes in session \(sessionId) (shell PID: \(childPid))")

        /// Get all descendant processes
        let descendants = getDescendantProcesses(of: childPid)
        logger.debug("Found \(descendants.count) descendant processes")

        /// Kill descendants first (bottom-up), then the shell
        for pid in descendants.reversed() {
            logger.debug("Sending SIGKILL to process \(pid)")
            Darwin.kill(pid, SIGKILL)
        }

        /// Finally kill the shell
        Darwin.kill(childPid, SIGKILL)

        /// Wait for processes to exit
        var status: Int32 = 0
        Darwin.waitpid(childPid, &status, 0)

        logger.debug("All processes killed in session \(sessionId)")
    }

    /// Get all descendant processes of a given PID
    private func getDescendantProcesses(of parentPid: pid_t) -> [pid_t] {
        var descendants: [pid_t] = []

        /// Use ps to find child processes
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/ps")
        task.arguments = ["-A", "-o", "pid,ppid"]

        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = nil

        do {
            try task.run()
            task.waitUntilExit()

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            guard let output = String(data: data, encoding: .utf8) else {
                return descendants
            }

            /// Parse ps output to build parent-child relationships
            var childrenMap: [pid_t: [pid_t]] = [:]
            for line in output.components(separatedBy: "\n") {
                let parts = line.split(separator: " ").compactMap { Int32($0) }
                guard parts.count == 2 else { continue }

                let pid = parts[0]
                let ppid = parts[1]

                childrenMap[ppid, default: []].append(pid)
            }

            /// Recursively collect all descendants
            func collectDescendants(of pid: pid_t) {
                if let children = childrenMap[pid] {
                    for child in children {
                        descendants.append(child)
                        collectDescendants(of: child)
                    }
                }
            }

            collectDescendants(of: parentPid)

        } catch {
            logger.error("Failed to enumerate processes: \(error)")
        }

        return descendants
    }

    deinit {
        close()
    }
}

// MARK: - Errors

public enum PTYSessionError: Error, CustomStringConvertible {
    case sessionNotFound(String)
    case sessionClosed
    case forkFailed(Int32)
    case writeFailed(Int32)

    public var description: String {
        switch self {
        case .sessionNotFound(let id):
            return "PTY session not found: \(id)"

        case .sessionClosed:
            return "PTY session is closed"

        case .forkFailed(let errno):
            return "Failed to fork PTY process: errno \(errno)"

        case .writeFailed(let errno):
            return "Failed to write to PTY: errno \(errno)"
        }
    }
}
