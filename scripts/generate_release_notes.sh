#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

# generate_release_notes.sh - Generate HTML release notes from whats-new.json
#
# Usage:
#   ./scripts/generate_release_notes.sh VERSION
#
# Example:
#   ./scripts/generate_release_notes.sh 20251230.1
#
# Output:
#   Generates release-notes/VERSION.html with formatted release notes
#   Suitable for Sparkle's sparkle:releaseNotesLink

set -e

VERSION="$1"

if [ -z "$VERSION" ]; then
    echo "Usage: $0 VERSION"
    echo "Example: $0 20251230.1"
    exit 1
fi

# Ensure output directory exists
mkdir -p release-notes

# Extract release data from whats-new.json using jq
RELEASE_DATA=$(cat Resources/whats-new.json | jq -r ".releases[] | select(.version == \"$VERSION\")")

if [ -z "$RELEASE_DATA" ]; then
    echo "ERROR: Version $VERSION not found in Resources/whats-new.json"
    exit 1
fi

# Extract fields
RELEASE_DATE=$(echo "$RELEASE_DATA" | jq -r '.release_date')
INTRODUCTION=$(echo "$RELEASE_DATA" | jq -r '.introduction')

# Generate HTML
cat > "release-notes/$VERSION.html" << 'HTML_HEAD'
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>SAM Release Notes</title>
    <style>
        body {
            font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, Oxygen, Ubuntu, Cantarell, sans-serif;
            line-height: 1.6;
            color: #333;
            max-width: 700px;
            margin: 20px auto;
            padding: 0 20px;
            background-color: #ffffff;
        }
        h1 {
            font-size: 24px;
            font-weight: 600;
            color: #1d1d1f;
            margin-bottom: 8px;
            border-bottom: 2px solid #0071e3;
            padding-bottom: 8px;
        }
        .release-date {
            color: #6e6e73;
            font-size: 14px;
            margin-bottom: 16px;
        }
        .introduction {
            background-color: #f5f5f7;
            padding: 16px;
            border-radius: 8px;
            margin-bottom: 24px;
            font-size: 15px;
            line-height: 1.5;
        }
        h2 {
            font-size: 20px;
            font-weight: 600;
            color: #1d1d1f;
            margin-top: 24px;
            margin-bottom: 12px;
            border-bottom: 1px solid #d2d2d7;
            padding-bottom: 4px;
        }
        .feature {
            margin-bottom: 16px;
            padding: 12px;
            border-left: 3px solid #0071e3;
            background-color: #f9f9f9;
        }
        .feature-title {
            font-weight: 600;
            font-size: 16px;
            color: #1d1d1f;
            margin-bottom: 4px;
        }
        .feature-description {
            font-size: 14px;
            color: #6e6e73;
            margin: 0;
        }
        .improvement {
            margin-bottom: 12px;
            padding: 10px;
            background-color: #fafafa;
            border-radius: 4px;
        }
        .improvement-title {
            font-weight: 500;
            font-size: 15px;
            color: #1d1d1f;
            margin-bottom: 2px;
        }
        .improvement-description {
            font-size: 13px;
            color: #86868b;
            margin: 0;
        }
        a {
            color: #0071e3;
            text-decoration: none;
        }
        a:hover {
            text-decoration: underline;
        }
    </style>
</head>
<body>
HTML_HEAD

# Add title and date
echo "    <h1>What's New in SAM $VERSION</h1>" >> "release-notes/$VERSION.html"
echo "    <div class=\"release-date\">Released $RELEASE_DATE</div>" >> "release-notes/$VERSION.html"

# Add introduction
echo "    <div class=\"introduction\">" >> "release-notes/$VERSION.html"
echo "        $INTRODUCTION" >> "release-notes/$VERSION.html"
echo "    </div>" >> "release-notes/$VERSION.html"

# Add highlights
echo "    <h2>Highlights</h2>" >> "release-notes/$VERSION.html"
echo "$RELEASE_DATA" | jq -r '.highlights[] | "    <div class=\"feature\">\n        <div class=\"feature-title\">" + .title + "</div>\n        <p class=\"feature-description\">" + .description + "</p>\n    </div>"' >> "release-notes/$VERSION.html"

# Add improvements
echo "    <h2>Improvements</h2>" >> "release-notes/$VERSION.html"
echo "$RELEASE_DATA" | jq -r '.improvements[] | "    <div class=\"improvement\">\n        <div class=\"improvement-title\">" + .title + "</div>\n        <p class=\"improvement-description\">" + .description + "</p>\n    </div>"' >> "release-notes/$VERSION.html"

# Add footer
cat >> "release-notes/$VERSION.html" << 'HTML_FOOT'
    <br>
    <p style="text-align: center; color: #86868b; font-size: 12px;">
        <a href="https://github.com/SyntheticAutonomicMind/SAM">GitHub Repository</a>
    </p>
</body>
</html>
HTML_FOOT

echo "SUCCESS: Release notes generated: release-notes/$VERSION.html"
echo "File size: $(wc -c < "release-notes/$VERSION.html") bytes"
