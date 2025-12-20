<!-- SPDX-License-Identifier: CC-BY-NC-4.0 -->
<!-- SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius) -->


# THINK TOOL SPECIFICATION
**Date**: October 9, 2025  
**Priority**: CRITICAL - Foundational for agentic behavior

---

## PURPOSE

The **Think Tool** enables SAM's LLM agents to engage in transparent, structured reasoning before responding to users. This implements Chain-of-Thought (CoT) reasoning patterns that dramatically improve response quality for complex tasks.

### Inspiration: GitHub Copilot's Think Tool

GitHub Copilot agents use a "think" tool that allows them to:
- Organize thoughts before responding
- Brainstorm multiple solution approaches
- Break down complex tasks into logical steps
- Make reasoning transparent to users
- Improve response quality through deliberate planning

**User's Vision**: "Our agents should be able to create and maintain lists, operate sequentially, **think**, perform complex operations - basically work the same way that you do but for non-code development use cases"

---

## 🏗ARCHITECTURE

### Tool Definition

```swift
// Sources/MCPFramework/Tools/ThinkTool.swift

import Foundation

/// Enables LLM agents to engage in transparent reasoning before responding
public class ThinkTool: MCPTool {
    
    // MARK: - MCPTool Protocol
    
    public let name = "think"
    
    public let description = """
    Use this tool to think deeply about the user's request and organize your thoughts. \
    This tool helps improve response quality by allowing you to consider the request carefully, \
    brainstorm solutions, and plan complex tasks. It's particularly useful for:
    
    1. Exploring repository issues and brainstorming bug fixes
    2. Analyzing test results and planning fixes
    3. Planning complex refactoring approaches
    4. Designing new features and architecture
    5. Organizing debugging hypotheses
    
    The tool logs your thought process for transparency but doesn't execute any code or make changes.
    """
    
    public let parameters: [MCPToolParameter] = [
        MCPToolParameter(
            name: "thoughts",
            type: .string,
            description: """
            Your thoughts about the current task or problem. This should be a clear, structured \
            explanation of your reasoning, analysis, or planning process. Use markdown formatting \
            for clarity (bullet points, numbered lists, code blocks, etc.).
            """,
            required: true
        )
    ]
    
    public let category: MCPToolCategory = .utility
    public let securityLevel: MCPSecurityLevel = .safe
    public let isEnabled: Bool = true
    
    // MARK: - Execution
    
    public func execute(parameters: [String: Any], context: MCPToolContext) async throws -> MCPToolResult {
        guard let thoughts = parameters["thoughts"] as? String else {
            throw MCPToolError.invalidParameters("Missing required 'thoughts' parameter")
        }
        
        guard !thoughts.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MCPToolError.invalidParameters("Thoughts parameter cannot be empty")
        }
        
        // Log the thinking process (for debugging/analytics)
        await logThinkingProcess(thoughts: thoughts, context: context)
        
        // Create structured result
        let thinkingContent = formatThinkingContent(thoughts)
        
        return MCPToolResult(
            success: true,
            content: thinkingContent,
            metadata: [
                "tool": "think",
                "timestamp": ISO8601DateFormatter().string(from: Date()),
                "thoughtLength": thoughts.count,
                "contextConversationId": context.conversationId
            ]
        )
    }
    
    // MARK: - Private Helpers
    
    private func formatThinkingContent(_ thoughts: String) -> String {
        return """
        **Thinking Process**
        
        \(thoughts)
        
        ---
        *Thought process logged for transparency*
        """
    }
    
    private func logThinkingProcess(thoughts: String, context: MCPToolContext) async {
        // Log to conversation history or analytics system
        // This helps with debugging and understanding agent reasoning
        print("THINK_TOOL: Agent thinking process in conversation \(context.conversationId)")
        print("THINK_TOOL: \(thoughts.prefix(100))...")
    }
}
```

---

## 🎨 UI INTEGRATION

### ChatWidget Display

Thinking messages should be displayed distinctly from regular responses:

```swift
// Sources/UserInterface/Chat/ChatWidget.swift

// Add thinking message styling
private func renderThinkingMessage(_ content: String) -> some View {
    VStack(alignment: .leading, spacing: 8) {
        HStack {
            Image(systemName: "brain.head.profile")
                .foregroundColor(.purple)
            Text("Thinking Process")
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundColor(.purple)
            Spacer()
        }
        
        // Expandable/collapsible thinking content
        DisclosureGroup("View Reasoning") {
            MarkdownText(content: content)
                .font(.body.monospaced())
                .foregroundColor(.secondary)
                .padding()
                .background(Color.secondary.opacity(0.1))
                .cornerRadius(8)
        }
    }
    .padding()
    .background(Color.purple.opacity(0.05))
    .cornerRadius(12)
}
```

### Visual Design

**Collapsed State** (default):
```
Thinking Process
   ▶ View Reasoning
```

**Expanded State** (user clicks):
```
Thinking Process
   ▼ View Reasoning
   
   [Thinking content in gray box with monospaced font]
   
   I need to analyze this request in steps:
   1. Understand what the user is asking for
   2. Check if similar functionality exists
   3. Plan the implementation approach
   ...
   
   ---
   *Thought process logged for transparency*
```

---

## SYSTEM PROMPT INTEGRATION

Update SAM's system prompts to encourage thinking tool usage:

### For Simple Prompts/Providers

```swift
// Sources/Configuration/SimpleSystemPromptManager.swift

private let cognitiveInstructions = """
You have access to a "think" tool that helps improve response quality. Use it when:

1. **Complex Questions**: User asks about architecture, design decisions, or multi-step problems
2. **Debugging**: Analyzing errors or unexpected behavior
3. **Planning**: Breaking down large tasks into smaller steps
4. **Brainstorming**: Exploring multiple solution approaches
5. **Uncertainty**: When you need to reason through the best approach

Example usage:
{
  "tool": "think",
  "parameters": {
    "thoughts": "Let me analyze this step by step:\\n1. The user wants...\\n2. I should check...\\n3. The best approach is..."
  }
}

After thinking, provide your actual response to the user.
"""
```

### For Provider-Specific Prompts

Different LLM providers may have different optimal patterns for thinking tool usage. Add provider-specific guidance.

---

## 🧪 TESTING PROTOCOL

### Unit Tests

```swift
// Tests/MCPFrameworkTests/ThinkToolTests.swift

import XCTest
@testable import MCPFramework

class ThinkToolTests: XCTestCase {
    
    var thinkTool: ThinkTool!
    
    override func setUp() {
        super.setUp()
        thinkTool = ThinkTool()
    }
    
    func testBasicThinking() async throws {
        let thoughts = "I need to analyze this request in three steps: 1. Understand, 2. Plan, 3. Execute"
        let context = MCPToolContext(conversationId: "test-123")
        
        let result = try await thinkTool.execute(
            parameters: ["thoughts": thoughts],
            context: context
        )
        
        XCTAssertTrue(result.success)
        XCTAssertTrue(result.content.contains(thoughts))
        XCTAssertTrue(result.content.contains(""))
        XCTAssertEqual(result.metadata["tool"] as? String, "think")
    }
    
    func testEmptyThoughtsRejected() async throws {
        let context = MCPToolContext(conversationId: "test-123")
        
        do {
            _ = try await thinkTool.execute(
                parameters: ["thoughts": "   "],
                context: context
            )
            XCTFail("Should have thrown error for empty thoughts")
        } catch MCPToolError.invalidParameters {
            // Expected
        }
    }
    
    func testMarkdownFormattingPreserved() async throws {
        let thoughts = """
        ## Analysis
        
        1. First step
        2. Second step
        
        ```swift
        let code = "example"
        ```
        """
        
        let context = MCPToolContext(conversationId: "test-123")
        let result = try await thinkTool.execute(
            parameters: ["thoughts": thoughts],
            context: context
        )
        
        XCTAssertTrue(result.content.contains("## Analysis"))
        XCTAssertTrue(result.content.contains("```swift"))
    }
}
```

### Integration Tests

```bash
# Test via SAM API with GPT-4
curl -X POST http://127.0.0.1:8080/api/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "gpt-4",
    "messages": [
      {
        "role": "user",
        "content": "I need to refactor the authentication system to support OAuth2. This is complex - please think through the approach before suggesting changes."
      }
    ]
  }'

# Expected: LLM should use think tool first, then provide response

# Test with local MLX model
curl -X POST http://127.0.0.1:8080/api/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "lmstudio-community_Qwen2.5-Coder-7B-Instruct-MLX-4bit",
    "messages": [
      {
        "role": "user",
        "content": "Debug why my app crashes on startup. Walk me through your debugging process."
      }
    ]
  }'

# Expected: Model uses think tool to outline debugging steps before asking questions
```

### User Experience Tests

1. **Transparency Test**: Does showing thinking process build trust?
2. **Quality Test**: Are responses better when thinking tool is used?
3. **UI Test**: Is the collapsed/expanded thinking UI intuitive?
4. **Performance Test**: Does thinking add significant latency?

---

## IMPLEMENTATION PHASES

### Phase 1: Core Tool (2 hours)
- [ ] Create ThinkTool.swift in MCPFramework
- [ ] Implement tool protocol and execution
- [ ] Add to tool registry
- [ ] Write unit tests

### Phase 2: UI Integration (2-3 hours)
- [ ] Add thinking message rendering to ChatWidget
- [ ] Implement expandable/collapsible UI
- [ ] Add thinking message styling (purple theme)
- [ ] Test UI responsiveness

### Phase 3: System Prompt Updates (1 hour)
- [ ] Update SimpleSystemPromptManager with thinking guidance
- [ ] Add provider-specific thinking patterns
- [ ] Test with different LLM providers (GPT-4, Claude, local MLX)

### Phase 4: Testing & Refinement (1 hour)
- [ ] Integration testing with real conversations
- [ ] User experience validation
- [ ] Performance testing
- [ ] Documentation updates

**Total Estimated Time**: 6-7 hours

---

## SUCCESS CRITERIA

### Functional Requirements
- Think tool executes successfully with valid input
- Rejects empty or invalid thoughts parameter
- Returns formatted, structured thinking content
- Metadata includes timestamp and context

### UX Requirements
- Thinking messages visually distinct from responses
- Expandable/collapsible UI for thinking content
- Markdown formatting preserved in thinking display
- Doesn't interrupt conversation flow

### Quality Requirements
- LLM uses think tool for complex questions (>70% of time)
- Responses improve when thinking tool used (subjective evaluation)
- Thinking process makes sense to users (comprehensibility)
- No significant latency increase (<500ms overhead)

### Integration Requirements
- Works with all LLM providers (OpenAI, Anthropic, local MLX)
- Integrates with MCP tool registry
- Plays nicely with other tools (can use before/after other tools)
- Proper error handling and user feedback

---

## FUTURE ENHANCEMENTS

### V2: Advanced Features
1. **Thinking History**: Store thinking processes for learning/analytics
2. **Thinking Patterns**: Identify common reasoning patterns, suggest improvements
3. **Collaborative Thinking**: Multiple agents think together on complex problems
4. **Thinking Templates**: Pre-structured thinking patterns for common scenarios

### V3: Meta-Cognition
1. **Self-Reflection**: Agent evaluates quality of its own thinking
2. **Learning**: Improve thinking patterns based on user feedback
3. **Explainability**: Detailed breakdowns of why agent chose specific approaches

---

## 📚 REFERENCES

### Theoretical Foundation
- **Chain-of-Thought Prompting**: Wei et al. (2022) - "Chain-of-Thought Prompting Elicits Reasoning in Large Language Models"
- **Self-Consistency**: Wang et al. (2022) - "Self-Consistency Improves Chain of Thought Reasoning in Language Models"
- **Tree of Thoughts**: Yao et al. (2023) - "Tree of Thoughts: Deliberate Problem Solving with Large Language Models"

### Implementation References
- GitHub Copilot's "think" tool pattern (via .github/copilot-instructions.md)
- Anthropic's tool use documentation: https://docs.anthropic.com/en/docs/build-with-claude/tool-use
- OpenAI function calling: https://platform.openai.com/docs/guides/function-calling

### SAM-Specific Context
- User requirement: "agents should work like Copilot - sequential operations, thinking, complex operations"
- Existing MCP framework (MCPTool protocol, MCPManager, tool registry)
- ChatWidget rendering with markdown support

---

## NEXT STEPS

1. **Review & Approval**: Get user feedback on this specification
2. **Implementation**: Follow Phase 1-4 implementation plan
3. **Testing**: Comprehensive testing with real use cases
4. **Integration**: Ensure works with all existing MCP tools
5. **Documentation**: Update MCP_TOOLS_USER_GUIDE.md with thinking tool examples
6. **Iteration**: Refine based on user feedback and agent behavior

**Estimated Completion**: 1 day from approval
