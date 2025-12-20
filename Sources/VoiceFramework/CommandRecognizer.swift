// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import Foundation

/// Recognizes action commands in transcribed speech
public class CommandRecognizer {

    public enum VoiceCommand: Equatable {
        case sendIt
        case changeIt
        case cancel
        case unknown
    }

    private let commandPatterns: [(VoiceCommand, [String])] = [
        (.sendIt, ["send it", "send", "submit", "go ahead", "yes send"]),
        (.changeIt, ["change it", "edit it", "modify it", "let me edit", "change that"]),
        (.cancel, ["cancel", "never mind", "nevermind", "stop", "forget it", "don't send"])
    ]

    /// Detect command in text
    /// Returns tuple of (command: VoiceCommand, cleanedText: String)
    public func recognize(in text: String) -> (command: VoiceCommand, cleanedText: String) {
        let normalizedText = normalize(text)

        /// Check each command pattern
        for (command, patterns) in commandPatterns {
            for pattern in patterns {
                if normalizedText.contains(pattern) {
                    /// Remove command phrase and return cleaned text
                    let cleanedText = normalizedText
                        .replacingOccurrences(of: pattern, with: "")
                        .trimmingCharacters(in: .whitespacesAndNewlines)

                    return (command, cleanedText)
                }

                /// Also check if text is ONLY the command (exact match)
                if normalizedText == pattern {
                    return (command, "")
                }
            }
        }

        return (.unknown, text)
    }

    /// Check if text contains any command
    public func containsCommand(in text: String) -> Bool {
        let normalizedText = normalize(text)

        for (_, patterns) in commandPatterns {
            for pattern in patterns {
                if normalizedText.contains(pattern) {
                    return true
                }
            }
        }

        return false
    }

    /// Normalize text for command detection
    private func normalize(_ text: String) -> String {
        return text
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            /// Remove punctuation
            .replacingOccurrences(of: "[.,!?;:]", with: "", options: .regularExpression)
    }
}
