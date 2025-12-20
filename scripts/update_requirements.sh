#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

# Update Python dependencies for SAM
# This script helps maintain requirements.txt with locked dependency versions

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REQUIREMENTS_IN="$SCRIPT_DIR/requirements.in"
REQUIREMENTS_TXT="$SCRIPT_DIR/requirements.txt"

echo "===================="
echo "SAM Dependency Updater"
echo "===================="
echo ""

# Check if pip-tools is installed
if ! python3 -m pip show pip-tools &> /dev/null; then
    echo "pip-tools not found. Installing..."
    python3 -m pip install pip-tools
fi

echo "Compiling requirements.txt from requirements.in..."
echo ""

# Use pip-compile to generate locked requirements.txt
# --resolver=backtracking: Use newer dependency resolver (more reliable)
# --upgrade: Get latest compatible versions
# --generate-hashes: Add hashes for security (optional)
python3 -m piptools compile \
    --resolver=backtracking \
    --output-file="$REQUIREMENTS_TXT" \
    "$REQUIREMENTS_IN"

echo ""
echo "===================="
echo "Success!"
echo "===================="
echo ""
echo "requirements.txt has been updated with locked dependency versions."
echo ""
echo "Next steps:"
echo "  1. Review the changes: git diff scripts/requirements.txt"
echo "  2. Test the new dependencies: make build-debug"
echo "  3. Verify SAM works: test image generation with upscaling"
echo "  4. Commit if everything works: git commit -am 'chore: Update Python dependencies'"
echo ""
echo "Note: Always test thoroughly before committing dependency updates!"
echo "===================="
