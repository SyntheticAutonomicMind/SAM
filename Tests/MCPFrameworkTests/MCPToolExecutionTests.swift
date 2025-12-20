// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import XCTest
@testable import MCPFramework
@testable import ConfigurationSystem
@testable import APIFramework
import Foundation

/// Integration tests for MCP tool execution
/// These tests verify tool execution flow and parameter handling
final class MCPToolExecutionTests: XCTestCase {
    
    var testDirectory: URL!
    var cleanupFiles: [URL] = []
    
    override func setUp() {
        super.setUp()
        testDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MCPExecTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: testDirectory, withIntermediateDirectories: true)
    }
    
    override func tearDown() {
        for file in cleanupFiles {
            try? FileManager.default.removeItem(at: file)
        }
        try? FileManager.default.removeItem(at: testDirectory)
        super.tearDown()
    }
    
    // MARK: - Parameter Extraction Tests
    
    func testExtractStringParameter() {
        let params: [String: Any] = [
            "operation": "read_file",
            "filePath": "/path/to/file.txt"
        ]
        
        let operation = params["operation"] as? String
        let filePath = params["filePath"] as? String
        
        XCTAssertEqual(operation, "read_file")
        XCTAssertEqual(filePath, "/path/to/file.txt")
    }
    
    func testExtractIntegerParameter() {
        let params: [String: Any] = [
            "offset": 100,
            "limit": 50
        ]
        
        let offset = params["offset"] as? Int
        let limit = params["limit"] as? Int
        
        XCTAssertEqual(offset, 100)
        XCTAssertEqual(limit, 50)
    }
    
    func testExtractBooleanParameter() {
        let params: [String: Any] = [
            "isRegexp": true,
            "recursive": false
        ]
        
        let isRegexp = params["isRegexp"] as? Bool
        let recursive = params["recursive"] as? Bool
        
        XCTAssertTrue(isRegexp ?? false)
        XCTAssertFalse(recursive ?? true)
    }
    
    func testExtractArrayParameter() {
        let params: [String: Any] = [
            "files": ["file1.txt", "file2.txt", "file3.txt"],
            "excludePatterns": ["*.log", "*.tmp"]
        ]
        
        let files = params["files"] as? [String]
        let excludes = params["excludePatterns"] as? [String]
        
        XCTAssertEqual(files?.count, 3)
        XCTAssertEqual(excludes?.count, 2)
        XCTAssertTrue(files?.contains("file2.txt") ?? false)
    }
    
    func testExtractNestedParameters() {
        let params: [String: Any] = [
            "task": [
                "label": "build",
                "type": "shell",
                "command": "make build"
            ] as [String: Any]
        ]
        
        let task = params["task"] as? [String: Any]
        let label = task?["label"] as? String
        let command = task?["command"] as? String
        
        XCTAssertEqual(label, "build")
        XCTAssertEqual(command, "make build")
    }
    
    // MARK: - Operation Validation Tests
    
    func testFileOperationsValidation() {
        let tool = FileOperationsTool()
        let validOperations = tool.parameters["operation"]?.enumValues ?? []
        
        // Test all documented operations exist
        let expectedOps = [
            "read_file", "create_file", "replace_string", "multi_replace_string",
            "insert_edit", "apply_patch", "rename_file", "delete_file",
            "list_dir", "file_search", "grep_search"
        ]
        
        for op in expectedOps {
            XCTAssertTrue(validOperations.contains(op), "Missing operation: \(op)")
        }
    }
    
    func testTerminalOperationsValidation() {
        let tool = TerminalOperationsTool()
        let validOperations = tool.parameters["operation"]?.enumValues ?? []
        
        let expectedOps = [
            "run_command", "create_directory", "create_session"
        ]
        
        for op in expectedOps {
            XCTAssertTrue(validOperations.contains(op), "Missing operation: \(op)")
        }
    }
    
    func testMemoryOperationsValidation() {
        let tool = MemoryOperationsTool()
        let validOperations = tool.parameters["operation"]?.enumValues ?? []
        
        let expectedOps = ["search_memory", "store_memory", "list_collections", "manage_todos"]
        
        for op in expectedOps {
            XCTAssertTrue(validOperations.contains(op), "Missing operation: \(op)")
        }
    }
    
    // MARK: - Error Handling Tests
    
    func testMissingRequiredParameter() {
        // Simulate missing required parameter scenario
        let params: [String: Any] = [
            "operation": "read_file"
            // Missing: "filePath"
        ]
        
        let filePath = params["filePath"] as? String
        XCTAssertNil(filePath, "FilePath should be nil when not provided")
    }
    
    func testInvalidOperationType() {
        let tool = FileOperationsTool()
        let validOperations = tool.parameters["operation"]?.enumValues ?? []
        
        XCTAssertFalse(validOperations.contains("invalid_operation"))
    }
    
    // MARK: - MCPOutput Tests
    
    func testMCPOutputCreation() {
        let output = MCPOutput(content: "Test output")
        XCTAssertEqual(output.content, "Test output")
    }
    
    func testMCPOutputWithAdditionalData() {
        let output = MCPOutput(
            content: "Result",
            additionalData: ["key": "value"]
        )
        XCTAssertEqual(output.content, "Result")
        XCTAssertEqual(output.additionalData["key"] as? String, "value")
    }
    
    // MARK: - MCPToolResult Tests
    
    func testSuccessfulToolResult() {
        let result = MCPToolResult(
            toolName: "file_operations",
            success: true,
            output: MCPOutput(content: "File created successfully")
        )
        
        XCTAssertTrue(result.success)
        XCTAssertEqual(result.toolName, "file_operations")
        XCTAssertFalse(result.output.content.isEmpty)
    }
    
    func testFailedToolResult() {
        let result = MCPToolResult(
            toolName: "file_operations",
            success: false,
            output: MCPOutput(content: "Error: File not found")
        )
        
        XCTAssertFalse(result.success)
        XCTAssertTrue(result.output.content.contains("Error"))
    }
    
    // MARK: - Context Tests
    
    func testContextWorkingDirectory() {
        let context = MCPExecutionContext(
            conversationId: UUID(),
            userId: "test",
            metadata: [:],
            toolCallId: "call-1",
            isExternalAPICall: false,
            isUserInitiated: true,
            workingDirectory: "/Users/test/project",
            terminalManager: nil,
            iterationController: nil,
            effectiveScopeId: nil
        )
        
        XCTAssertEqual(context.workingDirectory, "/Users/test/project")
    }
    
    func testContextUserInitiated() {
        let userContext = MCPExecutionContext(
            conversationId: UUID(),
            userId: "user",
            metadata: [:],
            toolCallId: "call-1",
            isExternalAPICall: false,
            isUserInitiated: true,
            workingDirectory: nil,
            terminalManager: nil,
            iterationController: nil,
            effectiveScopeId: nil
        )
        
        let agentContext = MCPExecutionContext(
            conversationId: UUID(),
            userId: "agent",
            metadata: [:],
            toolCallId: "call-2",
            isExternalAPICall: false,
            isUserInitiated: false,
            workingDirectory: nil,
            terminalManager: nil,
            iterationController: nil,
            effectiveScopeId: nil
        )
        
        XCTAssertTrue(userContext.isUserInitiated)
        XCTAssertFalse(agentContext.isUserInitiated)
    }
    
    // MARK: - Path Resolution Tests
    
    func testAbsolutePathPreserved() {
        let absolutePath = "/Users/test/file.txt"
        let workingDir = "/Users/other/dir"
        
        let resolved = MCPAuthorizationGuard.resolvePath(absolutePath, workingDirectory: workingDir)
        XCTAssertEqual(resolved, absolutePath)
    }
    
    func testRelativePathResolved() {
        let relativePath = "./subdir/file.txt"
        let workingDir = "/Users/test/project"
        
        let resolved = MCPAuthorizationGuard.resolvePath(relativePath, workingDirectory: workingDir)
        XCTAssertEqual(resolved, "/Users/test/project/subdir/file.txt")
    }
    
    func testDotDotPathResolved() {
        let relativePath = "../other/file.txt"
        let workingDir = "/Users/test/project/subdir"
        
        let resolved = MCPAuthorizationGuard.resolvePath(relativePath, workingDirectory: workingDir)
        // Should resolve the .. component
        XCTAssertFalse(resolved.contains(".."))
    }
    
    func testTildePathExpanded() {
        let tildePath = "~/Documents/file.txt"
        let workingDir = "/Users/test"
        
        let resolved = MCPAuthorizationGuard.resolvePath(tildePath, workingDirectory: workingDir)
        // Should expand ~ to actual home directory
        XCTAssertFalse(resolved.contains("~"))
    }
    
    // MARK: - Tool Registry Tests
    
    func testAllToolsHaveUniqueNames() {
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
        
        var names = Set<String>()
        for tool in tools {
            XCTAssertFalse(names.contains(tool.name), "Duplicate tool name: \(tool.name)")
            names.insert(tool.name)
        }
    }
    
    func testToolParameterConsistency() {
        let operationTools: [any MCPTool] = [
            FileOperationsTool(),
            TerminalOperationsTool(),
            MemoryOperationsTool(),
            BuildVersionControlTool()
        ]
        
        for tool in operationTools {
            // All operation-based tools should have an "operation" parameter
            XCTAssertNotNil(tool.parameters["operation"], "\(tool.name) should have operation parameter")
            
            // Operation parameter should be required
            let opParam = tool.parameters["operation"]
            XCTAssertTrue(opParam?.required ?? false, "\(tool.name) operation should be required")
            
            // Operation should have enum values
            XCTAssertNotNil(opParam?.enumValues, "\(tool.name) operation should have enum values")
            XCTAssertTrue((opParam?.enumValues?.count ?? 0) > 0, "\(tool.name) should have at least one operation")
        }
    }
}

// MARK: - JSON Serialization Tests

extension MCPToolExecutionTests {
    
    func testParametersJsonSerialization() {
        let params: [String: Any] = [
            "operation": "create_file",
            "filePath": "/path/to/file.txt",
            "content": "Hello, World!"
        ]
        
        let data = try? JSONSerialization.data(withJSONObject: params)
        XCTAssertNotNil(data)
        
        if let data = data {
            let decoded = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            XCTAssertEqual(decoded?["operation"] as? String, "create_file")
            XCTAssertEqual(decoded?["filePath"] as? String, "/path/to/file.txt")
        }
    }
    
    func testComplexParametersSerialization() {
        let params: [String: Any] = [
            "operation": "multi_replace_string",
            "replacements": [
                ["filePath": "/file1.txt", "oldString": "old1", "newString": "new1"],
                ["filePath": "/file2.txt", "oldString": "old2", "newString": "new2"]
            ]
        ]
        
        let data = try? JSONSerialization.data(withJSONObject: params)
        XCTAssertNotNil(data)
        
        if let data = data {
            let decoded = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            let replacements = decoded?["replacements"] as? [[String: String]]
            XCTAssertEqual(replacements?.count, 2)
        }
    }
}
