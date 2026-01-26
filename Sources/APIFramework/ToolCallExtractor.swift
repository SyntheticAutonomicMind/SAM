// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import Foundation
import Logging

/// Universal tool call extractor that supports all major tool calling formats Supports: OpenAI, Ministral, Qwen, Hermes, and JSON code blocks Format auto-detection for: - OpenAI: Native function_call JSON format (remote API) - Ministral: [TOOL_CALLS][{...}] format (Mistral models) - Qwen: <function_call>...</function_call> XML tags (Qwen3 models) - Hermes: Nous Research Hermes format (Hermes-2/3 models) - JSON fallback: ```json {...} ``` code blocks and bare JSON.
public class ToolCallExtractor {
    private let logger = Logger(label: "com.sam.api.toolextractor")

    /// Detected tool call format types **Why multiple formats**: Different LLM providers/models use different tool call syntax **Format details**: - `openai`: Native OpenAI API format (remote API only, structured tool_calls field) - `ministral`: Mistral-style `[TOOL_CALLS][...]` markers - `qwen`: Qwen models use `<function_call>...</function_call>` XML-style tags - `hermes`: Hermes/Nous models - OpenAI-like JSON but with format variations - `jsonCodeBlock`: Generic JSON in markdown code blocks `\`\`\`json {...} \`\`\`` - `bareJSON`: Direct JSON array/object in response text - `none`: No tool calls detected in response.
    public enum ToolCallFormat {
        case openai
        case ministral
        case qwen
        case hermes
        case jsonCodeBlock
        case bareJSON
        case none
    }

    /// Extracted tool call information.
    public struct ToolCall: Sendable {
        public let name: String
        public let arguments: String
        public let id: String?

        public init(name: String, arguments: String, id: String? = nil) {
            self.name = name
            self.arguments = arguments
            self.id = id
        }
    }

    public func extract(from content: String) -> ([ToolCall], String, ToolCallFormat) {
        /// STEP 0A: Qwen2-style format (for Qwen2.5-Coder models) Pattern: FUNCTION: tool_name\nARGS: {...} This uses unique Unicode flower characters that won't appear in normal conversation See: https://github.com/QwenLM/Qwen-Agent for canonical implementation.
        if content.contains("FUNCTION") || content.contains("ARGS") {
            logger.debug("Detected Qwen2-style function calling format (Qwen2.5-Coder compatible)")
            let (calls, cleaned) = extractQwen2Format(from: content)
            if !calls.isEmpty {
                return (calls, cleaned, .qwen)
            }
        }

        /// STEP 0B: <tool_call> XML tag format (LlamaProvider system prompt format) This is the format we instruct llama.cpp models to use.
        if content.contains("<tool_call>") {
            logger.debug("Detected <tool_call> XML tag format (LlamaProvider)")
            let (calls, cleaned) = extractToolCallFormat(from: content)
            if !calls.isEmpty {
                return (calls, cleaned, .qwen)
            }
        }

        /// STEP 0B: Qwen <function_call> XML tag format (native Qwen models).
        if content.contains("<function_call>") {
            logger.debug("Detected Qwen <function_call> XML tag format")
            let (calls, cleaned) = extractQwenFormat(from: content)
            if !calls.isEmpty {
                return (calls, cleaned, .qwen)
            }
        }

        /// STEP 0C: "Calling tool:" prefix format (llama.cpp models that don't follow XML instruction) Pattern: "Calling tool: tool_name\n{...}" - common when models ignore <tool_call> instruction.
        if content.contains("Calling tool:") {
            logger.debug("Detected 'Calling tool:' prefix format (llama.cpp alternative)")
            let (calls, cleaned) = extractCallingToolFormat(from: content)
            if !calls.isEmpty {
                return (calls, cleaned, .bareJSON)
            }
        }

        /// Ministral [TOOL_CALLS] prefix format.
        if content.contains("[TOOL_CALLS]") {
            logger.debug("Detected Ministral [TOOL_CALLS] prefix format")
            let (calls, cleaned) = extractMinistralFormat(from: content)
            if !calls.isEmpty {
                return (calls, cleaned, .ministral)
            }
        }

        /// Hermes format detection (check for Hermes-specific patterns) Hermes uses similar structure to OpenAI but may have variations Look for function call patterns that indicate Hermes models.
        if containsHermesPattern(content) {
            logger.debug("Detected Hermes tool call format")
            let (calls, cleaned) = extractHermesFormat(from: content)
            if !calls.isEmpty {
                return (calls, cleaned, .hermes)
            }
        }

        /// JSON code blocks (```json ...
        if content.contains("```json") || content.contains("```") {
            logger.debug("Detected JSON code block format")
            let (calls, cleaned) = extractJSONCodeBlocks(from: content)
            if !calls.isEmpty {
                return (calls, cleaned, .jsonCodeBlock)
            }
        }

        /// Bare JSON (direct arrays or objects).
        if content.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("[") ||
           content.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("{") {
            logger.debug("Attempting bare JSON extraction")
            let (calls, cleaned) = extractBareJSON(from: content)
            if !calls.isEmpty {
                return (calls, cleaned, .bareJSON)
            }
        }

        /// JSON embedded in conversational text (most permissive) Pattern: {"name": "...", "arguments": {...}} anywhere in the content This catches cases where LLM generates tool calls inline without special markers.
        if content.contains("\"name\"") && content.contains("\"arguments\"") {
            logger.debug("Attempting embedded JSON extraction")
            let (calls, cleaned) = extractEmbeddedJSON(from: content)
            if !calls.isEmpty {
                return (calls, cleaned, .bareJSON)
            }
        }

        /// No tool calls detected.
        logger.debug("No tool calls detected in content")
        return ([], content, .none)
    }

    // MARK: - Format-Specific Extractors

    /// Extract Qwen <function_call>...</function_call> format.
    private func extractQwenFormat(from content: String) -> ([ToolCall], String) {
        var toolCalls: [ToolCall] = []
        var cleanedContent = content

        let pattern = "<function_call>\\s*(.+?)\\s*</function_call>"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else {
            logger.error("Failed to create regex for Qwen format")
            return ([], content)
        }

        let nsContent = content as NSString
        let matches = regex.matches(in: content, range: NSRange(location: 0, length: nsContent.length))

        logger.debug("Found \(matches.count) <function_call> tags")

        /// Process matches in reverse to maintain correct string indices during removal.
        for match in matches.reversed() {
            guard match.numberOfRanges >= 2 else { continue }

            let jsonRange = match.range(at: 1)
            let jsonString = nsContent.substring(with: jsonRange)

            logger.debug("Extracted JSON from <function_call>: \(jsonString)")

            /// Parse JSON as tool call.
            if let toolCall = parseToolCallJSON(jsonString) {
                toolCalls.insert(toolCall, at: 0)
                logger.debug("Parsed tool call '\(toolCall.name)' from <function_call> tag")

                /// Remove <function_call>...</function_call> from content.
                let fullRange = match.range
                cleanedContent = (cleanedContent as NSString).replacingCharacters(in: fullRange, with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
                logger.warning("JSON in <function_call> did not parse as valid tool call")
            }
        }

        return (toolCalls, cleanedContent)
    }

    /// Extract <tool_call>...</tool_call> format (LlamaProvider system prompt format) This is the format we instruct llama.cpp models to use in the system prompt.
    private func extractToolCallFormat(from content: String) -> ([ToolCall], String) {
        var toolCalls: [ToolCall] = []
        var cleanedContent = content

        let pattern = "<tool_call>\\s*(.+?)\\s*</tool_call>"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else {
            logger.error("Failed to create regex for <tool_call> format")
            return ([], content)
        }

        let nsContent = content as NSString
        let matches = regex.matches(in: content, range: NSRange(location: 0, length: nsContent.length))

        logger.debug("Found \(matches.count) <tool_call> tags")

        /// Process matches in reverse to maintain correct string indices during removal.
        for match in matches.reversed() {
            guard match.numberOfRanges >= 2 else { continue }

            let jsonRange = match.range(at: 1)
            let jsonString = nsContent.substring(with: jsonRange)

            logger.debug("Extracted JSON from <tool_call>: \(jsonString)")

            /// Parse JSON as tool call.
            if let toolCall = parseToolCallJSON(jsonString) {
                toolCalls.insert(toolCall, at: 0)
                logger.debug("Parsed tool call '\(toolCall.name)' from <tool_call> tag")

                /// Remove <tool_call>...</tool_call> from content.
                let fullRange = match.range
                cleanedContent = (cleanedContent as NSString).replacingCharacters(in: fullRange, with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
                logger.warning("JSON in <tool_call> did not parse as valid tool call")
            }
        }

        return (toolCalls, cleanedContent)
    }

    /// Extract Qwen2-style function calling format (for Qwen2.5-Coder models) **Purpose**: Parse Qwen2.5-Coder's native function calling format **Format**: `FUNCTION: tool_name\nARGS: {json_arguments}` **Special markers** (Unicode flower characters): - `FUNCTION` - Tool name marker - `ARGS` - Arguments JSON marker - `RESULT` - Tool result marker (not used in extraction) - `RETURN` - Final response marker (not used in extraction) **Example**: ``` FUNCTION: fetch_webpage ARGS: {"urls": ["https://example.com"], "query": "AI"} ``` **Why this format**: - Native format for Qwen2.5-Coder models - Unicode flowers unique → no false matches in normal conversation - Regular Qwen2.5 supports Hermes style, Coder variants require this format **Source**: Qwen-Agent GitHub repository (qwen_fncall_prompt.py) This is the native format used by Qwen2.5-Coder models and implemented in Qwen-Agent Pattern: FUNCTION: tool_name\nARGS: {json_arguments} Special markers: - FUNCTION(Unicode flower) - tool name marker - ARGS(Unicode flower) - arguments marker - RESULT- tool result marker (not used in extraction) - RETURN- final response marker (not used in extraction) Example: FUNCTION: fetch_webpage\nARGS: {"urls": ["https://example.com"], "query": "AI"}.
    private func extractQwen2Format(from content: String) -> ([ToolCall], String) {
        var toolCalls: [ToolCall] = []
        var cleanedContent = content

        /// STRATEGY: Find "FUNCTION:" marker, extract tool name, then find "ARGS:" and extract JSON These Unicode flower characters are unique and won't appear in normal conversation This ensures we don't accidentally match conversational JSON.

        let functionMarker = "FUNCTION:"
        let argsMarker = "ARGS:"

        /// Work with cleanedContent directly to avoid index mismatch after modifications.
        while let functionRange = cleanedContent.range(of: functionMarker) {
            logger.debug("Found Qwen2 FUNCTIONmarker at position \(cleanedContent.distance(from: cleanedContent.startIndex, to: functionRange.lowerBound))")

            /// Extract tool name (between FUNCTION: and next newline or ARGS).
            var nameStart = functionRange.upperBound

            /// Skip whitespace after FUNCTION:.
            while nameStart < cleanedContent.endIndex && (cleanedContent[nameStart] == " " || cleanedContent[nameStart] == "\t") {
                nameStart = cleanedContent.index(after: nameStart)
            }

            /// Find end of tool name (newline, ARGS, or end of string).
            var nameEnd = nameStart
            while nameEnd < cleanedContent.endIndex {
                let char = cleanedContent[nameEnd]
                if char == "\n" || char == "\r" || cleanedContent[nameEnd...].hasPrefix(argsMarker) {
                    break
                }
                nameEnd = cleanedContent.index(after: nameEnd)
            }

            let toolName = String(cleanedContent[nameStart..<nameEnd]).trimmingCharacters(in: .whitespacesAndNewlines)

            if toolName.isEmpty {
                logger.warning("Qwen2 format: Empty tool name after FUNCTIONmarker")
                /// Remove this malformed marker and continue searching.
                cleanedContent.removeSubrange(functionRange)
                continue
            }

            logger.debug("Qwen2 format: Extracted tool name '\(toolName)'")

            /// Find ARGS: marker.
            guard let argsRange = cleanedContent.range(of: argsMarker, range: nameEnd..<cleanedContent.endIndex) else {
                logger.warning("Qwen2 format: No ARGSmarker found after FUNCTION")
                /// Remove incomplete function marker.
                cleanedContent.removeSubrange(functionRange)
                continue
            }

            /// Extract JSON arguments after ARGS:.
            var jsonStart = argsRange.upperBound

            /// Skip whitespace after ARGS:.
            while jsonStart < cleanedContent.endIndex && (cleanedContent[jsonStart] == " " || cleanedContent[jsonStart] == "\t") {
                jsonStart = cleanedContent.index(after: jsonStart)
            }

            /// Find JSON by brace counting (handles nested JSON).
            if jsonStart >= cleanedContent.endIndex || cleanedContent[jsonStart] != "{" {
                logger.warning("Qwen2 format: No JSON object found after ARGSmarker")
                /// Remove incomplete markers.
                cleanedContent.removeSubrange(functionRange)
                continue
            }

            var jsonEnd = jsonStart
            var braceCount = 0
            var inString = false
            var escapeNext = false

            while jsonEnd < cleanedContent.endIndex {
                let char = cleanedContent[jsonEnd]

                if escapeNext {
                    escapeNext = false
                } else if char == "\\" {
                    escapeNext = true
                } else if char == "\"" && !escapeNext {
                    inString.toggle()
                } else if !inString {
                    if char == "{" {
                        braceCount += 1
                    } else if char == "}" {
                        braceCount -= 1
                        if braceCount == 0 {
                            /// Found complete JSON.
                            jsonEnd = cleanedContent.index(after: jsonEnd)
                            break
                        }
                    }
                }

                jsonEnd = cleanedContent.index(after: jsonEnd)
            }

            if braceCount != 0 {
                logger.warning("Qwen2 format: Incomplete JSON after ARGSmarker")
                /// Remove incomplete markers.
                cleanedContent.removeSubrange(functionRange)
                continue
            }

            let jsonString = String(cleanedContent[jsonStart..<jsonEnd])
            logger.debug("Qwen2 format: Extracted JSON arguments: \(jsonString.prefix(100))...")

            /// Parse and validate JSON.
            if let data = jsonString.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                /// Create tool call Convert arguments back to JSON string for consistency.
                if let argsData = try? JSONSerialization.data(withJSONObject: json, options: []),
                   let argsString = String(data: argsData, encoding: .utf8) {
                    toolCalls.append(ToolCall(name: toolName, arguments: argsString))
                    logger.debug("Qwen2 format: Successfully extracted tool call '\(toolName)'")

                    /// Remove the entire FUNCTION...ARGS...{...} pattern from content.
                    let removalRange = functionRange.lowerBound..<jsonEnd
                    cleanedContent.removeSubrange(removalRange)
                    /// Continue from beginning since string modified.
                } else {
                    logger.warning("Qwen2 format: Failed to re-serialize JSON arguments")
                    cleanedContent.removeSubrange(functionRange)
                }
            } else {
                logger.warning("Qwen2 format: JSON did not parse as valid object")
                cleanedContent.removeSubrange(functionRange)
            }
        }

        /// Clean up any remaining RESULTor RETURNmarkers.
        cleanedContent = cleanedContent.replacingOccurrences(of: "RESULT:", with: "")
        cleanedContent = cleanedContent.replacingOccurrences(of: "RETURN:", with: "")

        return (toolCalls, cleanedContent.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Extract "Calling tool: tool_name\n{...}" format (llama.cpp models that don't follow XML instruction) This handles cases where models ignore <tool_call> tags and generate plain JSON with prefix Example: "Calling tool: fetch_webpage\n{\"name\": \"fetch_webpage\", \"arguments\": {...}}".
    private func extractCallingToolFormat(from content: String) -> ([ToolCall], String) {
        var toolCalls: [ToolCall] = []
        var cleanedContent = content

        /// STRATEGY: Find "Calling tool:" prefix, then extract JSON starting after it Can't use regex for nested JSON - must parse character by character.

        var searchStart = content.startIndex

        while let callingRange = content.range(of: "Calling tool:", range: searchStart..<content.endIndex) {
            /// Found "Calling tool:" prefix.
            logger.debug("Found 'Calling tool:' at position \(content.distance(from: content.startIndex, to: callingRange.lowerBound))")

            /// Skip past "Calling tool: tool_name" to find the JSON.
            var jsonStart = callingRange.upperBound

            /// Skip whitespace and tool name line until we find '{'.
            while jsonStart < content.endIndex && content[jsonStart] != "{" {
                jsonStart = content.index(after: jsonStart)
            }

            if jsonStart >= content.endIndex {
                /// No JSON found after this "Calling tool:".
                searchStart = content.index(after: callingRange.upperBound)
                continue
            }

            /// Extract JSON by counting braces.
            var jsonEnd = jsonStart
            var braceCount = 0
            var inString = false
            var escapeNext = false

            while jsonEnd < content.endIndex {
                let char = content[jsonEnd]

                if escapeNext {
                    escapeNext = false
                } else if char == "\\" {
                    escapeNext = true
                } else if char == "\"" && !escapeNext {
                    inString.toggle()
                } else if !inString {
                    if char == "{" {
                        braceCount += 1
                    } else if char == "}" {
                        braceCount -= 1
                        if braceCount == 0 {
                            /// Found complete JSON.
                            jsonEnd = content.index(after: jsonEnd)
                            break
                        }
                    }
                }

                jsonEnd = content.index(after: jsonEnd)
            }

            /// Extract JSON string.
            let jsonString = String(content[jsonStart..<jsonEnd])
            logger.debug("Extracted JSON from 'Calling tool:' pattern: \(jsonString.prefix(100))...")

            /// Parse JSON as tool call.
            if let toolCall = parseToolCallJSON(jsonString) {
                toolCalls.append(toolCall)
                logger.debug("Parsed tool call '\(toolCall.name)' from 'Calling tool:' pattern")

                /// Remove "Calling tool: ...\n{...}" from content Remove from start of "Calling tool:" to end of JSON.
                let removalRange = callingRange.lowerBound..<jsonEnd
                cleanedContent.removeSubrange(removalRange)

                /// Reset search since we modified the string.
                searchStart = content.startIndex
            } else {
                logger.warning("JSON in 'Calling tool:' pattern did not parse as valid tool call")
                /// Continue searching after this match.
                searchStart = content.index(after: callingRange.upperBound)
            }
        }

        return (toolCalls, cleanedContent.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Extract Ministral [TOOL_CALLS][...] format.
    private func extractMinistralFormat(from content: String) -> ([ToolCall], String) {
        var toolCalls: [ToolCall] = []
        var cleanedContent = content

        /// Extract JSON array after [TOOL_CALLS] prefix Use greedy matching (.+) to capture the entire JSON array.
        let pattern = "\\[TOOL_CALLS\\]\\s*(\\[.+\\])"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else {
            logger.error("Failed to create regex for Ministral format")
            return ([], content)
        }

        let nsContent = content as NSString
        let matches = regex.matches(in: content, range: NSRange(location: 0, length: nsContent.length))

        logger.debug("Found \(matches.count) [TOOL_CALLS] regex matches")

        for match in matches.reversed() {
            guard match.numberOfRanges >= 2 else { continue }

            let jsonArrayRange = match.range(at: 1)
            let jsonArrayString = nsContent.substring(with: jsonArrayRange)

            logger.debug("Extracted JSON string (length: \(jsonArrayString.count)): \(jsonArrayString)")

            /// Parse JSON array.
            if let jsonData = jsonArrayString.data(using: .utf8),
               let jsonArray = try? JSONSerialization.jsonObject(with: jsonData) as? [[String: Any]] {

                /// Parse each tool call in array.
                for toolCallDict in jsonArray {
                    if let name = toolCallDict["name"] as? String {
                        let arguments = toolCallDict["arguments"] ?? [:]
                        let id = toolCallDict["id"] as? String

                        /// Convert arguments to JSON string.
                        if let argumentsData = try? JSONSerialization.data(withJSONObject: arguments, options: []),
                           let argumentsJSON = String(data: argumentsData, encoding: .utf8) {
                            let toolCall = ToolCall(name: name, arguments: argumentsJSON, id: id)
                            toolCalls.insert(toolCall, at: 0)
                            logger.debug("Parsed tool call '\(name)' from [TOOL_CALLS] array")
                        }
                    }
                }

                /// Remove [TOOL_CALLS][...] from content.
                let fullRange = match.range
                cleanedContent = (cleanedContent as NSString).replacingCharacters(in: fullRange, with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        return (toolCalls, cleanedContent)
    }

    /// Detect Hermes-specific patterns **What is Hermes format**: Used by Hermes/Nous Research models Structure resembles OpenAI but without API-specific wrappers **Key characteristics**: - JSON with "name" and "arguments" keys (like OpenAI) - May use "function" key instead of "name" in some versions - "arguments" can be object OR string (OpenAI always uses string) - No `tool_calls` wrapper array, tools appear directly in response **Detection strategy**: Conservative approach - Look for {"name": ..., "arguments": ...} structure - Must NOT match Qwen (<function_call>) or Ministral ([TOOL_CALLS]) - Avoids false positives from other JSON in responses.
    private func containsHermesPattern(_ content: String) -> Bool {
        /// Hermes typically uses "name" and "arguments" keys.
        let lowerContent = content.lowercased()
        let hasNameAndArguments = lowerContent.contains("\"name\"") && lowerContent.contains("\"arguments\"")
        let hasFunction = lowerContent.contains("\"function\"")

        /// Not already detected as Qwen or Ministral.
        let notQwen = !content.contains("<function_call>")
        let notMinistral = !content.contains("[TOOL_CALLS]")

        return (hasNameAndArguments || hasFunction) && notQwen && notMinistral
    }

    /// Extract Hermes format **Format structure**: JSON objects with function call data embedded in response Pattern: `{"name": "tool_name", "arguments": {"param": "value"}}` **Why different from OpenAI**: Hermes models trained on simpler format without wrappers **Extraction approach**: Regex to find JSON objects matching function call structure.
    private func extractHermesFormat(from content: String) -> ([ToolCall], String) {
        var toolCalls: [ToolCall] = []
        var cleanedContent = content

        /// Find JSON objects that look like function calls: {"name": ..., "arguments": ...}.
        let pattern = "\\{[^{}]*\"name\"[^{}]*\"arguments\"[^{}]*\\}"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else {
            logger.error("Failed to create regex for Hermes format")
            return ([], content)
        }

        let nsContent = content as NSString
        let matches = regex.matches(in: content, range: NSRange(location: 0, length: nsContent.length))

        logger.debug("Found \(matches.count) potential Hermes function call patterns")

        for match in matches.reversed() {
            let jsonRange = match.range
            let jsonString = nsContent.substring(with: jsonRange)

            if let toolCall = parseToolCallJSON(jsonString) {
                toolCalls.insert(toolCall, at: 0)
                logger.debug("Parsed Hermes tool call '\(toolCall.name)'")

                /// Remove the JSON from content.
                cleanedContent = (cleanedContent as NSString).replacingCharacters(in: jsonRange, with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        return (toolCalls, cleanedContent)
    }

    /// Extract JSON code blocks (```json ...
    private func extractJSONCodeBlocks(from content: String) -> ([ToolCall], String) {
        var toolCalls: [ToolCall] = []
        var cleanedContent = content

        /// Match code blocks with any language tag (json, xml, or none) Pattern: ``` + optional language identifier + content + ```.
        let pattern = "```(?:[a-zA-Z]+)?\\s*([\\s\\S]*?)```"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            logger.error("Failed to create regex for JSON code blocks")
            return ([], content)
        }

        let nsContent = content as NSString
        let matches = regex.matches(in: content, range: NSRange(location: 0, length: nsContent.length))

        logger.debug("Found \(matches.count) JSON code blocks")

        for match in matches.reversed() {
            guard match.numberOfRanges >= 2 else { continue }

            let jsonRange = match.range(at: 1)
            let jsonString = nsContent.substring(with: jsonRange).trimmingCharacters(in: .whitespacesAndNewlines)

            /// Try to parse as tool call(s).
            if let extracted = parseJSONAsToolCalls(jsonString) {
                toolCalls.insert(contentsOf: extracted.reversed(), at: 0)

                /// Remove code block from content.
                let fullRange = match.range
                cleanedContent = (cleanedContent as NSString).replacingCharacters(in: fullRange, with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        return (toolCalls, cleanedContent)
    }

    /// Extract bare JSON (direct arrays or objects).
    private func extractBareJSON(from content: String) -> ([ToolCall], String) {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)

        /// Try to parse entire content as JSON.
        if let extracted = parseJSONAsToolCalls(trimmed) {
            logger.debug("Successfully parsed bare JSON as \(extracted.count) tool calls")
            return (extracted, "")
        }

        return ([], content)
    }

    /// Extract JSON embedded in conversational text Finds {"name": "...", "arguments": {...}} patterns anywhere in text and extracts them This is the most permissive extraction - catches tool calls mixed with conversational responses.
    private func extractEmbeddedJSON(from content: String) -> ([ToolCall], String) {
        var toolCalls: [ToolCall] = []
        var cleanedContent = content

        /// Find all JSON objects that look like tool calls Strategy: Scan for { followed by "name" field, extract complete JSON by brace counting.
        var searchStart = cleanedContent.startIndex

        while searchStart < cleanedContent.endIndex {
            /// Find next '{'.
            guard let braceIndex = cleanedContent[searchStart...].firstIndex(of: "{") else {
                break
            }

            /// Check if this looks like a tool call (has "name" shortly after {).
            let lookahead = cleanedContent.index(braceIndex, offsetBy: min(100, cleanedContent.distance(from: braceIndex, to: cleanedContent.endIndex)))
            let snippet = String(cleanedContent[braceIndex..<lookahead])

            if snippet.contains("\"name\"") {
                /// Extract complete JSON by counting braces.
                var jsonEnd = braceIndex
                var braceCount = 0
                var inString = false
                var escapeNext = false

                while jsonEnd < cleanedContent.endIndex {
                    let char = cleanedContent[jsonEnd]

                    if escapeNext {
                        escapeNext = false
                    } else if char == "\\" {
                        escapeNext = true
                    } else if char == "\"" && !escapeNext {
                        inString.toggle()
                    } else if !inString {
                        if char == "{" {
                            braceCount += 1
                        } else if char == "}" {
                            braceCount -= 1
                            if braceCount == 0 {
                                /// Found complete JSON.
                                jsonEnd = cleanedContent.index(after: jsonEnd)
                                break
                            }
                        }
                    }

                    jsonEnd = cleanedContent.index(after: jsonEnd)
                }

                /// Extract and parse JSON.
                let jsonString = String(cleanedContent[braceIndex..<jsonEnd])
                logger.debug("Extracted embedded JSON: \(jsonString.prefix(100))...")

                if let toolCall = parseToolCallJSON(jsonString) {
                    toolCalls.append(toolCall)
                    logger.debug("Parsed embedded tool call '\(toolCall.name)'")

                    /// Remove the JSON from cleanedContent (using indices from cleanedContent, not original content)
                    cleanedContent.removeSubrange(braceIndex..<jsonEnd)

                    /// Reset search to beginning since we modified the string
                    searchStart = cleanedContent.startIndex
                } else {
                    /// Not a valid tool call, continue searching after this {.
                    searchStart = cleanedContent.index(after: braceIndex)
                }
            } else {
                /// No "name" field nearby, continue searching.
                searchStart = cleanedContent.index(after: braceIndex)
            }
        }

        return (toolCalls, cleanedContent.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    // MARK: - Helper Methods

    /// Parse JSON string as a single tool call Expects format: {"name": "tool_name", "arguments": {...}}.
    private func parseToolCallJSON(_ jsonString: String) -> ToolCall? {
        guard let jsonData = jsonString.data(using: .utf8),
              let jsonDict = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
            logger.warning("Failed to parse JSON: \(jsonString)")
            return nil
        }

        /// Check for proper standard format with "name" and "arguments" fields.
        if let name = jsonDict["name"] as? String, jsonDict["arguments"] != nil {
            /// Standard format: {"name": "tool_name", "arguments": {...}}.
            return parseStandardToolCall(jsonDict, name: name)
        }

        /// Qwen mixed format (has "name" + other fields that should be "arguments") Pattern: {"name": "run_sam_command", "command": "...", ...} Should become: {"name": "run_sam_command", "arguments": {"command": "...", ...}}.
        if let name = jsonDict["name"] as? String, jsonDict["arguments"] == nil {
            logger.debug("Detected Qwen mixed format with name='\(name)' + additional fields")
            /// Extract all fields except "name" and "id" to use as arguments.
            var argumentsDict = jsonDict
            argumentsDict.removeValue(forKey: "name")
            let toolId = argumentsDict.removeValue(forKey: "id") as? String

            /// Convert arguments dict to JSON string.
            if let argsData = try? JSONSerialization.data(withJSONObject: argumentsDict, options: []),
               let argsString = String(data: argsData, encoding: .utf8) {
                return ToolCall(name: name, arguments: argsString, id: toolId)
            }
        }

        /// Alternative format with "tool" field instead of "name" (some models use this) Pattern: {"tool": "image_generation", "prompt": "...", ...} Should become: {"name": "image_generation", "arguments": {"prompt": "...", ...}}.
        if let toolName = jsonDict["tool"] as? String {
            logger.debug("Detected alternative 'tool' field format with tool='\(toolName)' + additional fields")
            /// Extract all fields except "tool" and "id" to use as arguments.
            var argumentsDict = jsonDict
            argumentsDict.removeValue(forKey: "tool")
            let toolId = argumentsDict.removeValue(forKey: "id") as? String

            /// Convert arguments dict to JSON string.
            if let argsData = try? JSONSerialization.data(withJSONObject: argumentsDict, options: []),
               let argsString = String(data: argsData, encoding: .utf8) {
                logger.debug("Converted 'tool' format to standard: name='\(toolName)', arguments=\(argsString)")
                return ToolCall(name: toolName, arguments: argsString, id: toolId)
            }
        }

        /// Alternative format with "operation" field instead of "name" (DeepSeek and other GGUF models) Pattern: {"operation": "image_generation", "prompt": "...", ...} Should become: {"name": "image_generation", "arguments": {"prompt": "...", ...}}.
        if let toolName = jsonDict["operation"] as? String {
            logger.debug("Detected alternative 'operation' field format with operation='\(toolName)' + additional fields")
            /// Extract all fields except "operation" and "id" to use as arguments.
            var argumentsDict = jsonDict
            argumentsDict.removeValue(forKey: "operation")
            let toolId = argumentsDict.removeValue(forKey: "id") as? String

            /// Convert arguments dict to JSON string.
            if let argsData = try? JSONSerialization.data(withJSONObject: argumentsDict, options: []),
               let argsString = String(data: argsData, encoding: .utf8) {
                logger.debug("Converted 'operation' format to standard: name='\(toolName)', arguments=\(argsString)")
                return ToolCall(name: toolName, arguments: argsString, id: toolId)
            }
        }

        /// Qwen bare arguments pattern (no "name" field at all) Pattern: {"command": "...", ...} -> infer tool name as "run_sam_command".
        if let command = jsonDict["command"] as? String {
            logger.debug("Detected Qwen bare run_sam_command arguments: {\"command\": \"\(command)\"}")
            /// Convert to standard format by wrapping arguments.
            if let wrappedJSON = try? JSONSerialization.data(withJSONObject: jsonDict, options: []),
               let wrappedString = String(data: wrappedJSON, encoding: .utf8) {
                return ToolCall(name: "run_sam_command", arguments: wrappedString, id: nil)
            }
        }

        logger.warning("No recognized tool call pattern in JSON")
        return nil
    }

    /// Parse standard tool call format with "name" and "arguments" fields.
    private func parseStandardToolCall(_ jsonDict: [String: Any], name: String) -> ToolCall? {
        /// Extract arguments (can be object or already-stringified JSON).
        let arguments: String
        if let argsDict = jsonDict["arguments"] as? [String: Any] {
            /// Arguments is a dictionary, convert to JSON string.
            if let argsData = try? JSONSerialization.data(withJSONObject: argsDict, options: []),
               let argsJSON = String(data: argsData, encoding: .utf8) {
                arguments = argsJSON
            } else {
                logger.warning("Failed to serialize arguments dictionary")
                return nil
            }
        } else if let argsString = jsonDict["arguments"] as? String {
            /// Arguments is already a string.
            arguments = argsString
        } else {
            logger.warning("Invalid 'arguments' field type")
            return nil
        }

        let id = jsonDict["id"] as? String

        return ToolCall(name: name, arguments: arguments, id: id)
    }

    /// Parse JSON string as array of tool calls or single tool call.
    private func parseJSONAsToolCalls(_ jsonString: String) -> [ToolCall]? {
        guard let jsonData = jsonString.data(using: .utf8) else {
            return nil
        }

        /// Try as array first.
        if let jsonArray = try? JSONSerialization.jsonObject(with: jsonData) as? [[String: Any]] {
            var toolCalls: [ToolCall] = []

            for toolCallDict in jsonArray {
                if let name = toolCallDict["name"] as? String {
                    let arguments = toolCallDict["arguments"] ?? [:]
                    let id = toolCallDict["id"] as? String

                    /// Convert arguments to JSON string.
                    if let argumentsData = try? JSONSerialization.data(withJSONObject: arguments, options: []),
                       let argumentsJSON = String(data: argumentsData, encoding: .utf8) {
                        toolCalls.append(ToolCall(name: name, arguments: argumentsJSON, id: id))
                    }
                }
            }

            return toolCalls.isEmpty ? nil : toolCalls
        }

        /// Try as single object.
        if let toolCall = parseToolCallJSON(jsonString) {
            return [toolCall]
        }

        return nil
    }
}
