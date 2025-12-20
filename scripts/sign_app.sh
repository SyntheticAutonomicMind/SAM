#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

set -e

# SAM Code Signing Script
# Signs SAM.app with Developer ID certificate for Gatekeeper distribution

APP_NAME="SAM"
APP_PATH=".build/Build/Products/Release/${APP_NAME}.app"

# Get signing identity from environment variable (set in ~/.profile, ~/.zshrc, etc.)
SIGNING_IDENTITY="${APPLE_DEVELOPER_ID}"

# Use DirectDistribution entitlements for Developer ID signing
# (App Store builds use SAM.entitlements with provisioning profile)
ENTITLEMENTS="SAM-DirectDistribution.entitlements"

# Check if signing identity is set
if [ -z "${SIGNING_IDENTITY}" ]; then
    echo "ERROR: APPLE_DEVELOPER_ID environment variable not set"
    echo ""
    echo "Set it in your shell profile (~/.profile, ~/.zshrc, etc.):"
    echo "  export APPLE_DEVELOPER_ID=\"Developer ID Application: Your Name (TEAMID)\""
    echo ""
    echo "Or set it temporarily:"
    echo "  export APPLE_DEVELOPER_ID=\"Developer ID Application: Your Name (TEAMID)\""
    echo "  ./scripts/sign_app.sh"
    exit 1
fi

echo "Signing ${APP_NAME}..."

# Check if app exists
if [ ! -d "${APP_PATH}" ]; then
    echo "ERROR: ${APP_PATH} not found"
    echo "Run 'make build-release' first"
    exit 1
fi

# Check if entitlements file exists
if [ ! -f "${ENTITLEMENTS}" ]; then
    echo "ERROR: ${ENTITLEMENTS} not found"
    exit 1
fi

# Check if signing identity exists
if ! security find-identity -v -p codesigning | grep -q "${SIGNING_IDENTITY}"; then
    echo "ERROR: Signing identity not found: ${SIGNING_IDENTITY}"
    echo "Available identities:"
    security find-identity -v -p codesigning
    exit 1
fi

# Sign embedded frameworks first (if any)
echo "  - Signing embedded frameworks..."
if find "${APP_PATH}" -name "*.framework" -print0 2>/dev/null | grep -q .; then
    find "${APP_PATH}" -name "*.framework" -print0 | while IFS= read -r -d '' framework; do
        framework_name=$(basename "$framework")
        echo "     - ${framework_name}"
        
        # Sparkle.framework needs special handling (has nested apps and executables)
        if [[ "$framework_name" == "Sparkle.framework" ]]; then
            echo "        - Detected Sparkle - signing nested components..."
            
            # Sign XPC services first (they're nested)
            if [ -d "$framework/Versions/B/XPCServices" ]; then
                find "$framework/Versions/B/XPCServices" -name "*.xpc" -print0 | while IFS= read -r -d '' xpc; do
                    xpc_name=$(basename "$xpc")
                    echo "           - ${xpc_name}"
                    codesign --force --sign "${SIGNING_IDENTITY}" \
                             --options runtime \
                             --timestamp \
                             "$xpc" 2>&1 | sed 's/^/              /'
                done
            fi
            
            # Sign Updater.app (nested app)
            if [ -d "$framework/Versions/B/Updater.app" ]; then
                echo "           - Updater.app (nested application)"
                codesign --force --sign "${SIGNING_IDENTITY}" \
                         --options runtime \
                         --timestamp \
                         --deep \
                         "$framework/Versions/B/Updater.app" 2>&1 | sed 's/^/              /'
            fi
            
            # Sign Autoupdate executable
            if [ -f "$framework/Versions/B/Autoupdate" ]; then
                echo "           - Autoupdate (executable)"
                codesign --force --sign "${SIGNING_IDENTITY}" \
                         --options runtime \
                         --timestamp \
                         "$framework/Versions/B/Autoupdate" 2>&1 | sed 's/^/              /'
            fi
            
            # Finally sign the framework itself with runtime hardening
            codesign --force --sign "${SIGNING_IDENTITY}" \
                     --options runtime \
                     --timestamp \
                     "$framework" 2>&1 | sed 's/^/        /'
        else
            # Other frameworks: sign without runtime hardening (they're embedded)
            codesign --force --sign "${SIGNING_IDENTITY}" \
                     --timestamp \
                     "$framework" 2>&1 | sed 's/^/        /'
        fi
    done
else
    echo "     - No frameworks found"
fi

# Sign embedded dylibs (if any)
echo "  - Checking for embedded libraries..."
DYLIBS_FOUND=false
find "${APP_PATH}/Contents" -name "*.dylib" -print0 2>/dev/null | while IFS= read -r -d '' dylib; do
    DYLIBS_FOUND=true
    echo "  - Signing library: $(basename "$dylib")"
    codesign --force --sign "${SIGNING_IDENTITY}" \
             --options runtime \
             --timestamp \
             "$dylib" 2>&1 | sed 's/^/     /'
done

if [ "$DYLIBS_FOUND" = false ]; then
    echo "  - No embedded libraries found"
fi

# Sign Python executables (if Python env exists)
if [ -d "${APP_PATH}/Contents/Resources/python_env/bin" ]; then
    echo "  - Signing Python environment executables..."
    PYTHON_BIN="${APP_PATH}/Contents/Resources/python_env/bin"
    
    # Find all executable files (not symlinks)
    find "$PYTHON_BIN" -type f -perm +111 ! -name "*.py" ! -name "*.sh" 2>/dev/null | while IFS= read -r executable; do
        exec_name=$(basename "$executable")
        echo "  - Signing Python executable: $exec_name"
        codesign --force --sign "${SIGNING_IDENTITY}" \
                 --options runtime \
                 --timestamp \
                 "$executable" 2>&1 | sed 's/^/     /'
    done
else
    echo "  - No Python environment found (skipping)"
fi

# Sign Python base executables (bundled Python standalone)
if [ -d "${APP_PATH}/Contents/Resources/python_base/bin" ]; then
    echo "  - Signing Python base executables..."
    PYTHON_BASE_BIN="${APP_PATH}/Contents/Resources/python_base/bin"
    
    # Find all executable files (not symlinks) in python_base
    find "$PYTHON_BASE_BIN" -type f -perm +111 ! -name "*.py" ! -name "*.sh" 2>/dev/null | while IFS= read -r executable; do
        exec_name=$(basename "$executable")
        echo "     - Signing Python base executable: $exec_name"
        codesign --force --sign "${SIGNING_IDENTITY}" \
                 --options runtime \
                 --timestamp \
                 "$executable" 2>&1 | sed 's/^/        /' || true
    done
else
    echo "  - No Python base directory found (skipping)"
fi

# Sign Python base extension modules (.so files in python_base)
if [ -d "${APP_PATH}/Contents/Resources/python_base/lib" ]; then
    echo "  - Signing Python base extension modules (.so files)..."
    PYTHON_BASE_LIB="${APP_PATH}/Contents/Resources/python_base/lib"
    
    # Count total .so files for progress
    SO_COUNT=$(find "$PYTHON_BASE_LIB" -name "*.so" -type f 2>/dev/null | wc -l | tr -d ' ')
    echo "     Found $SO_COUNT base extension modules to sign"
    
    SIGNED_COUNT=0
    # Find all .so files (compiled Python extensions)
    find "$PYTHON_BASE_LIB" -name "*.so" -type f 2>/dev/null | while IFS= read -r sofile; do
        SIGNED_COUNT=$((SIGNED_COUNT + 1))
        # Only show progress every 10 files to avoid spam
        if [ $((SIGNED_COUNT % 10)) -eq 0 ] || [ $SIGNED_COUNT -eq $SO_COUNT ]; then
            echo "     Progress: $SIGNED_COUNT/$SO_COUNT"
        fi
        
        codesign --force --sign "${SIGNING_IDENTITY}" \
                 --options runtime \
                 --timestamp \
                 "$sofile" 2>/dev/null || true
    done
    
    echo "     ✓ Signed $SO_COUNT base extension modules"
fi

# Sign Python extension modules (.so files)
if [ -d "${APP_PATH}/Contents/Resources/python_env/lib" ]; then
    echo "  - Signing Python extension modules (.so files)..."
    PYTHON_LIB="${APP_PATH}/Contents/Resources/python_env/lib"
    
    # Count total .so files for progress
    SO_COUNT=$(find "$PYTHON_LIB" -name "*.so" -type f 2>/dev/null | wc -l | tr -d ' ')
    echo "     Found $SO_COUNT extension modules to sign"
    
    SIGNED_COUNT=0
    # Find all .so files (compiled Python extensions)
    find "$PYTHON_LIB" -name "*.so" -type f 2>/dev/null | while IFS= read -r sofile; do
        SIGNED_COUNT=$((SIGNED_COUNT + 1))
        # Only show progress every 10 files to avoid spam
        if [ $((SIGNED_COUNT % 10)) -eq 0 ] || [ $SIGNED_COUNT -eq $SO_COUNT ]; then
            echo "     Progress: $SIGNED_COUNT/$SO_COUNT"
        fi
        
        codesign --force --sign "${SIGNING_IDENTITY}" \
                 --options runtime \
                 --timestamp \
                 "$sofile" 2>/dev/null || true
    done
    
    echo "     ✓ Signed $SO_COUNT extension modules"
fi

# Sign Python package binaries (executables in lib/**/bin/)
if [ -d "${APP_PATH}/Contents/Resources/python_env/lib" ]; then
    echo "  - Signing Python package binaries..."
    PYTHON_LIB="${APP_PATH}/Contents/Resources/python_env/lib"
    
    # Find executables in package bin directories (e.g., wandb/bin/*)
    find "$PYTHON_LIB" -type d -name "bin" 2>/dev/null | while IFS= read -r bindir; do
        find "$bindir" -type f -perm +111 2>/dev/null | while IFS= read -r executable; do
            exec_name=$(basename "$executable")
            pkg_name=$(basename "$(dirname "$(dirname "$bindir")")")
            echo "     - Signing $pkg_name binary: $exec_name"
            codesign --force --sign "${SIGNING_IDENTITY}" \
                     --options runtime \
                     --timestamp \
                     "$executable" 2>&1 | sed 's/^/        /' || true
        done
    done
fi

# Sign embedded bundles (if any) - CRITICAL for MLX Metal library bundle
echo "  - Signing embedded bundles..."
if find "${APP_PATH}/Contents/Resources" -name "*.bundle" -print0 2>/dev/null | grep -q .; then
    find "${APP_PATH}/Contents/Resources" -name "*.bundle" -print0 | while IFS= read -r -d '' bundle; do
        echo "     - $(basename "$bundle")"
        # Sign bundles without runtime hardening
        codesign --force --sign "${SIGNING_IDENTITY}" \
                 --timestamp \
                 "$bundle" 2>&1 | sed 's/^/        /'
    done
else
    echo "     - No bundles found"
fi

# Sign the main app bundle
echo "  - Signing main app bundle..."
codesign --force --sign "${SIGNING_IDENTITY}" \
         --entitlements "${ENTITLEMENTS}" \
         --options runtime \
         --timestamp \
         "${APP_PATH}" 2>&1 | sed 's/^/     /'

# Verify signature
echo "Verifying signature..."
codesign --verify --deep --strict --verbose=2 "${APP_PATH}" 2>&1 | sed 's/^/  /'

echo "Gatekeeper assessment (pre-notarization)..."
echo "  Note: 'rejected (Unnotarized)' is expected"
spctl --assess --verbose=4 --type execute "${APP_PATH}" 2>&1 | sed 's/^/  /'

echo "SUCCESS: ${APP_NAME} signed successfully"
