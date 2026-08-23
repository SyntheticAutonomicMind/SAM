#!/bin/bash
echo "=== Test with proper Metal shader ==="
echo '#include <metal_stdlib>
using namespace metal;
vertex void vertex_main() {}' | xcrun -sdk macosx metal -c -x metal - -o /tmp/test_vertex.air 2>&1
echo "EXIT: $?"

echo "=== Test metal directly (wrapper) ==="
echo '#include <metal_stdlib>
using namespace metal;
vertex void vertex_main() {}' | /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/metal -c -x metal - -o /tmp/test_vertex2.air 2>&1
echo "EXIT: $?"

echo "=== Now test a full xcodebuild ==="
echo "=== Try building mlx-swift Cmlx target ==="
# Test that xcodebuild can now find the metal compiler
cd /Users/andrew/actions-runner/_work/SAM/SAM 2>/dev/null || true
echo "Working dir: $(pwd)"
