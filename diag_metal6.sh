#!/bin/bash
echo "=== strings from metal proxy (filtered) ==="
strings /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/metal | grep -iE "toolchain|library|developer|cryptex|find|search|path" | head -30

echo "=== Check for MetalToolchain config ==="
ls -la /var/db/xdgassistantd/ 2>&1 | head -5
find /var -name "MetalToolchain*" -type f 2>/dev/null | head -10
find /var -name "MetalToolchain*" -type l 2>/dev/null | head -10

echo "=== Check DVT registration ==="
ls -la /var/db/Developer/ 2>&1 | head -20
defaults read /Library/Preferences/com.apple.DeveloperTools 2>&1 | head -20

echo "=== Check xcodebuild -showComponent ==="
xcodebuild -showComponent MetalToolchain -json 2>&1

echo "=== Check assetd ==="
sudo ls -la /System/Library/AssetsV2/ 2>&1 | head -10
