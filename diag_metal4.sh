#!/bin/bash
# Fix permissions on the DVT Downloads Metal Toolchain mount
DVT_PATH="/private/var/root/Library/Developer/DVTDownloads/MetalToolchain"

echo "=== Current permissions ==="
sudo ls -la "$DVT_PATH" 2>&1
sudo ls -la "$DVT_PATH/mounts/" 2>&1
sudo ls -la "$DVT_PATH/mounts/058e1b31129b642e40598a87b55aa54b2a29e538/" 2>&1

# Copy the Metal.xctoolchain to a location accessible to all users
echo "=== Copying Metal.xctoolchain to /Library/Developer/Toolchains/ ==="
sudo rm -rf /Library/Developer/Toolchains/Metal.xctoolchain
sudo cp -R "$DVT_PATH/mounts/058e1b31129b642e40598a87b55aa54b2a29e538/Metal.xctoolchain" /Library/Developer/Toolchains/
sudo chown -R root:wheel /Library/Developer/Toolchains/Metal.xctoolchain
sudo chmod -R 755 /Library/Developer/Toolchains/Metal.xctoolchain

echo "=== Installed ==="
ls -la /Library/Developer/Toolchains/Metal.xctoolchain/usr/bin/metal 2>&1

# Now try using the default toolchain's metal binary
echo "=== Test default toolchain metal ==="
echo 'void main() {}' | /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/metal -c -x metal - -o /tmp/test.air 2>&1
echo "EXIT: $?"

# Try as andrew user
echo "=== Test as andrew user ==="
echo 'void main() {}' | /Library/Developer/Toolchains/Metal.xctoolchain/usr/bin/metal -c -x metal - -o /tmp/test2.air 2>&1
echo "EXIT: $?"
