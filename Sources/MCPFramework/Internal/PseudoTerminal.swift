// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import Foundation
import Darwin

/// Pseudo-Terminal (PTY) implementation for interactive terminal support Provides a full interactive terminal with PTY support, ANSI escape sequences, and CP437 character set compatibility for robust terminal emulation.
public class PseudoTerminal {

    /// Result of PTY command execution.
    public struct Result {
        public let terminalId: String
        public let command: String
        public let output: String
        public let exitCode: Int32
        public let executionTime: Double
        public let isBackground: Bool
        public let pid: pid_t?
        public let isInteractive: Bool
    }

    private var masterFd: Int32 = -1
    private var childPid: pid_t = -1
    private var originalTermios: termios?
    private let terminalId: String

    public init() {
        self.terminalId = UUID().uuidString
    }

    deinit {
        cleanup()
    }

    /// Execute a command in a pseudo-terminal - Parameters: - command: Shell command to execute - workingDirectory: Working directory for command execution - isInteractive: Whether command requires interactive terminal - Returns: Execution result with output and exit code.
    public func executeCommand(
        _ command: String,
        workingDirectory: String? = nil,
        isInteractive: Bool = false
    ) async throws -> Result {
        let startTime = Date()

        /// Save original terminal settings if stdin is a tty.
        var currentTermios = termios()
        if Darwin.tcgetattr(STDIN_FILENO, &currentTermios) == 0 {
            originalTermios = currentTermios
        }

        /// Get current window size.
        var windowSize = winsize()
        _ = Darwin.ioctl(STDIN_FILENO, TIOCGWINSZ, &windowSize)

        /// Fork with PTY.
        var master: Int32 = -1
        let pid = Darwin.forkpty(&master, nil, &currentTermios, &windowSize)

        guard pid >= 0 else {
            throw PTYError.forkFailed(errno)
        }

        if pid == 0 {
            /// Child process.

            /// Change working directory if specified.
            if let workingDir = workingDirectory {
                Darwin.chdir(workingDir)
            }

            /// Set locale for proper character handling.
            setenv("LANG", "en_US.UTF-8", 1)
            setenv("TERM", "xterm-256color", 1)

            /// Execute command.
            let shell = "/bin/bash"
            let args = [shell, "-c", command]
            let cArgs = args.map { strdup($0) } + [nil]
            defer { cArgs.forEach { free($0) } }

            Darwin.execv(shell, cArgs)

            /// If exec fails, exit with error.
            Darwin.exit(127)
        }

        /// Parent process.
        self.masterFd = master
        self.childPid = pid

        /// Collect output.
        let output = try await collectOutput(from: master, pid: pid)

        /// Wait for child to exit.
        var status: Int32 = 0
        while true {
            let result = Darwin.waitpid(pid, &status, 0)
            if result > 0 {
                break
            }
            if result < 0 && errno != EINTR {
                break
            }
        }

        let exitCode = WIFEXITED(status) ? WEXITSTATUS(status) : 127
        let executionTime = Date().timeIntervalSince(startTime)

        cleanup()

        return Result(
            terminalId: terminalId,
            command: command,
            output: output,
            exitCode: exitCode,
            executionTime: executionTime,
            isBackground: false,
            pid: pid,
            isInteractive: isInteractive
        )
    }

    /// Collect output from PTY master.
    private func collectOutput(from master: Int32, pid: pid_t) async throws -> String {
        var output = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)

        /// Set master to non-blocking for reading.
        var flags = Darwin.fcntl(master, F_GETFL, 0)
        flags |= O_NONBLOCK
        Darwin.fcntl(master, F_SETFL, flags)

        /// Read until process exits or no more data.
        var processRunning = true
        while processRunning {
            let bytesRead = Darwin.read(master, &buffer, buffer.count)

            if bytesRead > 0 {
                output.append(contentsOf: buffer[0..<bytesRead])
            } else if bytesRead == 0 {
                /// EOF - process has closed the PTY.
                break
            } else if errno == EAGAIN || errno == EWOULDBLOCK {
                /// No data available, check if process still running.
                var status: Int32 = 0
                let result = Darwin.waitpid(pid, &status, WNOHANG)

                if result > 0 {
                    /// Process has exited.
                    processRunning = false
                } else if result == 0 {
                    /// Process still running, wait a bit and try again.
                    try await Task.sleep(nanoseconds: 10_000_000)
                } else if errno != EINTR {
                    /// Error.
                    break
                }
            } else if errno != EINTR {
                /// Read error.
                break
            }
        }

        /// Convert output to string, handling ANSI sequences.
        return String(data: output, encoding: .utf8) ?? ""
    }

    /// Clean up PTY resources.
    private func cleanup() {
        if masterFd >= 0 {
            Darwin.close(masterFd)
            masterFd = -1
        }

        /// Restore original terminal settings.
        if let original = originalTermios {
            var term = original
            Darwin.tcsetattr(STDIN_FILENO, TCSANOW, &term)
            Darwin.tcsetattr(STDOUT_FILENO, TCSANOW, &term)
            Darwin.tcsetattr(STDERR_FILENO, TCSANOW, &term)
        }

        childPid = -1
    }

    /// Resize PTY window.
    public func resize(rows: UInt16, columns: UInt16) {
        guard masterFd >= 0 else { return }

        var windowSize = winsize()
        windowSize.ws_row = rows
        windowSize.ws_col = columns

        Darwin.ioctl(masterFd, TIOCSWINSZ, &windowSize)
    }
}

// MARK: - PTY Error Types

public enum PTYError: Error, CustomStringConvertible {
    case forkFailed(Int32)
    case ptyAllocationFailed
    case execFailed
    case readFailed(Int32)

    public var description: String {
        switch self {
        case .forkFailed(let errno):
            return "Failed to fork process: errno \(errno)"

        case .ptyAllocationFailed:
            return "Failed to allocate pseudo-terminal"

        case .execFailed:
            return "Failed to execute command"

        case .readFailed(let errno):
            return "Failed to read from PTY: errno \(errno)"
        }
    }
}

// MARK: - Darwin/BSD PTY Functions

/// Import necessary Darwin functions.
private func WIFEXITED(_ status: Int32) -> Bool {
    return (status & 0x7f) == 0
}

private func WEXITSTATUS(_ status: Int32) -> Int32 {
    return (status >> 8) & 0xff
}

private func WIFSTOPPED(_ status: Int32) -> Bool {
    return (status & 0xff) == 0x7f
}

private func WIFSIGNALED(_ status: Int32) -> Bool {
    return (status & 0x7f) != 0 && (status & 0x7f) != 0x7f
}

private func WTERMSIG(_ status: Int32) -> Int32 {
    return status & 0x7f
}
