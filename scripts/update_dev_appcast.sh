#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

# Script to update appcast-dev-items.xml with new development release entry
# Usage: ./scripts/update_dev_appcast.sh <version> <zip_path> [private_key_path]

set -e

VERSION="$1"
ZIP_PATH="$2"
PRIVATE_KEY_PATH="${3:-$HOME/.sam-sparkle-keys/private_key.txt}"

if [ -z "$VERSION" ] || [ -z "$ZIP_PATH" ]; then
    echo "Usage: $0 <version> <zip_path> [private_key_path]"
    echo "Example: $0 20260111.1-dev.1 dist/SAM-20260111.1-dev.1.zip"
    echo "         $0 20260111.1-dev.1 dist/SAM-20260111.1-dev.1.zip /tmp/sparkle_key.txt"
    exit 1
fi

if [ ! -f "$ZIP_PATH" ]; then
    echo "Error: ZIP file not found: $ZIP_PATH"
    exit 1
fi

if [ ! -f "$PRIVATE_KEY_PATH" ]; then
    echo "Error: Sparkle private key not found: $PRIVATE_KEY_PATH"
    echo "Please run scripts/setup_sparkle.sh to generate keys"
    exit 1
fi

DEV_ITEMS_FILE="appcast-dev-items.xml"
if [ ! -f "$DEV_ITEMS_FILE" ]; then
    echo "Error: $DEV_ITEMS_FILE not found in current directory"
    exit 1
fi

# Get file size
FILE_SIZE=$(stat -f%z "$ZIP_PATH")

# Get current date in RFC 822 format
PUB_DATE=$(date -u +"%a, %d %b %Y %H:%M:%S %z")

# Find sign_update binary
SIGN_UPDATE_BINARY=""
if [ -f ".build/artifacts/sparkle/Sparkle/bin/sign_update" ]; then
    SIGN_UPDATE_BINARY=".build/artifacts/sparkle/Sparkle/bin/sign_update"
elif [ -f ".build/SourcePackages/artifacts/sparkle/Sparkle/bin/sign_update" ]; then
    SIGN_UPDATE_BINARY=".build/SourcePackages/artifacts/sparkle/Sparkle/bin/sign_update"
elif [ -f ".build/checkouts/Sparkle/sign_update" ]; then
    SIGN_UPDATE_BINARY=".build/checkouts/Sparkle/sign_update"
fi

if [ -z "$SIGN_UPDATE_BINARY" ]; then
    echo "Error: sign_update binary not found"
    echo "Please run 'make build-debug' or 'make build-release' first"
    exit 1
fi

# Sign the ZIP file to get EdDSA signature
echo "Signing ZIP file with EdDSA key..."
SIGNATURE_OUTPUT=$("$SIGN_UPDATE_BINARY" "$ZIP_PATH" -f "$PRIVATE_KEY_PATH")

if [ -z "$SIGNATURE_OUTPUT" ]; then
    echo "Error: Failed to generate signature"
    exit 1
fi

# Extract just the signature value from: sparkle:edSignature="VALUE" length="..."
SIGNATURE=$(echo "$SIGNATURE_OUTPUT" | sed -n 's/.*sparkle:edSignature="\([^"]*\)".*/\1/p')

if [ -z "$SIGNATURE" ]; then
    echo "Error: Failed to extract signature from output: $SIGNATURE_OUTPUT"
    exit 1
fi

echo "  Signature: $SIGNATURE"

echo "Updating $DEV_ITEMS_FILE for version $VERSION"
echo "  ZIP: $ZIP_PATH"
echo "  Size: $FILE_SIZE bytes"
echo "  Date: $PUB_DATE"
echo "  EdDSA Signature: ${SIGNATURE:0:40}..."
echo ""

# Create new development item entry
read -r -d '' NEW_ITEM << EOF || true
<item>
    <title>SAM $VERSION</title>
    <description><![CDATA[
        <h2>SAM $VERSION (Development Build)</h2>
        <p><strong>⚠️ This is a DEVELOPMENT release for testing purposes.</strong></p>
        <h3>What's New:</h3>
        <ul>
            <li>See <a href="https://github.com/SyntheticAutonomicMind/SAM/releases/tag/$VERSION">GitHub Releases</a> for details</li>
        </ul>
        <h3>Known Issues:</h3>
        <ul>
            <li>Development builds may contain bugs and incomplete features</li>
        </ul>
    ]]></description>
    <pubDate>$PUB_DATE</pubDate>
    <sparkle:releaseNotesLink>https://github.com/SyntheticAutonomicMind/SAM/releases/tag/$VERSION</sparkle:releaseNotesLink>
    <sparkle:channel>development</sparkle:channel>
    <enclosure 
        url="https://github.com/SyntheticAutonomicMind/SAM/releases/download/$VERSION/SAM-$VERSION.zip"
        sparkle:version="$VERSION"
        sparkle:shortVersionString="$VERSION"
        sparkle:edSignature="$SIGNATURE"
        length="$FILE_SIZE"
        type="application/octet-stream"
    />
    <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
</item>

EOF

# Create a temporary file
TEMP_FILE=$(mktemp)

# Read through the file and insert new item after the "Development items will be added below this line" comment
INSERTED=0
while IFS= read -r line; do
    echo "$line" >> "$TEMP_FILE"
    if [[ "$line" == *"Development items will be added below this line"* ]] && [ $INSERTED -eq 0 ]; then
        echo "" >> "$TEMP_FILE"
        echo "$NEW_ITEM" >> "$TEMP_FILE"
        INSERTED=1
    fi
done < "$DEV_ITEMS_FILE"

# Move the temp file to replace the original
mv "$TEMP_FILE" "$DEV_ITEMS_FILE"

echo "✅ Updated $DEV_ITEMS_FILE with version $VERSION"
echo ""
echo "Next steps:"
echo "1. Run: ./scripts/generate-dev-appcast.sh"
echo "2. Commit both appcast-dev-items.xml and appcast-dev.xml"
