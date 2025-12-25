#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

# Script to update appcast.xml with new release entry
# Usage: ./scripts/update_appcast.sh <version> <zip_path> [private_key_path]

set -e

VERSION="$1"
ZIP_PATH="$2"
PRIVATE_KEY_PATH="${3:-$HOME/.sam-sparkle-keys/private_key.txt}"

if [ -z "$VERSION" ] || [ -z "$ZIP_PATH" ]; then
    echo "Usage: $0 <version> <zip_path> [private_key_path]"
    echo "Example: $0 20251214.1 dist/SAM-20251214.1.zip"
    echo "         $0 20251214.1 dist/SAM-20251214.1.zip /tmp/sparkle_key.txt"
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

APPCAST_FILE="appcast.xml"
if [ ! -f "$APPCAST_FILE" ]; then
    echo "Error: appcast.xml not found in current directory"
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
SIGNATURE=$("$SIGN_UPDATE_BINARY" "$ZIP_PATH" -f "$PRIVATE_KEY_PATH")

if [ -z "$SIGNATURE" ]; then
    echo "Error: Failed to generate signature"
    exit 1
fi

echo "  Signature: $SIGNATURE"

# Default release notes (GitHub link)
RELEASE_NOTES="<h2>What's New in SAM $VERSION</h2>
                <ul>
                    <li>See <a href=\"https://github.com/SyntheticAutonomicMind/SAM/releases/tag/$VERSION\">GitHub Releases</a> for details</li>
                </ul>"

echo "Updating appcast.xml for version $VERSION"
echo "  ZIP: $ZIP_PATH"
echo "  Size: $FILE_SIZE bytes"
echo "  Date: $PUB_DATE"
echo "  EdDSA Signature: ${SIGNATURE:0:40}..."
echo ""

# Create new entry
NEW_ENTRY="        <!-- Latest release: v$VERSION -->
        <item>
            <title>SAM $VERSION</title>
            <description><![CDATA[
                $RELEASE_NOTES
            ]]></description>
            <pubDate>$PUB_DATE</pubDate>
            <sparkle:releaseNotesLink>https://github.com/SyntheticAutonomicMind/SAM/releases/tag/$VERSION</sparkle:releaseNotesLink>
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
"

# Backup appcast.xml
cp "$APPCAST_FILE" "$APPCAST_FILE.bak"

# Write NEW_ENTRY to a temporary file to avoid shell quoting issues
TEMP_ENTRY_FILE=$(mktemp)
echo "$NEW_ENTRY" > "$TEMP_ENTRY_FILE"

# Use Python to properly insert the new entry after <language>en</language>
python3 <<PYTHON_SCRIPT
import re

# Read the new entry from temp file
with open('$TEMP_ENTRY_FILE', 'r') as f:
    new_entry = f.read()

# Read the appcast file
with open('$APPCAST_FILE', 'r') as f:
    content = f.read()

# Remove old "Latest release" comment if exists
content = re.sub(r'\s*<!-- Latest release:.*?-->\s*', '\n        ', content)

# Find the insertion point (after <language>en</language>)
insertion_point = content.find('<language>en</language>')
if insertion_point == -1:
    print("Error: Could not find <language>en</language> in appcast.xml")
    exit(1)

# Find the end of the line
end_of_line = content.find('\n', insertion_point)
if end_of_line == -1:
    end_of_line = len(content)

# Insert the new entry
new_content = content[:end_of_line + 1] + '\n' + new_entry + content[end_of_line + 1:]

# Write the updated content
with open('$APPCAST_FILE', 'w') as f:
    f.write(new_content)

print("SUCCESS: appcast.xml updated")
PYTHON_SCRIPT

# Clean up temp file
rm -f "$TEMP_ENTRY_FILE"

# Verify the XML is still valid
if command -v xmllint > /dev/null 2>&1; then
    if xmllint --noout "$APPCAST_FILE" 2>/dev/null; then
        echo "SUCCESS: appcast.xml is valid XML"
        rm -f "$APPCAST_FILE.bak"
    else
        echo "ERROR: appcast.xml is not valid XML, restoring backup"
        mv "$APPCAST_FILE.bak" "$APPCAST_FILE"
        exit 1
    fi
else
    echo "WARNING: xmllint not found, cannot verify XML validity"
fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "appcast.xml has been updated for v$VERSION"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "Next steps:"
echo "  1. Review changes: git diff appcast.xml"
echo "  2. Commit: git add appcast.xml && git commit -m 'chore: Update appcast.xml for v$VERSION'"
echo "  3. Push: git push origin main"
echo "  4. Upload ZIP to GitHub releases: $ZIP_PATH"
echo ""
