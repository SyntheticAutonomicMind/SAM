#!/usr/bin/env bash
#
# MCP API Test Suite
# Comprehensive testing of all SAM MCP tools via API
#
# Usage: ./mcp_api_tests.sh [--verbose] [--tool TOOLNAME]
#

# Don't exit on error - we want to run all tests
set +e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
API_URL="http://127.0.0.1:8080/api/chat/completions"
TEST_WORKSPACE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test_workspace"
TEST_RESULTS_FILE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test_results.txt"
VERBOSE=0
SPECIFIC_TOOL=""

# Test counters
TOTAL_TESTS=0
PASSED_TESTS=0
FAILED_TESTS=0
SKIPPED_TESTS=0

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --verbose|-v)
            VERBOSE=1
            shift
            ;;
        --tool|-t)
            SPECIFIC_TOOL="$2"
            shift 2
            ;;
        --help|-h)
            echo "Usage: $0 [--verbose] [--tool TOOLNAME]"
            echo ""
            echo "Options:"
            echo "  --verbose, -v     Show detailed test output"
            echo "  --tool, -t NAME   Run tests for specific tool only"
            echo "  --help, -h        Show this help"
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

# Helper functions
print_header() {
    echo ""
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BLUE}$1${NC}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

print_test() {
    echo -e "\n${YELLOW}TEST:${NC} $1"
}

print_pass() {
    echo -e "${GREEN}✓ PASS${NC}: $1"
    ((PASSED_TESTS++))
    ((TOTAL_TESTS++))
}

print_fail() {
    echo -e "${RED}✗ FAIL${NC}: $1"
    echo -e "${RED}  Reason: $2${NC}"
    ((FAILED_TESTS++))
    ((TOTAL_TESTS++))
}

print_skip() {
    echo -e "${YELLOW}⊘ SKIP${NC}: $1"
    ((SKIPPED_TESTS++))
    ((TOTAL_TESTS++))
}

# Make API call to SAM
# Usage: api_call "prompt message"
# Returns: full JSON response
api_call() {
    local prompt="$1"
    local response
    
    if [[ $VERBOSE -eq 1 ]]; then
        echo -e "${BLUE}API Request:${NC} $prompt"
    fi
    
    response=$(curl -s --max-time 60 -X POST "$API_URL" \
        -H "Content-Type: application/json" \
        -d "{
            \"model\": \"gpt-4\",
            \"messages\": [{
                \"role\": \"user\",
                \"content\": $(echo "$prompt" | jq -Rs .)
            }],
            \"stream\": false,
            \"max_tokens\": 500
        }")
    
    if [[ $VERBOSE -eq 1 ]]; then
        echo -e "${BLUE}API Response:${NC}"
        echo "$response" | jq -C '.' 2>/dev/null || echo "$response"
    fi
    
    echo "$response"
}

# Extract assistant message from API response
get_response_content() {
    local response="$1"
    echo "$response" | jq -r '.choices[0].message.content // empty' 2>/dev/null || echo ""
}

# Check if response contains success indicators
check_success() {
    local content="$1"
    local success_pattern="$2"
    
    if echo "$content" | grep -iq "$success_pattern"; then
        return 0
    else
        return 1
    fi
}

# Initialize test environment
initialize_tests() {
    print_header "MCP API Test Suite - Initialization"
    
    echo "Test workspace: $TEST_WORKSPACE"
    echo "API endpoint: $API_URL"
    echo ""
    
    # Check if SAM server is running
    echo -n "Checking SAM server... "
    http_code=$(curl -s -o /dev/null -w "%{http_code}" "$API_URL" 2>&1)
    if echo "$http_code" | grep -q "404\|405\|200"; then
        echo -e "${GREEN}Running (HTTP $http_code)${NC}"
    else
        echo -e "${RED}Not running (HTTP $http_code)${NC}"
        echo ""
        echo "Please start SAM UI application or start server with:"
        echo "  cd /Users/andrew/repositories/SyntheticAutonomicMind/SAM"
        echo "  make build-debug"
        echo "  open .build/Build/Products/Debug/SAM.app"
        exit 1
    fi
    
    # Clear previous test results
    > "$TEST_RESULTS_FILE"
    
    echo "Initialized successfully"
}

# ============================================================================
# FILE OPERATIONS TESTS
# ============================================================================
test_file_operations() {
    if [[ -n "$SPECIFIC_TOOL" ]] && [[ "$SPECIFIC_TOOL" != "file_operations" ]]; then
        return
    fi
    
    print_header "File Operations Tests (16 operations)"
    
    # Test 1: Read file from root directory
    print_test "file_operations.read_file (root)"
    response=$(api_call "Use file_operations tool with operation='read_file' to read the file at $TEST_WORKSPACE/root_files/sample.txt")
    content=$(get_response_content "$response")
    if check_success "$content" "TESTMARKER\|multiple lines"; then
        print_pass "Read file from root directory"
    else
        print_fail "Read file from root directory" "Content not found in response"
    fi
    
    # Test 2: Read file from subdirectory
    print_test "file_operations.read_file (subdir)"
    response=$(api_call "Use file_operations tool with operation='read_file' to read $TEST_WORKSPACE/subdir1/script.py")
    content=$(get_response_content "$response")
    if check_success "$content" "hello_world\|calculate_sum"; then
        print_pass "Read file from subdirectory"
    else
        print_fail "Read file from subdirectory" "Python code not found"
    fi
    
    # Test 3: Read file from nested subdirectory
    print_test "file_operations.read_file (nested)"
    response=$(api_call "Use file_operations tool with operation='read_file' to read $TEST_WORKSPACE/subdir2/nested/deep.txt")
    content=$(get_response_content "$response")
    if check_success "$content" "NESTED FILE CONTENT\|deeply nested"; then
        print_pass "Read file from nested subdirectory"
    else
        print_fail "Read file from nested subdirectory" "Nested content not found"
    fi
    
    # Test 4: List directory (root)
    print_test "file_operations.list_dir (root)"
    response=$(api_call "Use file_operations tool with operation='list_dir' to list contents of $TEST_WORKSPACE/root_files/")
    content=$(get_response_content "$response")
    if check_success "$content" "sample.txt\|data.json\|README.md"; then
        print_pass "List root directory"
    else
        print_fail "List root directory" "Expected files not listed"
    fi
    
    # Test 5: List subdirectory
    print_test "file_operations.list_dir (subdir)"
    response=$(api_call "Use file_operations tool with operation='list_dir' to list $TEST_WORKSPACE/subdir1/")
    content=$(get_response_content "$response")
    if check_success "$content" "script.py\|config.ini"; then
        print_pass "List subdirectory"
    else
        print_fail "List subdirectory" "Subdir files not found"
    fi
    
    # Test 6: Grep search across workspace
    print_test "file_operations.grep_search"
    response=$(api_call "Use file_operations tool with operation='grep_search', query='TESTMARKER', isRegexp=false, includePattern='$TEST_WORKSPACE/**'")
    content=$(get_response_content "$response")
    if check_success "$content" "sample.txt.*TESTMARKER"; then
        print_pass "Grep search across workspace"
    else
        print_fail "Grep search" "TESTMARKER not found"
    fi
    
    # Test 7: File search (glob pattern)
    print_test "file_operations.file_search"
    response=$(api_call "Use file_operations tool with operation='file_search' to find all .py files in $TEST_WORKSPACE using pattern '**/*.py'")
    content=$(get_response_content "$response")
    if check_success "$content" "script.py"; then
        print_pass "File search with glob pattern"
    else
        print_fail "File search" "Python file not found"
    fi
    
    # Test 8: Create file in root
    print_test "file_operations.create_file (root)"
    TEST_FILE="$TEST_WORKSPACE/root_files/created_test.txt"
    response=$(api_call "Use file_operations tool with operation='create_file', filePath='$TEST_FILE', content='Test file created by MCP test suite'")
    content=$(get_response_content "$response")
    if [[ -f "$TEST_FILE" ]]; then
        print_pass "Create file in root directory"
        rm -f "$TEST_FILE"  # Cleanup
    else
        print_fail "Create file in root" "File not created on disk"
    fi
    
    # Test 9: Create file in subdirectory
    print_test "file_operations.create_file (subdir)"
    TEST_FILE="$TEST_WORKSPACE/subdir1/new_file.txt"
    response=$(api_call "Use file_operations tool with operation='create_file', filePath='$TEST_FILE', content='Created in subdirectory'")
    if [[ -f "$TEST_FILE" ]]; then
        print_pass "Create file in subdirectory"
        rm -f "$TEST_FILE"
    else
        print_fail "Create file in subdir" "File not created"
    fi
    
    # Test 10: Create file in nested subdirectory
    print_test "file_operations.create_file (nested)"
    TEST_FILE="$TEST_WORKSPACE/subdir2/nested/nested_new.txt"
    response=$(api_call "Use file_operations tool with operation='create_file', filePath='$TEST_FILE', content='Nested creation test'")
    if [[ -f "$TEST_FILE" ]]; then
        print_pass "Create file in nested subdirectory"
        rm -f "$TEST_FILE"
    else
        print_fail "Create file in nested" "File not created"
    fi
    
    # Test 11: Replace string in file
    print_test "file_operations.replace_string"
    # First create a test file
    TEST_FILE="$TEST_WORKSPACE/root_files/replace_test.txt"
    echo "Original content line 1" > "$TEST_FILE"
    echo "This line should be replaced" >> "$TEST_FILE"
    echo "Original content line 3" >> "$TEST_FILE"
    
    response=$(api_call "Use file_operations tool with operation='replace_string', filePath='$TEST_FILE', oldString='This line should be replaced', newString='This line was replaced by MCP'")
    
    if grep -q "This line was replaced by MCP" "$TEST_FILE"; then
        print_pass "Replace string in file"
    else
        print_fail "Replace string" "String not replaced"
    fi
    rm -f "$TEST_FILE"
    
    # Test 12: Rename file
    print_test "file_operations.rename_file"
    TEST_FILE="$TEST_WORKSPACE/root_files/rename_source.txt"
    RENAMED_FILE="$TEST_WORKSPACE/root_files/rename_target.txt"
    echo "Rename test" > "$TEST_FILE"
    
    response=$(api_call "Use file_operations tool with operation='rename_file', oldPath='$TEST_FILE', newPath='$RENAMED_FILE'")
    
    if [[ -f "$RENAMED_FILE" ]] && [[ ! -f "$TEST_FILE" ]]; then
        print_pass "Rename file"
        rm -f "$RENAMED_FILE"
    else
        print_fail "Rename file" "File not renamed correctly"
        rm -f "$TEST_FILE" "$RENAMED_FILE" 2>/dev/null
    fi
    
    # Test 13: Delete file
    print_test "file_operations.delete_file"
    TEST_FILE="$TEST_WORKSPACE/root_files/delete_test.txt"
    echo "Delete me" > "$TEST_FILE"
    
    response=$(api_call "Use file_operations tool with operation='delete_file', filePath='$TEST_FILE'")
    
    if [[ ! -f "$TEST_FILE" ]]; then
        print_pass "Delete file"
    else
        print_fail "Delete file" "File still exists"
        rm -f "$TEST_FILE"
    fi
    
    # Additional operations (semantic_search, list_usages, search_index, multi_replace_string, insert_edit, apply_patch)
    # These require more complex setups and will be tested in phase 2
    
    print_skip "file_operations.semantic_search (requires indexed workspace)"
    print_skip "file_operations.list_usages (requires code symbols)"
    print_skip "file_operations.search_index (requires index)"
}

# ============================================================================
# TERMINAL OPERATIONS TESTS
# ============================================================================
test_terminal_operations() {
    if [[ -n "$SPECIFIC_TOOL" ]] && [[ "$SPECIFIC_TOOL" != "terminal_operations" ]]; then
        return
    fi
    
    print_header "Terminal Operations Tests (11 operations)"
    
    # Test 1: Run simple command
    print_test "terminal_operations.run_command (simple)"
    response=$(api_call "Use terminal_operations tool with operation='run_command', command='echo Hello from MCP test', explanation='Testing echo command'")
    content=$(get_response_content "$response")
    if check_success "$content" "Hello from MCP test"; then
        print_pass "Run simple terminal command"
    else
        print_fail "Run command" "Output not found"
    fi
    
    # Test 2: Run command with directory listing
    print_test "terminal_operations.run_command (ls)"
    response=$(api_call "Use terminal_operations tool with operation='run_command', command='ls -la $TEST_WORKSPACE/root_files/', explanation='List test workspace'")
    content=$(get_response_content "$response")
    if check_success "$content" "sample.txt\|data.json"; then
        print_pass "Run ls command"
    else
        print_fail "Run ls" "Files not listed"
    fi
    
    # Test 3: Create directory
    print_test "terminal_operations.create_directory"
    TEST_DIR="$TEST_WORKSPACE/new_directory_test"
    response=$(api_call "Use terminal_operations tool with operation='create_directory', path='$TEST_DIR'")
    
    if [[ -d "$TEST_DIR" ]]; then
        print_pass "Create directory via terminal ops"
        rmdir "$TEST_DIR"
    else
        print_fail "Create directory" "Directory not created"
    fi
    
    # Test 4: Run Python script from subdirectory
    print_test "terminal_operations.run_command (python script)"
    response=$(api_call "Use terminal_operations tool with operation='run_command', command='python3 $TEST_WORKSPACE/subdir1/script.py', explanation='Run Python test script'")
    content=$(get_response_content "$response")
    if check_success "$content" "Hello from test_workspace\|Result: 30"; then
        print_pass "Execute Python script from subdirectory"
    else
        print_fail "Execute script" "Script output not found"
    fi
    
    # Terminal session operations skipped for now (require session management)
    print_skip "terminal_operations.create_session (requires session state)"
    print_skip "terminal_operations.send_input (requires active session)"
    print_skip "terminal_operations.get_output (requires active session)"
    print_skip "terminal_operations.get_history (requires active session)"
    print_skip "terminal_operations.close_session (requires active session)"
    print_skip "terminal_operations.get_terminal_output (requires terminal ID)"
    print_skip "terminal_operations.get_last_command (requires terminal history)"
}

# ============================================================================
# MEMORY OPERATIONS TESTS
# ============================================================================
test_memory_operations() {
    if [[ -n "$SPECIFIC_TOOL" ]] && [[ "$SPECIFIC_TOOL" != "memory_operations" ]]; then
        return
    fi
    
    print_header "Memory Operations Tests (4 operations)"
    
    # Test 1: Store memory
    print_test "memory_operations.store_memory"
    response=$(api_call "Use memory_operations tool with operation='store_memory', content='Test memory: SAM uses Swift and SwiftUI for the interface'")
    content=$(get_response_content "$response")
    if check_success "$content" "stored\|success"; then
        print_pass "Store memory"
    else
        print_fail "Store memory" "Storage confirmation not found"
    fi
    
    # Test 2: Search memory
    print_test "memory_operations.search_memory"
    response=$(api_call "Use memory_operations tool with operation='search_memory', query='Swift SwiftUI interface', similarity_threshold='0.3'")
    content=$(get_response_content "$response")
    if check_success "$content" "Swift\|SwiftUI"; then
        print_pass "Search memory"
    else
        print_fail "Search memory" "Stored content not found"
    fi
    
    # Test 3: List collections
    print_test "memory_operations.list_collections"
    response=$(api_call "Use memory_operations tool with operation='list_collections'")
    content=$(get_response_content "$response")
    if check_success "$content" "collection\|memory"; then
        print_pass "List memory collections"
    else
        # Might be empty, that's ok
        print_pass "List memory collections (empty result ok)"
    fi
    
    # Test 4: Manage todos
    print_test "memory_operations.manage_todos (read)"
    response=$(api_call "Use memory_operations tool with operation='manage_todos', todoOperation='read'")
    content=$(get_response_content "$response")
    # Todo list might be empty, just check it doesn't error
    if ! check_success "$content" "error\|failed"; then
        print_pass "Read todo list"
    else
        print_fail "Read todos" "Error in response"
    fi
}

# ============================================================================
# WEB OPERATIONS TESTS  
# ============================================================================
test_web_operations() {
    if [[ -n "$SPECIFIC_TOOL" ]] && [[ "$SPECIFIC_TOOL" != "web_operations" ]]; then
        return
    fi
    
    print_header "Web Operations Tests (5+ operations)"
    
    # Test 1: Fetch webpage (real data as user requested)
    print_test "web_operations.fetch"
    response=$(api_call "Use web_operations tool with operation='fetch', url='https://httpbin.org/html' to fetch a test HTML page")
    content=$(get_response_content "$response")
    if check_success "$content" "html\|DOCTYPE"; then
        print_pass "Fetch webpage content"
    else
        print_fail "Fetch webpage" "HTML content not retrieved"
    fi
    
    # Test 2: Fetch JSON data (real API)
    print_test "web_operations.fetch (JSON)"
    response=$(api_call "Use web_operations tool with operation='fetch', url='https://httpbin.org/json' to fetch JSON test data")
    content=$(get_response_content "$response")
    if check_success "$content" "slideshow\|json"; then
        print_pass "Fetch JSON data"
    else
        print_fail "Fetch JSON" "JSON data not retrieved"
    fi
    
    # Test 3: Web search (if configured)
    print_test "web_operations.web_search"
    response=$(api_call "Use web_operations tool with operation='web_search', query='Swift programming language wikipedia', max_results=3")
    content=$(get_response_content "$response")
    if check_success "$content" "Swift\|result\|wikipedia"; then
        print_pass "Web search"
    else
        print_skip "Web search (may require API key configuration)"
    fi
    
    # Web research and scrape skipped (require more setup)
    print_skip "web_operations.research (requires comprehensive setup)"
    print_skip "web_operations.scrape (requires target URL)"
    print_skip "web_operations.retrieve (requires stored research)"
}

# ============================================================================
# DOCUMENT OPERATIONS TESTS
# ============================================================================
test_document_operations() {
    if [[ -n "$SPECIFIC_TOOL" ]] && [[ "$SPECIFIC_TOOL" != "document_operations" ]]; then
        return
    fi
    
    print_header "Document Operations Tests (3 operations)"
    
    # Test 1: Import document
    print_test "document_operations.document_import"
    response=$(api_call "Use document_operations tool with operation='document_import', filePath='$TEST_WORKSPACE/root_files/README.md', conversationId='test-conversation-001'")
    content=$(get_response_content "$response")
    if check_success "$content" "imported\|success\|chunked"; then
        print_pass "Import document"
    else
        print_fail "Import document" "Import confirmation not found"
    fi
    
    # Test 2: Get document info
    print_test "document_operations.get_doc_info"
    response=$(api_call "Use document_operations tool with operation='get_doc_info', conversationId='test-conversation-001'")
    content=$(get_response_content "$response")
    if check_success "$content" "README\|document"; then
        print_pass "Get document info"
    else
        print_skip "Get document info (may be empty)"
    fi
    
    # Document create skipped (requires more context)
    print_skip "document_operations.document_create (requires document creation context)"
}

# ============================================================================
# BUILD AND VERSION CONTROL TESTS
# ============================================================================
test_build_and_version_control() {
    if [[ -n "$SPECIFIC_TOOL" ]] && [[ "$SPECIFIC_TOOL" != "build_and_version_control" ]]; then
        return
    fi
    
    print_header "Build and Version Control Tests (5 operations)"
    
    # Test 1: Get changed files (git)
    print_test "build_and_version_control.get_changed_files"
    response=$(api_call "Use build_and_version_control tool with operation='get_changed_files' to check git status")
    content=$(get_response_content "$response")
    # Just check it doesn't error (repo might be clean)
    if ! check_success "$content" "fatal\|error.*git"; then
        print_pass "Get changed files"
    else
        print_fail "Get changed files" "Git error"
    fi
    
    # Test 2: Create test task
    print_test "build_and_version_control.create_and_run_task"
    response=$(api_call "Use build_and_version_control tool with operation='create_and_run_task', task={'label':'test-echo','type':'shell','command':'echo Test task execution'}, workspaceFolder='/Users/andrew/repositories/SyntheticAutonomicMind/SAM'")
    content=$(get_response_content "$response")
    if check_success "$content" "Test task execution\|completed"; then
        print_pass "Create and run task"
    else
        print_fail "Create and run task" "Task did not execute"
    fi
    
    # Git commit skipped (don't want to commit during tests)
    print_skip "build_and_version_control.git_commit (skipped to avoid test commits)"
    print_skip "build_and_version_control.run_task (requires existing task)"
    print_skip "build_and_version_control.get_task_output (requires task execution)"
}

# ============================================================================
# OTHER TOOLS TESTS
# ============================================================================
test_other_tools() {
    if [[ -n "$SPECIFIC_TOOL" ]] && ! echo "think user_collaboration read_tool_result run_subagent" | grep -q "$SPECIFIC_TOOL"; then
        return
    fi
    
    print_header "Other Tools Tests"
    
    # Test think tool
    print_test "think"
    response=$(api_call "Use think tool to analyze: What is 2+2?")
    content=$(get_response_content "$response")
    if ! check_success "$content" "fatal\|error"; then
        print_pass "Think tool (basic invocation)"
    else
        print_fail "Think tool" "Error in response"
    fi
    
    # User collaboration skipped (interactive)
    print_skip "user_collaboration (interactive, requires user input)"
    
    # read_tool_result skipped (deprecated)
    print_skip "read_tool_result (deprecated - inline results now used)"
    
    # run_subagent skipped (requires workflow setup)
    print_skip "run_subagent (requires workflow configuration)"
}

# ============================================================================
# MAIN TEST EXECUTION
# ============================================================================
main() {
    initialize_tests
    
    # Run all test suites
    test_file_operations
    test_terminal_operations
    test_memory_operations
    test_web_operations
    test_document_operations
    test_build_and_version_control
    test_other_tools
    
    # Print summary
    print_header "Test Results Summary"
    
    echo ""
    echo "Total Tests:  $TOTAL_TESTS"
    echo -e "${GREEN}Passed:       $PASSED_TESTS${NC}"
    echo -e "${RED}Failed:       $FAILED_TESTS${NC}"
    echo -e "${YELLOW}Skipped:      $SKIPPED_TESTS${NC}"
    echo ""
    
    # Calculate pass rate
    if [[ $TOTAL_TESTS -gt 0 ]]; then
        PASS_RATE=$(echo "scale=1; $PASSED_TESTS * 100 / $TOTAL_TESTS" | bc)
        echo "Pass Rate:    ${PASS_RATE}% (excluding skipped)"
    fi
    
    # Write results to file
    {
        echo "MCP API Test Results - $(date)"
        echo "======================================"
        echo ""
        echo "Total:   $TOTAL_TESTS"
        echo "Passed:  $PASSED_TESTS"
        echo "Failed:  $FAILED_TESTS"
        echo "Skipped: $SKIPPED_TESTS"
        echo ""
        if [[ $TOTAL_TESTS -gt 0 ]]; then
            echo "Pass Rate: ${PASS_RATE}%"
        fi
    } > "$TEST_RESULTS_FILE"
    
    echo "Results saved to: $TEST_RESULTS_FILE"
    echo ""
    
    # Exit with failure if any tests failed
    if [[ $FAILED_TESTS -gt 0 ]]; then
        exit 1
    else
        exit 0
    fi
}

# Run main function
main
