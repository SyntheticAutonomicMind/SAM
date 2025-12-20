#!/bin/bash
# Test release workflow locally on the runner
# This simulates the GitHub Actions workflow without pushing

set -e

VERSION=${1:-"20251214.TEST"}

echo "=== Testing Release Workflow Locally ==="
echo "Version: $VERSION"
echo ""

# Step 1: Update Info.plist
echo "1. Updating Info.plist..."
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" Info.plist
UPDATED_VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Info.plist)
echo "   Version set to: $UPDATED_VERSION"

if [ "$UPDATED_VERSION" != "$VERSION" ]; then
    echo "   ERROR: Version update failed"
    exit 1
fi

# Step 2: Clean previous build (optional, comment out to test with existing build)
echo ""
echo "2. Cleaning previous build..."
make clean || true

# Step 3: Build
echo ""
echo "3. Building release..."
time make build-release

# Step 4: Validate Python bundle  
echo ""
echo "4. Validating Python bundle..."
./scripts/validate_python_bundle.sh Release

# Step 5: Source environment
echo ""
echo "5. Loading runner environment..."
if [ -f /Users/andrew/.sam_runner_env ]; then
    source /Users/andrew/.sam_runner_env
    echo "   Keychains unlocked"
else
    echo "   WARNING: No runner environment file"
fi

# Step 6: Sign
echo ""
echo "6. Signing..."
time ./scripts/sign_app.sh

# Step 7: Notarize
echo ""
echo "7. Notarizing..."
time ./scripts/notarize_app.sh

# Step 8: Create DMG
echo ""
echo "8. Creating DMG..."
time make create-dmg

# Step 9: Verify files
echo ""
echo "9. Verifying distribution files..."
if [ -f "dist/SAM-${VERSION}.dmg" ]; then
    echo "   ✓ Found DMG: dist/SAM-${VERSION}.dmg"
    ls -lh "dist/SAM-${VERSION}.dmg"
else
    echo "   ✗ ERROR: DMG not found at dist/SAM-${VERSION}.dmg"
    exit 1
fi

if [ -f "dist/SAM-${VERSION}.zip" ]; then
    echo "   ✓ Found ZIP: dist/SAM-${VERSION}.zip"  
    ls -lh "dist/SAM-${VERSION}.zip"
else
    echo "   WARNING: ZIP not found"
fi

echo ""
echo "=== SUCCESS: Release workflow completed locally ==="
echo ""
echo "Files created:"
echo "  - dist/SAM-${VERSION}.dmg"
echo "  - dist/SAM-${VERSION}.zip"
echo ""
echo "Next steps:"
echo "  1. Test the DMG: open dist/SAM-${VERSION}.dmg"
echo "  2. If successful, create git tag and push"
