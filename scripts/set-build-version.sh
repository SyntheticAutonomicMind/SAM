#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

set -e

# set-build-version.sh - Update CFBundleVersion with date when version changes
# 
# This script automatically updates the CFBundleVersion in Info.plist
# to use the current date (YYYYMMDD format) ONLY when CFBundleShortVersionString
# changes. This provides a stable build identifier tied to version releases.
#
# Usage:
#   ./scripts/set-build-version.sh [configuration]
#
# Arguments:
#   configuration - "Debug" or "Release" (default: both)
#
# The script updates:
#   - Info.plist in project root (source template)
#   - Info.plist in build output (if exists)
#
# Example:
#   When version changes from 1.0.86 to 1.0.87:
#   Before: Version 1.0.86 (20251129)
#   After:  Version 1.0.87 (20251129) <- updates to current date

# Get current version from Info.plist
CURRENT_VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Info.plist 2>/dev/null)
CURRENT_BUILD=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" Info.plist 2>/dev/null)

if [ -z "$CURRENT_VERSION" ]; then
    echo "ERROR: Could not read CFBundleShortVersionString from Info.plist"
    exit 1
fi

# Version tracking file
VERSION_FILE=".last_version"

# Read last version
LAST_VERSION=""
if [ -f "$VERSION_FILE" ]; then
    LAST_VERSION=$(cat "$VERSION_FILE")
fi

# Check if version changed
if [ "$CURRENT_VERSION" != "$LAST_VERSION" ]; then
    # Version changed - update build number to current date
    NEW_BUILD=$(date +%Y%m%d)
    
    echo "Version changed: $LAST_VERSION -> $CURRENT_VERSION"
    echo "Updating CFBundleVersion to: $NEW_BUILD"
    
    /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $NEW_BUILD" Info.plist 2>/dev/null
    
    if [ $? -ne 0 ]; then
        echo "ERROR: Failed to update Info.plist"
        exit 1
    fi
    
    # Save current version
    echo "$CURRENT_VERSION" > "$VERSION_FILE"
    
    echo "SUCCESS: Build version updated to $NEW_BUILD"
else
    echo "Version unchanged ($CURRENT_VERSION), keeping build number: $CURRENT_BUILD"
fi

# Also update build outputs if they exist (use current build number from Info.plist)
CONFIGURATION="${1:-}"
BUILD_NUMBER=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" Info.plist 2>/dev/null)

update_build_output() {
    local config="$1"
    local build_plist=".build/Build/Products/$config/SAM.app/Contents/Info.plist"
    
    if [ -f "$build_plist" ]; then
        echo "Updating $config build output to: $BUILD_NUMBER"
        /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$build_plist" 2>/dev/null
        if [ $? -eq 0 ]; then
            echo "SUCCESS: $config build updated"
        fi
    fi
}

if [ -n "$CONFIGURATION" ]; then
    update_build_output "$CONFIGURATION"
else
    update_build_output "Debug"
    update_build_output "Release"
fi

exit 0
