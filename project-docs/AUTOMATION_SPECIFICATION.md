<!-- SPDX-License-Identifier: CC-BY-NC-4.0 -->
<!-- SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius) -->


# SAM Automation and Local Code Execution Specification

## Overview

This specification defines automation and local code execution capabilities for SAM, enabling users to perform complex tasks, execute code safely, and automate workflows through natural conversation. The system provides secure execution environments while maintaining user safety and system integrity.

**Priority Level**: Lowest priority - implement after UI enhancements, document import, and web research capabilities are complete.

## Design Philosophy

### User Experience Principles
- **Conversational Automation**: All automation accessible through natural language requests
- **Safety First**: Multiple layers of security prevent harmful operations
- **Transparent Execution**: Users see what actions SAM is performing
- **Learning Capabilities**: System learns from successful automation patterns

### Security Principles
- **Sandboxed Execution**: All code execution in controlled environments
- **Permission-Based Access**: Explicit user consent for system operations
- **Audit Trail**: Complete logging of all automated actions
- **Fail-Safe Design**: System defaults to safe operation modes

## Reference Implementation Analysis

### SAM 1.0 Automation Patterns
**Location**: `reference/SAM-1.0/Sources/SyntheticAutonomicMind/Automation/`

**Key Components**:
```swift
// SAM 1.0 automation architecture
class TaskAutomator {
    func executeTask(_ task: AutomationTask) async throws -> TaskResult
    func createWorkflow(_ steps: [WorkflowStep]) async throws -> Workflow
    func scheduleRecurringTask(_ task: AutomationTask, schedule: Schedule) async throws
}

class SecureExecutor {
    func executeCode(_ code: String, language: CodeLanguage, sandbox: SandboxConfig) async throws -> ExecutionResult
    func validateCodeSafety(_ code: String) async throws -> SafetyAssessment
    func createSandboxEnvironment(_ config: SandboxConfig) async throws -> SandboxEnvironment
}
```

**SAM 1.0 Automation Capabilities**:
- File system operations with user permission
- Script execution in sandboxed environments
- API integration and data processing
- System task automation (with limitations)
- Workflow creation and management

### Security Framework Requirements
- App Store compliance for sandboxed execution
- User permission requests for privileged operations
- Code analysis and safety validation
- Resource usage monitoring and limits
- Comprehensive audit logging

## Automation Architecture

### Core Components

#### AutomationService
**Purpose**: Central service coordinating all automation and execution operations
**Security**: Implements multi-layer security validation and sandboxing

```swift
/**
 Central automation service providing secure task execution and workflow management.
 
 This service coordinates the complete automation pipeline:
 - Safe code execution in sandboxed environments
 - Workflow creation and management
 - System task automation with user permission
 - Integration with external APIs and services
 */
@MainActor
public class AutomationService: ObservableObject {
    private let securityFramework: AutomationSecurityFramework
    private let executionEngine: CodeExecutionEngine
    private let workflowManager: WorkflowManager
    private let logger = Logger(label: "com.sam.automation")
    
    @Published public var isExecuting: Bool = false
    @Published public var executionProgress: Double = 0.0
    @Published public var currentOperation: String = ""
    @Published public var activeWorkflows: [Workflow] = []
    
    public init(securityFramework: AutomationSecurityFramework) {
        self.securityFramework = securityFramework
        self.executionEngine = CodeExecutionEngine(securityFramework: securityFramework)
        self.workflowManager = WorkflowManager()
    }
}
```

#### Secure Code Execution Engine
**Purpose**: Execute code safely in controlled environments

```swift
/**
 Secure code execution engine with comprehensive safety measures.
 */
class CodeExecutionEngine {
    private let securityFramework: AutomationSecurityFramework
    private let sandboxManager: SandboxManager
    private let logger = Logger(label: "com.sam.execution")
    
    /**
     Execute code in a secure sandboxed environment.
     */
    func executeCode(
        _ code: String,
        language: SupportedLanguage,
        context: ExecutionContext
    ) async throws -> ExecutionResult {
        
        // Step 1: Security validation
        let safetyAssessment = try await validateCodeSafety(code, language: language)
        guard safetyAssessment.isSafe else {
            throw AutomationError.unsafeCode(safetyAssessment.risks)
        }
        
        // Step 2: User permission check
        let permissions = try await securityFramework.getRequiredPermissions(for: code, language: language)
        guard try await requestUserPermission(for: permissions) else {
            throw AutomationError.permissionDenied(permissions)
        }
        
        // Step 3: Sandbox creation
        let sandbox = try await sandboxManager.createSandbox(
            language: language,
            permissions: permissions,
            resourceLimits: context.resourceLimits
        )
        
        // Step 4: Code execution
        logger.info("Executing \(language.rawValue) code in sandbox")
        let result = try await sandbox.execute(code)
        
        // Step 5: Result validation and cleanup
        try await sandbox.cleanup()
        
        return ExecutionResult(
            output: result.output,
            errors: result.errors,
            executionTime: result.executionTime,
            resourceUsage: result.resourceUsage,
            exitCode: result.exitCode
        )
    }
    
    private func validateCodeSafety(_ code: String, language: SupportedLanguage) async throws -> SafetyAssessment {
        let validator = CodeSafetyValidator(language: language)
        
        // Static analysis for dangerous patterns
        let staticRisks = validator.analyzeStaticRisks(code)
        
        // Dynamic analysis simulation
        let dynamicRisks = try await validator.simulateExecution(code)
        
        // Combined risk assessment
        let overallRisk = RiskCalculator.calculateOverallRisk(
            staticRisks: staticRisks,
            dynamicRisks: dynamicRisks
        )
        
        return SafetyAssessment(
            isSafe: overallRisk <= .moderate,
            overallRisk: overallRisk,
            risks: staticRisks + dynamicRisks,
            recommendations: generateSafetyRecommendations(overallRisk)
        )
    }
}
```

### Supported Languages and Environments

#### Python Execution Environment
```swift
class PythonSandbox: CodeSandbox {
    let language: SupportedLanguage = .python
    
    func execute(_ code: String) async throws -> SandboxExecutionResult {
        // Create isolated Python environment
        let pythonPath = createIsolatedPythonEnvironment()
        
        // Install allowed packages only
        try await installAllowedPackages(["numpy", "pandas", "requests", "json"])
        
        // Execute with resource limits
        let process = createSandboxedProcess(
            executable: pythonPath,
            arguments: ["-c", code],
            resourceLimits: ResourceLimits(
                maxMemory: 512 * 1024 * 1024, // 512MB
                maxCPUTime: 30, // 30 seconds
                maxFileSize: 10 * 1024 * 1024 // 10MB
            )
        )
        
        return try await process.run()
    }
}
```

#### Shell Script Execution  
```swift
class ShellSandbox: CodeSandbox {
    let language: SupportedLanguage = .shell
    
    func execute(_ code: String) async throws -> SandboxExecutionResult {
        // Analyze shell commands for safety
        let commands = ShellParser.parseCommands(code)
        try validateShellCommands(commands)
        
        // Execute in restricted shell environment
        let restrictedShell = createRestrictedShell(
            allowedCommands: ["ls", "cat", "echo", "grep", "sort", "wc"],
            blockedPaths: ["/System", "/usr/bin", "/sbin"],
            workingDirectory: createTempWorkspace()
        )
        
        return try await restrictedShell.execute(code)
    }
    
    private func validateShellCommands(_ commands: [ShellCommand]) throws {
        for command in commands {
            // Block dangerous commands
            let dangerousCommands = ["rm", "sudo", "su", "chmod", "dd", "format"]
            if dangerousCommands.contains(command.name) {
                throw AutomationError.dangerousCommand(command.name)
            }
            
            // Validate file paths
            for path in command.paths {
                guard isPathSafe(path) else {
                    throw AutomationError.unsafePath(path)
                }
            }
        }
    }
}
```

#### JavaScript/Node.js Environment
```swift
class JavaScriptSandbox: CodeSandbox {
    let language: SupportedLanguage = .javascript
    
    func execute(_ code: String) async throws -> SandboxExecutionResult {
        // Create isolated Node.js environment
        let nodeEnvironment = createIsolatedNodeEnvironment()
        
        // Wrap code with security constraints
        let wrappedCode = """
            (function() {
                // Disable dangerous globals
                delete global.process;
                delete global.require;
                delete global.Buffer;
                
                // Provide safe alternatives
                const console = {
                    log: (...args) => print(args.join(' ')),
                    error: (...args) => print('ERROR: ' + args.join(' '))
                };
                
                // Execute user code
                \(code)
            })();
        """
        
        return try await nodeEnvironment.execute(wrappedCode)
    }
}
```

### Workflow Management

#### Workflow Creation and Execution
```swift
/**
 Workflow management system for multi-step automation tasks.
 */
class WorkflowManager {
    private var workflows: [UUID: Workflow] = [:]
    private let logger = Logger(label: "com.sam.workflow")
    
    /**
     Create a workflow from natural language description.
     */
    func createWorkflow(from description: String) async throws -> Workflow {
        // Parse workflow description into steps
        let parser = WorkflowParser()
        let steps = try await parser.parseSteps(from: description)
        
        // Validate workflow safety
        let validator = WorkflowValidator()
        try await validator.validateWorkflow(steps)
        
        // Create workflow object
        let workflow = Workflow(
            id: UUID(),
            name: generateWorkflowName(from: description),
            steps: steps,
            createdAt: Date(),
            status: .created
        )
        
        workflows[workflow.id] = workflow
        return workflow
    }
    
    /**
     Execute a workflow with user supervision.
     */
    func executeWorkflow(_ workflow: Workflow, supervised: Bool = true) async throws -> WorkflowResult {
        logger.info("Executing workflow: \(workflow.name)")
        workflow.status = .running
        
        var stepResults: [StepResult] = []
        
        for (index, step) in workflow.steps.enumerated() {
            if supervised {
                // Request user approval for each step
                let approval = try await requestStepApproval(step, workflowName: workflow.name)
                guard approval else {
                    workflow.status = .cancelled
                    throw AutomationError.workflowCancelled
                }
            }
            
            // Execute step
            let stepResult = try await executeWorkflowStep(step)
            stepResults.append(stepResult)
            
            // Check for errors
            if !stepResult.success {
                workflow.status = .failed
                throw AutomationError.stepFailed(step.name, stepResult.error)
            }
        }
        
        workflow.status = .completed
        
        return WorkflowResult(
            workflow: workflow,
            stepResults: stepResults,
            overallSuccess: true,
            completedAt: Date()
        )
    }
}
```

### File System Operations

#### Safe File System Access
```swift
/**
 Secure file system operations with user permission and sandboxing.
 */
class FileSystemAutomator {
    private let securityFramework: AutomationSecurityFramework
    
    /**
     Perform file operations with comprehensive safety checks.
     */
    func performFileOperation(_ operation: FileOperation) async throws -> FileOperationResult {
        // Validate operation safety
        try validateFileOperation(operation)
        
        // Request user permission
        let permission = try await requestFilePermission(operation)
        guard permission else {
            throw AutomationError.filePermissionDenied(operation)
        }
        
        // Execute operation in sandbox
        let sandbox = try await createFileOperationSandbox()
        return try await sandbox.executeFileOperation(operation)
    }
    
    private func validateFileOperation(_ operation: FileOperation) throws {
        // Check path safety
        for path in operation.paths {
            guard isPathSafe(path) else {
                throw AutomationError.unsafePath(path)
            }
            
            // Prevent access to system directories
            let systemPaths = ["/System", "/usr", "/bin", "/sbin", "/private"]
            for systemPath in systemPaths {
                if path.hasPrefix(systemPath) {
                    throw AutomationError.systemPathAccess(path)
                }
            }
        }
        
        // Validate operation type
        switch operation.type {
        case .delete:
            // Extra confirmation for delete operations
            try validateDeleteOperation(operation)
        case .modify:
            // Ensure backup for modify operations
            try ensureBackupCapability(operation)
        case .create, .read:
            // Generally safe operations
            break
        }
    }
}
```

### API Integration and External Services

#### Secure API Integration
```swift
/**
 Secure API integration service for external service automation.
 */
class APIIntegrationService {
    private let credentialManager: CredentialManager
    
    /**
     Make API requests with proper authentication and rate limiting.
     */
    func makeAPIRequest(
        endpoint: String,
        method: HTTPMethod,
        parameters: [String: Any]
    ) async throws -> APIResponse {
        
        // Validate endpoint safety
        try validateEndpoint(endpoint)
        
        // Get user credentials securely
        let credentials = try await credentialManager.getCredentials(for: endpoint)
        
        // Create secure request
        var request = URLRequest(url: URL(string: endpoint)!)
        request.httpMethod = method.rawValue
        request.setValue("SAM-Automation/1.0", forHTTPHeaderField: "User-Agent")
        
        // Add authentication
        if let credentials = credentials {
            request.setValue("Bearer \(credentials.token)", forHTTPHeaderField: "Authorization")
        }
        
        // Rate limiting
        try await applyRateLimit(for: endpoint)
        
        // Execute request
        let (data, response) = try await URLSession.shared.data(for: request)
        
        return APIResponse(
            data: data,
            response: response,
            endpoint: endpoint
        )
    }
}
```

### Conversational Integration

#### Natural Language Automation Interface
**User Interaction Patterns**:
```
User: "Write a Python script to analyze this CSV file"
SAM: "I'll create a Python script for CSV analysis. The script will run in a secure sandbox with limited file access. May I proceed?"
[Creates and executes safe Python code for data analysis]

User: "Automate organizing my Downloads folder"
SAM: "I can help organize your Downloads folder. This will involve reading file names and creating folders. I'll show you each step before executing. Shall I start?"
[Creates workflow with user approval for each step]

User: "Set up a workflow to backup my documents daily"
SAM: "I'll create a backup workflow for your documents. This involves file system access and scheduling. Let me break down the steps..."
[Creates supervised workflow with scheduling]
```

#### MCP Tool Integration
```swift
// Automation tools for conversational access
class CodeExecutionTool: MCPTool {
    let name = "execute_code"
    let description = "Execute code safely in a sandboxed environment"
    
    func execute(parameters: [String: Any]) async throws -> MCPToolResult {
        guard let code = parameters["code"] as? String,
              let languageStr = parameters["language"] as? String,
              let language = SupportedLanguage(rawValue: languageStr) else {
            throw MCPError.missingParameter("code or language")
        }
        
        let automationService = AutomationService.shared
        let context = ExecutionContext(
            supervised: parameters["supervised"] as? Bool ?? true,
            resourceLimits: ResourceLimits.standard
        )
        
        let result = try await automationService.executeCode(
            code,
            language: language,
            context: context
        )
        
        return MCPToolResult.success(data: result.toJSON())
    }
}

class WorkflowTool: MCPTool {
    let name = "create_workflow"
    let description = "Create and execute automation workflows"
    
    func execute(parameters: [String: Any]) async throws -> MCPToolResult {
        guard let description = parameters["description"] as? String else {
            throw MCPError.missingParameter("description")
        }
        
        let workflowManager = WorkflowManager.shared
        let workflow = try await workflowManager.createWorkflow(from: description)
        
        let supervised = parameters["supervised"] as? Bool ?? true
        let result = try await workflowManager.executeWorkflow(workflow, supervised: supervised)
        
        return MCPToolResult.success(data: result.toJSON())
    }
}
```

## Security Framework

### Multi-Layer Security Model
```swift
/**
 Comprehensive security framework for automation operations.
 */
class AutomationSecurityFramework {
    private let permissionManager: PermissionManager
    private let auditLogger: AuditLogger
    
    /**
     Validate and authorize automation operations.
     */
    func authorizeOperation(_ operation: AutomationOperation) async throws -> AuthorizationResult {
        // Layer 1: Static analysis
        let staticAnalysis = try await performStaticAnalysis(operation)
        guard staticAnalysis.isAuthorized else {
            throw SecurityError.staticAnalysisFailure(staticAnalysis.issues)
        }
        
        // Layer 2: Permission validation
        let requiredPermissions = operation.requiredPermissions
        for permission in requiredPermissions {
            guard try await permissionManager.hasPermission(permission) else {
                let granted = try await permissionManager.requestPermission(permission)
                if !granted {
                    throw SecurityError.permissionDenied(permission)
                }
            }
        }
        
        // Layer 3: Resource limits validation
        try validateResourceLimits(operation)
        
        // Layer 4: Audit logging
        auditLogger.logOperation(operation, authorized: true)
        
        return AuthorizationResult(authorized: true, restrictions: staticAnalysis.restrictions)
    }
}
```

### Audit Trail and Logging
```swift
class AutomationAuditLogger {
    /**
     Comprehensive logging of all automation activities.
     */
    func logExecution(_ execution: CodeExecution) {
        let auditEntry = AuditEntry(
            timestamp: Date(),
            operation: .codeExecution,
            language: execution.language,
            codeHash: execution.codeHash, // For security, store hash not content
            result: execution.result,
            resourceUsage: execution.resourceUsage,
            user: getCurrentUser()
        )
        
        // Store in secure audit log
        storeAuditEntry(auditEntry)
        
        // Real-time monitoring
        if execution.result.hasSecurityImplications {
            notifySecurityMonitor(auditEntry)
        }
    }
}
```

## Implementation Phases

### Phase 1: Foundation (Basic Code Execution)
1. **Security Framework**: Core security validation and sandboxing
2. **Python Sandbox**: Safe Python code execution environment
3. **Basic UI**: Code execution interface with approval prompts
4. **Audit System**: Comprehensive logging and monitoring
5. **MCP Integration**: Code execution accessible through conversation

### Phase 2: Enhanced Execution (Multi-Language)  
1. **Shell Script Support**: Safe shell command execution
2. **JavaScript Environment**: Node.js sandbox for web automation
3. **File System Operations**: Secure file management with user approval
4. **Workflow Engine**: Multi-step automation with supervision
5. **Error Recovery**: Comprehensive error handling and recovery

### Phase 3: Advanced Automation (Workflows)
1. **Workflow Builder**: Visual and conversational workflow creation
2. **API Integration**: Secure external service automation
3. **Scheduling System**: Time-based and event-triggered automation
4. **Advanced Security**: Behavioral analysis and threat detection
5. **Performance Optimization**: Resource usage optimization and caching

### Phase 4: Intelligence & Production (Complete System)
1. **AI-Powered Automation**: LLM-driven task planning and execution
2. **Learning System**: Learn from successful automation patterns
3. **Enterprise Features**: Advanced security and compliance features
4. **Performance Analytics**: Comprehensive automation metrics
5. **Documentation System**: User guides and best practices

## Success Criteria

### Security Requirements
- Complete sandboxing of all code execution
- User permission required for all privileged operations
- Comprehensive audit logging of all automation activities
- App Store compliance for distribution
- No unauthorized system access or privilege escalation

### Functionality Requirements  
- Safe execution of Python, shell scripts, and JavaScript
- File system operations with user supervision
- Multi-step workflow creation and execution
- API integration for external service automation
- Conversational access to all automation capabilities

### User Experience Requirements
- **Transparency**: Users understand what automation will do before execution
- **Control**: Users can approve, deny, or modify automation steps
- **Safety**: System prevents harmful operations through multiple safeguards
- **Learning**: System improves automation suggestions based on user patterns

## Risk Mitigation

### Technical Risks
- **Sandbox Escape**: Multiple containment layers and regular security audits
- **Resource Exhaustion**: Strict resource limits and monitoring
- **Data Loss**: Automatic backups and confirmation for destructive operations
- **System Compromise**: Principle of least privilege and permission validation

### User Experience Risks
- **Complexity**: Hide technical details behind conversational interface
- **Trust**: Transparent operation with clear explanations
- **Reliability**: Comprehensive testing and error recovery
- **Performance**: Efficient execution without blocking user interface

This comprehensive automation specification provides SAM with powerful but safe automation capabilities, enabling users to perform complex tasks through natural conversation while maintaining security and system integrity as the highest priorities.