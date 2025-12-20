#!/usr/bin/env bash
#
# SAM Comprehensive Test Suite Runner
# ===================================
#
# Runs both unit tests (Swift XCTest) and E2E tests (Python/curl API tests)
#
# Usage:
#   ./run_all_tests.sh              # Run all tests
#   ./run_all_tests.sh --unit       # Run only unit tests
#   ./run_all_tests.sh --e2e        # Run only E2E tests
#   ./run_all_tests.sh --verbose    # Verbose output
#   ./run_all_tests.sh --tool NAME  # Test specific tool (E2E only)
#

set -e

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BUILD_DIR="$PROJECT_ROOT/.build/Build/Products/Debug"
SAM_APP="$BUILD_DIR/SAM"
LOG_FILE="$PROJECT_ROOT/sam_server.log"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# Options
RUN_UNIT=true
RUN_E2E=true
VERBOSE=false
SPECIFIC_TOOL=""
KEEP_SERVER=false

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --unit)
            RUN_UNIT=true
            RUN_E2E=false
            shift
            ;;
        --e2e)
            RUN_UNIT=false
            RUN_E2E=true
            shift
            ;;
        --verbose|-v)
            VERBOSE=true
            shift
            ;;
        --tool|-t)
            SPECIFIC_TOOL="$2"
            shift 2
            ;;
        --keep-server)
            KEEP_SERVER=true
            shift
            ;;
        --help|-h)
            echo "SAM Comprehensive Test Suite Runner"
            echo ""
            echo "Usage: $0 [options]"
            echo ""
            echo "Options:"
            echo "  --unit          Run only unit tests (Swift XCTest)"
            echo "  --e2e           Run only E2E tests (API tests)"
            echo "  --verbose, -v   Verbose output"
            echo "  --tool, -t NAME Test specific tool (E2E only)"
            echo "  --keep-server   Don't stop SAM server after tests"
            echo "  --help, -h      Show this help"
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

# Functions
print_header() {
    echo ""
    echo -e "${BLUE}════════════════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}$1${NC}"
    echo -e "${BLUE}════════════════════════════════════════════════════════════${NC}"
}

print_section() {
    echo ""
    echo -e "${CYAN}─── $1 ───${NC}"
}

check_sam_running() {
    curl -s --max-time 2 -o /dev/null http://127.0.0.1:8080/api/chat/completions 2>/dev/null
    return $?
}

start_sam_server() {
    print_section "Starting SAM Server"
    
    # Kill existing SAM processes
    pkill -9 SAM 2>/dev/null || true
    sleep 1
    
    # Check if built
    if [[ ! -f "$SAM_APP" ]]; then
        echo -e "${YELLOW}SAM not built, building...${NC}"
        cd "$PROJECT_ROOT"
        make build-debug
    fi
    
    # Start server
    echo "Starting SAM server..."
    nohup "$SAM_APP" > "$LOG_FILE" 2>&1 &
    SAM_PID=$!
    echo "$SAM_PID" > "$PROJECT_ROOT/sam.pid"
    
    # Wait for server to start
    for i in {1..30}; do
        if check_sam_running; then
            echo -e "${GREEN}SAM server started (PID: $SAM_PID)${NC}"
            return 0
        fi
        sleep 1
    done
    
    echo -e "${RED}Failed to start SAM server${NC}"
    cat "$LOG_FILE" | tail -20
    return 1
}

stop_sam_server() {
    if [[ "$KEEP_SERVER" == "true" ]]; then
        echo -e "${YELLOW}Keeping SAM server running (--keep-server)${NC}"
        return 0
    fi
    
    print_section "Stopping SAM Server"
    
    if [[ -f "$PROJECT_ROOT/sam.pid" ]]; then
        SAM_PID=$(cat "$PROJECT_ROOT/sam.pid")
        kill "$SAM_PID" 2>/dev/null || true
        rm -f "$PROJECT_ROOT/sam.pid"
    fi
    
    pkill -9 SAM 2>/dev/null || true
    echo "SAM server stopped"
}

run_unit_tests() {
    print_header "Running Unit Tests (Swift XCTest)"
    
    cd "$PROJECT_ROOT"
    
    # Build tests
    print_section "Building Tests"
    swift build --build-tests 2>&1 | tee build_tests.log
    
    if [[ ${PIPESTATUS[0]} -ne 0 ]]; then
        echo -e "${RED}Failed to build tests${NC}"
        return 1
    fi
    
    # Run tests
    print_section "Executing Tests"
    
    local test_args=""
    if [[ "$VERBOSE" == "true" ]]; then
        test_args="--verbose"
    fi
    
    # Run specific test targets
    local unit_test_result=0
    
    echo -e "\n${CYAN}Testing MCPFramework...${NC}"
    swift test --filter MCPFrameworkTests $test_args 2>&1 || unit_test_result=1
    
    echo -e "\n${CYAN}Testing MCPToolExecution...${NC}"
    swift test --filter MCPToolExecutionTests $test_args 2>&1 || unit_test_result=1
    
    echo -e "\n${CYAN}Testing APIFramework...${NC}"
    swift test --filter APIFrameworkTests $test_args 2>&1 || unit_test_result=1
    
    if [[ $unit_test_result -eq 0 ]]; then
        echo -e "\n${GREEN}✓ All unit tests passed${NC}"
    else
        echo -e "\n${RED}✗ Some unit tests failed${NC}"
    fi
    
    return $unit_test_result
}

run_e2e_tests() {
    print_header "Running E2E Tests (API Tests)"
    
    # Ensure SAM is running
    if ! check_sam_running; then
        start_sam_server || return 1
    fi
    
    cd "$PROJECT_ROOT/Tests/e2e"
    
    # Build test arguments
    local test_args=""
    if [[ "$VERBOSE" == "true" ]]; then
        test_args="$test_args --verbose"
    fi
    if [[ -n "$SPECIFIC_TOOL" ]]; then
        test_args="$test_args --tool $SPECIFIC_TOOL"
    fi
    
    print_section "Executing E2E Tests"
    
    python3 mcp_e2e_tests.py $test_args
    local e2e_result=$?
    
    if [[ $e2e_result -eq 0 ]]; then
        echo -e "\n${GREEN}✓ All E2E tests passed${NC}"
    else
        echo -e "\n${RED}✗ Some E2E tests failed${NC}"
    fi
    
    return $e2e_result
}

run_bash_api_tests() {
    print_header "Running Bash API Tests (Legacy)"
    
    # Ensure SAM is running
    if ! check_sam_running; then
        start_sam_server || return 1
    fi
    
    cd "$PROJECT_ROOT/Tests"
    
    if [[ -f "mcp_api_tests.sh" ]]; then
        local test_args=""
        if [[ "$VERBOSE" == "true" ]]; then
            test_args="--verbose"
        fi
        if [[ -n "$SPECIFIC_TOOL" ]]; then
            test_args="$test_args --tool $SPECIFIC_TOOL"
        fi
        
        ./mcp_api_tests.sh $test_args
        return $?
    else
        echo "Bash API tests not found, skipping"
        return 0
    fi
}

# Main execution
main() {
    print_header "SAM Comprehensive Test Suite"
    echo "Date: $(date)"
    echo "Project: $PROJECT_ROOT"
    echo ""
    
    local overall_result=0
    local unit_result=0
    local e2e_result=0
    
    # Run unit tests
    if [[ "$RUN_UNIT" == "true" ]]; then
        run_unit_tests
        unit_result=$?
        if [[ $unit_result -ne 0 ]]; then
            overall_result=1
        fi
    fi
    
    # Run E2E tests
    if [[ "$RUN_E2E" == "true" ]]; then
        run_e2e_tests
        e2e_result=$?
        if [[ $e2e_result -ne 0 ]]; then
            overall_result=1
        fi
    fi
    
    # Stop SAM server
    if [[ "$RUN_E2E" == "true" ]]; then
        stop_sam_server
    fi
    
    # Final summary
    print_header "Test Suite Summary"
    
    if [[ "$RUN_UNIT" == "true" ]]; then
        if [[ $unit_result -eq 0 ]]; then
            echo -e "Unit Tests:  ${GREEN}PASSED${NC}"
        else
            echo -e "Unit Tests:  ${RED}FAILED${NC}"
        fi
    fi
    
    if [[ "$RUN_E2E" == "true" ]]; then
        if [[ $e2e_result -eq 0 ]]; then
            echo -e "E2E Tests:   ${GREEN}PASSED${NC}"
        else
            echo -e "E2E Tests:   ${RED}FAILED${NC}"
        fi
    fi
    
    echo ""
    
    if [[ $overall_result -eq 0 ]]; then
        echo -e "${GREEN}════════════════════════════════════════════════════════════${NC}"
        echo -e "${GREEN}All tests passed!${NC}"
        echo -e "${GREEN}════════════════════════════════════════════════════════════${NC}"
    else
        echo -e "${RED}════════════════════════════════════════════════════════════${NC}"
        echo -e "${RED}Some tests failed. Check output above for details.${NC}"
        echo -e "${RED}════════════════════════════════════════════════════════════${NC}"
    fi
    
    exit $overall_result
}

# Trap to ensure cleanup
trap stop_sam_server EXIT

# Run main
main
