#!/bin/bash
# Collaboration checkpoint using file-based communication
# Replaces user_collaboration.sh which has terminal corruption issues

CHECKPOINT_DIR="scratch/checkpoints"
CHECKPOINT_FILE="$CHECKPOINT_DIR/latest.txt"

# Create checkpoint directory if it doesn't exist
mkdir -p "$CHECKPOINT_DIR"

# Write checkpoint message to file
MESSAGE="$1"
TIMESTAMP=$(date +"%Y-%m-%d %H:%M:%S")

cat > "$CHECKPOINT_FILE" << EOF
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
🤝 COLLABORATION CHECKPOINT
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Timestamp: $TIMESTAMP

$MESSAGE

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Please review the above and respond:
- Type 'yes' or 'approve' to continue
- Type 'no' to reject
- Type any other response for clarification

Your response: 
EOF

# Display the checkpoint
cat "$CHECKPOINT_FILE"

# Simple prompt for response (no fancy readline stuff that might break)
echo -n "> "
read -r RESPONSE

# Write response to file for record
echo -e "\n\nUser Response ($TIMESTAMP): $RESPONSE" >> "$CHECKPOINT_DIR/history.log"
echo "$MESSAGE" >> "$CHECKPOINT_DIR/history.log"
echo "---" >> "$CHECKPOINT_DIR/history.log"

# Return the response
echo "$RESPONSE"
