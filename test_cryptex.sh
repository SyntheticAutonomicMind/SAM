#!/bin/bash
echo "=== Cryptex metal binary ==="
file /System/Volumes/Data/private/var/run/com.apple.security.cryptexd/mnt/com.apple.MobileAsset.MetalToolchain-v17.3.7003.10.XioxnB/Metal.xctoolchain/usr/bin/metal 2>&1

echo "=== Library metal binary ==="
file /Library/Developer/Toolchains/Metal.xctoolchain/usr/bin/metal 2>&1

echo "=== Compare sizes ==="
ls -la /System/Volumes/Data/private/var/run/com.apple.security.cryptexd/mnt/com.apple.MobileAsset.MetalToolchain-v17.3.7003.10.XioxnB/Metal.xctoolchain/usr/bin/metal 2>&1
ls -la /Library/Developer/Toolchains/Metal.xctoolchain/usr/bin/metal 2>&1
ls -la /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/metal 2>&1

echo "=== Test cryptex metal directly ==="
echo 'void main() {}' | /System/Volumes/Data/private/var/run/com.apple.security.cryptexd/mnt/com.apple.MobileAsset.MetalToolchain-v17.3.7003.10.XioxnB/Metal.xctoolchain/usr/bin/metal -c -x metal - -o /tmp/test_cryptex2.air 2>&1
echo "EXIT: $?"

echo "=== Check if xcrun -sdk macosx metal uses a different binary ==="
xcrun -sdk macosx --find metal 2>&1
