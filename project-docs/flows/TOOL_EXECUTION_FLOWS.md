<!-- SPDX-License-Identifier: CC-BY-NC-4.0 -->
<!-- SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius) -->


# MCP Tool Execution Flow Diagrams

**Version:** 1.0  
**Last Updated:** December 1, 2025  
**Related:** `project-docs/2025-12-01/0800/MCP_FRAMEWORK.md`

## Overview

This document provides Mermaid diagrams visualizing the execution flows within SAM's MCPFramework subsystem.

---

## 1. Tool Registration Flow

Shows how tools are initialized and registered with the MCPManager.

```mermaid
sequenceDiagram
    participant App as SAMApp
    participant MCPMgr as MCPManager
    participant Registry as MCPToolRegistry
    participant Tools as Tool Instances
    participant MemMgr as MemoryManager
    participant WS as WorkflowSpawner
    
    App->>MCPMgr: initialize()
    
    Note over MCPMgr: Dependency Injection Phase
    App->>MCPMgr: setMemoryManager(memoryManager)
    MCPMgr->>MCPMgr: Store memory manager reference
    
    App->>MCPMgr: setWorkflowSpawner(spawner)
    MCPMgr->>MCPMgr: Store workflow spawner reference
    
    App->>MCPMgr: setAdvancedToolsFactory(factory)
    MCPMgr->>MCPMgr: Store factory closure
    
    Note over MCPMgr: Tool Initialization Phase
    MCPMgr->>MCPMgr: initializeBuiltinTools()
    
    MCPMgr->>Tools: Create ThinkTool()
    Tools-->>MCPMgr: ThinkTool instance
    
    MCPMgr->>Tools: Create UserCollaborationTool()
    Tools-->>MCPMgr: UserCollaborationTool instance
    
    MCPMgr->>Tools: Create MemoryOperationsTool()
    Tools-->>MCPMgr: MemoryOperationsTool instance
    
    MCPMgr->>Tools: setMemoryManager(memoryManager)
    Note over Tools: Inject dependencies into tools
    
    MCPMgr->>Tools: Create RunSubagentTool()
    Tools-->>MCPMgr: RunSubagentTool instance
    
    MCPMgr->>Tools: setWorkflowSpawner(spawner)
    Note over Tools: Inject workflow spawner
    
    MCPMgr->>MCPMgr: createAdvancedTools() via factory
    Note over MCPMgr: FileOperationsTool, TerminalOperationsTool, etc.
    
    loop For each tool
        MCPMgr->>Tools: tool.initialize()
        Tools-->>MCPMgr: Success/Failure
        
        alt Initialization succeeds
            MCPMgr->>MCPMgr: Add to builtinTools array
        else Initialization fails
            MCPMgr->>MCPMgr: Log error, continue with other tools
        end
    end
    
    Note over MCPMgr: Registration Phase
    MCPMgr->>MCPMgr: registerAllTools()
    
    loop For each builtin tool
        MCPMgr->>Registry: registerTool(tool, name: tool.name)
        Registry->>Registry: Store in toolOrder map
        MCPMgr->>MCPMgr: Add to availableTools @Published
    end
    
    MCPMgr->>Registry: getToolsInOrder()
    Note over Registry: Returns tools in explicit order<br/>for KV cache efficiency
    Registry-->>MCPMgr: Ordered tool array
    
    MCPMgr->>MCPMgr: isInitialized = true
    
    MCPMgr-->>App: Initialization complete
    Note over App: availableTools published to UI
```

**Key Points:**
- Dependency injection happens BEFORE tool initialization
- Tools initialize asynchronously (may fail individually)
- Registration uses explicit ordering for KV cache optimization
- Published availableTools array triggers UI updates

---

## 2. Tool Execution Flow with Authorization

Shows complete flow from agent request to tool execution, including authorization checks.

```mermaid
sequenceDiagram
    participant Agent as AgentOrchestrator
    participant MCPMgr as MCPManager
    participant Registry as MCPToolRegistry
    participant AuthGuard as MCPAuthorizationGuard
    participant AuthMgr as AuthorizationManager
    participant Tool as Tool Implementation
    participant Internal as Internal Tool
    
    Agent->>MCPMgr: executeTool(name, params, context)
    
    Note over MCPMgr: Handle dotted tool names
    MCPMgr->>MCPMgr: Parse "file_operations.read_file"
    MCPMgr->>MCPMgr: Extract tool="file_operations"<br/>operation="read_file"
    
    MCPMgr->>Registry: getTool("file_operations")
    Registry-->>MCPMgr: FileOperationsTool instance
    
    alt Tool not found
        Registry-->>MCPMgr: nil
        MCPMgr-->>Agent: MCPError.toolNotFound
    end
    
    MCPMgr->>Tool: validateParameters(params)
    
    alt Validation fails
        Tool-->>MCPMgr: MCPError.invalidParameters
        MCPMgr-->>Agent: MCPToolResult(success=false)
    end
    
    Note over Tool: Authorization Check (for write operations)
    
    alt Read operation
        Tool->>Tool: No authorization needed
        Tool->>Tool: Skip to execution
    end
    
    alt Write operation
        Tool->>AuthGuard: checkPathAuthorization(path, workingDir, conversationId, operation, isUserInitiated)
        
        alt User-initiated operation
            AuthGuard-->>Tool: .allowed("User-initiated operation")
        end
        
        alt Path inside working directory
            AuthGuard->>AuthGuard: Resolve path against workingDir
            AuthGuard->>AuthGuard: Check: normalizedPath.hasPrefix(workingDirPath + "/")
            AuthGuard-->>Tool: .allowed("Path is inside working directory")
        end
        
        alt Path outside working directory
            AuthGuard->>AuthMgr: isAuthorized(conversationId, operation)
            
            alt Previously authorized
                AuthMgr->>AuthMgr: Check grant exists and not expired
                AuthMgr->>AuthMgr: Consume grant if one-time use
                AuthMgr-->>AuthGuard: true
                AuthGuard-->>Tool: .allowed("User previously authorized")
            end
            
            alt Not authorized
                AuthMgr-->>AuthGuard: false
                AuthGuard-->>Tool: .requiresAuthorization(reason)
                
                Tool->>Tool: Generate authorization error
                Tool-->>MCPMgr: MCPToolResult(success=false, output=authError)
                MCPMgr-->>Agent: Error with suggested user_collaboration prompt
            end
        end
    end
    
    Note over Tool: Execute Tool (authorized)
    Tool->>Tool: execute(params, context)
    
    alt ConsolidatedMCP
        Tool->>Tool: routeOperation(operation, params, context)
        Tool->>Internal: Create internal tool instance
        Tool->>Internal: execute(params, context)
        Internal->>Internal: Perform actual operation
        Internal-->>Tool: MCPToolResult
    end
    
    alt Simple MCPTool
        Tool->>Tool: Perform operation directly
    end
    
    Tool->>Tool: Generate MCPToolResult
    Tool->>Tool: Add performance metrics
    Tool->>Tool: Add progress events
    
    Tool-->>MCPMgr: MCPToolResult(success, output, events)
    
    MCPMgr->>MCPMgr: Log execution time
    MCPMgr->>MCPMgr: Log success/failure
    
    MCPMgr-->>Agent: MCPToolResult
```

**Key Points:**
- Dotted tool names are parsed and converted to operation parameters
- Read operations skip authorization checks
- Write operations check path-based authorization first
- Temporary grants from user_collaboration are consumed on use
- ConsolidatedMCP tools route to internal tool implementations

---

## 3. ConsolidatedMCP Routing Pattern

Shows how consolidated tools route operations to internal implementations.

```mermaid
graph TD
    A[LLM Tool Call:<br/>file_operations] --> B{Extract Parameters}
    B --> C[operation: read_file]
    B --> D[filePath: src/file.txt]
    B --> E[offset: 0]
    B --> F[limit: 100]
    
    C --> G{Validate Operation}
    G -->|Supported| H{Check Category}
    G -->|Unsupported| I[Operation Error]
    
    H -->|Read Operation| J[No Authorization]
    H -->|Write Operation| K{Check Authorization}
    H -->|Search Operation| J
    
    K -->|Inside Working Dir| L[Auto-Approved]
    K -->|Outside Working Dir| M{Previously Authorized?}
    
    M -->|Yes| L
    M -->|No| N[Authorization Error]
    
    J --> O{Route to Internal Tool}
    L --> O
    
    O -->|read_file| P[ReadFileTool]
    O -->|create_file| Q[CreateFileTool]
    O -->|grep_search| R[GrepSearchTool]
    O -->|replace_string| S[ReplaceStringTool]
    
    P --> T[Execute Internal Tool]
    Q --> T
    R --> T
    S --> T
    
    T --> U[Return MCPToolResult]
    
    style A fill:#e1f5ff
    style U fill:#d4edda
    style I fill:#f8d7da
    style N fill:#f8d7da
```

**Consolidated Tools:**
- `file_operations` - 16 operations (read, search, write)
- `terminal_operations` - 11 operations (command, PTY session)
- `memory_operations` - 4 operations (memory, todos)
- `build_and_version_control` - 5 operations (tasks, git)

---

## 4. User Collaboration & Authorization Flow

Shows the blocking user collaboration mechanism and authorization grant flow.

```mermaid
sequenceDiagram
    participant Agent as AI Agent
    participant Tool as FileOperationsTool
    participant AuthGuard as MCPAuthorizationGuard
    participant UserCollab as UserCollaborationTool
    participant NotifCtr as ToolNotificationCenter
    participant UI as ChatWidget UI
    participant User as Human User
    participant AuthMgr as AuthorizationManager
    
    Agent->>Tool: create_file("/etc/config.txt", content="...")
    
    Tool->>AuthGuard: checkPathAuthorization(path="/etc/config.txt", workingDir="/workspace/conv-123")
    
    AuthGuard->>AuthGuard: Resolve path → /etc/config.txt (absolute)
    AuthGuard->>AuthGuard: Compare to workingDir → /workspace/conv-123
    AuthGuard->>AuthGuard: Path is OUTSIDE working directory
    
    AuthGuard->>AuthMgr: isAuthorized(conversationId, "file_operations.create_file")
    AuthMgr->>AuthMgr: Check for existing grant
    AuthMgr-->>AuthGuard: false (no grant found)
    
    AuthGuard-->>Tool: .requiresAuthorization("Outside working directory")
    
    Tool->>Tool: Generate authorization error message
    Tool-->>Agent: MCPToolResult(success=false, output=authError)
    
    Note over Agent: Agent sees error, uses user_collaboration
    
    Agent->>UserCollab: user_collaboration(<br/>prompt="May I create /etc/config.txt?",<br/>authorize_operation="file_operations.create_file")
    
    UserCollab->>UserCollab: Extract toolCallId from context (e.g., "call_abc123")
    UserCollab->>UserCollab: Create PendingResponse entry
    
    UserCollab->>NotifCtr: postUserInputRequired(toolCallId, prompt, context, conversationId)
    
    NotifCtr->>UI: Notification posted
    UI->>UI: Display collaboration prompt to user
    UI->>UI: Show "Waiting for your response..."
    
    Note over UserCollab: BLOCKS WORKFLOW INDEFINITELY
    UserCollab->>UserCollab: while true { check for response; sleep 100ms }
    
    Note over User: User thinks, types response
    User->>UI: "Yes, proceed"
    
    UI->>UserCollab: submitUserResponse(toolCallId="call_abc123", userInput="Yes, proceed")
    
    UserCollab->>UserCollab: Store response in PendingResponse
    
    Note over UserCollab: Response detected, break wait loop
    
    UserCollab->>UserCollab: Check if response is approval
    UserCollab->>AuthMgr: isApprovalResponse("Yes, proceed") → true
    
    UserCollab->>AuthMgr: grantAuthorization(<br/>conversationId,<br/>"file_operations.create_file",<br/>expirySeconds=300,<br/>oneTimeUse=false)
    
    AuthMgr->>AuthMgr: Create AuthorizationGrant
    AuthMgr->>AuthMgr: Set expiry: now + 300s
    AuthMgr->>AuthMgr: Store in authorizations array
    
    AuthMgr-->>UserCollab: Grant created
    
    UserCollab->>NotifCtr: postUserResponseReceived(toolCallId, userInput, conversationId)
    
    UserCollab-->>Agent: MCPToolResult(success=true, output="User response: Yes, proceed<br/>ACTION REQUIRED: Process response and continue")
    
    Note over Agent: Agent retries file creation
    
    Agent->>Tool: create_file("/etc/config.txt", content="...") [retry]
    
    Tool->>AuthGuard: checkPathAuthorization(...)
    AuthGuard->>AuthMgr: isAuthorized(conversationId, "file_operations.create_file")
    
    AuthMgr->>AuthMgr: Find matching grant
    AuthMgr->>AuthMgr: Check: grant.expiresAt > now → true
    AuthMgr->>AuthMgr: Check: !grant.consumed → true
    
    AuthMgr-->>AuthGuard: true
    
    AuthGuard-->>Tool: .allowed("User previously authorized this operation")
    
    Tool->>Tool: Execute file creation
    Tool->>Tool: Write file to /etc/config.txt
    
    Tool-->>Agent: MCPToolResult(success=true, output="File created")
```

**Key Behaviors:**

**Blocking Mechanism:**
- `user_collaboration` has `requiresBlocking = true`
- Workflow execution STOPS until user responds
- No timeout - user has full control
- Infinite wait loop: `while true { check response; sleep 100ms }`

**Authorization Grant:**
- Default expiry: 5 minutes (300 seconds)
- Can be one-time or multi-use
- Consumed on first use if one-time
- Cleaned up when expired

**Response Detection:**
- Approval keywords: "yes", "ok", "proceed", "approve", "confirm"
- Rejection keywords: "no", "cancel", "stop", "deny"
- Case-insensitive matching

---

## 5. PTY Session Lifecycle

Shows creation, usage, and management of persistent terminal sessions.

```mermaid
stateDiagram-v2
    [*] --> CheckExisting: create_session request
    
    CheckExisting --> SessionExists: Session with conversationId found
    CheckExisting --> CreateNew: No session found
    
    SessionExists --> CheckWorkingDir: Compare working directories
    CheckWorkingDir --> ReuseSession: Same working directory
    CheckWorkingDir --> RestartSession: Working directory changed
    
    RestartSession --> CloseExisting: close_session
    CloseExisting --> CreateNew: Create with new working dir
    
    CreateNew --> Fork: Call Darwin.forkpty()
    Fork --> ParentProcess: pid > 0 (parent)
    Fork --> ChildProcess: pid == 0 (child)
    
    ChildProcess --> SetupEnv: chdir(workingDirectory)
    SetupEnv --> SetTermVars: TERM=xterm-256color<br/>LANG=en_US.UTF-8
    SetTermVars --> ExecShell: execv("/bin/bash", ["-il"])
    ExecShell --> BashRunning: Bash shell started
    
    ParentProcess --> SetupFD: Set master FD non-blocking
    SetupFD --> StartReadLoop: Async read task
    StartReadLoop --> Active: Session active
    
    Active --> ReadOutput: Agent sends command
    ReadOutput --> BufferAppend: Read from master FD
    BufferAppend --> Active: Append to outputBuffer
    
    Active --> SendInput: send_input("ls -la\r\n")
    SendInput --> WriteToFD: Write to master FD
    WriteToFD --> Active: Command sent
    
    Active --> GetOutput: get_output(fromIndex)
    GetOutput --> ReturnSlice: Return outputBuffer[fromIndex...]
    ReturnSlice --> Active: Output retrieved
    
    Active --> GetHistory: get_history()
    GetHistory --> ReturnAll: Return full outputBuffer
    ReturnAll --> Active: History retrieved
    
    Active --> Resize: resize_session(rows, cols)
    Resize --> IOCTL: ioctl(TIOCSWINSZ, &windowSize)
    IOCTL --> Active: Size updated
    
    Active --> Kill: killAllSessionProcesses()
    Kill --> FindDescendants: ps -A -o pid,ppid
    FindDescendants --> KillTree: SIGKILL descendants + shell
    KillTree --> Closed: All processes terminated
    
    Active --> Close: close_session()
    Close --> SIGTERM: Send SIGTERM to child
    SIGTERM --> WaitExit: waitpid(childPid, WNOHANG)
    
    WaitExit --> Exited: Child exited
    WaitExit --> SIGKILL: Child still running after 100ms
    SIGKILL --> Exited: Force kill
    
    Exited --> CleanupFD: close(masterFd)
    CleanupFD --> RemoveFromMap: Remove from sessions map
    RemoveFromMap --> Closed: Session closed
    
    ReuseSession --> Active: Return existing session
    
    Closed --> [*]
    BashRunning --> Active: Shell ready
```

**PTY Session Features:**

**Session Persistence:**
- Conversation-scoped (session ID = conversation ID)
- Maintains shell environment across commands
- Output buffer preserves full history
- Reused when working directory unchanged

**Output Capture:**
- Async read loop (non-blocking)
- Reads from master FD continuously
- Appends to thread-safe buffer
- Returns slices on demand (fromIndex parameter)

**Shell Configuration:**
- Bash interactive login shell (`-il`)
- 256-color terminal support
- UTF-8 encoding
- Inherits user's shell environment

**Cleanup:**
- Graceful shutdown: SIGTERM → wait → SIGKILL
- Descendant process cleanup
- FD closure
- Session map removal

---

## 6. Tool Display Information Flow

Shows how tools provide UI-friendly progress information.

```mermaid
graph TD
    A[Agent calls tool] --> B{Tool implements<br/>ToolDisplayInfoProvider?}
    
    B -->|Yes| C[Tool registered in<br/>ToolDisplayInfoRegistry]
    B -->|No| D[Generic display info]
    
    C --> E[extractDisplayInfo<br/>from arguments]
    E --> F{Operation-specific<br/>logic}
    
    F -->|file_operations| G[Switch on operation]
    F -->|terminal_operations| H[Switch on operation]
    F -->|memory_operations| I[Switch on operation]
    
    G -->|create_file| J[Creating file: filename.txt]
    G -->|read_file| K[Reading file: filename.txt]
    G -->|grep_search| L[Searching code: pattern]
    
    H -->|run_command| M[Running: command preview...]
    H -->|send_input| N[Sending to terminal: input preview...]
    H -->|create_session| O[Creating terminal session]
    
    I -->|search_memory| P[Searching memory: query]
    I -->|manage_todos| Q{Todo operation}
    
    Q -->|read| R[Reading todo list]
    Q -->|write| S{Status analysis}
    Q -->|update| T[Updating N todos]
    
    S -->|Completed tasks| U[Completed: Task Title]
    S -->|In-progress tasks| V[Starting: Task Title]
    S -->|Creating list| W[Creating todo list: N tasks]
    
    J --> X[Return display string]
    K --> X
    L --> X
    M --> X
    N --> X
    O --> X
    P --> X
    R --> X
    T --> X
    U --> X
    V --> X
    W --> X
    
    X --> Y[ChatWidget displays in UI]
    
    D --> Z[Tool name + basic info]
    Z --> Y
    
    style A fill:#e1f5ff
    style Y fill:#d4edda
```

**Display Info Sources:**

**extractDisplayInfo:**
- Returns concise string (e.g., "Creating file: test.txt")
- Truncates long values (50-80 chars)
- Operation-specific formatting

**extractToolDetails:**
- Returns array of detail strings
- More comprehensive than display info
- Used for tool execution cards in UI

**Example Implementation:**
```swift
extension FileOperationsTool: ToolDisplayInfoProvider {
    public static func extractDisplayInfo(from arguments: [String: Any]) -> String? {
        guard let operation = arguments["operation"] as? String else { return nil }
        
        switch operation {
        case "create_file":
            if let filePath = arguments["filePath"] as? String {
                let fileName = (filePath as NSString).lastPathComponent
                return "Creating file: \(fileName)"
            }
            return "Creating file"
        
        case "grep_search":
            if let query = arguments["query"] as? String {
                let preview = query.count > 50 ? String(query.prefix(47)) + "..." : query
                return "Searching code: \(preview)"
            }
            return "Searching code"
        
        default:
            return nil
        }
    }
}
```

---

## 7. Tool Execution States

Shows the different execution states and transitions during tool execution.

```mermaid
stateDiagram-v2
    [*] --> Queued: Tool call received
    
    Queued --> Validating: Extract from queue
    
    Validating --> ValidationFailed: Parameters invalid
    Validating --> CheckingAuth: Parameters valid
    
    ValidationFailed --> [*]: Return error result
    
    CheckingAuth --> AuthDenied: Authorization denied
    CheckingAuth --> AuthPending: Requires user approval
    CheckingAuth --> Executing: Authorized
    
    AuthDenied --> [*]: Return authorization error
    
    AuthPending --> BlockingWait: user_collaboration tool
    BlockingWait --> UserResponded: User approves
    BlockingWait --> UserRejected: User rejects
    
    UserResponded --> Executing: Grant created, retry
    UserRejected --> [*]: Return rejection
    
    Executing --> Routing: ConsolidatedMCP
    Executing --> DirectExecution: Simple MCPTool
    
    Routing --> InternalTool: Route to internal implementation
    InternalTool --> DirectExecution: Internal tool executes
    
    DirectExecution --> EmitProgress: Long-running operation
    EmitProgress --> DirectExecution: Continue execution
    
    DirectExecution --> Success: Operation succeeds
    DirectExecution --> Failure: Operation fails
    
    Success --> GenerateResult: Create MCPToolResult
    Failure --> GenerateResult: Create error result
    
    GenerateResult --> AddMetrics: Add performance data
    AddMetrics --> AddEvents: Add progress events
    AddEvents --> [*]: Return result
    
    note right of BlockingWait
        user_collaboration blocks
        workflow indefinitely
        until user responds
    end note
    
    note right of EmitProgress
        Tools can emit progress
        events during execution
        for UI display
    end note
```

**State Transitions:**

**Queued → Validating:**
- Extract parameters
- Check required fields
- Validate types

**Validating → CheckingAuth:**
- Path-based authorization (write operations)
- Check existing grants
- User-initiated bypass

**CheckingAuth → AuthPending:**
- Path outside working directory
- No existing grant
- Agent-initiated operation

**AuthPending → BlockingWait:**
- user_collaboration tool called
- Workflow STOPS
- UI displays prompt

**Executing → Routing:**
- ConsolidatedMCP tools route to internal implementations
- Operation parameter determines routing
- Simple tools skip routing

**DirectExecution → Success/Failure:**
- Actual operation execution
- File I/O, terminal commands, etc.
- Error handling

**GenerateResult → Return:**
- Create MCPToolResult
- Add performance metrics
- Add progress events
- Return to orchestrator

---

## Summary

These flows illustrate:

1. **Tool Registration** - Dependency injection, initialization, ordered registration
2. **Tool Execution** - Authorization checks, routing, execution
3. **ConsolidatedMCP** - Operation-based routing to internal tools
4. **User Collaboration** - Blocking mechanism, authorization grants
5. **PTY Sessions** - Persistent terminals, lifecycle management
6. **Display Information** - UI-friendly progress messages
7. **Execution States** - Complete state machine for tool execution

All flows work together to provide a comprehensive, secure, and extensible tool execution framework for SAM's AI agents.

---

**End of TOOL_EXECUTION_FLOWS.md**
