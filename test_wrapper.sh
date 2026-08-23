#!/bin/bash
set -e

echo "=== Backing up original metal binary ==="
sudo cp /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/metal /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/metal.proxy.backup

echo "=== Creating wrapper script ==="
sudo tee /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/metal > /dev/null << 'WRAPPER'
#!/bin/bash
# Wrapper: delegate to the Metal Toolchain's metal binary
# The default toolchain's metal proxy can't find the Metal Toolchain on this builder.
# Use the cryptex-mounted Metal Toolchain instead.
METAL_BIN="/var/run/com.apple.security.cryptexd/mnt/com.apple.MobileAsset.MetalToolchain-v17.3.7003.10.XioxnB/Metal.xctoolchain/usr/bin/metal"
if [ ! -x "$METAL_BIN" ]; then
    METAL_BIN="/Library/Developer/Toolchains/Metal.xctoolchain/usr/bin/metal"
fi
exec "$METAL_BIN" "$@"
WRAPPER
sudo chmod +x /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/metal

echo "=== Test wrapper ==="
echo 'void main() {}' | /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/metal -c -x metal - -o /tmp/test_wrapper.air 2>&1
echo "EXIT: $?"

echo "=== Test with xcrun -sdk macosx ==="
echo 'void main() {}' | xcrun -sdk macosx metal -c -x metal - -o /tmp/test_xcrun.air 2>&1
echo "EXIT: $?"
