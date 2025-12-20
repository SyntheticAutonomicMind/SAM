#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

set -e

# SAM Notarization Script
# Submits SAM.app to Apple for notarization and staples the ticket

APP_NAME="SAM"
APP_PATH=".build/Build/Products/Release/${APP_NAME}.app"
DIST_DIR="dist"
KEYCHAIN_PROFILE="SAM"

# Check if app exists
if [ ! -d "${APP_PATH}" ]; then
    echo "ERROR: ${APP_PATH} not found"
    exit 1
fi

# Check if app is signed
if ! codesign --verify --deep --strict "${APP_PATH}" 2>/dev/null; then
    echo "ERROR: ${APP_PATH} is not properly signed"
    exit 1
fi

# Extract version from Info.plist
ABS_APP_PATH=$(cd "$(dirname "${APP_PATH}")" && pwd)/$(basename "${APP_PATH}")
VERSION=$(defaults read "${ABS_APP_PATH}/Contents/Info" CFBundleShortVersionString 2>/dev/null || echo "")
if [ -z "$VERSION" ]; then
    echo "WARNING: Could not read version from Info.plist, using 'dev'"
    VERSION="dev"
fi

ARCHIVE="${DIST_DIR}/${APP_NAME}-${VERSION}.zip"

echo "Packaging ${APP_NAME} ${VERSION} for notarization..."

# Create dist directory
mkdir -p "${DIST_DIR}"

# Remove old archive if exists
if [ -f "${ARCHIVE}" ]; then
    rm -f "${ARCHIVE}"
fi

# Create ZIP archive (preserves code signature)
echo "Creating ZIP archive..."
cd .build/Build/Products/Release
ditto -c -k --keepParent "${APP_NAME}.app" "../../../../${ARCHIVE}"
cd - > /dev/null

echo "Archive created: ${ARCHIVE}"

# Check if notarization credentials are configured
if ! xcrun notarytool history --keychain-profile "${KEYCHAIN_PROFILE}" 2>&1 | head -1 > /dev/null; then
    echo "ERROR: Notarization credentials not configured or keychain locked"
    xcrun notarytool history --keychain-profile "${KEYCHAIN_PROFILE}" 2>&1 | sed 's/^/  /'
    exit 1
fi

echo "Submitting to Apple for notarization (this may take several minutes)..."

# Submit for notarization
NOTARIZE_OUTPUT=$(xcrun notarytool submit "${ARCHIVE}" \
                --keychain-profile "${KEYCHAIN_PROFILE}" \
                --wait 2>&1)

NOTARIZE_EXIT_CODE=$?

echo "$NOTARIZE_OUTPUT"

# Check if notarization succeeded
if echo "$NOTARIZE_OUTPUT" | grep -q "status: Accepted"; then
    echo "SUCCESS: Notarization accepted by Apple"
    
    # Staple ticket to app bundle
    echo "Stapling notarization ticket..."
    xcrun stapler staple "${APP_PATH}" 2>&1 | sed 's/^/  /'
    
    # Verify stapling
    echo "Verifying stapled app..."
    xcrun stapler validate "${APP_PATH}" 2>&1 | sed 's/^/  /'
    
    # Final Gatekeeper check
    echo "Gatekeeper validation..."
    spctl --assess --type execute --verbose=4 "${APP_PATH}" 2>&1 | sed 's/^/  /'
    
    echo "SUCCESS: ${APP_NAME} ${VERSION} notarized and stapled"
    echo "Archive: ${ARCHIVE}"
    
elif echo "$NOTARIZE_OUTPUT" | grep -q "status: Invalid"; then
    echo "ERROR: Notarization rejected by Apple"
    
    # Try to get submission ID for detailed log
    SUBMISSION_ID=$(echo "$NOTARIZE_OUTPUT" | grep "id:" | head -1 | awk '{print $2}')
    if [ -n "$SUBMISSION_ID" ]; then
        echo "Detailed log:"
        xcrun notarytool log "$SUBMISSION_ID" --keychain-profile "${KEYCHAIN_PROFILE}" 2>&1 | sed 's/^/  /'
    fi
    
    exit 1
else
    echo "ERROR: Notarization failed"
    echo "Check output above for details"
    exit 1
fi
