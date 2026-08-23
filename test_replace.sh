#!/bin/bash
echo "=== Checking default toolchain metal binary ==="
file /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/metal

echo "=== Checking Metal toolchain metal binary ==="
file /Library/Developer/Toolchains/Metal.xctoolchain/usr/bin/metal

echo "=== Try replacing ==="
sudo cp /Library/Developer/Toolchains/Metal.xctoolchain/usr/bin/metal /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/metal

echo "=== Test after replacement ==="
echo 'void main() {}' | /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/metal -c -x metal - -o /tmp/test_replaced.air 2>&1
echo "EXIT: $?"

echo "=== Test with SDK ==="
echo 'void main() {}' | xcrun -sdk macosx metal -c -x metal - -o /tmp/test_sdk.air 2>&1
echo "EXIT: $?"
