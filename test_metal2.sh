#!/bin/bash
echo "=== Check if Metal.xctoolchain exists in Xcode Toolchains ==="
ls -la /Applications/Xcode.app/Contents/Developer/Toolchains/ 2>&1

echo "=== Check /Library/Developer/Toolchains ==="
ls -la /Library/Developer/Toolchains/ 2>&1

echo "=== Try symlink approach ==="
sudo ln -sf /var/run/com.apple.security.cryptexd/mnt/com.apple.MobileAsset.MetalToolchain-v17.3.7003.10.XioxnB/Metal.xctoolchain /Library/Developer/Toolchains/Metal.xctoolchain 2>&1
ls -la /Library/Developer/Toolchains/ 2>&1

echo "=== Test default toolchain metal proxy ==="
echo 'void main() {}' | /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/metal -c -x metal - -o /tmp/test_proxy.air 2>&1
echo "EXIT: $?"

echo "=== Try with TOOLCHAINS env ==="
echo 'void main() {}' | TOOLCHAINS=metal /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/metal -c -x metal - -o /tmp/test_toolchains.air 2>&1
echo "EXIT: $?"

echo "=== Try with METAL_TOOLCHAIN_PATH env ==="
echo 'void main() {}' | METAL_TOOLCHAIN_PATH=/Library/Developer/Toolchains/Metal.xctoolchain /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/metal -c -x metal - -o /tmp/test_mtp.air 2>&1
echo "EXIT: $?"
