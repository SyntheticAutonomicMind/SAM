#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

# ask_sam.sh - Collaborate with SAM for diagnostics
# Enhanced version supporting large prompts, special characters, and model selection
#
# Usage:
#   ./ask_sam.sh <conversation-id> [--model model-name] [query]
#   ./ask_sam.sh <conversation-id> --model gpt-4 'query'
#   ./ask_sam.sh <conversation-id> --model gpt-4 < file.txt
#   echo "query" | ./ask_sam.sh <conversation-id> --model gpt-4

CONVERSATION_ID="${1:-}"
MODEL="gpt-5-mini"  # Default model
TEMP_FILE=$(mktemp)
trap "rm -f $TEMP_FILE" EXIT

# Check if conversation ID provided
if [ -z "$CONVERSATION_ID" ] || [ "$CONVERSATION_ID" = "--help" ]; then
  cat << 'USAGE'
Usage: ./ask_sam.sh <conversation-id> [--model model-name] [query]

OPTIONS:
--------
--model MODEL    Specify model to use (default: gpt-4)
                 Examples: gpt-4, gpt-3.5-turbo, llama/model, mlx/model

METHODS:
--------
1. Direct query:
   ./ask_sam.sh CA706D86 'Which tools did you use?'
   ./ask_sam.sh CA706D86 --model gpt-3.5-turbo 'Quick test'

2. From file:
   ./ask_sam.sh CA706D86 < prompt.txt
   ./ask_sam.sh CA706D86 --model gpt-4 < analysis.txt

3. Pipe input:
   echo "query" | ./ask_sam.sh CA706D86
   cat file | ./ask_sam.sh CA706D86 --model gpt-4

4. Here-doc:
   ./ask_sam.sh CA706D86 --model gpt-4 <<'QUERY'
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

# Parse --model if provided
if [ "$1" = "--model" ]; then
  if [ -z "$2" ]; then
    echo "ERROR: --model requires a model name"
    exit 1
  fi
  MODEL="$2"
  shift 2  # Remove --model and model name
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
PAYLOAD=$(jq -n \
  --arg model "$MODEL" \
  --arg convId "$CONVERSATION_ID" \
  --arg content "$QUERY" \
  '{
    model: $model,
    conversationId: $convId,
    messages: [{
      role: "user",
      content: $content
    }]
  }')

# Save payload to temp file for curl (handles large payloads better)
echo "$PAYLOAD" > "$TEMP_FILE"

# SAM returns streaming responses, parse SSE format
# Write to output file to detect if we got any content
OUTPUT_FILE=$(mktemp)
trap "rm -f $TEMP_FILE $OUTPUT_FILE" EXIT

curl -s -X POST http://127.0.0.1:8080/api/chat/completions \
  -H "Content-Type: application/json" \
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
