#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

# ask_sam.sh - Collaborate with SAM for diagnostics
# Enhanced version supporting large prompts, special characters, and model selection
#
# Usage:
#   ./ask_sam.sh [--uuid conversation-id] [--model model-name] [--token api-token] [query]
#   ./ask_sam.sh --model gpt-4 'query'  # Auto-generates UUID
#   ./ask_sam.sh --uuid ABC123 --token YOUR-TOKEN 'query'
#   ./ask_sam.sh --model gpt-4 < file.txt
#   echo "query" | ./ask_sam.sh --model gpt-4
#
# Environment Variables:
#   SAM_API_TOKEN - API token for authentication (alternative to --token)

# Default values
CONVERSATION_ID=""  # Will auto-generate if not provided
MODEL="gpt-5-mini"  # Default model
API_TOKEN="${SAM_API_TOKEN:-}"  # Read from environment variable if set
TEMP_FILE=$(mktemp)
OUTPUT_FILE=$(mktemp)
trap "rm -f $TEMP_FILE $OUTPUT_FILE" EXIT

# Check for help flag first
if [ "$1" = "--help" ] || [ "$1" = "-h" ]; then
  cat << 'USAGE'
Usage: ./ask_sam.sh [OPTIONS] [query]

OPTIONS:
--------
--uuid UUID      Conversation UUID (auto-generated if not provided)
--model MODEL    Specify model to use (default: gpt-4o-mini)
                 Examples: gpt-4o-mini, gpt-4o, claude-3-5-sonnet-20241022, o1-mini
--token TOKEN    API authentication token (can also use SAM_API_TOKEN env var)
                 Get token from: SAM Preferences → API Server → API Authentication

AUTHENTICATION:
---------------
SAM requires authentication for all API requests. Provide the token via:

1. Command line: --token YOUR-TOKEN
2. Environment variable: export SAM_API_TOKEN="YOUR-TOKEN"
3. Get your token from SAM Preferences → API Server → Copy button

METHODS:
--------
1. Auto-generated conversation (recommended):
   ./ask_sam.sh --token abc123 'Which tools did you use?'
   ./ask_sam.sh --model gpt-4o --token abc123 'Quick test'

2. Specific conversation UUID:
   ./ask_sam.sh --uuid CA706D86 --token abc123 'Follow-up question'

3. From file:
   SAM_API_TOKEN=abc123 ./ask_sam.sh < prompt.txt
   ./ask_sam.sh --model gpt-4o --token abc123 < analysis.txt

4. Pipe input:
   echo "query" | SAM_API_TOKEN=abc123 ./ask_sam.sh
   cat file | ./ask_sam.sh --model gpt-4o --token abc123

5. Here-doc:
   ./ask_sam.sh --model gpt-4o --token abc123 <<'QUERY'
   Multi-line query with special characters
   QUERY

COMMON DIAGNOSTIC QUERIES:
--------------------------
- 'Which exact tools did you use? What results did you get? Be verbose.'
- 'Which search queries worked and which failed? List exact query strings.'
- 'What patterns did you notice in what worked vs what didn't work?'
- 'Based on what you observed, what do you think is causing this issue?'

USAGE
  exit 0
fi

# Parse command line options
while [ $# -gt 0 ]; do
  case "$1" in
    --uuid)
      if [ -z "$2" ]; then
        echo "ERROR: --uuid requires a UUID value"
        exit 1
      fi
      CONVERSATION_ID="$2"
      shift 2
      ;;
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
    -*)
      echo "ERROR: Unknown option: $1"
      echo "Use: ./ask_sam.sh --help for usage information"
      exit 1
      ;;
    *)
      # First non-option argument is the query
      break
      ;;
  esac
done

# Auto-generate conversation UUID if not provided
if [ -z "$CONVERSATION_ID" ]; then
  CONVERSATION_ID=$(uuidgen)
  echo "Auto-generated conversation UUID: $CONVERSATION_ID"
  echo ""
fi

# Validate API token
if [ -z "$API_TOKEN" ]; then
  echo "ERROR: API token required for authentication"
  echo ""
  echo "SAM requires authentication for all API requests."
  echo "Get your token from: SAM Preferences → API Server → API Authentication"
  echo ""
  echo "Provide token via:"
  echo "  --token YOUR-TOKEN                (command line option)"
  echo "  export SAM_API_TOKEN=YOUR-TOKEN   (environment variable)"
  echo ""
  echo "Example: ./ask_sam.sh --token abc123-def456 'query'"
  exit 1
fi

# Validate conversation UUID format
if ! echo "$CONVERSATION_ID" | grep -qE '^[A-F0-9]{8}(-[A-F0-9]{4}){3}-[A-F0-9]{12}$|^[A-F0-9]{8}$'; then
  echo "WARNING: Conversation UUID '$CONVERSATION_ID' doesn't match expected format"
  echo "Expected: 8-character hex (ABC12345) or full UUID (XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX)"
  echo "Continuing anyway..."
  echo ""
fi

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
jq -n \
  --arg conv_id "$CONVERSATION_ID" \
  --arg model "$MODEL" \
  --arg query "$QUERY" \
  '{
    conversation_id: $conv_id,
    model: $model,
    messages: [
      {
        role: "user",
        content: $query
      }
    ],
    stream: true
  }' > "$TEMP_FILE"

# SAM returns streaming responses, parse SSE format
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
  echo "========================================="
  echo "WARNING: No response received from SAM"
  echo "========================================="
  echo "This could mean:"
  echo "  - Invalid API token (check token in SAM Preferences)"
  echo "  - SAM server crashed or stopped responding"
  echo "  - Conversation ID '$CONVERSATION_ID' not found"
  echo "  - SAM encountered an error processing the query"
  echo "  - Model '$MODEL' not available (check API keys in Preferences)"
  echo ""
  echo "Check sam_server.log for details:"
  echo "  tail -50 sam_server.log | grep -i error"
  exit 1
else
  echo ""
  echo "========================================="
  echo "Conversation UUID: $CONVERSATION_ID"
  echo "Model: $MODEL"
  echo "========================================="
fi

