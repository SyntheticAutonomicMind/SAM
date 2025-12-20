#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

# create_release.sh - Build and sign SAM release for Sparkle updates
# Usage: ./scripts/create_release.sh <version> [--test]
#   version: Version number (e.g., 1.0.108)
#   --test: Use test appcast URL for testing in private repo

set -e

# Configuration
KEYS_DIR="$HOME/.sam-sparkle-keys"
PRIVATE_KEY_FILE="$KEYS_DIR/private_key.txt"
BUILD_DIR=".build/Release"
RELEASES_DIR="releases"
APPCAST_FILE="appcast.xml"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Parse arguments
VERSION="$1"
TEST_MODE=false

if [ "$2" = "--test" ]; then
    TEST_MODE=true
fi

# Validate version argument
if [ -z "$VERSION" ]; then
    echo -e "${RED}ERROR: Version number required${NC}"
    echo "Usage: $0 <version> [--test]"
    echo "Example: $0 1.0.108"
    echo "         $0 1.0.108 --test"
    exit 1
fi

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "SAM Release Builder v$VERSION"
if [ "$TEST_MODE" = true ]; then
    echo -e "${YELLOW}(TEST MODE)${NC}"
fi
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# Check for private key
if [ ! -f "$PRIVATE_KEY_FILE" ]; then
    echo -e "${RED}ERROR: Sparkle private key not found${NC}"
    echo "Please run: ./scripts/setup_sparkle.sh"
    exit 1
fi

# Create releases directory
mkdir -p "$RELEASES_DIR"

echo "Step 1: Updating version in Info.plist..."
# Update CFBundleShortVersionString
plutil -replace CFBundleShortVersionString -string "$VERSION" Info.plist
# Update CFBundleVersion (use current date as build number)
BUILD_NUMBER=$(date +%Y%m%d)
plutil -replace CFBundleVersion -string "$BUILD_NUMBER" Info.plist
echo -e "${GREEN}✓${NC} Version updated to $VERSION (build $BUILD_NUMBER)"
echo ""

echo "Step 2: Building SAM in Release mode..."
make clean
make build-release 2>&1 | grep -E "(Building|SUCCESS|ERROR)" || true
if [ ! -d "$BUILD_DIR/SAM.app" ]; then
    echo -e "${RED}ERROR: Build failed - SAM.app not found${NC}"
    exit 1
fi
echo -e "${GREEN}✓${NC} Build complete"
echo ""

echo "Step 3: Code signing SAM.app..."
# Check if we have a Developer ID certificate
CERT_NAME=$(security find-identity -v -p codesigning | grep "Developer ID Application" | head -n1 | sed 's/.*"\(.*\)"/\1/')

if [ -z "$CERT_NAME" ]; then
    echo -e "${YELLOW}WARNING${NC}  No Developer ID certificate found - signing with ad-hoc signature"
    echo "   For distribution, you'll need a Developer ID Application certificate"
    codesign --force --deep --sign - "$BUILD_DIR/SAM.app"
else
    echo "Using certificate: $CERT_NAME"
    codesign --force --deep --sign "$CERT_NAME" --options runtime "$BUILD_DIR/SAM.app"
fi
echo -e "${GREEN}✓${NC} SAM.app signed"
echo ""

echo "Step 4: Creating ZIP archive..."
ARCHIVE_NAME="SAM-$VERSION.zip"
ARCHIVE_PATH="$RELEASES_DIR/$ARCHIVE_NAME"
cd "$BUILD_DIR"
ditto -c -k --sequesterRsrc --keepParent SAM.app "../../$ARCHIVE_PATH"
cd ../..
ARCHIVE_SIZE=$(stat -f%z "$ARCHIVE_PATH")
echo -e "${GREEN}✓${NC} Archive created: $ARCHIVE_PATH ($(numfmt --to=iec $ARCHIVE_SIZE 2>/dev/null || echo $ARCHIVE_SIZE bytes))"
echo ""

echo "Step 5: Signing archive with EdDSA..."
SIGNATURE=$(bin/sign_update "$ARCHIVE_PATH" -f "$PRIVATE_KEY_FILE")
if [ -z "$SIGNATURE" ]; then
    echo -e "${RED}ERROR: Failed to sign archive${NC}"
    exit 1
fi
echo -e "${GREEN}✓${NC} Archive signed"
echo ""

echo "Step 6: Updating appcast.xml..."
# Create backup of appcast
cp "$APPCAST_FILE" "$APPCAST_FILE.bak"

# Generate release notes from git log
PREV_TAG=$(git describe --tags --abbrev=0 2>/dev/null || echo "")
if [ -n "$PREV_TAG" ]; then
    RELEASE_NOTES=$(git log "$PREV_TAG"..HEAD --pretty=format:"<li>%s</li>" | head -20)
else
    RELEASE_NOTES="<li>Initial release</li>"
fi

# Create new appcast entry
PUB_DATE=$(date -u +"%a, %d %b %Y %H:%M:%S +0000")
FEED_URL="https://raw.githubusercontent.com/SyntheticAutonomicMind/SAM/main/appcast.xml"
if [ "$TEST_MODE" = true ]; then
    FEED_URL="https://raw.githubusercontent.com/SyntheticAutonomicMind/SAM-test/main/appcast.xml"
fi

# Insert new release at the top of appcast
cat > appcast_new.xml << EOF
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" xmlns:dc="http://purl.org/dc/elements/1.1/">
    <channel>
        <title>SAM Updates</title>
        <link>https://github.com/SyntheticAutonomicMind/SAM</link>
        <description>Updates for SAM (Synthetic Autonomic Mind)</description>
        <language>en</language>
        
        <!-- Latest release: v$VERSION -->
        <item>
            <title>SAM $VERSION</title>
            <description><![CDATA[
                <h2>What's New in SAM $VERSION</h2>
                <ul>
                    $RELEASE_NOTES
                </ul>
                
                <p>For full release notes, see <a href="https://github.com/SyntheticAutonomicMind/SAM/releases/tag/v$VERSION">GitHub Releases</a></p>
            ]]></description>
            <pubDate>$PUB_DATE</pubDate>
            <sparkle:releaseNotesLink>https://github.com/SyntheticAutonomicMind/SAM/releases/tag/v$VERSION</sparkle:releaseNotesLink>
            <enclosure 
                url="https://github.com/SyntheticAutonomicMind/SAM/releases/download/v$VERSION/$ARCHIVE_NAME"
                sparkle:version="$VERSION"
                sparkle:shortVersionString="$VERSION"
                sparkle:edSignature="$SIGNATURE"
                length="$ARCHIVE_SIZE"
                type="application/octet-stream"
            />
            <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
        </item>
EOF

# Append existing items (skip the XML header and channel opening)
tail -n +7 "$APPCAST_FILE" >> appcast_new.xml
mv appcast_new.xml "$APPCAST_FILE"
echo -e "${GREEN}✓${NC} appcast.xml updated"
echo ""

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo -e "${GREEN}Release $VERSION created successfully!${NC}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "Files created:"
echo "  • $ARCHIVE_PATH"
echo "  • $APPCAST_FILE (updated)"
echo "  • $APPCAST_FILE.bak (backup)"
echo ""
echo "NEXT STEPS:"
echo ""
echo "1. Test the update locally (if in test mode)"
echo "2. Create GitHub release:"
echo "   git tag -a v$VERSION -m \"Release $VERSION\""
echo "   git push origin v$VERSION"
echo ""
echo "3. Upload $ARCHIVE_NAME to GitHub release"
echo ""
echo "4. Commit and push appcast.xml:"
echo "   git add appcast.xml Info.plist"
echo "   git commit -m \"Release v$VERSION\""
echo "   git push"
echo ""
if [ "$TEST_MODE" = true ]; then
    echo -e "${YELLOW}NOTE: Test mode - update Info.plist SUFeedURL to:${NC}"
    echo "  $FEED_URL"
    echo ""
fi
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
