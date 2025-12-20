// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import Foundation

/// Utility for parsing human-readable duration strings Supports formats: "30s", "5m", "1h", "90m", etc.
public struct DurationParser {
    /// Parse duration string to seconds - Parameter duration: String in format like "5m", "300s", "1h" - Returns: Duration in seconds, or nil if invalid.
    public static func parseToSeconds(_ duration: String) -> TimeInterval? {
        let trimmed = duration.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let pattern = "^([0-9]+)([smh])$"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []),
              let match = regex.firstMatch(in: trimmed, options: [], range: NSRange(trimmed.startIndex..., in: trimmed)),
              match.numberOfRanges == 3 else {
            return nil
        }

        let numberRange = Range(match.range(at: 1), in: trimmed)!
        guard let number = Int(trimmed[numberRange]) else { return nil }

        let unitRange = Range(match.range(at: 2), in: trimmed)!
        let unit = String(trimmed[unitRange])

        /// Convert to seconds.
        switch unit {
        case "s":
            return TimeInterval(number)

        case "m":
            return TimeInterval(number * 60)

        case "h":
            return TimeInterval(number * 3600)

        default:
            return nil
        }
    }

    /// Get authorization expiry duration from user preferences - Returns: Duration in seconds (default: 300 = 5 minutes).
    public static func getAuthorizationExpiryDuration() -> TimeInterval {
        let durationString = UserDefaults.standard.string(forKey: "authorizationExpiryDuration") ?? "5m"
        return parseToSeconds(durationString) ?? 300
    }
}
