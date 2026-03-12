# MCP API Test Suite

Comprehensive testing suite for all SAM MCP (Model Context Protocol) tools via API.

## Overview

This test suite validates that all SAM MCP tools work correctly when invoked through the OpenAI-compatible API (`/api/chat/completions`). It tests:

- **File operations** across root, subdirectories, and nested directories
- **Terminal operations** for command execution and directory management
- **Memory operations** for storage, search, and todo management
- **Web operations** using real internet data (as requested)
- **Document operations** for import and retrieval
- **Build and version control** operations
- **Other tools** (think, collaboration, etc.)

## Quick Start

### Prerequisites

1. **SAM server must be running:**
   ```bash
   cd /Users/andrew/repositories/SyntheticAutonomicMind/SAM
   make build-debug
   pkill -9 SAM
   nohup .build/Build/Products/Debug/SAM > sam_server.log 2>&1 & sleep 3
   ```

2. **Verify server is responding:**
   ```bash
   curl -X POST http://127.0.0.1:8080/api/chat/completions \
     -H "Content-Type: application/json" \
     -d '{"model":"gpt-4","messages":[{"role":"user","content":"test"}]}'
   ```

### Running Tests

```bash
# Run all tests
cd tests
./mcp_api_tests.sh

# Run with verbose output
./mcp_api_tests.sh --verbose

# Run tests for specific tool only
./mcp_api_tests.sh --tool file_operations
```

### Viewing Results

```bash
# View latest test results
cat tests/test_results.txt

# View detailed output
./mcp_api_tests.sh --verbose
```

## Test Coverage

### Tool Inventory (10 consolidated tools, 48+ operations)

#### 1. **file_operations** (16 operations)
**Read Operations:**
- `read_file` - Read file contents (root, subdir, nested) ✓
- `list_dir` - List directory contents ✓
- `get_errors` - Get compilation/lint errors
- `get_search_results` - Get search view results

**Search Operations:**
- `file_search` - Find files by glob pattern ✓
- `grep_search` - Text search across files ✓
- `semantic_search` - Semantic code search
- `list_usages` - Find symbol usages
- `search_index` - Search working directory index

**Write Operations:**
- `create_file` - Create new file (root, subdir, nested) ✓
- `replace_string` - Replace text in file ✓
- `multi_replace_string` - Multiple replacements
- `insert_edit` - Insert/replace by line
- `rename_file` - Rename/move file ✓
- `delete_file` - Delete file ✓
- `apply_patch` - Apply unified diff patch

#### 3. **memory_operations** (4 operations)
- `search_memory` - Search stored memories ✓
- `store_memory` - Store new memory ✓
- `list_collections` - List memory collections ✓
- `manage_todos` - Manage todo list ✓

#### 4. **web_operations** (5+ operations)
- `research` - Comprehensive web research
- `retrieve` - Retrieve stored research
- `web_search` - Search the web
- `scrape` - Scrape webpage
- `fetch` - Fetch webpage content ✓ (tested with real data)
- `serpapi` - SerpAPI search (conditional)

#### 5. **document_operations** (3 operations)
- `document_import` - Import document to memory ✓
- `document_create` - Create new document
- `get_doc_info` - Get document information ✓

#### 7. **think** (1 operation)
- Reasoning and analysis tool ✓

#### 8. **user_collaboration** (1 operation)
- Interactive user collaboration (requires user input)

#### 9. **read_tool_result** (1 operation)
- Read persisted tool results (deprecated)

### Test Statistics

**Current Coverage:**
- Total Operations: 48+
- Tested Operations: ~27
- Passing Tests: See test_results.txt
- Skipped Tests: ~18 (require special setup/state)

**Directory Testing (Critical for Priority 1):**
- ✓ Root directory file operations
- ✓ Subdirectory file operations  
- ✓ Nested subdirectory file operations
- ✓ Create files in all directory levels
- ✓ Read files from all directory levels
- ✓ Terminal operations in different directories

## Test Workspace Structure

```
test_workspace/
├── root_files/
│   ├── README.md         # Test documentation
│   ├── sample.txt        # Sample text with markers
│   └── data.json         # JSON test data
├── subdir1/
│   ├── script.py         # Python script for execution
│   └── config.ini        # Configuration file
├── subdir2/
│   └── nested/
│       └── deep.txt      # Deeply nested file
└── data/
    └── test.csv          # CSV test data
```

## Real Data Testing (Per User Request)

The test suite uses real internet data where applicable:

- **web_operations.fetch**: Tests with httpbin.org (real HTML, JSON)
- **web_operations.web_search**: Searches real web content
- **document_operations**: Can import real documents from URLs
- **file_operations**: Uses actual file system operations

## Test Output Format

Tests provide color-coded output:

- 🟢 **PASS**: Test succeeded
- 🔴 **FAIL**: Test failed (with reason)
- 🟡 **SKIP**: Test skipped (requires setup/state)

Example:
```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
File Operations Tests (16 operations)
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

TEST: file_operations.read_file (root)
✓ PASS: Read file from root directory

TEST: file_operations.read_file (subdir)
✓ PASS: Read file from subdirectory

TEST: file_operations.read_file (nested)
✓ PASS: Read file from nested subdirectory
```

## Extending Tests

### Adding New Test Cases

1. **Add test function** to `mcp_api_tests.sh`:
   ```bash
   test_my_new_operation() {
       print_test "tool_name.operation_name"
       response=$(api_call "Use tool_name with operation='operation_name'...")
       content=$(get_response_content "$response")
       if check_success "$content" "expected_pattern"; then
           print_pass "Description"
       else
           print_fail "Description" "Reason"
       fi
   }
   ```

2. **Call from main()**: Add `test_my_new_operation` to main function

3. **Update this README**: Document the new test coverage

### Testing New Tools

For new consolidated MCP tools:

1. Review tool's `supportedOperations` array
2. Create test function for each operation
3. Use real data where possible
4. Test across directory structures if file-related
5. Add to test coverage documentation

## Troubleshooting

### SAM Server Not Running

```bash
Error: SAM server not responding
```

**Solution:**
```bash
cd /Users/andrew/repositories/SyntheticAutonomicMind/SAM
pkill -9 SAM
make build-debug
nohup .build/Build/Products/Debug/SAM > sam_server.log 2>&1 & sleep 3
```

### Permission Errors

```bash
Error: Operation denied / Authorization required
```

**Solution:** Some operations require security-scoped bookmark authorization. Check SAM's authorization system and grant access to test workspace.

### API Timeout

```bash
Error: Connection timeout
```

**Solution:** Increase timeout in curl commands or check if SAM is processing a long-running operation.

### Test Failures

Check detailed output with `--verbose` flag:
```bash
./mcp_api_tests.sh --verbose
```

Review SAM server logs:
```bash
tail -f /Users/andrew/repositories/SyntheticAutonomicMind/SAM/sam_server.log
```

## Maintenance

### Before Release

1. Run full test suite: `./mcp_api_tests.sh`
2. Verify all critical paths pass
3. Update test_results.txt
4. Document any new known issues

### After Code Changes

1. Run relevant tool tests: `./mcp_api_tests.sh --tool changed_tool`
2. Run full suite if core changes: `./mcp_api_tests.sh`
3. Update tests if API changes
4. Commit test results with code changes

## Future Enhancements

- [ ] Add performance benchmarks
- [ ] Test error handling edge cases
- [ ] Add concurrent operation tests
- [ ] Test large file operations (>1MB)
- [ ] Add security/authorization tests
- [ ] Test tool chaining scenarios
- [ ] Add regression test suite
- [ ] Automated CI/CD integration

## Related Documentation

- [SAM Architecture](../BUILDING.md)
- [MCP Tool Development](../Sources/MCPFramework/README.md)
- [API Documentation](../docs/API.md)
- [Contributing Guidelines](../CONTRIBUTING.md)

## License

Same as SAM project license.

---

**Last Updated:** November 17, 2025  
**Version:** 1.0  
**Maintainer:** SAM Development Team
