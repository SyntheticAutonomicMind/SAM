// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import Foundation
import Combine
import Logging

/// Detects pauses in audio input based on silence threshold
@MainActor
public class PauseDetector: ObservableObject {
    private let logger = Logger(label: "com.sam.voice.pause")
    @Published public private(set) var isPaused: Bool = false

    private var silenceStartTime: Date?
    private let pauseThreshold: TimeInterval = 2.0
    private let silenceThreshold: Float = 0.05 /// Audio level below this is considered silence (increased to handle background noise)
    private var checkTimer: Timer?

    /// Callback when pause is detected
    public var onPauseDetected: (() -> Void)?

    public init() {}

    /// Start monitoring for pauses
    public func startMonitoring() {
        stopMonitoring()

        /// Check for pause every 0.1 seconds
        checkTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.checkForPause()
            }
        }
    }

    /// Stop monitoring
    public func stopMonitoring() {
        checkTimer?.invalidate()
        checkTimer = nil
        silenceStartTime = nil
        isPaused = false
    }

    /// Update with audio level
    public func updateAudioLevel(_ level: Float) {
        /// Log audio level periodically (every 20 updates = ~2 seconds)
        if Int.random(in: 1...20) == 1 {
            logger.debug("Audio level: \(String(format: "%.4f", level)), threshold: \(String(format: "%.4f", silenceThreshold))")
        }

        if level < silenceThreshold {
            /// Audio is silent
            if silenceStartTime == nil {
                silenceStartTime = Date()
                logger.debug("Silence started at audio level \(String(format: "%.4f", level))")
            }
        } else {
            /// Audio detected, reset silence timer
            if silenceStartTime != nil {
                logger.debug("Silence broken by audio level \(String(format: "%.4f", level))")
            }
            silenceStartTime = nil
            isPaused = false
        }
    }

    /// Check if pause threshold has been exceeded
    private func checkForPause() {
        guard let startTime = silenceStartTime else {
            isPaused = false
            return
        }

        let silenceDuration = Date().timeIntervalSince(startTime)

        if silenceDuration >= pauseThreshold && !isPaused {
            isPaused = true
            onPauseDetected?()
        }
    }

    /// Reset pause state
    public func reset() {
        silenceStartTime = nil
        isPaused = false
    }
}
