// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)

import Foundation
import Combine
import SwiftUI

/// Buffers streaming deltas for a single in-flight assistant message and exposes
/// a throttled content view for SwiftUI. The MessageBus is still the source of
/// truth for persistence, but the active row reads from this buffer so that
/// high-frequency token arrivals only redraw the row, never the whole list.
@MainActor
public final class StreamingBuffer: ObservableObject {
    /// The message id this buffer is associated with. Set when streaming starts.
    @Published public private(set) var messageId: UUID?

    /// The latest flushed content (60fps). Views observe this for the row.
    @Published public private(set) var content: String = ""

    /// Whether streaming is currently active for this buffer.
    @Published public private(set) var isStreaming: Bool = false

    /// The most recently received content from the API (may include markers
    /// that have not yet been flushed to `content`). Used for the trailing
    /// "..." / cursor effect on the live row.
    @Published public private(set) var hasUnflushedDelta: Bool = false

    /// When streaming was last flushed to content. Used by views that want to
    /// animate a "transition from streaming -> final" state.
    @Published public private(set) var lastFlushAt: Date = .distantPast

    private var pendingDelta: String = ""
    private var flushTask: Task<Void, Never>?
    private let flushIntervalNanos: UInt64

    /// - Parameter flushHz: How many times per second to flush accumulated
    ///   deltas into `content`. Defaults to 60.
    public init(flushHz: Int = 60) {
        self.flushIntervalNanos = UInt64(1_000_000_000 / max(1, flushHz))
    }

    /// Begin streaming for a given message id. Resets the buffer.
    public func start(messageId: UUID) {
        self.messageId = messageId
        self.content = ""
        self.pendingDelta = ""
        self.isStreaming = true
        self.hasUnflushedDelta = false
        self.lastFlushAt = Date()
    }

    /// Append a delta. Coalesced with other deltas arriving in the same window.
    public func append(_ delta: String) {
        guard isStreaming else { return }
        guard !delta.isEmpty else { return }
        pendingDelta.append(delta)
        hasUnflushedDelta = true
        scheduleFlush()
    }

    /// Flush immediately and stop streaming. After this call, the bus's
    /// `messages` array is the source of truth for this message's content.
    public func finish() {
        flushNow()
        isStreaming = false
        hasUnflushedDelta = false
        cancelFlush()
    }

    /// Cancel streaming without flushing. Used when the user hits Stop.
    public func cancel() {
        cancelFlush()
        pendingDelta = ""
        isStreaming = false
        hasUnflushedDelta = false
    }

    /// Force an immediate flush (used when streaming ends or on app teardown).
    public func flushNow() {
        guard !pendingDelta.isEmpty else { return }
        content.append(pendingDelta)
        pendingDelta = ""
        hasUnflushedDelta = false
        lastFlushAt = Date()
    }

    /// Replace the current content outright. Used when the bus signals a
    /// complete rewrite (rare, mostly during error recovery).
    public func overrideContent(with newContent: String) {
        cancelFlush()
        pendingDelta = ""
        content = newContent
        hasUnflushedDelta = false
        lastFlushAt = Date()
    }

    private func scheduleFlush() {
        flushTask?.cancel()
        let interval = flushIntervalNanos
        flushTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: interval)
            guard let self else { return }
            guard !Task.isCancelled else { return }
            self.flushNow()
        }
    }

    private func cancelFlush() {
        flushTask?.cancel()
        flushTask = nil
    }

    deinit {
        flushTask?.cancel()
    }
}
