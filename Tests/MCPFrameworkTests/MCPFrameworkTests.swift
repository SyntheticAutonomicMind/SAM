// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import XCTest
@testable import MCPFramework
@testable import ConfigurationSystem
import Foundation

/// Comprehensive MCP Framework Unit Tests
/// Tests all MCP tools and their operations in isolation
final class MCPFrameworkTests: XCTestCase {
    
    // MARK: - Setup/Teardown
    
    var testDirectory: URL!
    var tempFiles: [URL] = []
    
    override func setUp() {
        super.setUp()
        // Create test directory
        let tempDir = FileManager.default.temporaryDirectory
        testDirectory = tempDir.appendingPathComponent("MCPTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: testDirectory, withIntermediateDirectories: true)
    }
    
    override func tearDown() {
        // Clean up temp files
        for file in tempFiles {
            try? FileManager.default.removeItem(at: file)
        }
        // Clean up test directory
        try? FileManager.default.removeItem(at: testDirectory)
        super.tearDown()
    }
    
    /// Helper to create a temp file
    func createTempFile(name: String, content: String) -> URL {
        let fileURL = testDirectory.appendingPathComponent(name)
        try? content.write(to: fileURL, atomically: true, encoding: .utf8)
        tempFiles.append(fileURL)
        return fileURL
    }
    
    // MARK: - MCPTool Protocol Tests
    
    func testMCPToolProtocolConformance() {
        // Verify all tools conform to MCPTool protocol
        let fileOpsTool = FileOperationsTool()
        
        XCTAssertFalse(fileOpsTool.name.isEmpty, "Tool must have a name")
        XCTAssertFalse(fileOpsTool.description.isEmpty, "Tool must have a description")
        XCTAssertFalse(fileOpsTool.parameters.isEmpty, "Tool must have parameters")
    }
    
    func testToolRegistration() {
        // Verify tools have required properties
        let tools: [any MCPTool] = [
            FileOperationsTool(),
            TerminalOperationsTool(),
            MemoryOperationsTool(),
            BuildVersionControlTool()
        ]
        
        for tool in tools {
            XCTAssertFalse(tool.name.isEmpty, "\(type(of: tool)) must have a name")
            XCTAssertNotNil(tool.parameters["operation"], "\(type(of: tool)) should have an operation parameter")
        }
        
        // ThinkTool doesn't have an operation parameter - it's special
        let thinkTool = ThinkTool()
        XCTAssertFalse(thinkTool.name.isEmpty, "ThinkTool must have a name")
        XCTAssertNotNil(thinkTool.parameters["thoughts"], "ThinkTool should have a thoughts parameter")
    }
    
    // MARK: - FileOperationsTool Unit Tests
    
    func testFileOperationsToolInit() {
        let tool = FileOperationsTool()
        XCTAssertEqual(tool.name, "file_operations")
        XCTAssertTrue(tool.description.contains("file"))
    }
    
    func testFileOperationsValidOperations() {
        let tool = FileOperationsTool()
        let validOps = [
            "read_file", "create_file", "replace_string", "multi_replace_string",
            "insert_edit", "apply_patch", "rename_file", "delete_file",
            "list_dir", "file_search", "grep_search", "semantic_search",
            "list_usages", "get_errors", "get_search_results", "search_index"
        ]
        
        // Tool should have operation parameter with enum
        guard let operationParam = tool.parameters["operation"] else {
            XCTFail("Tool must have operation parameter")
            return
        }
        
        XCTAssertNotNil(operationParam.enumValues, "Operation must have enum values")
        
        for op in validOps {
            XCTAssertTrue(
                operationParam.enumValues?.contains(op) ?? false,
                "Operation '\(op)' should be valid"
            )
        }
    }
    
    func testFileOperationsRequiredParameters() {
        let tool = FileOperationsTool()
        
        // Verify required parameters
        XCTAssertNotNil(tool.parameters["operation"])
        XCTAssertNotNil(tool.parameters["filePath"])
        
        // Check operation is required
        let opParam = tool.parameters["operation"]
        XCTAssertTrue(opParam?.required ?? false, "operation should be required")
    }
    
    // MARK: - TerminalOperationsTool Unit Tests
    
    func testTerminalOperationsToolInit() {
        let tool = TerminalOperationsTool()
        XCTAssertEqual(tool.name, "terminal_operations")
    }
    
    func testTerminalOperationsValidOperations() {
        let tool = TerminalOperationsTool()
        let validOps = [
            "run_command", "get_terminal_output", "get_terminal_buffer",
            "get_last_command", "get_terminal_selection", "create_directory",
            "create_session", "send_input", "get_output", "get_history", "close_session"
        ]
        
        guard let operationParam = tool.parameters["operation"] else {
            XCTFail("Tool must have operation parameter")
            return
        }
        
        for op in validOps {
            XCTAssertTrue(
                operationParam.enumValues?.contains(op) ?? false,
                "Operation '\(op)' should be valid for terminal_operations"
            )
        }
    }
    
    // MARK: - MemoryOperationsTool Unit Tests
    
    func testMemoryOperationsToolInit() {
        let tool = MemoryOperationsTool()
        XCTAssertEqual(tool.name, "memory_operations")
    }
    
    func testMemoryOperationsValidOperations() {
        let tool = MemoryOperationsTool()
        let validOps = ["search_memory", "store_memory", "list_collections", "manage_todos"]
        
        guard let operationParam = tool.parameters["operation"] else {
            XCTFail("Tool must have operation parameter")
            return
        }
        
        for op in validOps {
            XCTAssertTrue(
                operationParam.enumValues?.contains(op) ?? false,
                "Operation '\(op)' should be valid for memory_operations"
            )
        }
    }
    
    // MARK: - BuildVersionControlTool Unit Tests
    
    func testBuildVersionControlToolInit() {
        let tool = BuildVersionControlTool()
        XCTAssertEqual(tool.name, "build_and_version_control")
    }
    
    func testBuildVersionControlValidOperations() {
        let tool = BuildVersionControlTool()
        let validOps = [
            "create_and_run_task", "run_task", "get_task_output",
            "git_commit", "get_changed_files"
        ]
        
        guard let operationParam = tool.parameters["operation"] else {
            XCTFail("Tool must have operation parameter")
            return
        }
        
        for op in validOps {
            XCTAssertTrue(
                operationParam.enumValues?.contains(op) ?? false,
                "Operation '\(op)' should be valid for build_and_version_control"
            )
        }
    }
    
    // MARK: - ThinkTool Unit Tests
    
    func testThinkToolInit() {
        let tool = ThinkTool()
        XCTAssertEqual(tool.name, "think")
    }
    
    func testThinkToolHasThoughtsParameter() {
        let tool = ThinkTool()
        XCTAssertNotNil(tool.parameters["thoughts"], "ThinkTool should have 'thoughts' parameter")
    }
    
    // MARK: - MCPExecutionContext Tests
    
    func testMCPExecutionContextCreation() {
        let context = MCPExecutionContext(
            conversationId: UUID(),
            userId: "test-user",
            metadata: ["key": "value"],
            toolCallId: "call-123",
            isExternalAPICall: false,
            isUserInitiated: true,
            workingDirectory: "/tmp/test",
            terminalManager: nil,
            iterationController: nil,
            effectiveScopeId: nil
        )
        
        XCTAssertEqual(context.userId, "test-user")
        XCTAssertEqual(context.workingDirectory, "/tmp/test")
        XCTAssertTrue(context.isUserInitiated)
        XCTAssertFalse(context.isExternalAPICall)
    }
    
    // MARK: - MCPToolResult Tests
    
    func testMCPToolResultSuccess() {
        let result = MCPToolResult(
            toolName: "test_tool",
            success: true,
            output: MCPOutput(content: "Success message")
        )
        
        XCTAssertTrue(result.success)
        XCTAssertEqual(result.toolName, "test_tool")
        XCTAssertEqual(result.output.content, "Success message")
    }
    
    func testMCPToolResultFailure() {
        let result = MCPToolResult(
            toolName: "test_tool",
            success: false,
            output: MCPOutput(content: "Error: Something went wrong")
        )
        
        XCTAssertFalse(result.success)
        XCTAssertTrue(result.output.content.contains("Error"))
    }
    
    // MARK: - ToolResultStorage Unit Tests
    
    func testToolResultStorageThreshold() {
        XCTAssertEqual(ToolResultStorage.persistenceThreshold, 8_000)
        XCTAssertEqual(ToolResultStorage.maxInlineSize, 8192)
    }
    
    func testToolResultStorageProcessSmallResult() {
        let storage = ToolResultStorage()
        let smallContent = "Small content under threshold"
        
        let processed = storage.processToolResult(
            toolCallId: "test-123",
            content: smallContent,
            conversationId: UUID()
        )
        
        // Small content should be returned as-is
        XCTAssertEqual(processed, smallContent)
    }
    
    func testToolResultStorageProcessLargeResult() {
        let storage = ToolResultStorage()
        // Create content larger than maxInlineSize (8192)
        let largeContent = String(repeating: "x", count: 10_000)
        
        let processed = storage.processToolResult(
            toolCallId: "test-large-123",
            content: largeContent,
            conversationId: UUID()
        )
        
        // Large content should be chunked with marker
        XCTAssertTrue(processed.contains("TOOL_RESULT_PREVIEW") || processed.contains("TOOL_RESULT_STORED"))
    }
    
    // MARK: - MCPAuthorizationGuard Tests
    
    func testMCPAuthorizationGuardRelativePathResolution() {
        let workingDir = "/Users/test/project"
        let relativePath = "./src/file.swift"
        
        let resolved = MCPAuthorizationGuard.resolvePath(relativePath, workingDirectory: workingDir)
        
        XCTAssertTrue(resolved.hasPrefix("/Users/test/project"))
    }
    
    func testMCPAuthorizationGuardAbsolutePathPreserved() {
        let workingDir = "/Users/test/project"
        let absolutePath = "/tmp/other/file.txt"
        
        let resolved = MCPAuthorizationGuard.resolvePath(absolutePath, workingDirectory: workingDir)
        
        XCTAssertEqual(resolved, absolutePath)
    }
    
    // MARK: - ReadToolResultTool Unit Tests
    
    func testReadToolResultToolInit() {
        let tool = ReadToolResultTool()
        XCTAssertEqual(tool.name, "read_tool_result")
    }
    
    func testReadToolResultRequiredParameters() {
        let tool = ReadToolResultTool()
        
        XCTAssertNotNil(tool.parameters["toolCallId"], "Should have toolCallId parameter")
        XCTAssertNotNil(tool.parameters["offset"], "Should have offset parameter")
        XCTAssertNotNil(tool.parameters["length"], "Should have length parameter")
    }
    
    // MARK: - RunSubagentTool Unit Tests
    
    func testRunSubagentToolInit() {
        let tool = RunSubagentTool()
        XCTAssertEqual(tool.name, "run_subagent")
    }
    
    func testRunSubagentRequiredParameters() {
        let tool = RunSubagentTool()
        
        XCTAssertNotNil(tool.parameters["task"], "Should have task parameter")
    }
    
    // MARK: - UserCollaborationTool Unit Tests
    
    func testUserCollaborationToolInit() {
        let tool = UserCollaborationTool()
        XCTAssertEqual(tool.name, "user_collaboration")
    }
    
    func testUserCollaborationRequiredParameters() {
        let tool = UserCollaborationTool()
        
        XCTAssertNotNil(tool.parameters["prompt"], "Should have prompt parameter")
    }
    
    // MARK: - Parameter Validation Tests
    
    func testMCPToolParameterDefinition() {
        let param = MCPToolParameter(
            type: .string,
            description: "A test parameter",
            required: true,
            enumValues: nil
        )
        
        XCTAssertTrue(param.required)
        XCTAssertNil(param.enumValues)
    }
    
    func testMCPToolParameterWithEnum() {
        let param = MCPToolParameter(
            type: .string,
            description: "Operation to perform",
            required: true,
            enumValues: ["read", "write", "delete"]
        )
        
        XCTAssertEqual(param.enumValues?.count, 3)
        XCTAssertTrue(param.enumValues?.contains("read") ?? false)
    }
    
    func testMCPToolParameterOptional() {
        let param = MCPToolParameter(
            type: .integer,
            description: "Timeout in seconds",
            required: false,
            enumValues: nil
        )
        
        XCTAssertFalse(param.required)
    }
}

// MARK: - Additional Helper Tests

extension MCPFrameworkTests {
    
    func testAllToolsHaveDescriptions() {
        let tools: [any MCPTool] = [
            FileOperationsTool(),
            TerminalOperationsTool(),
            MemoryOperationsTool(),
            BuildVersionControlTool(),
            ThinkTool(),
            ReadToolResultTool(),
            RunSubagentTool(),
            UserCollaborationTool()
        ]
        
        for tool in tools {
            XCTAssertFalse(tool.description.isEmpty, "\(tool.name) should have a description")
            XCTAssertTrue(tool.description.count > 10, "\(tool.name) description should be meaningful")
        }
    }
    
    func testToolParameterTypes() {
        let tool = FileOperationsTool()
        
        // Check parameter types are correctly defined
        if let filePathParam = tool.parameters["filePath"] {
            // Verify it's a string type by checking description
            XCTAssertEqual(filePathParam.type.description, "string")
        }
        
        if let contentParam = tool.parameters["content"] {
            // Verify it's a string type by checking description
            XCTAssertEqual(contentParam.type.description, "string")
        }
    }
}
