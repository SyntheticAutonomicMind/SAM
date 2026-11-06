#!/bin/bash
# Sign a locally built SAM.app with the Developer ID identity.
#
# Keychain items trust the Developer ID requirement (identifier + team),
# so a signed local build reads stored credentials without password
# prompts. Ad-hoc/unsigned builds pin "Always Allow" to the exact
# cdhash, which changes every rebuild - prompts can never stick.
#
# Skips gracefully when no identity is available (CI, contributor
# machines): the build stays unsigned, exactly as before.
#
# Usage: sign-local.sh /path/to/SAM.app

set -u

BUNDLE="${1:?usage: sign-local.sh /path/to/SAM.app}"

if [ ! -d "$BUNDLE" ]; then
    echo "WARNING: $BUNDLE not found - skipping local signing."
    exit 0
fi

IDENTITY="${APPLE_DEVELOPER_ID:-}"

if [ -z "$IDENTITY" ]; then
    IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null \
        | grep "Developer ID Application" | head -1 \
        | sed -E 's/^[[:space:]]*[0-9]+[[:space:]]+"(.*)"/\1/')
fi

if [ -z "$IDENTITY" ]; then
    echo "NOTE: no Developer ID Application identity found - skipping local signing."
    echo "      Keychain items will prompt for access."
    echo "      Set APPLE_DEVELOPER_ID to enable prompt-free keychain access."
    exit 0
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# SAM.entitlements is the Xcode-ready form: it carries keychain-access-groups
# with the $(AppIdentifierPrefix) build variable (codesign does not expand it,
# and a literal variable fails AMFI at launch) plus NS*UsageDescription keys
# that only belong in Info.plist. Local builds sign with exactly the
# entitlement set the installed app uses: the three com.apple.security.cs.*
# keys. The legacy keychain SAM actually uses does not need entitlements.
PROCESSED_ENTITLEMENTS=$(mktemp /tmp/sam-entitlements-XXXX.plist)
cat > "$PROCESSED_ENTITLEMENTS" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.cs.allow-jit</key>
    <true/>
    <key>com.apple.security.cs.allow-unsigned-executable-memory</key>
    <true/>
    <key>com.apple.security.cs.disable-library-validation</key>
    <true/>
</dict>
</plist>
PLIST

echo "Signing local build with: $IDENTITY"
echo "  bundle: $BUNDLE"

# No --timestamp: local builds must not require Apple's timestamp service.
# Gatekeeper/notarization signatures (sign-and-notarize.sh) add it there.
if ! codesign --force --sign "$IDENTITY" \
        --entitlements "$PROCESSED_ENTITLEMENTS" \
        --options runtime \
        --deep \
        "$BUNDLE"; then
    echo "WARNING: local signing failed - keychain items may prompt for access."
    rm -f "$PROCESSED_ENTITLEMENTS"
    exit 0
fi

rm -f "$PROCESSED_ENTITLEMENTS"
echo "SUCCESS: local build signed (keychain reads resolve against the Developer ID ACL entries)"
