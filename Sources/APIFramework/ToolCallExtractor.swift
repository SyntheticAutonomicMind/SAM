// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import Foundation
import Logging

/// Extracts tool calls from AI response text.
///
/// Supports two formats that providers/models are explicitly instructed to emit:
/// - XML `<tool_call>...</tool_call>` blocks (instructed for local MLX/llama.cpp
///   models by `AppleMLXAdapter.swift` and the local provider system prompts).
/// - JSON code blocks in markdown: ```json ... ```
///
/// Historical formats that used to be supported but caused hallucinated tool
/// calls during long conversations have been removed:
/// - Bare JSON dictionaries in prose (matched on any `{"name": ..., "arguments": ...}`)
/// - "Embedded JSON" fallback that triggered on any text containing both keys
/// - Qwen `<function_call>` and `FUNCTION:...ARGS:` formats
/// - "Calling tool:" prefix
/// - Ministral `[TOOL_CALLS]`
/// - Hermes detection
///
/// Trust native API `tool_calls` fields when the provider supports them; this
/// extractor is only used as a fallback for local models that emit text-only
/// responses.
public class ToolCallExtractor {
    private let logger = Logger(label: "com.sam.api.toolextractor")

    /// Detected tool call format type.
    public enum ToolCallFormat {
        case xmlTag
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

    /// Clean trailing quote from MLX/local model tool call arguments.
    /// Some local models append an extra `"` to the JSON arguments string,
    /// producing `{...}"` which breaks JSON parsing. This strips the trailing
    /// quote when the arguments begin with `{` and end with `"`.
    public static func cleanToolArguments(_ arguments: String) -> String {
        var cleaned = arguments
        if cleaned.hasSuffix("\"") && cleaned.hasPrefix("{") {
            cleaned = String(cleaned.dropLast())
        }
        return cleaned
    }

    /// Extract tool calls from response content.
    ///
    /// Detection order:
    /// 1. XML `<tool_call>...</tool_call>` blocks - canonical format for local models
    /// 2. JSON code blocks in markdown (```json ... ```)
    /// 3. Bare JSON when the entire response IS just JSON (used by LocalProviderCore's
    ///    instructed output format: "respond with raw JSON, no code blocks")
    ///
    /// What is intentionally NOT supported (caused hallucinated tool calls during long
    /// conversations): parsing `{"name":..., "arguments":...}` patterns out of
    /// conversational prose. The previous "embedded JSON" fallback would grab JSON that
    /// the model wrote while discussing tool format or JSON examples.
    public func extract(from content: String) -> ([ToolCall], String, ToolCallFormat) {
        guard !content.isEmpty else {
            return ([], content, .none)
        }

        // 1. XML <tool_call>...</tool_call> blocks - canonical format for local models.
        if content.contains("<tool_call>") {
            logger.debug("Detected <tool_call> XML tag format")
            let (calls, cleaned) = extractXMLTagFormat(from: content)
            if !calls.isEmpty {
                return (calls, cleaned, .xmlTag)
            }
        }

        // 2. JSON code blocks in markdown.
        if content.contains("```") {
            logger.debug("Detected JSON code block format")
            let (calls, cleaned) = extractJSONCodeBlocks(from: content)
            if !calls.isEmpty {
                return (calls, cleaned, .jsonCodeBlock)
            }
        }

        // 3. Bare JSON - fires ONLY when the entire trimmed response is JSON.
        //    This is the format LocalProviderCore's buildToolInstructions() tells
        //    local models to use ("respond with the EXACT tool request in raw JSON").
        //    Does NOT fire when JSON appears inside prose - that was the cause of
        //    hallucinated tool calls in long conversations.
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("[") || trimmed.hasPrefix("{") {
            if let extracted = parseJSONAsToolCalls(trimmed), !extracted.isEmpty {
                logger.debug("Parsed bare JSON as \(extracted.count) tool calls (response is pure JSON)")
                return (extracted, "", .bareJSON)
            }
        }

        logger.debug("No tool calls detected in content")
        return ([], content, .none)
    }

    // MARK: - Format Extractors

    /// Extract `<tool_call>...</tool_call>` format. Each block contains a single
    /// JSON object with `name` and `arguments` fields.
    private func extractXMLTagFormat(from content: String) -> ([ToolCall], String) {
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

        // Process matches in reverse to maintain correct string indices during removal.
        for match in matches.reversed() {
            guard match.numberOfRanges >= 2 else { continue }

            let jsonRange = match.range(at: 1)
            let jsonString = nsContent.substring(with: jsonRange)

            if let toolCall = parseToolCallJSON(jsonString) {
                toolCalls.insert(toolCall, at: 0)
                logger.debug("Parsed tool call '\(toolCall.name)' from <tool_call> tag")
                let fullRange = match.range
                cleanedContent = (cleanedContent as NSString).replacingCharacters(in: fullRange, with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
                logger.warning("JSON in <tool_call> did not parse as valid tool call")
            }
        }

        return (toolCalls, cleanedContent)
    }

    /// Extract tool calls from JSON code blocks in markdown. Matches blocks with
    /// any language tag (`json`, `xml`, or none) and tries to parse the content
    /// as either an array of tool calls or a single tool call.
    private func extractJSONCodeBlocks(from content: String) -> ([ToolCall], String) {
        var toolCalls: [ToolCall] = []
        var cleanedContent = content

        let pattern = "```(?:[a-zA-Z]+)?\\s*([\\s\\S]*?)```"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            logger.error("Failed to create regex for JSON code blocks")
            return ([], content)
        }

        let nsContent = content as NSString
        let matches = regex.matches(in: content, range: NSRange(location: 0, length: nsContent.length))

        logger.debug("Found \(matches.count) code blocks")

        for match in matches.reversed() {
            guard match.numberOfRanges >= 2 else { continue }

            let jsonRange = match.range(at: 1)
            let jsonString = nsContent.substring(with: jsonRange).trimmingCharacters(in: .whitespacesAndNewlines)

            if let extracted = parseJSONAsToolCalls(jsonString), !extracted.isEmpty {
                toolCalls.insert(contentsOf: extracted.reversed(), at: 0)
                let fullRange = match.range
                cleanedContent = (cleanedContent as NSString).replacingCharacters(in: fullRange, with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        return (toolCalls, cleanedContent)
    }

    // MARK: - JSON Parsing Helpers

    /// Parse a JSON string as a tool call. Expects format:
    /// `{"name": "tool_name", "arguments": {...}}` where `arguments` is a dict
    /// or already-stringified JSON.
    private func parseToolCallJSON(_ jsonString: String) -> ToolCall? {
        guard let jsonData = jsonString.data(using: .utf8),
              let jsonDict = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
            logger.warning("Failed to parse JSON: \(jsonString.prefix(100))")
            return nil
        }

        guard let name = jsonDict["name"] as? String else {
            return nil
        }

        let arguments: String
        if let argsDict = jsonDict["arguments"] as? [String: Any] {
            if let argsData = try? JSONSerialization.data(withJSONObject: argsDict, options: []),
               let argsJSON = String(data: argsData, encoding: .utf8) {
                arguments = argsJSON
            } else {
                logger.warning("Failed to serialize arguments dictionary")
                return nil
            }
        } else if let argsString = jsonDict["arguments"] as? String {
            arguments = argsString
        } else {
            logger.warning("Invalid 'arguments' field type")
            return nil
        }

        return ToolCall(name: name, arguments: arguments, id: jsonDict["id"] as? String)
    }

    /// Parse JSON string as array of tool calls or single tool call.
    private func parseJSONAsToolCalls(_ jsonString: String) -> [ToolCall]? {
        guard let jsonData = jsonString.data(using: .utf8) else {
            return nil
        }

        // Try as array first.
        if let jsonArray = try? JSONSerialization.jsonObject(with: jsonData) as? [[String: Any]] {
            var toolCalls: [ToolCall] = []
            for toolCallDict in jsonArray {
                if let name = toolCallDict["name"] as? String {
                    let arguments = toolCallDict["arguments"] ?? [:]
                    let id = toolCallDict["id"] as? String

                    if let argumentsData = try? JSONSerialization.data(withJSONObject: arguments, options: []),
                       let argumentsJSON = String(data: argumentsData, encoding: .utf8) {
                        toolCalls.append(ToolCall(name: name, arguments: argumentsJSON, id: id))
                    }
                }
            }
            return toolCalls.isEmpty ? nil : toolCalls
        }

        // Try as single object.
        if let toolCall = parseToolCallJSON(jsonString) {
            return [toolCall]
        }

        return nil
    }
}