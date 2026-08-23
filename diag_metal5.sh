#!/bin/bash
echo "=== Cryptex mount permissions ==="
ls -la /var/run/com.apple.security.cryptexd/mnt/ 2>&1
echo "=== v17.3.7003 ==="
ls -la /var/run/com.apple.security.cryptexd/mnt/com.apple.MobileAsset.MetalToolchain-v17.3.7003.10.XioxnB/ 2>&1
echo "=== v17.3.48.0 ==="
ls -la /var/run/com.apple.security.cryptexd/mnt/com.apple.MobileAsset.MetalToolchain-v17.3.48.0.0Y7xRt/ 2>&1
echo "=== metal binary in v17.3.7003 ==="
ls -la /var/run/com.apple.security.cryptexd/mnt/com.apple.MobileAsset.MetalToolchain-v17.3.7003.10.XioxnB/Metal.xctoolchain/usr/bin/metal 2>&1
echo "=== Test metal from v17.3.7003 cryptex ==="
echo 'void main() {}' | /var/run/com.apple.security.cryptexd/mnt/com.apple.MobileAsset.MetalToolchain-v17.3.7003.10.XioxnB/Metal.xctoolchain/usr/bin/metal -c -x metal - -o /tmp/test_cryptex.air 2>&1
echo "EXIT: $?"
echo "=== Test metal from v17.3.48 cryptex ==="
echo 'void main() {}' | /var/run/com.apple.security.cryptexd/mnt/com.apple.MobileAsset.MetalToolchain-v17.3.48.0.0Y7xRt/Metal.xctoolchain/usr/bin/metal -c -x metal - -o /tmp/test_cryptex2.air 2>&1
echo "EXIT: $?"
echo "=== Test metal from /Library copy as andrew ==="
echo 'void main() {}' | /Library/Developer/Toolchains/Metal.xctoolchain/usr/bin/metal -c -x metal - -o /tmp/test_lib.air 2>&1
echo "EXIT: $?"
echo "=== Default toolchain metal binary size and type ==="
file /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/metal 2>&1
echo "=== Check if metal proxy looks for specific path ==="
strings /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/metal | grep -i "toolchain\|cryptex\|metal" | head -20
