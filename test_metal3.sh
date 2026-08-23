#!/bin/bash
echo "=== macOS Version ==="
sw_vers

echo "=== Xcode select ==="
xcode-select -p 2>&1

echo "=== DEVELOPER_DIR ==="
echo "$DEVELOPER_DIR"

echo "=== TOOLCHAINS ==="
echo "$TOOLCHAINS"

echo "=== Try metal with DYLD_LIBRARY_PATH ==="
echo 'void main() {}' | DYLD_LIBRARY_PATH=/Library/Developer/Toolchains/Metal.xctoolchain/usr/lib /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/metal -c -x metal - -o /tmp/test_dyld.air 2>&1
echo "EXIT: $?"

echo "=== Try metal with METAL_TOOLCHAIN environment ==="
echo 'void main() {}' | METAL_TOOLCHAIN=/Library/Developer/Toolchains/Metal.xctoolchain /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/metal -c -x metal - -o /tmp/test_mt.air 2>&1
echo "EXIT: $?"

echo "=== Try using metal via xcrun with toolchain ==="
echo 'void main() {}' | xcrun -toolchain Metal metal -c -x metal - -o /tmp/test_xcrun.air 2>&1
echo "EXIT: $?"

echo "=== Try xcodebuild -toolchain Metal ==="
echo 'void main() {}' | xcodebuild -toolchain Metal /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/metal -c -x metal - -o /tmp/test_xcbuild.air 2>&1
echo "EXIT: $?"
