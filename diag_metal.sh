#!/bin/bash
echo "=== Cryptex mount points ==="
ls -la /System/Volumes/Data/private/var/run/com.apple.security.cryptexd/mnt/ 2>&1

echo "=== Metal.xctoolchain locations ==="
find / -name "Metal.xctoolchain" -type d 2>/dev/null | head -10

echo "=== Metal.xctoolchain in cryptex ==="
CRYPEX_PATH="/System/Volumes/Data/private/var/run/com.apple.security.cryptexd/mnt/com.apple.MobileAsset.MetalToolchain-v17.3.48.0.0Y7xRt/Metal.xctoolchain"
if [ -d "$CRYPEX_PATH" ]; then
    echo "Found at cryptex path"
    ls -la "$CRYPEX_PATH/usr/bin/metal" 2>&1
else
    echo "Cryptex path does not exist or is not mounted"
fi

echo "=== xcode-select ==="
sudo xcode-select -s /Applications/Xcode.app 2>&1
sudo xcode-select -p 2>&1

echo "=== Test metal via default toolchain ==="
echo "void main() {}" | /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/metal -c -x metal - -o /tmp/test.air 2>&1
echo "EXIT: $?"

echo "=== Metal.xctoolchain in /Library ==="
ls -la /Library/Developer/Toolchains/Metal.xctoolchain/usr/bin/metal 2>&1

echo "=== Check if we need to register the toolchain ==="
xcodebuild -list-toolchains 2>&1

echo "=== Try with DEVELOPER_DIR ==="
DEVELOPER_DIR=/Library/Developer/Toolchains/Metal.xctoolchain xcrun --find metal 2>&1

echo "=== Try metal from Metal toolchain directly ==="
echo "void main() {}" | /Library/Developer/Toolchains/Metal.xctoolchain/usr/bin/metal -c -x metal - -o /tmp/test2.air 2>&1
echo "EXIT: $?"