#!/bin/bash
# Increment development build number or add -dev.1 suffix
# Usage: ./scripts/increment-dev-version.sh

set -e

PLIST="Info.plist"

# Check if Info.plist exists
if [ ! -f "$PLIST" ]; then
    echo "Error: Info.plist not found"
    exit 1
fi

# Get current version
CURRENT_VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$PLIST")

if [[ "$CURRENT_VERSION" =~ -dev\.([0-9]+)$ ]]; then
    # Already development version, increment build number
    DEV_NUM="${BASH_REMATCH[1]}"
    NEW_DEV_NUM=$((DEV_NUM + 1))
    BASE_VERSION="${CURRENT_VERSION%-dev.*}"
    NEW_VERSION="${BASE_VERSION}-dev.${NEW_DEV_NUM}"
    echo "Incrementing development build: $CURRENT_VERSION → $NEW_VERSION"
else
    # Stable version, add -dev.1 suffix
    NEW_VERSION="${CURRENT_VERSION}-dev.1"
    echo "Creating first development build: $CURRENT_VERSION → $NEW_VERSION"
fi

# Update Info.plist
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $NEW_VERSION" "$PLIST"

echo "✅ Version updated to: $NEW_VERSION"
