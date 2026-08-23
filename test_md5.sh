#!/bin/bash
echo "=== MD5 of all metal binaries ==="
md5 /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/metal 2>&1
md5 /Library/Developer/Toolchains/Metal.xctoolchain/usr/bin/metal 2>&1
md5 /var/run/com.apple.security.cryptexd/mnt/com.apple.MobileAsset.MetalToolchain-v17.3.7003.10.XioxnB/Metal.xctoolchain/usr/bin/metal 2>&1

echo "=== Test default toolchain metal (after replacement) ==="
echo 'void main() {}' | /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/metal -c -x metal - -o /tmp/test1.air 2>&1
echo "EXIT: $?"

echo "=== Test library copy metal ==="
echo 'void main() {}' | /Library/Developer/Toolchains/Metal.xctoolchain/usr/bin/metal -c -x metal - -o /tmp/test2.air 2>&1
echo "EXIT: $?"

echo "=== Test cryptex metal ==="
echo 'void main() {}' | /var/run/com.apple.security.cryptexd/mnt/com.apple.MobileAsset.MetalToolchain-v17.3.7003.10.XioxnB/Metal.xctoolchain/usr/bin/metal -c -x metal - -o /tmp/test3.air 2>&1
echo "EXIT: $?"

echo "=== Test xcrun -sdk macosx metal ==="
echo 'void main() {}' | xcrun -sdk macosx metal -c -x metal - -o /tmp/test4.air 2>&1
echo "EXIT: $?"
