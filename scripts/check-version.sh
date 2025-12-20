#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

set -e

# check-version.sh - Automatically bumps version when source changes detected
# 
# This script checks if Sources/ or Tests/ have changed since the last
# version bump in Info.plist. If changes are detected, it automatically
# increments the patch version (e.g., 1.0.8 - 1.0.9).
#
# Usage:
#   ./scripts/check-version.sh
#
# Exit codes:
#   0 - Success (version bumped or no changes needed)
#   1 - Error (could not read/write Info.plist)
#
# Can be skipped in CI/CD by setting SKIP_VERSION_CHECK=1

# Allow skipping in CI/CD environments
if [ "${SKIP_VERSION_CHECK}" = "1" ]; then
    echo "ℹ️  Version check skipped (SKIP_VERSION_CHECK=1)"
    exit 0
fi

# Get current version from Info.plist
CURRENT_VERSION=$(defaults read "$(pwd)/Info.plist" CFBundleShortVersionString 2>/dev/null || echo "unknown")

if [ "$CURRENT_VERSION" = "unknown" ]; then
    echo "ERROR: Could not read version from Info.plist"
    exit 1
fi

# Get last commit that changed Info.plist (version bump)
LAST_VERSION_COMMIT=$(git log -1 --pretty=format:"%H" -- Info.plist 2>/dev/null || echo "")

if [ -z "$LAST_VERSION_COMMIT" ]; then
    echo "ℹ️  Info: First build or no git history for Info.plist"
    echo "SUCCESS: Version check passed: $CURRENT_VERSION"
    exit 0
fi

# CRITICAL: Check for uncommitted changes in Sources/ or Tests/
# If there are uncommitted changes, they're not ready for production
UNCOMMITTED_CHANGES=$(git diff --name-only HEAD 2>/dev/null | grep -E "^(Sources|Tests)/" || echo "")
UNCOMMITTED_COUNT=$(echo "$UNCOMMITTED_CHANGES" | grep -v '^$' | wc -l | tr -d ' ')

if [ "$UNCOMMITTED_COUNT" -gt 0 ]; then
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "ERROR: UNCOMMITTED CHANGES DETECTED"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    echo "Found $UNCOMMITTED_COUNT uncommitted file(s) in Sources/ or Tests/"
    echo ""
    echo "Uncommitted files:"
    echo "$UNCOMMITTED_CHANGES" | head -10
    if [ "$UNCOMMITTED_COUNT" -gt 10 ]; then
        echo "... and $(($UNCOMMITTED_COUNT - 10)) more"
    fi
    echo ""
    echo "ERROR: Commit all changes before production build"
    echo ""
    exit 1
fi

# Check if Sources/ or Tests/ changed since last version bump (committed changes only)
CHANGED_FILES=$(git diff --name-only $LAST_VERSION_COMMIT HEAD 2>/dev/null | grep -E "^(Sources|Tests)/" || echo "")
CHANGE_COUNT=$(echo "$CHANGED_FILES" | grep -v '^$' | wc -l | tr -d ' ')

if [ "$CHANGE_COUNT" -gt 0 ]; then
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "🔄 AUTO-BUMPING VERSION"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    echo "Current version: $CURRENT_VERSION"
    echo "Files changed since last version bump: $CHANGE_COUNT"
    echo ""
    
    # Parse version (assumes semantic versioning: MAJOR.MINOR.PATCH)
    IFS='.' read -r MAJOR MINOR PATCH <<< "$CURRENT_VERSION"
    
    # Increment patch version
    NEW_PATCH=$((PATCH + 1))
    NEW_VERSION="${MAJOR}.${MINOR}.${NEW_PATCH}"
    
    echo "Incrementing patch version: $CURRENT_VERSION - $NEW_VERSION"
    echo ""
    echo "Changed files:"
    echo "$CHANGED_FILES" | head -10
    if [ "$CHANGE_COUNT" -gt 10 ]; then
        echo "... and $(($CHANGE_COUNT - 10)) more"
    fi
    echo ""
    
    # Update Info.plist with new version
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $NEW_VERSION" Info.plist 2>/dev/null
    
    if [ $? -eq 0 ]; then
        echo "SUCCESS: Version bumped: $NEW_VERSION"
        echo "📝 Info.plist updated"
        echo ""
        
        # Auto-commit the version bump
        git add Info.plist
        git commit -m "chore: Bump version to $NEW_VERSION

Auto-generated version bump by check-version.sh
Changes detected in $CHANGE_COUNT file(s) since last version bump" 2>/dev/null
        
        if [ $? -eq 0 ]; then
            echo "SUCCESS: Version bump committed"
        else
            echo "WARNING:  Warning: Could not commit version bump (may already be committed)"
        fi
        
        CURRENT_VERSION="$NEW_VERSION"
    else
        echo "ERROR: Failed to update Info.plist"
        exit 1
    fi
fi

echo "SUCCESS: Version check passed: $CURRENT_VERSION"
exit 0
