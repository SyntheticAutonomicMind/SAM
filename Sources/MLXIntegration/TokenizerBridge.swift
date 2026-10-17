// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

/// TokenizerBridge.swift Bridges swift-transformers' Tokenizer protocol to MLXLMCommon's Tokenizer protocol.
/// In mlx-swift-lm 3.x, MLXLMCommon.Tokenizer is a protocol with a different API surface than
/// Tokenizers.Tokenizer from swift-transformers. This wrapper delegates all calls to the upstream
/// tokenizer, translating between the two protocol interfaces.

import Foundation
import Tokenizers
import MLXLMCommon

/// Wraps a `Tokenizers.Tokenizer` (from swift-transformers) to conform to `MLXLMCommon.Tokenizer`.
public struct TokenizerBridge: MLXLMCommon.Tokenizer {
    private let upstream: Tokenizers.Tokenizer

    public init(_ upstream: Tokenizers.Tokenizer) {
        self.upstream = upstream
    }

    public func encode(text: String, addSpecialTokens: Bool) -> [Int] {
        upstream.encode(text: text, addSpecialTokens: addSpecialTokens)
    }

    // swift-transformers uses `decode(tokens:)` instead of `decode(tokenIds:)`.
    public func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String {
        upstream.decode(tokens: tokenIds, skipSpecialTokens: skipSpecialTokens)
    }

    public func convertTokenToId(_ token: String) -> Int? {
        upstream.convertTokenToId(token)
    }

    public func convertIdToToken(_ id: Int) -> String? {
        upstream.convertIdToToken(id)
    }

    public var bosToken: String? { upstream.bosToken }
    public var eosToken: String? { upstream.eosToken }
    public var unknownToken: String? { upstream.unknownToken }

    public func applyChatTemplate(
        messages: [[String: any Sendable]],
        tools: [[String: any Sendable]]?,
        additionalContext: [String: any Sendable]?
    ) throws -> [Int] {
        do {
            return try upstream.applyChatTemplate(
                messages: messages, tools: tools, additionalContext: additionalContext)
        } catch Tokenizers.TokenizerError.missingChatTemplate {
            throw MLXLMCommon.TokenizerError.missingChatTemplate
        }
    }
}
