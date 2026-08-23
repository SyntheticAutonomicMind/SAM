#!/bin/bash
echo 'void main() {}' | /var/run/com.apple.security.cryptexd/mnt/com.apple.MobileAsset.MetalToolchain-v17.3.7003.10.XioxnB/Metal.xctoolchain/usr/bin/metal -c -x metal - -o /tmp/test_cryptex.air 2>&1
echo "EXIT: $?"
