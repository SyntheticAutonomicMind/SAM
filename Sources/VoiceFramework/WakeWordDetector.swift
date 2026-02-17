// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import Foundation
import Logging

/// Detects wake words in transcribed speech
public class WakeWordDetector {
    private let logger = Logger(label: "com.sam.voice.wakeword")

    /// UserDefaults key for storing custom wake words
    public static let wakeWordsKey = "voice.wakeWords"

    /// Default wake words - used when no custom configuration exists
    public static let defaultWakeWords = [
        "hey sam",
        "ok sam",
        "okay sam",
        "hello sam",
        "hi sam",
        "hello computer",
        "hey computer"
    ]

    /// Current active wake words (loaded from UserDefaults or defaults)
    private var wakeWords: [String]

    public init() {
        self.wakeWords = Self.loadWakeWords()
        logger.debug("WakeWordDetector initialized with \(wakeWords.count) wake words")
    }

    /// Reload wake words from UserDefaults (call when settings change)
    public func reloadWakeWords() {
        wakeWords = Self.loadWakeWords()
        logger.debug("WakeWordDetector reloaded with \(wakeWords.count) wake words")
    }

    /// Get current wake words
    public var currentWakeWords: [String] {
        return wakeWords
    }

    /// Load wake words from UserDefaults, falling back to defaults
    public static func loadWakeWords() -> [String] {
        if let data = UserDefaults.standard.data(forKey: wakeWordsKey),
           let decoded = try? JSONDecoder().decode([String].self, from: data),
           !decoded.isEmpty {
            return decoded
        }
        return defaultWakeWords
    }

    /// Save wake words to UserDefaults
    public static func saveWakeWords(_ words: [String]) {
        if let encoded = try? JSONEncoder().encode(words) {
            UserDefaults.standard.set(encoded, forKey: wakeWordsKey)
        }
    }

    /// Reset wake words to defaults
    public static func resetToDefaults() {
        UserDefaults.standard.removeObject(forKey: wakeWordsKey)
    }

    /// Detect if text contains a wake word
    /// Returns tuple of (detected: Bool, textWithoutWakeWord: String)
    public func detect(in text: String) -> (detected: Bool, cleanedText: String) {
        let normalizedText = normalize(text)
        logger.trace("Checking '\(normalizedText)' for wake words")

        for wakeWord in wakeWords {
            /// Check if text starts with wake word
            if normalizedText.hasPrefix(wakeWord) {
                logger.debug("DETECTED: wake word '\(wakeWord)' at start")
                /// Remove wake word and return cleaned text
                let cleanedText = String(normalizedText.dropFirst(wakeWord.count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return (true, cleanedText)
            }

            /// Also check for wake word anywhere in the first few words (fuzzy matching)
            let words = normalizedText.split(separator: " ", maxSplits: 5)
            let firstWords = words.prefix(3).joined(separator: " ")

            if firstWords.contains(wakeWord) {
                logger.debug("DETECTED: wake word '\(wakeWord)' in first words")
                /// Find position after wake word
                if let range = normalizedText.range(of: wakeWord) {
                    let cleanedText = String(normalizedText[range.upperBound...])
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    return (true, cleanedText)
                }
            }
        }

        return (false, text)
    }

    /// Normalize text for wake word detection
    private func normalize(_ text: String) -> String {
        return text
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            /// Remove punctuation
            .replacingOccurrences(of: "[.,!?;:]", with: "", options: .regularExpression)
    }
}
