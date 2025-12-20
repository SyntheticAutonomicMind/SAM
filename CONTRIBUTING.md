# Contributing to SAM

Thank you for your interest in contributing to SAM (Synthetic Autonomic Mind)! This document provides guidelines and information for contributors.

## Table of Contents
- [Code of Conduct](#code-of-conduct)
- [Getting Started](#getting-started)
- [Development Setup](#development-setup)
- [Swift 6 Concurrency](#swift-6-concurrency)
- [Making Changes](#making-changes)
- [Submitting Changes](#submitting-changes)
- [Code Style](#code-style)
- [Testing](#testing)
- [Documentation](#documentation)

## Code of Conduct

We are committed to providing a welcoming and inclusive environment. Please:
- Be respectful and considerate in all interactions
- Welcome newcomers and help them get started
- Focus on constructive feedback
- Assume good intentions

## Getting Started

### Prerequisites
- macOS 14.0 (Sonoma) or later
- Xcode 26.1+ with Swift 6.2.1+
- Familiarity with Swift and SwiftUI
- Understanding of Swift 6 concurrency (async/await, actors, Sendable)

### First Steps
1. **Fork the repository** on GitHub
2. **Clone your fork** locally:
   ```bash
   git clone https://github.com/YOUR-USERNAME/SAM.git
   cd SAM
   ```
3. **Add upstream remote**:
   ```bash
   git remote add upstream https://github.com/SyntheticAutonomicMind/SAM.git
   ```
4. **Build the project**:
   ```bash
   make build-debug
   ```

### Finding Work
- Check [GitHub Issues](https://github.com/SyntheticAutonomicMind/SAM/issues) for open tasks
- Look for issues labeled `good-first-issue` or `help-wanted`
- Review the project boards for planned features
- Propose new features by opening a discussion first

## Development Setup

### Building
```bash
# Debug build (faster, includes debug symbols)
make build-debug

# Release build (optimized for production)
make build-release

# Clean build artifacts
make clean

# Test build like GitHub Actions CI/CD
./scripts/test_like_pipeline.sh
```

### Running
```bash
# Run from build directory
.build/Build/Products/Debug/SAM.app/Contents/MacOS/SAM

# Run as background service
nohup .build/Build/Products/Debug/SAM > sam_server.log 2>&1 &

# Check logs
tail -f sam_server.log
```

### Testing
```bash
# Run all tests
swift test

# Run specific test suite
swift test --filter ConversationManagerTests

# Run with verbose output
swift test --verbose
```

### Code Quality
```bash
# Lint the codebase
swiftlint lint

# Auto-fix linting issues
swiftlint --fix

# Lint specific directory
cd Sources && swiftlint lint
```

## Swift 6 Concurrency

SAM uses Swift 6 strict concurrency checking. All code must be concurrency-safe.

### Key Requirements

**Sendable Conformance:**
All types that cross actor boundaries must conform to `Sendable`:
```swift
// Structs with only Sendable fields
struct MyData: Sendable {
    let value: String
    let count: Int
}

// Structs with non-Sendable fields (e.g., [String: Any])
struct ToolArguments: @unchecked Sendable {
    let params: [String: Any]  // Safe if only JSON-serializable types
}

// Classes that are stateless or properly synchronized
final class MyService: @unchecked Sendable {
    nonisolated(unsafe) private let dependency: SomeDependency
}
```

**MainActor Isolation:**
UI code and AppKit/NSAttributedString operations must run on MainActor:
```swift
@MainActor
class MyViewModel: ObservableObject {
    @Published var data: String = ""
    
    func updateUI() {
        // Safe - already on MainActor
        self.data = "Updated"
    }
}

// Methods that touch UI
@MainActor
func renderDiagram() -> NSAttributedString {
    // NSAttributedString is not Sendable
    // Must be on MainActor
}
```

**Actor Boundary Captures:**
Capture variables before crossing actor boundaries:
```swift
// BAD - property access across actor boundary
func doWork() async {
    await withTaskGroup(of: Void.self) { group in
        group.addTask {
            await self.property.doSomething()  // ❌ Error
        }
    }
}

// GOOD - capture before async
func doWork() async {
    let property = self.property  // Capture synchronously
    await withTaskGroup(of: Void.self) { group in
        group.addTask {
            await property.doSomething()  // ✅ OK
        }
    }
}
```

**SQLite Expression Helpers:**
Use helpers from `SQLiteHelpers.swift` to avoid Expression<T> ambiguity:
```swift
import ConversationEngine

// Instead of: Expression<String>("column")  // ❌ Ambiguous
let nameColumn = column("name", String.self)     // ✅ Correct
let ageColumn = columnOptional("age", Int.self)  // ✅ Correct
```

### Testing Concurrency

**Before committing:**
```bash
# Local build - should show 0 errors
make build-debug

# Simulate CI/CD environment
./scripts/test_like_pipeline.sh
```

**Expected:** 0 errors, ~211 warnings (Sendable-related, non-blocking)

### Common Patterns

**Pattern 1: Wrapper for Non-Sendable Dictionaries**
```swift
private struct SendableParams: @unchecked Sendable {
    let value: [String: Any]  // Safe if only JSON types
}

let params = SendableParams(value: toolCall.arguments)
await withTaskGroup { group in
    group.addTask { @Sendable in
        await execute(params: params.value)
    }
}
```

**Pattern 2: nonisolated(unsafe) for Safe Non-Sendable**
```swift
class ToolManager {
    nonisolated(unsafe) private let toolRegistry: [String: Tool]
    
    // Safe because toolRegistry is immutable after init
    init(tools: [String: Tool]) {
        self.toolRegistry = tools
    }
}
```

**Pattern 3: Capture Before Loops**
```swift
// BAD
for item in items {
    await process(options: self.options)  // ❌ Capture in loop
}

// GOOD
let options = self.options  // Capture once
for item in items {
    await process(options: options)  // ✅ OK
}
```

See [project-docs/SWIFT6_CONCURRENCY_MIGRATION.md](project-docs/SWIFT6_CONCURRENCY_MIGRATION.md) for complete migration history and patterns.

## Making Changes

### Creating a Branch
Create a descriptive branch name:
```bash
git checkout -b feature/add-new-tool
git checkout -b fix/conversation-export-bug
git checkout -b refactor/split-chatwidget
git checkout -b docs/update-api-reference
```

### Commit Messages
We follow [Conventional Commits](https://www.conventionalcommits.org/):

**Format:**
```
<type>(<scope>): <subject>

[optional body]

[optional footer]
```

**Types:**
- `feat`: New feature
- `fix`: Bug fix
- `refactor`: Code refactoring (no functional changes)
- `docs`: Documentation changes
- `test`: Adding or updating tests
- `chore`: Maintenance tasks (dependencies, build config)
- `perf`: Performance improvements
- `style`: Code style changes (formatting, whitespace)

**Scopes:**
- `ui`: User interface changes
- `api`: API provider implementations
- `mcp`: MCP framework and tools
- `conversation`: Conversation management
- `config`: Configuration system
- `build`: Build system and dependencies

**Examples:**
```bash
git commit -m "feat(mcp): Add web scraping tool with structured data extraction"
git commit -m "fix(ui): Prevent toolbar overflow on narrow windows"
git commit -m "refactor(api): Extract streaming logic into separate service"
git commit -m "docs(readme): Update installation instructions for macOS"
```

### Code Changes

**Before making changes:**
1. Ensure you're working on the latest code:
   ```bash
   git fetch upstream
   git rebase upstream/main
   ```
2. Read the relevant source code to understand context
3. Check for existing issues or discussions about your change

**While making changes:**
1. Keep changes focused and atomic
2. Write clear, self-documenting code
3. Add comments for complex logic
4. Update documentation as needed
5. Add or update tests for new functionality

**Testing your changes:**
1. Build successfully: `make build-debug`
2. Run tests: `swift test`
3. Lint your code: `swiftlint lint`
4. Test manually in the app
5. Check logs for errors or warnings

## Submitting Changes

### Pull Request Process

1. **Push your branch** to your fork:
   ```bash
   git push origin feature/your-feature
   ```

2. **Create a Pull Request** on GitHub:
   - Provide a clear title using conventional commit format
   - Describe what changed and why
   - Reference related issues (e.g., "Fixes #123")
   - Include screenshots for UI changes
   - List any breaking changes

3. **PR Checklist:**
   - [ ] Code builds without errors
   - [ ] All tests pass
   - [ ] SwiftLint passes with no new violations
   - [ ] Documentation updated (if needed)
   - [ ] Commit messages follow conventions
   - [ ] No unrelated changes included
   - [ ] Branch is up to date with main

4. **Review Process:**
   - Maintainers will review your PR
   - Address feedback in new commits (don't force-push during review)
   - Once approved, a maintainer will merge your PR

### What Makes a Good PR

**Good PRs:**
- Solve one problem or add one feature
- Include tests for new functionality
- Have clear, descriptive commit messages
- Update relevant documentation
- Are reasonably sized (under 500 lines when possible)

**PRs that need improvement:**
- Mix multiple unrelated changes
- Lack tests or documentation
- Have unclear or missing descriptions
- Include unrelated formatting changes
- Are extremely large without discussion

## Code Style

### Swift Style Guidelines

We follow the [Swift API Design Guidelines](https://swift.org/documentation/api-design-guidelines/) with these additions:

**Naming:**
- Use descriptive names: `conversationManager` not `cm`
- Use camelCase for variables and functions
- Use PascalCase for types
- Avoid single-character names except in loops: `for item in items` ✅, `let i = 0` ❌

**Functions:**
- Keep functions under 50 lines when possible
- Extract complex logic into helper functions
- Use meaningful parameter names
- Document public APIs with doc comments

**Types:**
- Keep type bodies under 350 lines (warnings at 250)
- Consider splitting large types into extensions or separate files
- Use protocols for abstraction
- Prefer structs over classes when possible

**Error Handling:**
- Use proper error handling, avoid force unwraps (`!`)
- Use `guard` for early returns
- Provide meaningful error messages

**SwiftUI:**
- Extract view components for reusability
- Keep view bodies readable
- Use `@State`, `@StateObject`, `@ObservedObject` appropriately
- Extract business logic from views

### SwiftLint Rules

Key rules we enforce:
- **Line length**: 120 characters (warnings only)
- **Function body length**: 50 lines warning, 100 error
- **Type body length**: 250 lines warning, 350 error
- **Cyclomatic complexity**: 15 warning, 25 error
- **Force unwrapping**: Avoid when safer alternatives exist
- **Trailing whitespace**: Not allowed
- **Identifier naming**: camelCase, descriptive names

Run `swiftlint --fix` to auto-fix many issues.

## Testing

### Writing Tests

**Unit Tests:**
```swift
import XCTest
@testable import SAM

final class ConversationManagerTests: XCTestCase {
    var conversationManager: ConversationManager!
    
    override func setUp() {
        super.setUp()
        conversationManager = ConversationManager()
    }
    
    func testCreateConversation() async throws {
        let conversation = try await conversationManager.createConversation(
            title: "Test Conversation"
        )
        XCTAssertEqual(conversation.title, "Test Conversation")
    }
}
```

**Integration Tests:**
- Test tool execution end-to-end
- Test API provider integration
- Test conversation persistence

**UI Tests:**
- Test critical user workflows
- Test accessibility features
- Use XCUITest framework

### Test Coverage

- Aim for 70%+ code coverage
- Prioritize testing critical paths
- Test error cases and edge conditions
- Mock external dependencies

## Documentation

### Code Documentation

**Public APIs must have doc comments:**
```swift
/// Manages conversation state and persistence.
///
/// The ConversationManager handles:
/// - Creating and deleting conversations
/// - Loading and saving messages
/// - Managing conversation metadata
///
/// - Note: All operations are thread-safe.
public class ConversationManager {
    /// Creates a new conversation with the specified title.
    ///
    /// - Parameter title: The conversation title
    /// - Returns: The newly created conversation
    /// - Throws: `ConversationError.saveFailed` if persistence fails
    public func createConversation(title: String) async throws -> Conversation {
        // Implementation
    }
}
```

### User Documentation

Update `project-docs/` when adding user-facing features:
- Tool documentation for new MCP tools (update MCP_TOOLS_SPECIFICATION.md)
- Feature guides for new capabilities
- Flow documentation if message/tool execution changes
- Architecture documentation if subsystem behavior changes

### README Updates

Update README.md for:
- New features in "Key Features" section
- Changed installation/build process
- New configuration options
- Updated system requirements

## Specific Contribution Areas

### Adding MCP Tools

1. **Create tool class** in `Sources/MCPFramework/Tools/`:
   ```swift
   public class MyNewTool: ConsolidatedMCP, @unchecked Sendable {
       public let name = "my_new_tool"
       public let description = "Description of what the tool does"
       
       public var supportedOperations: [String] {
           return ["read", "write"]
       }
       
       public var parameters: [String: MCPToolParameter] {
           // Define parameters
       }
       
       @MainActor  // If needed for UI operations
       public func routeOperation(
           _ operation: String,
           parameters: [String: Any],
           context: MCPExecutionContext
       ) async -> MCPToolResult {
           // Implementation
       }
   }
   ```

2. **Register tool** in `MCPManager.swift`:
   ```swift
   MyNewTool(),
   ```

3. **Ensure Sendable conformance** for all parameter/result types
4. **Add tests** for the tool
5. **Document** in `project-docs/MCP_TOOLS_SPECIFICATION.md`

### Adding API Providers

1. **Create provider** in `Sources/APIFramework/`:
   ```swift
   class MyProvider: APIProvider {
       // Implement required protocol methods
   }
   ```

2. **Register** in `EndpointManager`
3. **Add configuration UI** in settings
4. **Document** setup process

### UI Improvements

1. **Extract reusable components** to `Sources/UserInterface/Components/`
2. **Maintain accessibility** (VoiceOver support, keyboard navigation)
3. **Test on different window sizes**
4. **Follow macOS Human Interface Guidelines**

## Questions?

- Open a [GitHub Discussion](https://github.com/SyntheticAutonomicMind/SAM/discussions) for questions
- Check existing issues and PRs for similar work
- Reach out to maintainers for guidance on larger contributions

---

**Thank you for contributing to SAM!** Your efforts help make SAM better for everyone.
