// Tokenizer loader for a bundled model directory.
// MLXHuggingFace provides one via macro, but that product pulls iOS 27 SDK
// symbols; this wrapper keeps the Phase 1 build on the iOS 26.5 SDK.

import Foundation
import MLXLMCommon
import Tokenizers

struct BundleTokenizerLoader: TokenizerLoader {
    func load(from directory: URL) async throws -> any MLXLMCommon.Tokenizer {
        let tokenizer = try await AutoTokenizer.from(modelFolder: directory)
        return WrappedTokenizer(tokenizer: tokenizer)
    }
}

/// Forwards swift-transformers' tokenizer to MLXLMCommon's Tokenizer protocol.
struct WrappedTokenizer: MLXLMCommon.Tokenizer {
    let tokenizer: any Tokenizers.Tokenizer

    func encode(text: String, addSpecialTokens: Bool) -> [Int] {
        tokenizer.encode(text: text, addSpecialTokens: addSpecialTokens)
    }

    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String {
        tokenizer.decode(tokens: tokenIds, skipSpecialTokens: skipSpecialTokens)
    }

    func convertTokenToId(_ token: String) -> Int? {
        tokenizer.convertTokenToId(token)
    }

    func convertIdToToken(_ id: Int) -> String? {
        tokenizer.convertIdToToken(id)
    }

    var bosToken: String? { tokenizer.bosToken }
    var eosToken: String? { tokenizer.eosToken }
    var unknownToken: String? { tokenizer.unknownToken }

    func applyChatTemplate(
        messages: [[String: any Sendable]],
        tools: [[String: any Sendable]]?,
        additionalContext: [String: any Sendable]?
    ) throws -> [Int] {
        try tokenizer.applyChatTemplate(
            messages: messages, tools: tools, additionalContext: additionalContext)
    }
}
