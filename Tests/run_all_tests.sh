#!/usr/bin/env bash
#
# SAM Test Suite Runner
# =====================
#
# Runs Swift XCTest unit tests.
#
# Usage:
#   ./run_all_tests.sh              # Run all tests
#   ./run_all_tests.sh --verbose    # Verbose output
#   ./run_all_tests.sh --filter X   # Run specific test suite/class
#

set -e

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# Options
VERBOSE=false
FILTER=""

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --verbose|-v)
            VERBOSE=true
            shift
            ;;
        --filter)
            FILTER="$2"
            shift 2
            ;;
        --help|-h)
            echo "SAM Test Suite Runner"
            echo ""
            echo "Usage: $0 [options]"
            echo ""
            echo "Options:"
            echo "  --verbose, -v   Verbose output"
            echo "  --filter, -f X  Run only tests matching filter X"
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
    echo -e "${BLUE}══════ ${1} ══════${NC}"
}

print_section() {
    echo ""
    echo -e "${CYAN}─── $1 ───${NC}"
}

# Main execution
main() {
    print_header "SAM Test Suite Runner"
    echo "Project: $PROJECT_ROOT"
    echo "Date: $(date)"
    echo ""

    cd "$PROJECT_ROOT"

    # Build tests
    print_section "Building Tests"
    local build_args=""
    if [[ "$VERBOSE" == "true" ]]; then
        build_args="--verbose"
    fi

    if ! swift build --build-tests 2>&1; then
        echo -e "${RED}Failed to build tests${NC}"
        exit 1
    fi
    echo -e "${GREEN}Tests built successfully${NC}"

    # Run tests
    print_section "Executing Tests"

    local test_args=""
    if [[ "$VERBOSE" == "true" ]]; then
        test_args="--verbose"
    fi
    if [[ -n "$FILTER" ]]; then
        test_args="$test_args --filter $FILTER"
    fi

    echo "Running: swift test $test_args"
    echo ""

    if ! swift test $test_args 2>&1; then
        echo ""
        echo -e "${RED}Some tests failed${NC}"
        exit 1
    fi

    echo ""
    echo -e "${GREEN}══════ All tests passed ══════${NC}"
    exit 0
}

main
