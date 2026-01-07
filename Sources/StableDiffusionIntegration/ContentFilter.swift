// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import Foundation
import Logging

/// Comprehensive NSFW content filter for image generation prompts
/// Ported from ALICE project's enhanced filtering system
/// Keywords are base64-encoded to avoid exposing explicit content in source code
public struct ContentFilter {
    private static let logger = Logger(label: "com.sam.contentfilter")
    
    /// Decode base64-encoded keywords
    private static func decodeKeywords(_ encoded: [String]) -> [String] {
        return encoded.compactMap { encodedKeyword in
            guard let data = Data(base64Encoded: encodedKeyword),
                  let decoded = String(data: data, encoding: .utf8) else {
                return nil
            }
            return decoded
        }
    }
    
    /// Check if text contains NSFW keywords or content
    ///
    /// Comprehensive filter that detects:
    /// - Direct NSFW keywords
    /// - Common variations and euphemisms
    /// - Obfuscation attempts (leetspeak, spacing, symbols)
    /// - Medical/technical terms used inappropriately
    /// - Context-based detection
    ///
    /// - Parameter text: The text to check for NSFW content
    /// - Returns: True if NSFW content detected, False otherwise
    public static func checkNSFWContent(_ text: String) -> Bool {
        // Base64-encoded NSFW keywords (decoded at runtime)
        // Encoding prevents explicit words from appearing in source code
        let encodedKeywords = [
            "bnVkZQ==", "bmFrZWQ=", "bnNmdw==", "cG9ybg==", "cG9ybm9ncmFwaGlj", "ZXJvdGlj", "eHh4",
            "c2V4", "c2V4dWFs", "c2V4dWFsaXR5", "ZXhwbGljaXQ=", "YWR1bHQgb25seQ==", "MTgr", "cjE4",
            "dG9wbGVzcw==", "Ym90dG9tbGVzcw==", "bmlwcGxl", "bmlwcGxlcw==", "YnJlYXN0cw==",
            "Z2VuaXRhbGlh", "Z2VuaXRhbA==", "cGVuaXM=", "dmFnaW5h", "dnVsdmE=", "YW51cw==",
            "Y29jaw==", "ZGljaw==", "cHVzc3k=", "Y3VudA==", "YXNz", "dGl0cw==", "Ym9vYnM=",
            "bGluZ2VyaWU=", "dW5kZXJ3ZWFy", "cGFudGllcw==", "YnJh", "dGhvbmc=", "Zy1zdHJpbmc=",
            "YmlraW5pIGJvdHRvbQ==", "c2VlLXRocm91Z2g=", "dHJhbnNwYXJlbnQgY2xvdGhpbmc=",
            "aW50ZXJjb3Vyc2U=", "Y29pdHVz", "Y29wdWxhdGlvbg==", "bWF0aW5n",
            "ZmVsbGF0aW8=", "Y3VubmlsaW5ndXM=", "b3JhbCBzZXg=", "Ymxvd2pvYg==", "YmxvdyBqb2I=",
            "aGFuZGpvYg==", "aGFuZCBqb2I=", "ZmluZ2VyaW5n", "cGVuZXRyYXRpb24=", "cGVuZXRyYXRpbmc=",
            "bWFzdHVyYmF0aW9u", "bWFzdHVyYmF0aW5n", "b3JnYXNt", "Y2xpbWF4", "ZWphY3VsYXRpb24=",
            "YXJvdXNhbA==", "YXJvdXNlZA==", "ZXJlY3Rpb24=", "aGFyZC1vbg==", "d2V0",
            "dGhyZWVzb21l", "Z2FuZ2Jhbmc=", "Z2FuZyBiYW5n", "b3JneQ==", "YnVra2FrZQ==",
            "YmRzbQ==", "Ym9uZGFnZQ==", "ZG9taW5hdGlvbg==", "c3VibWlzc2lvbg==", "c2FkaXNt", "bWFzb2NoaXNt",
            "ZmV0aXNo", "a2luaw==", "a2lua3k=",
            "c2VkdWN0aXZl", "cHJvdm9jYXRpdmU=", "c3VnZ2VzdGl2ZQ==", "c3VsdHJ5", "c2Vuc3VhbA==",
            "bGV3ZA==", "bGFzY2l2aW91cw==", "bHVzdGZ1bA==", "aG9ybnk=", "cmFuZHk=",
            "aW50aW1hdGU=", "aW50aW1hY3k=", "cGFzc2lvbmF0ZQ==",
            "aGVudGFp", "ZG91amlu", "ZWNjaGk=", "YWhlZ2Fv", "eWFvaQ==", "eXVyaQ==",
            "cnVsZTM0", "cnVsZSAzNA==", "bnNmbA==",
            "YWR1bHQgYWN0aXZpdHk=", "YmVkcm9vbSBzY2VuZQ==", "aG9yaXpvbnRhbA==", "bWFraW5nIGxvdmU=",
            "c2xlZXBpbmcgdG9nZXRoZXI=", "bmV0ZmxpeCBhbmQgY2hpbGw=", "c3RlYW15",
            "c3BpY3k=", "c2F1Y3k=", "bmF1Z2h0eQ==", "ZGlydHk=",
            "ZnVjaw==", "ZnVja2luZw==", "ZnVja2Vk", "c2NyZXdpbmc=", "YmFuZ2luZw==",
            "aHVtcGluZw==", "Z3JpbmRpbmc=", "cmlkaW5n",
            "ZGlsZG8=", "dmlicmF0b3I=", "c2V4IHRveQ==", "YnV0dHBsdWc=", "YnV0dCBwbHVn",
            "YW5hbA==", "dmFnaW5hbA==", "Y3Vt", "Y3VtbWluZw==", "c2VtZW4=", "Y3JlYW1waWU=",
            "ZmFjaWFs", "c3F1aXJ0", "c3F1aXJ0aW5n", "bGFjdGF0aW9u", "bGFjdGF0aW5n",
            "aW5jZXN0", "bG9saQ==", "bG9saWNvbg==", "c2hvdGE=", "c2hvdGFjb24=", "cGVkb3BoaWxl",
            "cmFwZQ==", "cmFwaW5n", "bW9sZXN0", "YXNzYXVsdA==",
            "bGFiaWE=", "Y2xpdG9yaXM=", "dGVzdGljbGVz", "c2Nyb3R1bQ==", "cHJvc3RhdGU=",
            "ZXJvZ2Vub3Vz", "bWFtbWFyeQ==", "cGhhbGx1cw==", "Zm9yZXNraW4="
        ]
        
        let nsfwKeywords = decodeKeywords(encodedKeywords)
        
        // Normalize text for checking
        let textLower = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        
        // Remove extra spaces for detection
        let textNormalized = textLower.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        
        // Check direct keywords with word boundaries to avoid false positives
        for keyword in nsfwKeywords {
            // Use word boundary matching for better accuracy
            let pattern = "\\b\(NSRegularExpression.escapedPattern(for: keyword))\\b"
            if let regex = try? NSRegularExpression(pattern: pattern, options: []),
               regex.firstMatch(in: textNormalized, options: [], range: NSRange(textNormalized.startIndex..., in: textNormalized)) != nil {
                logger.warning("NSFW content blocked: keyword detected in prompt")
                return true
            }
        }
        
        // Detect leetspeak/obfuscation patterns (base64-encoded pattern descriptions)
        let obfuscationPatterns: [(pattern: String, keyword: String)] = [
            ("n[\\W_]*u[\\W_]*d[\\W_]*e", "pattern1"),
            ("s[\\W_]*e[\\W_]*x", "pattern2"),
            ("p[\\W_]*o[\\W_]*r[\\W_]*n", "pattern3"),
            ("n[\\W_]*a[\\W_]*k[\\W_]*e[\\W_]*d", "pattern4"),
            ("f[\\W_]*u[\\W_]*c[\\W_]*k", "pattern5"),
            ("p[\\W_]*u[\\W_]*s[\\W_]*s[\\W_]*y", "pattern6"),
            ("[bp][\\W_]*[o0][\\W_]*[o0][\\W_]*[bp]", "pattern7"),
            ("t[\\W_]*i[\\W_]*t[\\W_]*s", "pattern8"),
            ("[bp][o0][o0][bp]s?", "pattern9"),
            ("n[i!1]ppl[e3]s?", "pattern10"),
            ("s[e3]x[yu]a?l?", "pattern11"),
            ("[e3]r[o0]t[i1]c", "pattern12"),
            ("p[o0]rn[o0]?", "pattern13"),
            ("xxx+", "pattern14"),
            ("n[a@]k[e3]d", "pattern15"),
            ("n[u\\W]d[e3]", "pattern16"),
            ("s[e3]x", "pattern17"),
            ("d[o0]m[i1]natr[i1]x", "pattern18")
        ]
        
        for (pattern, keyword) in obfuscationPatterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: []),
               regex.firstMatch(in: textLower, options: [], range: NSRange(textLower.startIndex..., in: textLower)) != nil {
                logger.warning("NSFW content blocked: obfuscation pattern detected in prompt")
                return true
            }
        }
        
        // Detect suspicious character substitutions (unicode lookalikes)
        let suspiciousChars: [Character: Character] = [
            "а": "a", "е": "e", "і": "i", "о": "o", "р": "p", "с": "c", "у": "u", "х": "x",
            "ė": "e", "ṇ": "n", "ū": "u", "ṡ": "s", "ḋ": "d"
        ]
        
        var textDecoded = textLower
        for (char, replacement) in suspiciousChars {
            textDecoded = textDecoded.replacingOccurrences(of: String(char), with: String(replacement))
        }
        
        if textDecoded != textLower {
            // Recheck with decoded text
            for keyword in nsfwKeywords {
                let pattern = "\\b\(NSRegularExpression.escapedPattern(for: keyword))\\b"
                if let regex = try? NSRegularExpression(pattern: pattern, options: []),
                   regex.firstMatch(in: textDecoded, options: [], range: NSRange(textDecoded.startIndex..., in: textDecoded)) != nil {
                    logger.warning("NSFW content blocked: unicode-obfuscated content detected in prompt")
                    return true
                }
            }
        }
        
        // Context-based detection (combinations of borderline words)
        // These require specific combinations to avoid false positives
        let contextPatterns: [(pattern: String, description: String)] = [
            ("\\b(bed|bedroom|room)\\b.*\\b(naked|nude|undressed)\\b", "context1"),
            ("\\b(touching|touch|caressing|caress|rubbing)\\b.*\\b(breast|chest|body|intimate)\\b(?!.*(cancer|awareness|health|medical|exam))", "context2"),
            ("\\b(spread|spreading|open|opening)\\b.*\\b(legs|thighs)\\b", "context3"),
            ("\\b(wet|moist|dripping)\\b.*\\b(body|skin|clothes|clothing)\\b", "context4"),
            ("\\b(removing|remove|taking off|stripping)\\b.*\\b(clothes|clothing|dress|shirt|pants)\\b", "context5"),
            ("\\b(exposed|revealing|showing)\\b.*\\b(breast|nipple|genital)(?!.*(cancer|awareness|health|medical|exam))", "context6")
        ]
        
        for (pattern, description) in contextPatterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: []),
               regex.firstMatch(in: textNormalized, options: [], range: NSRange(textNormalized.startIndex..., in: textNormalized)) != nil {
                logger.warning("NSFW content blocked: context pattern detected in prompt")
                return true
            }
        }
        
        return false
    }
}
