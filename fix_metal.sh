#!/bin/bash
set -e

echo "=== Fixing Metal Toolchain permissions ==="

# Fix permissions on the asset files
echo "Fixing asset file permissions..."
sudo chown -R root:wheel /System/Library/AssetsV2/com_apple_MobileAsset_MetalToolchain/ 2>/dev/null || true
sudo chmod -R 755 /System/Library/AssetsV2/com_apple_MobileAsset_MetalToolchain/ 2>/dev/null || true

# Delete the broken Metal Toolchain registration
echo "Deleting broken Metal Toolchain registration..."
sudo xcodebuild -deleteComponent MetalToolchain 2>&1 || true

# Re-download the Metal Toolchain
echo "Re-downloading Metal Toolchain..."
sudo xcodebuild -downloadComponent MetalToolchain 2>&1

# Wait for the download to settle
sleep 5

# Import the Metal Toolchain from the downloaded DMG
echo "Importing Metal Toolchain..."
DMG_PATH=$(ls -t /System/Library/AssetsV2/com_apple_MobileAsset_MetalToolchain/*/AssetData/Restore/*.dmg 2>/dev/null | head -1)
echo "DMG: $DMG_PATH"
if [ -n "$DMG_PATH" ]; then
    sudo xcodebuild -importComponent MetalToolchain -importPath "$DMG_PATH" 2>&1
    echo "Import exit: $?"
fi

# Check status
echo "=== showComponent after fix ==="
xcodebuild -showComponent MetalToolchain -json 2>&1

# Test metal
echo "=== Test default toolchain metal ==="
echo 'void main() {}' | /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/metal -c -x metal - -o /tmp/test.air 2>&1
echo "EXIT: $?"
