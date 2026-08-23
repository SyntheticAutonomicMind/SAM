#!/bin/bash
echo "=== showComponent MetalToolchain ==="
xcodebuild -showComponent MetalToolchain 2>&1

echo "=== importComponent MetalToolchain ==="
DMG_PATH=$(ls -t /System/Library/AssetsV2/com_apple_MobileAsset_MetalToolchain/*/AssetData/Restore/*.dmg 2>/dev/null | head -1)
echo "DMG: $DMG_PATH"
sudo xcodebuild -importComponent MetalToolchain -importPath "$DMG_PATH" 2>&1

echo "=== showComponent after import ==="
xcodebuild -showComponent MetalToolchain 2>&1

echo "=== Test metal via default toolchain ==="
echo "void main() {}" | /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/metal -c -x metal - -o /tmp/test.air 2>&1
echo "EXIT: $?"

echo "=== Check cryptex mounts ==="
ls -la /System/Volumes/Data/private/var/run/com.apple.security.cryptexd/mnt/ 2>&1

echo "=== Check for Metal.xctoolchain after import ==="
find / -name "Metal.xctoolchain" -type d 2>/dev/null | head -10
