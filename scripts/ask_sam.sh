#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

# ask_sam.sh - Collaborate with SAM for diagnostics
# Enhanced version supporting large prompts, special characters, and model selection
#
# Usage:
#   ./ask_sam.sh <conversation-id> [--model model-name] [--token api-token] [query]
#   ./ask_sam.sh <conversation-id> --model gpt-4 'query'
#   ./ask_sam.sh <conversation-id> --token YOUR-TOKEN 'query'
#   ./ask_sam.sh <conversation-id> --model gpt-4 < file.txt
#   echo "query" | ./ask_sam.sh <conversation-id> --model gpt-4
#
# Environment Variables:
#   SAM_API_TOKEN - API token for authentication (alternative to --token)

CONVERSATION_ID="${1:-}"
MODEL="gpt-5-mini"  # Default model
API_TOKEN="${SAM_API_TOKEN:-}"  # Read from environment variable if set
TEMP_FILE=$(mktemp)
trap "rm -f $TEMP_FILE" EXIT

# Check if conversation ID provided
if [ -z "$CONVERSATION_ID" ] || [ "$CONVERSATION_ID" = "--help" ]; then
  cat << 'USAGE'
Usage: ./ask_sam.sh <conversation-id> [--model model-name] [--token api-token] [query]

OPTIONS:
--------
--model MODEL    Specify model to use (default: gpt-4)
                 Examples: gpt-4, gpt-3.5-turbo, llama/model, mlx/model
--token TOKEN    API authentication token (can also use SAM_API_TOKEN env var)
                 Get token from: SAM Preferences → API Server → API Authentication

AUTHENTICATION:
---------------
SAM now requires authentication for all API requests. You can provide the token via:

1. Command line: --token YOUR-TOKEN
2. Environment variable: export SAM_API_TOKEN="YOUR-TOKEN"
3. Get your token from SAM Preferences → API Server → Copy button

Example: ./ask_sam.sh CA706D86 --token abc123-def456 'Which tools did you use?'

METHODS:
--------
1. Direct query:
   ./ask_sam.sh CA706D86 --token abc123 'Which tools did you use?'
   ./ask_sam.sh CA706D86 --model gpt-3.5-turbo --token abc123 'Quick test'

2. From file:
   SAM_API_TOKEN=abc123 ./ask_sam.sh CA706D86 < prompt.txt
   ./ask_sam.sh CA706D86 --model gpt-4 --token abc123 < analysis.txt

3. Pipe input:
   echo "query" | SAM_API_TOKEN=abc123 ./ask_sam.sh CA706D86
   cat file | ./ask_sam.sh CA706D86 --model gpt-4 --token abc123

4. Here-doc:
   ./ask_sam.sh CA706D86 --model gpt-4 --token abc123 <<'QUERY'
   Multi-line query with special characters
   QUERY

COMMON DIAGNOSTIC QUERIES:
--------------------------
- 'Which exact tools did you use? What results did you get? Be verbose.'
- 'Which search queries worked and which failed? List exact query strings.'
- 'What patterns did you notice in what worked vs what didn't work?'
- 'Based on what you observed, what do you think is causing this issue?'

USAGE
  exit 1
fi

shift  # Remove conversation ID from args

# Parse --model and --token if provided
while [ $# -gt 0 ]; do
  case "$1" in
    --model)
      if [ -z "$2" ]; then
        echo "ERROR: --model requires a model name"
        exit 1
      fi
      MODEL="$2"
      shift 2
      ;;
    --token)
      if [ -z "$2" ]; then
        echo "ERROR: --token requires a token value"
        exit 1
      fi
      API_TOKEN="$2"
      shift 2
      ;;
    *)
      # First non-option argument is the query
      break
      ;;
  esac
done

# Get query from remaining args, stdin, or file
if [ -n "$1" ]; then
  # Query provided as argument
  QUERY="$1"
elif [ ! -t 0 ]; then
  # Reading from stdin (pipe or redirect)
  QUERY=$(cat)
else
  echo "ERROR: No query provided"
  echo "Use: ./ask_sam.sh --help for usage information"
  exit 1
fi

if [ -z "$QUERY" ]; then
  echo "ERROR: Query is empty"
  exit 1
fi

# Check if API token is provided
if [ -z "$API_TOKEN" ]; then
  echo "ERROR: API token required for authentication"
  echo ""
  echo "SAM now requires authentication for all API requests."
  echo "Get your token from: SAM Preferences → API Server → API Authentication"
  echo ""
  echo "Provide token via:"
  echo "  --token YOUR-TOKEN                (command line option)"
  echo "  export SAM_API_TOKEN=YOUR-TOKEN   (environment variable)"
  echo ""
  echo "Example: ./ask_sam.sh $CONVERSATION_ID --token abc123-def456 'query'"
  exit 1
fi

# Check if SAM server is running
if ! curl -s http://127.0.0.1:8080/health > /dev/null 2>&1; then
  echo "ERROR: SAM server is not running or not responding"
  echo "Start SAM server first:"
  echo "  pkill -9 SAM"
  echo "  make build-debug"
  echo "  nohup .build/Build/Products/Debug/SAM > sam_server.log 2>&1 & sleep 3"
  exit 1
fi

# Display query info (truncate if very long)
QUERY_LENGTH=${#QUERY}
if [ $QUERY_LENGTH -gt 100 ]; then
  QUERY_PREVIEW="${QUERY:0:100}... (${QUERY_LENGTH} chars total)"
else
  QUERY_PREVIEW="$QUERY"
fi

echo "Asking SAM (conversation: $CONVERSATION_ID, model: $MODEL)..."
echo "Query: $QUERY_PREVIEW"
echo ""
echo "========================================="
echo "SAM'S RESPONSE:"
echo "========================================="

# Create JSON payload with proper escaping (jq handles all special characters)
PAYLOAD=$(jq -n \
# SAM returns streaming responses, parse SSE format
# Write to output file to detect if we got any content
OUTPUT_FILE=$(mktemp)
trap "rm -f $TEMP_FILE $OUTPUT_FILE" EXIT

curl -s -X POST http://127.0.0.1:8080/api/chat/completions \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $API_TOKEN" \
  -d @"$TEMP_FILE" | while IFS= read -r line; do
    # Parse SSE format: "data: {json}"
    if [[ "$line" == data:* ]]; then
      json_data="${line#data: }"
      if [ "$json_data" != "[DONE]" ]; then
        # Extract content delta from streaming response
        content=$(echo "$json_data" | jq -jr '.choices[]?.delta?.content // empty' 2>/dev/null)
        if [ -n "$content" ]; then
          echo -n "$content"
          echo -n "$content" >> "$OUTPUT_FILE"
        fi
      fi
    fi
  done

# Check if we got any response
if [ ! -s "$OUTPUT_FILE" ]; then
  echo ""
  echo ""
  echo "WARNING: No response received from SAM"
  echo "This could mean:"
  echo "  - Invalid API token (check token in SAM Preferences)"
  echo "  - SAM server crashed or stopped responding"
  echo "  - Conversation ID '$CONVERSATION_ID' not found"
  echo "  - SAM encountered an error processing the query"
  echo "  - Model '$MODEL' not available (check API keys in Preferences)"
  echo ""
  echo "Check sam_server.log for details:"
  echo "  tail -50 sam_server.log | grep -i error"
else
  echo ""
fi

echo ""
echo "========================================="
  echo "WARNING: No response received from SAM"
  echo "This could mean:"
  echo "  - SAM server crashed or stopped responding"
  echo "  - Conversation ID '$CONVERSATION_ID' not found"
  echo "  - SAM encountered an error processing the query"
  echo "  - Model '$MODEL' not available (check API keys in Preferences)"
  echo ""
  echo "Check sam_server.log for details:"
  echo "  tail -50 sam_server.log | grep -i error"
else
  echo ""
fi

echo ""
echo "========================================="
