#!/bin/bash
# Use ktrace to trace what the metal proxy binary does
echo 'void main() {}' | ktrace -f /tmp/metal_trace.out /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/metal -c -x metal - -o /tmp/test_ktrace.air 2>&1
echo "EXIT: $?"
echo "=== ktrace output (grep for path/open) ==="
kdump -f /tmp/metal_trace.out 2>&1 | grep -iE "open|stat|metal|toolchain|cryptex|library" | head -50
