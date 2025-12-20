// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import Foundation
import Logging

/// A log handler that supports dynamic log level changes at runtime This handler wraps StreamLogHandler and allows the log level to be changed dynamically without requiring an application restart.
public struct DynamicLogHandler: LogHandler {
    /// Shared log level that can be changed at runtime Thread-safe using atomic operations.
    nonisolated(unsafe) private static let _currentLogLevel = ManagedAtomic<Logger.Level>(.info)

    /// Get or set the current log level for all DynamicLogHandler instances.
    public static var currentLogLevel: Logger.Level {
        get { _currentLogLevel.load(ordering: .relaxed) }
        set { _currentLogLevel.store(newValue, ordering: .relaxed) }
    }

    /// The underlying handler that does the actual logging.
    private var handler: StreamLogHandler

    /// Initialize with a label.
    public init(label: String) {
        self.handler = StreamLogHandler.standardOutput(label: label)
        self.handler.logLevel = Self.currentLogLevel
    }

    /// The log level for this handler (reads from shared property).
    public var logLevel: Logger.Level {
        get { Self.currentLogLevel }
        set { Self.currentLogLevel = newValue }
    }

    /// Metadata for this handler.
    public var metadata: Logger.Metadata {
        get { handler.metadata }
        set { handler.metadata = newValue }
    }

    /// Get or set metadata for a specific key.
    public subscript(metadataKey key: String) -> Logger.Metadata.Value? {
        get { handler[metadataKey: key] }
        set { handler[metadataKey: key] = newValue }
    }

    /// Log a message at the specified level.
    public func log(
        level: Logger.Level,
        message: Logger.Message,
        metadata: Logger.Metadata?,
        source: String,
        file: String,
        function: String,
        line: UInt
    ) {
        /// Check current shared log level before forwarding to handler.
        guard level >= Self.currentLogLevel else { return }

        handler.log(
            level: level,
            message: message,
            metadata: metadata,
            source: source,
            file: file,
            function: function,
            line: line
        )
    }
}

/// Atomic wrapper for thread-safe log level changes.
private final class ManagedAtomic<T> {
    private var value: T
    private let lock = NSLock()

    init(_ initialValue: T) {
        self.value = initialValue
    }

    func load(ordering: AtomicLoadOrdering) -> T {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func store(_ newValue: T, ordering: AtomicStoreOrdering) {
        lock.lock()
        defer { lock.unlock() }
        value = newValue
    }
}

private enum AtomicLoadOrdering {
    case relaxed
}

private enum AtomicStoreOrdering {
    case relaxed
}
