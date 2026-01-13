import Foundation

/// Represents different chat template formats for LLM training
public enum ChatTemplate: String, CaseIterable, Sendable, Codable {
    case llama3 = "Llama 3/4"
    case mistral = "Mistral"
    case qwen = "Qwen 2.5"
    case gemma = "Gemma 2/3"
    case phi = "Phi 3"
    case custom = "Custom"
    
    /// Human-readable description of the template
    public var description: String {
        rawValue
    }
    
    /// Recommended for these model families
    public var modelFamilies: [String] {
        switch self {
        case .llama3: return ["llama-3", "llama-4", "llama3", "llama4"]
        case .mistral: return ["mistral", "mixtral"]
        case .qwen: return ["qwen", "qwen2.5"]
        case .gemma: return ["gemma", "gemma-2", "gemma-3"]
        case .phi: return ["phi-3", "phi3"]
        case .custom: return []
        }
    }
}

/// Engine for formatting messages according to different chat templates
public actor ChatTemplateEngine {
    
    /// Formats a user/assistant message pair according to the specified template
    /// - Parameters:
    ///   - userMessage: The user's input message
    ///   - assistantMessage: The assistant's response
    ///   - template: The chat template format to use
    ///   - systemPrompt: Optional system prompt to include
    /// - Returns: Formatted message string ready for training
    public func format(
        userMessage: String,
        assistantMessage: String,
        template: ChatTemplate,
        systemPrompt: String? = nil
    ) -> String {
        switch template {
        case .llama3:
            return formatLlama3(
                userMessage: userMessage,
                assistantMessage: assistantMessage,
                systemPrompt: systemPrompt
            )
        case .mistral:
            return formatMistral(
                userMessage: userMessage,
                assistantMessage: assistantMessage,
                systemPrompt: systemPrompt
            )
        case .qwen:
            return formatQwen(
                userMessage: userMessage,
                assistantMessage: assistantMessage,
                systemPrompt: systemPrompt
            )
        case .gemma:
            return formatGemma(
                userMessage: userMessage,
                assistantMessage: assistantMessage,
                systemPrompt: systemPrompt
            )
        case .phi:
            return formatPhi(
                userMessage: userMessage,
                assistantMessage: assistantMessage,
                systemPrompt: systemPrompt
            )
        case .custom:
            return formatCustom(
                userMessage: userMessage,
                assistantMessage: assistantMessage,
                systemPrompt: systemPrompt
            )
        }
    }
    
    /// Formats a message using a custom Jinja2 template string from a model
    /// This is a simplified implementation that handles basic template patterns
    /// - Parameters:
    ///   - userMessage: The user's input message
    ///   - assistantMessage: The assistant's response
    ///   - templateString: The Jinja2 template string from tokenizer_config.json
    ///   - systemPrompt: Optional system prompt to include
    /// - Returns: Formatted message string
    public func formatWithTemplate(
        userMessage: String,
        assistantMessage: String,
        templateString: String,
        systemPrompt: String? = nil
    ) -> String {
        // Extract special tokens from template
        let tokens = extractTokensFromTemplate(templateString)
        
        var result = ""
        
        // Add system prompt if present
        if let systemPrompt = systemPrompt {
            result += "\(tokens.startToken)system\n\(systemPrompt)\(tokens.endToken)\n"
        }
        
        // Add user message
        result += "\(tokens.startToken)user\n\(userMessage)\(tokens.endToken)\n"
        
        // Add assistant message
        result += "\(tokens.startToken)assistant\n\(assistantMessage)\(tokens.endToken)\n"
        
        return result
    }
    
    /// Extracts role delimiter tokens from a Jinja2 template
    /// - Parameter template: The Jinja2 template string
    /// - Returns: Tuple of (startToken, endToken)
    private func extractTokensFromTemplate(_ template: String) -> (startToken: String, endToken: String) {
        // Common patterns to detect
        let patterns: [(startToken: String, endToken: String)] = [
            ("<|im_start|>", "<|im_end|>"),  // Qwen, ChatML
            ("<|start_header_id|>", "<|eot_id|>"),  // Llama 3/4
            ("<start_of_turn>", "<end_of_turn>"),  // Gemma
            ("<|user|>", "<|end|>"),  // Phi
            ("[INST]", "[/INST]"),  // Mistral
        ]
        
        for pattern in patterns {
            if template.contains(pattern.startToken) {
                return pattern
            }
        }
        
        // Fallback to generic markers
        return (startToken: "<|im_start|>", endToken: "<|im_end|>")
    }
    
    // MARK: - Template Implementations
    
    /// Llama 3/4 chat template format
    /// Format: <|begin_of_text|><|start_header_id|>system<|end_header_id|>...
    private func formatLlama3(
        userMessage: String,
        assistantMessage: String,
        systemPrompt: String?
    ) -> String {
        var result = "<|begin_of_text|>"
        
        if let systemPrompt = systemPrompt {
            result += "<|start_header_id|>system<|end_header_id|>\n\n\(systemPrompt)<|eot_id|>"
        }
        
        result += "<|start_header_id|>user<|end_header_id|>\n\n\(userMessage)<|eot_id|>"
        result += "<|start_header_id|>assistant<|end_header_id|>\n\n\(assistantMessage)<|eot_id|>"
        
        return result
    }
    
    /// Mistral chat template format
    /// Format: <s>[INST] ... [/INST] ... </s>
    private func formatMistral(
        userMessage: String,
        assistantMessage: String,
        systemPrompt: String?
    ) -> String {
        var instruction = userMessage
        
        if let systemPrompt = systemPrompt {
            instruction = "\(systemPrompt)\n\n\(userMessage)"
        }
        
        return "<s>[INST] \(instruction) [/INST] \(assistantMessage)</s>"
    }
    
    /// Qwen 2.5 chat template format
    /// Format: <|im_start|>system...
    private func formatQwen(
        userMessage: String,
        assistantMessage: String,
        systemPrompt: String?
    ) -> String {
        var result = ""
        
        if let systemPrompt = systemPrompt {
            result += "<|im_start|>system\n\(systemPrompt)<|im_end|>\n"
        }
        
        result += "<|im_start|>user\n\(userMessage)<|im_end|>\n"
        result += "<|im_start|>assistant\n\(assistantMessage)<|im_end|>\n"
        
        return result
    }
    
    /// Gemma 2/3 chat template format
    /// Format: <start_of_turn>user...
    private func formatGemma(
        userMessage: String,
        assistantMessage: String,
        systemPrompt: String?
    ) -> String {
        var result = ""
        
        if let systemPrompt = systemPrompt {
            result += "<start_of_turn>system\n\(systemPrompt)<end_of_turn>\n"
        }
        
        result += "<start_of_turn>user\n\(userMessage)<end_of_turn>\n"
        result += "<start_of_turn>model\n\(assistantMessage)<end_of_turn>"
        
        return result
    }
    
    /// Phi 3 chat template format
    /// Format: <|user|>...<|end|>...
    private func formatPhi(
        userMessage: String,
        assistantMessage: String,
        systemPrompt: String?
    ) -> String {
        var result = ""
        
        if let systemPrompt = systemPrompt {
            result += "<|system|>\n\(systemPrompt)<|end|>\n"
        }
        
        result += "<|user|>\n\(userMessage)<|end|>\n"
        result += "<|assistant|>\n\(assistantMessage)<|end|>"
        
        return result
    }
    
    /// Custom/generic chat template format
    /// Simple markdown-style format
    private func formatCustom(
        userMessage: String,
        assistantMessage: String,
        systemPrompt: String?
    ) -> String {
        var result = ""
        
        if let systemPrompt = systemPrompt {
            result += "### System:\n\(systemPrompt)\n\n"
        }
        
        result += "### User:\n\(userMessage)\n\n"
        result += "### Assistant:\n\(assistantMessage)"
        
        return result
    }
    
    /// Formats a multi-turn conversation
    /// - Parameters:
    ///   - turns: Array of (user, assistant) message pairs
    ///   - template: The chat template format to use
    ///   - systemPrompt: Optional system prompt to include
    /// - Returns: Formatted multi-turn conversation
    public func formatConversation(
        turns: [(user: String, assistant: String)],
        template: ChatTemplate,
        systemPrompt: String? = nil
    ) -> String {
        var result = ""
        
        for (index, turn) in turns.enumerated() {
            // Only include system prompt in first turn for most templates
            let prompt = (index == 0) ? systemPrompt : nil
            let formatted = format(
                userMessage: turn.user,
                assistantMessage: turn.assistant,
                template: template,
                systemPrompt: prompt
            )
            
            result += formatted
            
            // Add newline between turns (except for Mistral which handles it internally)
            if index < turns.count - 1 && template != .mistral {
                result += "\n"
            }
        }
        
        return result
    }
    
    /// Auto-detects the appropriate template based on model name
    /// - Parameter modelName: Name of the model
    /// - Returns: Best matching template, or .custom if no match
    public func detectTemplate(for modelName: String) -> ChatTemplate {
        let lowercased = modelName.lowercased()
        
        for template in ChatTemplate.allCases where template != .custom {
            for family in template.modelFamilies {
                if lowercased.contains(family.lowercased()) {
                    return template
                }
            }
        }
        
        return .custom
    }
}
