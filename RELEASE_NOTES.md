# SAM Release Notes System

This document explains how to generate and publish beautiful HTML release notes for Sparkle updates.

## Overview

SAM uses a two-tier release notes system:

1. **whats-new.json** - Structured data with features, improvements, and descriptions
2. **HTML Release Notes** - Generated from whats-new.json for Sparkle's release notes window

## Quick Start

### 1. Update whats-new.json

Add a new release entry to `Resources/whats-new.json`:

```json
{
  "releases": [
    {
      "version": "20251230.1",
      "release_date": "December 30, 2025",
      "introduction": "Brief summary of the release",
      "highlights": [
        {
          "id": "unique-id",
          "icon": "system.icon.name",
          "title": "Feature Title",
          "description": "What it does and why it matters"
        }
      ],
      "improvements": [
        {
          "id": "unique-id",
          "icon": "system.icon.name",
          "title": "Improvement Title",
          "description": "What changed and why"
        }
      ]
    }
  ]
}
```

### 2. Generate HTML Release Notes

```bash
./scripts/generate_release_notes.sh 20251230.1
```

This creates `release-notes/20251230.1.html` with styled, formatted release notes.

### 3. Host the HTML (Options)

#### Option A: GitHub Raw (Recommended for now)

1. Commit the generated HTML:
   ```bash
   git add -f release-notes/20251230.1.html
   git commit -m "docs: add release notes for 20251230.1"
   git push
   ```

2. Get the raw GitHub URL:
   ```
   https://raw.githubusercontent.com/SyntheticAutonomicMind/SAM/main/release-notes/20251230.1.html
   ```

3. Update `appcast.xml` to use this URL:
   ```xml
   <sparkle:releaseNotesLink>
     https://raw.githubusercontent.com/SyntheticAutonomicMind/SAM/main/release-notes/20251230.1.html
   </sparkle:releaseNotesLink>
   ```

#### Option B: GitHub Pages (Future Enhancement)

1. Enable GitHub Pages in repository settings
2. Set source to `main` branch, `/docs` folder
3. Move generated HTML to `docs/release-notes/`
4. URL becomes: `https://syntheticautonomicmind.github.io/SAM/release-notes/20251230.1.html`

#### Option C: Embedded in appcast.xml (Current Default)

The `update_appcast.sh` script currently generates inline HTML in the `<description>` tag with a link to GitHub releases.

To use generated HTML instead, modify `update_appcast.sh` to:
- Check for `release-notes/$VERSION.html`
- Extract just the `<body>` content
- Embed it in the `<description>` CDATA section

## HTML Generation Details

The `generate_release_notes.sh` script:

1. Reads `Resources/whats-new.json`
2. Finds the release matching the version
3. Generates styled HTML with:
   - Apple-style typography and spacing
   - Highlight sections (major features)
   - Improvement sections (smaller changes)
   - Responsive design
   - Proper accessibility

### Styling

The generated HTML uses:
- `-apple-system` font stack for native macOS appearance
- Blue accent color (#0071e3) matching Sparkle's default theme
- Semantic HTML5 structure
- Inline CSS (no external dependencies)

## File Locations

| File | Purpose | Committed? |
|------|---------|------------|
| `Resources/whats-new.json` | Source of truth for release notes | ✅ Yes |
| `scripts/generate_release_notes.sh` | HTML generator script | ✅ Yes |
| `release-notes/*.html` | Generated HTML files | ❌ No (gitignored by default) |

**Note:** HTML files are gitignored to avoid committing generated content. Commit them explicitly with `-f` if hosting on GitHub raw.

## Integration with Release Workflow

### Automated Release (GitHub Actions)

The `.github/workflows/release.yml` currently:
1. Builds the app
2. Signs and notarizes
3. Generates appcast.xml with basic release notes (GitHub link)

**To integrate HTML release notes:**

Add these steps before "Update appcast.xml":

```yaml
- name: Generate HTML Release Notes
  run: |
    VERSION=${{ steps.version.outputs.VERSION }}
    ./scripts/generate_release_notes.sh "$VERSION"

- name: Commit Release Notes
  run: |
    VERSION=${{ steps.version.outputs.VERSION }}
    git add -f "release-notes/${VERSION}.html"
    git commit -m "docs: add release notes for ${VERSION}"
    git push origin HEAD:main
```

Then modify `scripts/update_appcast.sh` to use the generated HTML.

### Manual Release

1. Update `Info.plist` version
2. Update `Resources/whats-new.json`
3. Generate HTML: `./scripts/generate_release_notes.sh 20251230.1`
4. Commit HTML (if hosting on GitHub): `git add -f release-notes/20251230.1.html`
5. Build: `make build-release`
6. Sign: `make sign-release`
7. Update appcast: `./scripts/update_appcast.sh 20251230.1 dist/SAM-20251230.1.zip`
8. Commit and push

## Testing Release Notes Locally

To preview the generated HTML:

```bash
./scripts/generate_release_notes.sh 20251230.1
open release-notes/20251230.1.html
```

This opens the HTML in your default browser for review.

## Sparkle Integration

Sparkle displays release notes in a WebView when:
- User clicks "Check for Updates"
- Automatic update check finds a new version

The content can come from:
1. `<description>` tag (inline HTML/text)
2. `<sparkle:releaseNotesLink>` (external URL)
3. Both (description shown first, then link)

### Current Behavior

```xml
<sparkle:releaseNotesLink>
  https://github.com/SyntheticAutonomicMind/SAM/releases/tag/20251230.1
</sparkle:releaseNotesLink>
```

Shows GitHub release page in embedded iframe (not ideal).

### Improved Behavior

```xml
<description><![CDATA[
  <h1>What's New in SAM 20251230.1</h1>
  <div class="introduction">...</div>
  <!-- Full formatted HTML from generator -->
]]></description>
```

Displays rich, styled release notes directly in the update window.

## Future Enhancements

### 1. Markdown Support

Generate Markdown from whats-new.json for GitHub releases:

```bash
./scripts/generate_release_changelog.sh 20251230.1 > CHANGELOG.md
```

### 2. Multi-Language Support

Add language field to whats-new.json and generate localized HTML:

```bash
./scripts/generate_release_notes.sh 20251230.1 --lang fr
```

### 3. Automated Testing

Validate whats-new.json structure:

```bash
./scripts/validate_release_notes.sh
```

### 4. Inline Images

Support for feature screenshots in release notes.

## Troubleshooting

### "Version X.Y.Z not found in whats-new.json"

Ensure the version in whats-new.json exactly matches the version you're generating for:

```bash
# Check what versions exist
jq '.releases[].version' Resources/whats-new.json
```

### "jq: command not found"

Install jq (JSON processor):

```bash
brew install jq
```

### HTML not rendering in Sparkle

- Check that the HTML is valid (open in browser)
- Ensure `<description>` tag has `<![CDATA[` wrapper
- Verify Sparkle can access the URL (if using external link)

## See Also

- `VERSIONING.md` - Version numbering scheme
- `BUILDING.md` - Build and release process
- `scripts/update_appcast.sh` - Appcast update script
- [Sparkle Documentation](https://sparkle-project.org/documentation/)
