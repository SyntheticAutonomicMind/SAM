#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

# release.sh - Standardized release entry point
# Bumps version in Info.plist, commits, and creates an annotated tag.
# Does NOT build, sign, notarize, or push - CI handles those steps.
#
# Usage: ./scripts/release.sh <VERSION>
#   VERSION: YYYYMMDD.N format (e.g., 20260415.1)

set -e

VERSION="$1"

if [ -z "$VERSION" ]; then
    echo "Usage: $0 <VERSION>"
    echo "  VERSION format: YYYYMMDD.N (e.g., 20260415.1)"
    exit 1
fi

# Validate version format (YYYYMMDD.N where N is one or more digits)
if ! echo "$VERSION" | grep -qE '^[0-9]{8}\.[0-9]+$'; then
    echo "ERROR: Invalid version format: $VERSION"
    echo "  Expected: YYYYMMDD.N (e.g., 20260415.1)"
    exit 1
fi

# Ensure Info.plist exists
if [ ! -f "Info.plist" ]; then
    echo "ERROR: Info.plist not found (run from project root)"
    exit 1
fi

# Ensure working tree is clean (no uncommitted changes)
if ! git diff --quiet HEAD 2>/dev/null; then
    echo "ERROR: Working tree has uncommitted changes"
    echo "Commit or stash changes before releasing."
    exit 1
fi

# Check tag doesn't already exist
if git rev-parse "v$VERSION" >/dev/null 2>&1; then
    echo "ERROR: Tag v$VERSION already exists"
    exit 1
fi

echo "Releasing SAM $VERSION"
echo ""

# Update version in Info.plist
echo "Setting CFBundleShortVersionString to $VERSION..."
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" Info.plist

# Synchronize CFBundleVersion to match
echo "Synchronizing CFBundleVersion..."
./scripts/set-build-version.sh

# Commit the version change
git add Info.plist
git commit -m "chore(release): bump version to $VERSION"

# Create annotated tag
git tag -a "v$VERSION" -m "SAM $VERSION"

echo ""
echo "Done. Version $VERSION committed and tagged as v$VERSION."
echo ""
echo "Next steps:"
echo "  git push origin main --tags    # Push to trigger CI"
