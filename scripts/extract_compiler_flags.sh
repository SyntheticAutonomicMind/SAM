#!/bin/bash
# Extract Swift compiler flags from build log
# Usage: ./scripts/extract_compiler_flags.sh <build_log_file>

set -e

if [ "$#" -ne 1 ]; then
    echo "Usage: $0 <build_log_file>"
    echo "Example: $0 ~/Downloads/logs_*/\"0_Build SAM.txt\""
    exit 1
fi

LOG_FILE="$1"

if [ ! -f "$LOG_FILE" ]; then
    echo "Error: File not found: $LOG_FILE"
    exit 1
fi

echo "=== Extracting Swift Compiler Flags ==="
echo "Source: $LOG_FILE"
echo ""

# Extract swift-frontend commands
echo "--- Swift Frontend Invocations ---"
grep "swift-frontend" "$LOG_FILE" | head -3 | while read -r line; do
    echo "$line" | tr ' ' '\n' | grep -E "^-" | sort | uniq
    echo "---"
done

# Extract specific concurrency-related flags
echo ""
echo "--- Concurrency-Related Flags ---"
grep -E "swift-version|concurrency|sendable|isolation|actor" "$LOG_FILE" | grep "^\s*-" | sort | uniq || echo "(none found)"

# Extract SAM-specific compilation
echo ""
echo "--- SAM Target Compilation ---"
grep "ConversationEngine" "$LOG_FILE" | grep "swiftc\|swift-frontend" | head -2

echo ""
echo "=== Done ==="
