#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

# Validate that the Python environment bundled in SAM.app is complete and functional
#
# This script ensures that:
# 1. python_base directory exists and contains standalone Python
# 2. python_env virtual environment exists and is properly configured
# 3. Python interpreter works and can import critical packages
# 4. All required dependencies are installed

set -e

# Accept build configuration as parameter (Debug or Release)
BUILD_CONFIG="${1:-Debug}"

APP_BUNDLE=".build/Build/Products/$BUILD_CONFIG/SAM.app"
RESOURCES_DIR="$APP_BUNDLE/Contents/Resources"
PYTHON_BASE="$RESOURCES_DIR/python_base"
PYTHON_ENV="$RESOURCES_DIR/python_env"
PYTHON_BIN="$PYTHON_ENV/bin/python3"

echo "=========================================="
echo "Validating Python Bundle ($BUILD_CONFIG)"
echo "=========================================="
echo ""

VALIDATION_FAILED=0

# Check 1: python_base exists and has correct structure
echo "[1/8] Checking python_base directory..."
if [ ! -d "$PYTHON_BASE" ]; then
    echo "FAIL: python_base directory not found at $PYTHON_BASE"
    VALIDATION_FAILED=1
else
    echo "✓ python_base exists"
fi

if [ ! -d "$PYTHON_BASE/bin" ]; then
    echo "FAIL: python_base/bin not found"
    VALIDATION_FAILED=1
else
    echo "✓ python_base/bin exists"
fi

if [ ! -d "$PYTHON_BASE/lib" ]; then
    echo "FAIL: python_base/lib not found"
    VALIDATION_FAILED=1
else
    echo "✓ python_base/lib exists"
fi

if [ ! -f "$PYTHON_BASE/bin/python3.12" ]; then
    echo "FAIL: python3.12 executable not found in python_base"
    VALIDATION_FAILED=1
else
    echo "✓ python3.12 executable exists"
fi

# Check 2: python_base size (should be ~40-60MB for install_only variant)
echo ""
echo "[2/8] Checking python_base size..."
PYTHON_BASE_SIZE=$(du -sm "$PYTHON_BASE" 2>/dev/null | awk '{print $1}')
if [ "$PYTHON_BASE_SIZE" -lt 30 ]; then
    echo "FAIL: python_base is too small (${PYTHON_BASE_SIZE}MB, expected 40-60MB)"
    echo "This indicates incomplete Python installation"
    VALIDATION_FAILED=1
elif [ "$PYTHON_BASE_SIZE" -gt 100 ]; then
    echo "WARNING: python_base is larger than expected (${PYTHON_BASE_SIZE}MB)"
    echo "✓ But size is acceptable"
else
    echo "✓ python_base size OK (${PYTHON_BASE_SIZE}MB)"
fi

# Check 3: python_env exists and has correct structure
echo ""
echo "[3/8] Checking python_env virtual environment..."
if [ ! -d "$PYTHON_ENV" ]; then
    echo "FAIL: python_env directory not found at $PYTHON_ENV"
    VALIDATION_FAILED=1
else
    echo "✓ python_env exists"
fi

if [ ! -d "$PYTHON_ENV/bin" ]; then
    echo "FAIL: python_env/bin not found"
    VALIDATION_FAILED=1
else
    echo "✓ python_env/bin exists"
fi

if [ ! -f "$PYTHON_BIN" ]; then
    echo "FAIL: python3 not found at $PYTHON_BIN"
    VALIDATION_FAILED=1
else
    echo "✓ python3 wrapper exists"
fi

if [ ! -f "$PYTHON_ENV/pyvenv.cfg" ]; then
    echo "FAIL: pyvenv.cfg not found"
    VALIDATION_FAILED=1
else
    echo "✓ pyvenv.cfg exists"
fi

# Check 4: Python interpreter works
echo ""
echo "[4/8] Testing Python interpreter..."
if ! PYTHON_VERSION=$("$PYTHON_BIN" --version 2>&1); then
    echo "FAIL: Python interpreter doesn't work"
    echo "Error: $PYTHON_VERSION"
    VALIDATION_FAILED=1
else
    echo "✓ Python works: $PYTHON_VERSION"
fi

# Check 5: Python can import sys and print path
echo ""
echo "[5/8] Testing Python standard library..."
if ! "$PYTHON_BIN" -c "import sys; import os; import json" 2>&1; then
    echo "FAIL: Cannot import standard library modules"
    VALIDATION_FAILED=1
else
    echo "✓ Standard library modules importable"
fi

# Check 6: Check site-packages exists and has packages
echo ""
echo "[6/8] Checking installed packages..."
SITE_PACKAGES="$PYTHON_ENV/lib/python3.12/site-packages"
if [ ! -d "$SITE_PACKAGES" ]; then
    echo "FAIL: site-packages directory not found"
    VALIDATION_FAILED=1
else
    PACKAGE_COUNT=$(ls -1 "$SITE_PACKAGES" | wc -l | tr -d ' ')
    if [ "$PACKAGE_COUNT" -lt 10 ]; then
        echo "FAIL: Very few packages installed ($PACKAGE_COUNT)"
        VALIDATION_FAILED=1
    else
        echo "✓ site-packages has $PACKAGE_COUNT entries"
    fi
fi

# Check 7: Test critical package imports
echo ""
echo "[7/8] Testing critical package imports..."

CRITICAL_PACKAGES=(
    "torch"
    "torchvision"
    "diffusers"
    "transformers"
    "PIL"
    "numpy"
    "cv2"
)

IMPORT_FAILURES=0
for pkg in "${CRITICAL_PACKAGES[@]}"; do
    if "$PYTHON_BIN" -c "import $pkg" 2>&1; then
        echo "✓ $pkg can be imported"
    else
        echo "FAIL: Cannot import $pkg"
        IMPORT_FAILURES=$((IMPORT_FAILURES + 1))
        VALIDATION_FAILED=1
    fi
done

if [ $IMPORT_FAILURES -eq 0 ]; then
    echo "✓ All critical packages import successfully"
fi

# Check 8: Test ml-stable-diffusion tools presence
echo ""
echo "[8/8] Checking ml-stable-diffusion tools..."
ML_TOOLS=(
    "$RESOURCES_DIR/convert_sd_to_coreml.py"
    "$RESOURCES_DIR/scripts/generate_image_diffusers.py"
    "$RESOURCES_DIR/scripts/upscale_image.py"
)

for tool in "${ML_TOOLS[@]}"; do
    if [ ! -f "$tool" ]; then
        echo "FAIL: Missing tool: $(basename $tool)"
        VALIDATION_FAILED=1
    else
        echo "✓ $(basename $tool) present"
    fi
done

# Summary
echo ""
echo "=========================================="
if [ $VALIDATION_FAILED -eq 0 ]; then
    echo "SUCCESS: VALIDATION PASSED"
    echo "=========================================="
    echo ""
    echo "Python environment is complete and functional"
    echo "Python base: $PYTHON_BASE_SIZE MB"
    echo "Virtual environment ready for model conversion and image generation"
    exit 0
else
    echo "ERROR: VALIDATION FAILED"
    echo "=========================================="
    echo ""
    echo "Python environment has issues. Please check the errors above."
    echo ""
    echo "Common fixes:"
    echo "  1. Run: make clean && make build-debug"
    echo "  2. Clear Python cache: rm -rf .python_cache"
    echo "  3. Check internet connection (for package downloads)"
    exit 1
fi
