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

# Calculate today's date (YYYYMMDD)
TODAY_DATE=$(date +"%Y%m%d")

# Get current version from Info.plist
CURRENT_VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$PLIST")

if [[ "$CURRENT_VERSION" =~ -dev\.([0-9]+)$ ]]; then
    # Already a development version
    DEV_NUM="${BASH_REMATCH[1]}"
    BASE_VERSION="${CURRENT_VERSION%-dev.*}"
    BASE_DATE="${BASE_VERSION%.*}"
    
    # Check if base version matches today's date
    if [[ "$BASE_DATE" == "$TODAY_DATE" ]]; then
        # Same day, increment dev number
        NEW_DEV_NUM=$((DEV_NUM + 1))
        NEW_VERSION="${BASE_VERSION}-dev.${NEW_DEV_NUM}"
        echo "Incrementing development build: $CURRENT_VERSION → $NEW_VERSION"
    else
        # New day, calculate new base version and reset to -dev.1
        # Check for existing stable releases today
        LATEST_STABLE=$(git tag -l "${TODAY_DATE}.*" --sort=-version:refname 2>/dev/null | grep -v '\-dev\.' | head -1 || echo "")
        
        if [ -n "$LATEST_STABLE" ]; then
            # Stable release exists today, increment patch number
            PATCH_NUM="${LATEST_STABLE##*.}"
            NEW_PATCH=$((PATCH_NUM + 1))
            NEW_BASE_VERSION="${TODAY_DATE}.${NEW_PATCH}"
        else
            # No stable release today, start with .1
            NEW_BASE_VERSION="${TODAY_DATE}.1"
        fi
        
        NEW_VERSION="${NEW_BASE_VERSION}-dev.1"
        echo "New day development build: $CURRENT_VERSION → $NEW_VERSION"
    fi
else
    # Stable version or first run
    # Update to today's date if needed
    BASE_DATE="${CURRENT_VERSION%.*}"
    
    if [[ "$BASE_DATE" != "$TODAY_DATE" ]]; then
        # Different day, need to update base version
        echo "Date changed from $BASE_DATE to $TODAY_DATE"
        
        # Check for existing stable releases today
        LATEST_STABLE=$(git tag -l "${TODAY_DATE}.*" --sort=-version:refname 2>/dev/null | grep -v '\-dev\.' | head -1 || echo "")
        
        if [ -n "$LATEST_STABLE" ]; then
            # Stable release exists today, increment patch number
            PATCH_NUM="${LATEST_STABLE##*.}"
            NEW_PATCH=$((PATCH_NUM + 1))
            NEW_BASE_VERSION="${TODAY_DATE}.${NEW_PATCH}"
            echo "Found stable release $LATEST_STABLE, incrementing to $NEW_BASE_VERSION"
        else
            # No stable release today, start with .1
            NEW_BASE_VERSION="${TODAY_DATE}.1"
        fi
        
        # Update Info.plist base version first
        /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $NEW_BASE_VERSION" "$PLIST"
        /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $NEW_BASE_VERSION" "$PLIST"
    else
        # Same day as current version
        # Check if stable release with this exact version exists
        if git tag -l "$CURRENT_VERSION" 2>/dev/null | grep -q "^${CURRENT_VERSION}$"; then
            # Stable release exists with current version, increment patch
            PATCH_NUM="${CURRENT_VERSION##*.}"
            NEW_PATCH=$((PATCH_NUM + 1))
            NEW_BASE_VERSION="${TODAY_DATE}.${NEW_PATCH}"
            echo "Stable release $CURRENT_VERSION exists, incrementing to $NEW_BASE_VERSION"
        else
            # No stable release with current version, use as-is
            NEW_BASE_VERSION="$CURRENT_VERSION"
        fi
    fi
    
    NEW_VERSION="${NEW_BASE_VERSION}-dev.1"
    echo "Creating development build: $NEW_BASE_VERSION → $NEW_VERSION"
fi

# Update Info.plist with new dev version
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $NEW_VERSION" "$PLIST"

echo "✅ Version updated to: $NEW_VERSION"
