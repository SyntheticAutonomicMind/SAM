#!/bin/bash
# Use dtruss to trace what the metal proxy does when looking for the Metal Toolchain
echo 'void main() {}' | sudo dtruss -f /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/metal -c -x metal - -o /tmp/test_dtruss.air 2>&1 | grep -iE "open|stat|metal|toolchain" | head -50
echo "EXIT: $?"
