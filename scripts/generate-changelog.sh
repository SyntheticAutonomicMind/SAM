#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)


# Generate CHANGELOG.md from git tags
# Usage: ./generate-changelog.sh [output-file] [--from-tag TAG] [--to-tag TAG]
#
# Examples:
#   ./generate-changelog.sh                    # Full changelog to stdout
#   ./generate-changelog.sh CHANGELOG.md       # Full changelog to file
#   ./generate-changelog.sh --from-tag v1.0.0  # Changes since v1.0.0
#   ./generate-changelog.sh --from-tag v1.0.0 --to-tag v2.0.0  # Changes between tags

set -e

OUTPUT_FILE=""
FROM_TAG=""
TO_TAG=""

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --from-tag)
            FROM_TAG="$2"
            shift 2
            ;;
        --to-tag)
            TO_TAG="$2"
            shift 2
            ;;
        --help|-h)
            echo "Generate CHANGELOG.md from git tags"
            echo ""
            echo "Usage: $0 [output-file] [OPTIONS]"
            echo ""
            echo "OPTIONS:"
            echo "  --from-tag TAG   Start from this tag (exclusive)"
            echo "  --to-tag TAG     End at this tag (inclusive)"
            echo "  --help, -h       Show this help"
            echo ""
            echo "Examples:"
            echo "  $0                              # Full changelog to stdout"
            echo "  $0 CHANGELOG.md                 # Full changelog to file"
            echo "  $0 --from-tag v1.0.0            # Changes since v1.0.0"
            echo "  $0 release-notes.md --from-tag v1.0.0 --to-tag v2.0.0"
            exit 0
            ;;
        *)
            if [ -z "$OUTPUT_FILE" ]; then
                OUTPUT_FILE="$1"
            else
                echo "Unknown option: $1"
                exit 1
            fi
            shift
            ;;
    esac
done

# Function to output (to file or stdout)
output() {
    if [ -n "$OUTPUT_FILE" ]; then
        echo "$1" >> "$OUTPUT_FILE"
    else
        echo "$1"
    fi
}

# Clear output file if specified
if [ -n "$OUTPUT_FILE" ]; then
    > "$OUTPUT_FILE"
fi

# Header
output "# Changelog"
output ""
output "All notable changes to SAM are documented in this file."
output ""
output "The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),"
output "and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html)."
output ""

# Get tags (YYYYMMDD.* format)
if [ -n "$TO_TAG" ] && [ -n "$FROM_TAG" ]; then
    # Specific range
    TAGS=$(git tag -l '[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9].*' --sort=-version:refname | sed -n "/$TO_TAG/,/$FROM_TAG/p" | head -n -1)
elif [ -n "$FROM_TAG" ]; then
    # From tag to HEAD
    TAGS=$(git tag -l '[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9].*' --sort=-version:refname | sed "/$FROM_TAG/q" | head -n -1)
elif [ -n "$TO_TAG" ]; then
    # From beginning to tag
    TAGS=$(git tag -l '[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9].*' --sort=-version:refname | sed -n "1,/$TO_TAG/p")
else
    # All tags (YYYYMMDD.RELEASE format)
    TAGS=$(git tag -l '[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9].*' --sort=-version:refname 2>/dev/null || echo "")
fi

if [ -z "$TAGS" ]; then
    output "## [Unreleased]"
    output ""
    output "This is the initial release of SAM - Synthetic Autonomic Mind."
    output ""
    output "### Added"
    output "- Multi-provider AI support (OpenAI, Anthropic, GitHub Copilot, DeepSeek, MLX, GGUF)"
    output "- 15 MCP tools with 46+ operations"
    output "- Vector RAG memory system"
    output "- Shared Topics for multi-conversation projects"
    output "- Stable Diffusion image generation"
    output "- Native macOS SwiftUI interface"
    output "- OpenAI-compatible REST API"
    exit 0
fi

PREV_TAG=""
for TAG in $TAGS; do
    # Get tag date
    TAG_DATE=$(git log -1 --format=%ai "$TAG" 2>/dev/null | cut -d' ' -f1)
    
    output ""
    output "## [$TAG] - $TAG_DATE"
    output ""
    
    # Determine range
    if [ -n "$PREV_TAG" ]; then
        RANGE="$TAG..$PREV_TAG"
    else
        # Most recent tag - get commits from previous tag to this one
        NEXT_TAG=$(echo "$TAGS" | grep -A1 "^$TAG$" | tail -1)
        if [ "$NEXT_TAG" != "$TAG" ] && [ -n "$NEXT_TAG" ]; then
            RANGE="$NEXT_TAG..$TAG"
        else
            RANGE="$TAG~50..$TAG"
        fi
    fi
    
    # Collect commits by type
    ADDED=""
    FIXED=""
    CHANGED=""
    DOCS=""
    OTHER=""
    
    while IFS= read -r COMMIT; do
        [ -z "$COMMIT" ] && continue
        
        if [[ "$COMMIT" =~ ^feat(\(.+\))?:\ (.+) ]]; then
            ADDED="${ADDED}- ${BASH_REMATCH[2]}\n"
        elif [[ "$COMMIT" =~ ^fix(\(.+\))?:\ (.+) ]]; then
            FIXED="${FIXED}- ${BASH_REMATCH[2]}\n"
        elif [[ "$COMMIT" =~ ^refactor(\(.+\))?:\ (.+) ]]; then
            CHANGED="${CHANGED}- ${BASH_REMATCH[2]}\n"
        elif [[ "$COMMIT" =~ ^docs(\(.+\))?:\ (.+) ]]; then
            DOCS="${DOCS}- ${BASH_REMATCH[2]}\n"
        elif [[ "$COMMIT" =~ ^chore(\(.+\))?:\ (.+) ]]; then
            # Skip chore commits from changelog
            :
        else
            OTHER="${OTHER}- ${COMMIT}\n"
        fi
    done < <(git log --pretty=format:"%s" "$RANGE" 2>/dev/null)
    
    # Output sections
    if [ -n "$ADDED" ]; then
        output "### Added"
        echo -e "$ADDED" | while read -r line; do
            [ -n "$line" ] && output "$line"
        done
        output ""
    fi
    
    if [ -n "$FIXED" ]; then
        output "### Fixed"
        echo -e "$FIXED" | while read -r line; do
            [ -n "$line" ] && output "$line"
        done
        output ""
    fi
    
    if [ -n "$CHANGED" ]; then
        output "### Changed"
        echo -e "$CHANGED" | while read -r line; do
            [ -n "$line" ] && output "$line"
        done
        output ""
    fi
    
    if [ -n "$DOCS" ]; then
        output "### Documentation"
        echo -e "$DOCS" | while read -r line; do
            [ -n "$line" ] && output "$line"
        done
        output ""
    fi
    
    # Only include OTHER if nothing else was found
    if [ -z "$ADDED" ] && [ -z "$FIXED" ] && [ -z "$CHANGED" ] && [ -z "$DOCS" ]; then
        if [ -n "$OTHER" ]; then
            output "### Other"
            echo -e "$OTHER" | while read -r line; do
                [ -n "$line" ] && output "$line"
            done
            output ""
        else
            output "*No conventional commits found for this release.*"
            output ""
        fi
    fi
    
    PREV_TAG=$TAG
done

if [ -n "$OUTPUT_FILE" ]; then
    echo "SUCCESS: Generated changelog: $OUTPUT_FILE"
fi
