#!/bin/bash
# Simulate CI/CD pipeline build locally
# This ensures we catch the same errors the pipeline would catch

set -e

echo "🔄 PIPELINE SIMULATION - Exact GitHub Actions Build"
echo "=================================================="
echo ""

# Show environment
echo "📊 Environment Check:"
echo "   Xcode: $(xcodebuild -version | head -1)"
echo "   Pipeline expects: Xcode 16.0"
XCODE_VERSION=$(xcodebuild -version | grep -o '[0-9]*\.[0-9]*' | head -1)
if [[ "$XCODE_VERSION" != "16.0" ]]; then
    echo "   WARNING: Version mismatch! Pipeline uses Xcode 16.0, you have $XCODE_VERSION"
    echo "   WARNING:  Errors may differ between local and CI/CD builds"
fi
echo "   Swift: $(swift --version | head -1)"
echo "   macOS: $(sw_vers -productVersion)"
echo ""

# Check submodules like pipeline does
echo "DEBUG: Checking submodules (like GitHub Actions checkout)..."
if git submodule status | grep -q '^-'; then
    echo "   WARNING: Submodules not initialized!"
    echo "   Pipeline does: git submodule update --init --recursive"
    read -p "   Initialize submodules now? [y/N] " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        git submodule update --init --recursive
    fi
fi
echo "   SUCCESS: Submodules OK"
echo ""

# Clean everything like CI/CD does (fresh checkout state)
echo "🧹 Cleaning build artifacts (simulating fresh checkout)..."
make clean
echo ""

# Build exactly like the pipeline
echo "🔨 Building SAM (Debug) - exact pipeline command..."
echo "   Command: make build-debug"
echo ""

BUILD_LOG="./scratch/pipeline-sim-$(date +%Y%m%d-%H%M%S).log"

if make build-debug 2>&1 | tee "$BUILD_LOG"; then
    echo ""
    echo "SUCCESS: BUILD SUCCEEDED"
    echo ""
    echo "📊 Error Summary:"
    ERROR_COUNT=$(grep -c " error:" "$BUILD_LOG" 2>/dev/null || echo "0")
    WARNING_COUNT=$(grep -c " warning:" "$BUILD_LOG" 2>/dev/null || echo "0")
    echo "   Errors: $ERROR_COUNT"
    echo "   Warnings: $WARNING_COUNT"
    echo ""
    
    if [ "$ERROR_COUNT" -eq 0 ]; then
        echo "SUCCESS: SUCCESS: No errors! Pipeline should pass."
        echo ""
        echo "   WARNING:  CAVEAT: Xcode version mismatch means pipeline could still fail"
        echo "   WARNING:  Pipeline uses Xcode 16.0, you have $XCODE_VERSION"
        echo "   WARNING:  Swift 6 strictness may differ between compiler versions"
    else
        echo "ERRORS FOUND - Pipeline will fail:"
        echo ""
        grep " error:" "$BUILD_LOG" | head -20
    fi
    
    # Check artifacts like pipeline does
    echo ""
    echo "DEBUG: Checking build artifacts (like pipeline)..."
    if [ -d ".build/Build/Products/Debug/SAM.app" ]; then
        echo "   SUCCESS: SAM.app exists"
        if [ -f ".build/Build/Products/Debug/SAM.app/Contents/MacOS/SAM" ]; then
            echo "   SUCCESS: SAM executable exists"
        else
            echo "   ERROR: SAM executable missing!"
        fi
    else
        echo "   ERROR: SAM.app missing!"
    fi
else
    echo ""
    echo "ERROR: BUILD FAILED"
    echo ""
    echo "📊 Errors found:"
    grep " error:" "$BUILD_LOG" 2>/dev/null | head -20 || echo "No error markers found in log"
    exit 1
fi

echo ""
echo "📝 Full build log saved to: $BUILD_LOG"
echo ""
echo "🔧 To fix Xcode version mismatch:"
echo "   - Install Xcode 16.0 from Apple Developer"
echo "   - Use: sudo xcode-select -s /Applications/Xcode-16.0.app"
echo "   - Re-run this script"

