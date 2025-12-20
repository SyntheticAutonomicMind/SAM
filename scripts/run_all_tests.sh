#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

# SAM Comprehensive Test Runner
# Runs both Swift unit tests and Python E2E tests

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color
BOLD='\033[1m'

# Test results
SWIFT_TESTS_PASSED=0
SWIFT_TESTS_FAILED=0
E2E_TESTS_PASSED=0
E2E_TESTS_FAILED=0
E2E_TESTS_SKIPPED=0

echo -e "${BOLD}${CYAN}╔═══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}${CYAN}║             SAM COMPREHENSIVE TEST SUITE                       ║${NC}"
echo -e "${BOLD}${CYAN}╚═══════════════════════════════════════════════════════════════╝${NC}"
echo ""

# Parse arguments
SWIFT_ONLY=false
E2E_ONLY=false
VERBOSE=false

while [[ "$#" -gt 0 ]]; do
    case $1 in
        --swift-only) SWIFT_ONLY=true ;;
        --e2e-only) E2E_ONLY=true ;;
        --verbose) VERBOSE=true ;;
        --help)
            echo "Usage: $0 [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --swift-only    Run only Swift unit tests"
            echo "  --e2e-only      Run only Python E2E tests"
            echo "  --verbose       Show detailed test output"
            echo "  --help          Show this help message"
            exit 0
            ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
    shift
done

# Function to run Swift tests
run_swift_tests() {
    echo -e "${BOLD}${BLUE}┌─────────────────────────────────────────────────────────────────┐${NC}"
    echo -e "${BOLD}${BLUE}│ SWIFT UNIT TESTS                                                │${NC}"
    echo -e "${BOLD}${BLUE}└─────────────────────────────────────────────────────────────────┘${NC}"
    echo ""
    
    cd "$PROJECT_ROOT"
    
    if [ "$VERBOSE" = true ]; then
        swift test 2>&1 | tee /tmp/swift_test_output.log
    else
        swift test 2>&1 | tee /tmp/swift_test_output.log | grep -E "^Test|passed|failed|Executed"
    fi
    
    # Parse results
    local result_line=$(grep "^Test Suite 'SAMPackageTests.xctest'" /tmp/swift_test_output.log | tail -1)
    if echo "$result_line" | grep -q "passed"; then
        SWIFT_TESTS_PASSED=$(echo "$result_line" | grep -oE "Executed [0-9]+" | grep -oE "[0-9]+")
        SWIFT_TESTS_FAILED=0
        echo -e "${GREEN}✓ Swift Unit Tests: All $SWIFT_TESTS_PASSED tests passed${NC}"
    else
        SWIFT_TESTS_PASSED=$(echo "$result_line" | grep -oE "Executed [0-9]+" | grep -oE "[0-9]+" | head -1)
        SWIFT_TESTS_FAILED=$(echo "$result_line" | grep -oE "with [0-9]+ failures" | grep -oE "[0-9]+" | head -1)
        echo -e "${RED}✗ Swift Unit Tests: $SWIFT_TESTS_FAILED failed out of $SWIFT_TESTS_PASSED${NC}"
    fi
    echo ""
}

# Function to check if SAM is running
check_sam_running() {
    local max_retries=3
    local retry=0
    
    while [ $retry -lt $max_retries ]; do
        if curl -s -X POST "http://127.0.0.1:8080/api/chat/completions" -H "Content-Type: application/json" -d '{"model":"test","messages":[]}' 2>/dev/null | grep -q "model"; then
            return 0
        fi
        sleep 2
        retry=$((retry + 1))
    done
    return 1
}

# Function to run E2E tests
run_e2e_tests() {
    echo -e "${BOLD}${BLUE}┌─────────────────────────────────────────────────────────────────┐${NC}"
    echo -e "${BOLD}${BLUE}│ PYTHON E2E TESTS                                                │${NC}"
    echo -e "${BOLD}${BLUE}└─────────────────────────────────────────────────────────────────┘${NC}"
    echo ""
    
    # Check if SAM is running
    echo -e "${YELLOW}Checking if SAM server is running...${NC}"
    if ! check_sam_running; then
        echo -e "${RED}✗ SAM server is not running. Please start SAM first:${NC}"
        echo -e "${CYAN}  make build-debug${NC}"
        echo -e "${CYAN}  .build/Build/Products/Debug/SAM${NC}"
        return 1
    fi
    echo -e "${GREEN}✓ SAM server is running${NC}"
    echo ""
    
    # Run E2E tests
    cd "$PROJECT_ROOT"
    if [ "$VERBOSE" = true ]; then
        python3 Tests/e2e/mcp_e2e_tests.py 2>&1 | tee /tmp/e2e_test_output.log
    else
        python3 Tests/e2e/mcp_e2e_tests.py 2>&1 | tee /tmp/e2e_test_output.log | grep -E "^TEST SUMMARY|^Total:|^Passed:|^Failed:|^Skipped:|Pass Rate:|✓ PASS|✗ FAIL|⊘ SKIP"
    fi
    
    # Parse results from log
    E2E_TESTS_PASSED=$(grep "^Passed:" /tmp/e2e_test_output.log | grep -oE "[0-9]+" | head -1 || echo "0")
    E2E_TESTS_FAILED=$(grep "^Failed:" /tmp/e2e_test_output.log | grep -oE "[0-9]+" | head -1 || echo "0")
    E2E_TESTS_SKIPPED=$(grep "^Skipped:" /tmp/e2e_test_output.log | grep -oE "[0-9]+" | head -1 || echo "0")
    
    echo ""
}

# Function to print final summary
print_summary() {
    echo ""
    echo -e "${BOLD}${CYAN}╔═══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}${CYAN}║                     FINAL TEST SUMMARY                         ║${NC}"
    echo -e "${BOLD}${CYAN}╚═══════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    
    local total_passed=$((SWIFT_TESTS_PASSED + E2E_TESTS_PASSED))
    local total_failed=$((SWIFT_TESTS_FAILED + E2E_TESTS_FAILED))
    local total=$((total_passed + total_failed + E2E_TESTS_SKIPPED))
    
    echo -e "${BOLD}Swift Unit Tests:${NC}"
    echo -e "  Passed:  ${GREEN}$SWIFT_TESTS_PASSED${NC}"
    echo -e "  Failed:  ${RED}$SWIFT_TESTS_FAILED${NC}"
    echo ""
    
    echo -e "${BOLD}Python E2E Tests:${NC}"
    echo -e "  Passed:  ${GREEN}$E2E_TESTS_PASSED${NC}"
    echo -e "  Failed:  ${RED}$E2E_TESTS_FAILED${NC}"
    echo -e "  Skipped: ${YELLOW}$E2E_TESTS_SKIPPED${NC}"
    echo ""
    
    echo -e "${BOLD}────────────────────────────────${NC}"
    echo -e "${BOLD}Total Tests:    $total${NC}"
    echo -e "${BOLD}Total Passed:   ${GREEN}$total_passed${NC}"
    echo -e "${BOLD}Total Failed:   ${RED}$total_failed${NC}"
    echo -e "${BOLD}Total Skipped:  ${YELLOW}$E2E_TESTS_SKIPPED${NC}"
    echo ""
    
    if [ "$total_failed" -eq 0 ]; then
        local pass_rate=100
        if [ "$total" -gt 0 ]; then
            pass_rate=$(echo "scale=1; ($total_passed * 100) / ($total - $E2E_TESTS_SKIPPED)" | bc)
        fi
        echo -e "${GREEN}${BOLD}✓ ALL TESTS PASSED! Pass Rate: ${pass_rate}%${NC}"
        return 0
    else
        local pass_rate=$(echo "scale=1; ($total_passed * 100) / ($total - $E2E_TESTS_SKIPPED)" | bc)
        echo -e "${RED}${BOLD}✗ SOME TESTS FAILED. Pass Rate: ${pass_rate}%${NC}"
        return 1
    fi
}

# Main execution
if [ "$E2E_ONLY" = false ]; then
    run_swift_tests
fi

if [ "$SWIFT_ONLY" = false ]; then
    run_e2e_tests
fi

print_summary
