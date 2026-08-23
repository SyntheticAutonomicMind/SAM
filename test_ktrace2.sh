#!/bin/bash
# Use ktrace to trace what the metal proxy binary does
ktrace -c /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/metal -c -x metal /dev/stdin -o /tmp/test_ktrace.air <<'EOF'
void main() {}
EOF
echo "ktrace EXIT: $?"
echo "=== kdump output (grep for path/open/metoolchain) ==="
kdump 2>&1 | grep -iE "open|stat|metal|toolchain|cryptex|library|path" | head -80
echo "=== kdump all Metal-related ==="
kdump 2>&1 | grep -i "metal" | head -40
