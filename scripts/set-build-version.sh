#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

set -e

# set-build-version.sh - Ensure CFBundleVersion matches CFBundleShortVersionString
# 
# Since SAM migrated to unified YYYYMMDD.RELEASE versioning (December 2025),
# both CFBundleVersion and CFBundleShortVersionString use the same value.
# This script ensures they stay synchronized.
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
# Versioning scheme (see VERSIONING.md):
#   Format: YYYYMMDD.RELEASE
#   Example: 20251230.1 (first release on Dec 30, 2025)
#   Both CFBundleShortVersionString and CFBundleVersion use this value.

# Get current version from Info.plist
CURRENT_VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Info.plist 2>/dev/null)
CURRENT_BUILD=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" Info.plist 2>/dev/null)

if [ -z "$CURRENT_VERSION" ]; then
    echo "ERROR: Could not read CFBundleShortVersionString from Info.plist"
    exit 1
fi

# Ensure CFBundleVersion matches CFBundleShortVersionString (unified versioning)
if [ "$CURRENT_VERSION" != "$CURRENT_BUILD" ]; then
    echo "Synchronizing CFBundleVersion to match CFBundleShortVersionString: $CURRENT_VERSION"
    
    /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $CURRENT_VERSION" Info.plist 2>/dev/null
    
    if [ $? -ne 0 ]; then
        echo "ERROR: Failed to update Info.plist"
        exit 1
    fi
    
    echo "SUCCESS: CFBundleVersion synchronized to $CURRENT_VERSION"
else
    echo "Version already synchronized: $CURRENT_VERSION"
fi

# Also update build outputs if they exist
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
