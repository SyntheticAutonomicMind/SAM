#!/bin/bash
# The Metal Toolchain is at:
# /private/var/root/Library/Developer/DVTDownloads/MetalToolchain/mounts/058e1b31129b642e40598a87b55aa54b2a29e538/Metal.xctoolchain
# But the default toolchain's metal binary can't find it.

# Let's try: copy the Metal.xctoolchain to /Library/Developer/Toolchains/ with proper permissions
echo "=== Checking existing Metal.xctoolchain ==="
ls -la /Library/Developer/Toolchains/Metal.xctoolchain/usr/bin/metal 2>&1

# Try using TOOLCHAINS env var
echo "=== Test with TOOLCHAINS=Metal ==="
echo 'void main() {}' | TOOLCHAINS=Metal /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/metal -c -x metal - -o /tmp/test3.air 2>&1
echo "EXIT: $?"

# Try with sudo xcode-select
echo "=== Test with sudo ==="
sudo -s echo 'void main() {}' | /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/metal -c -x metal - -o /tmp/test4.air 2>&1
echo "EXIT: $?"

# Check the DVT Downloads mount
echo "=== DVT Downloads mount ==="
sudo ls -la /private/var/root/Library/Developer/DVTDownloads/MetalToolchain/mounts/058e1b31129b642e40598a87b55aa54b2a29e538/Metal.xctoolchain/usr/bin/metal 2>&1

# Check what the default toolchain metal binary is
echo "=== Default toolchain metal binary ==="
file /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/metal 2>&1
ls -la /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/metal 2>&1

# Check if we can set DEVELOPER_DIR to Metal toolchain
echo "=== Test DEVELOPER_DIR ==="
DEVELOPER_DIR=/Library/Developer/Toolchains/Metal.xctoolchain xcrun --find metal 2>&1

# Check cryptex mounts
echo "=== Cryptex mounts ==="
sudo ls -la /System/Volumes/Data/private/var/run/com.apple.security.cryptexd/mnt/ 2>&1
