#!/bin/bash
echo "=== Test with TOOLCHAINS=Metal ==="
echo 'void main() {}' | TOOLCHAINS=Metal /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/metal -c -x metal - -o /tmp/test_t1.air 2>&1
echo "EXIT: $?"

echo "=== Test with DEVELOPER_DIR + xcrun ==="
echo 'void main() {}' | DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer TOOLCHAINS=Metal xcrun metal -c -x metal - -o /tmp/test_t2.air 2>&1
echo "EXIT: $?"

echo "=== Try xcode-select -s Metal toolchain ==="
sudo xcode-select -s /Library/Developer/Toolchains/Metal.xctoolchain 2>&1
echo "after select:"
xcode-select -p 2>&1
echo "=== Test metal after xcode-select ==="
echo 'void main() {}' | /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/metal -c -x metal - -o /tmp/test_t3.air 2>&1
echo "EXIT: $?"

echo "=== Reset xcode-select ==="
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer 2>&1
