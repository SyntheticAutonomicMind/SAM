#!/bin/bash
# Generate appcast-dev.xml from stable + development items
# Usage: ./scripts/generate-dev-appcast.sh

set -e

STABLE_APPCAST="appcast.xml"
DEV_APPCAST="appcast-dev.xml"
DEV_ITEMS="appcast-dev-items.xml"

# Check if required files exist
if [ ! -f "$STABLE_APPCAST" ]; then
    echo "Error: $STABLE_APPCAST not found"
    exit 1
fi

if [ ! -f "$DEV_ITEMS" ]; then
    echo "Error: $DEV_ITEMS not found"
    exit 1
fi

echo "Generating $DEV_APPCAST..."

# Create header
cat > "$DEV_APPCAST" <<'EOF'
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" xmlns:dc="http://purl.org/dc/elements/1.1/">
    <channel>
        <title>SAM Updates (Development)</title>
        <link>https://github.com/SyntheticAutonomicMind/SAM</link>
        <description>Development and stable releases of SAM</description>
        <language>en</language>

<!-- Development releases (from appcast-dev-items.xml) -->
EOF

# Extract and add development items (skip XML comments and empty lines)
# Use awk to properly handle multi-line comments
DEV_ITEMS_CONTENT=$(awk '
BEGIN { in_comment = 0; in_item = 0 }
/<!--/ { in_comment = 1; next }
/-->/ { in_comment = 0; next }
!in_comment && /<item>/ { in_item = 1 }
!in_comment && in_item { print }
!in_comment && /<\/item>/ { in_item = 0 }
' "$DEV_ITEMS")

if [ -n "$DEV_ITEMS_CONTENT" ]; then
    echo "Adding development items from $DEV_ITEMS"
    echo "$DEV_ITEMS_CONTENT" >> "$DEV_APPCAST"
else
    echo "No development items found in $DEV_ITEMS (this is OK for initial setup)"
fi

# Add separator comment
cat >> "$DEV_APPCAST" <<'EOF'

<!-- Stable releases (fallback from appcast.xml) -->
EOF

# Extract stable items from appcast.xml
sed -n '/<item>/,/<\/item>/p' "$STABLE_APPCAST" >> "$DEV_APPCAST"

# Close channel and RSS
cat >> "$DEV_APPCAST" <<'EOF'
    </channel>
</rss>
EOF

echo "✅ Generated $DEV_APPCAST"

# Validate generated XML
if command -v xmllint &> /dev/null; then
    if xmllint --noout "$DEV_APPCAST" 2>&1; then
        echo "✅ $DEV_APPCAST is valid XML"
    else
        echo "❌ $DEV_APPCAST has XML errors"
        exit 1
    fi
else
    echo "⚠️  xmllint not found, skipping validation"
fi
