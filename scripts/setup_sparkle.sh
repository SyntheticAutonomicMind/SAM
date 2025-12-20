#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

# setup_sparkle.sh - Initialize Sparkle signing keys for SAM updates
# This script must be run once to generate EdDSA keys for signing updates

set -e

KEYS_DIR="$HOME/.sam-sparkle-keys"
PUBLIC_KEY_FILE="$KEYS_DIR/public_key.txt"
PRIVATE_KEY_FILE="$KEYS_DIR/private_key.txt"

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "SAM Sparkle Update Signing Setup"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# Check if keys already exist
if [ -f "$PUBLIC_KEY_FILE" ] && [ -f "$PRIVATE_KEY_FILE" ]; then
    echo "WARNING:  Sparkle keys already exist at $KEYS_DIR"
    echo ""
    echo "Public key:  $(cat $PUBLIC_KEY_FILE)"
    echo "Private key: [REDACTED]"
    echo ""
    read -p "Do you want to regenerate keys? This will invalidate existing signatures (y/N): " -n 1 -r
    echo ""
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "Using existing keys."
        exit 0
    fi
fi

# Create keys directory
mkdir -p "$KEYS_DIR"
chmod 700 "$KEYS_DIR"

echo "Generating new EdDSA key pair..."
echo ""

# Generate keys using Sparkle's generate_keys tool
if [ ! -f "bin/generate_keys" ]; then
    echo "ERROR: bin/generate_keys not found"
    echo "Please run 'make build-debug' first to build Sparkle tools"
    exit 1
fi

# Generate keys and capture output
KEY_OUTPUT=$(bin/generate_keys 2>&1)

# Extract public and private keys from output
PUBLIC_KEY=$(echo "$KEY_OUTPUT" | grep "Public key:" | awk '{print $3}')
PRIVATE_KEY=$(echo "$KEY_OUTPUT" | grep "Private key:" | awk '{print $3}')

if [ -z "$PUBLIC_KEY" ] || [ -z "$PRIVATE_KEY" ]; then
    echo "ERROR: Failed to generate keys"
    echo "$KEY_OUTPUT"
    exit 1
fi

# Save keys to files
echo "$PUBLIC_KEY" > "$PUBLIC_KEY_FILE"
echo "$PRIVATE_KEY" > "$PRIVATE_KEY_FILE"
chmod 600 "$PRIVATE_KEY_FILE"
chmod 644 "$PUBLIC_KEY_FILE"

echo "SUCCESS: Keys generated successfully!"
echo ""
echo "Public key:  $PUBLIC_KEY"
echo "Private key: [SAVED SECURELY]"
echo ""
echo "Keys saved to: $KEYS_DIR"
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "NEXT STEPS:"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "1. Update Info.plist with the public key:"
echo "   <key>SUPublicEDKey</key>"
echo "   <string>$PUBLIC_KEY</string>"
echo ""
echo "2. BACKUP your private key securely:"
echo "   cp $PRIVATE_KEY_FILE /path/to/secure/backup/"
echo ""
echo "3. Never commit the private key to version control!"
echo ""
echo "4. Use scripts/create_release.sh to build and sign releases"
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
