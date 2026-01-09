# SAM Versioning Scheme

**Effective:** December 13, 2025  
**Format:** `YYYYMMDD.RELEASE`

## Overview

SAM uses a date-based versioning scheme with daily release counters to ensure consistent version comparison across builds and updates.

## Version Format

```
YYYYMMDD.RELEASE
```

**Components:**
- `YYYYMMDD`: Date of release (e.g., 20251213 for December 13, 2025)
- `RELEASE`: Daily release counter starting at 1 (e.g., 1, 2, 3...)

**Examples:**
- `20251213.1` - First release on December 13, 2025
- `20251213.2` - Second release on December 13, 2025
- `20251214.1` - First release on December 14, 2025

## Development Releases

Development builds use the same date-based scheme with a `-dev.BUILD` suffix:

```
YYYYMMDD.RELEASE-dev.BUILD
```

**Components:**
- `YYYYMMDD.RELEASE`: Base stable version this development build is targeting
- `BUILD`: Development build counter starting at 1

**Examples:**
- `20251213.1-dev.1` - First development build for eventual 20251213.1 release
- `20251213.1-dev.2` - Second development build
- `20251213.1` - Final stable release (supersedes all -dev builds)

**Version Comparison:**

Sparkle compares versions numerically and lexicographically:
- `20251213.1-dev.1` < `20251213.1-dev.2` (later dev build)
- `20251213.1-dev.2` < `20251213.1` (stable supersedes dev)
- `20251213.1` < `20251214.1-dev.1` (next day's dev build)

Users on the development channel receive all `-dev` builds plus stable releases.
Users on the stable channel never see `-dev` builds.

**Workflow:**
1. Make changes to codebase
2. Run `make build-dev` - automatically increments version to `-dev.N`
3. Build, sign, and create GitHub pre-release with `-dev` tag
4. Development channel users receive the update
5. When ready for stable, remove `-dev` suffix and create normal release

## Usage

Both `CFBundleVersion` and `CFBundleShortVersionString` use the same value:

```xml
<key>CFBundleShortVersionString</key>
<string>20251213.1</string>
<key>CFBundleVersion</key>
<string>20251213.1</string>
```

## Sparkle Appcast

In `appcast.xml`, use the same version for both attributes:

```xml
<enclosure 
    url="https://github.com/SyntheticAutonomicMind/SAM/releases/download/v20251213.1/SAM-20251213.1.dmg"
    sparkle:version="20251213.1"
    sparkle:shortVersionString="20251213.1"
    length="FILE_SIZE"
    type="application/octet-stream"
/>
```

## Version Comparison

Sparkle compares versions numerically:
- `20251213.1` < `20251213.2` (same day, later release)
- `20251213.2` < `20251214.1` (next day)
- `20251201.5` < `20251213.1` (earlier month)

This ensures consistent and predictable update behavior.

## Why This Scheme?

**Advantages:**
1. **Simple:** Easy to generate and increment
2. **Consistent:** Both bundle version and short version use same value
3. **Numeric:** Sparkle can compare versions reliably
4. **Chronological:** Versions sort naturally by date
5. **Multi-release:** Supports multiple releases per day

**Previous Issues:**
- Semantic versioning (0.90.0 vs 1.1.0) caused string comparison problems
- Separate `CFBundleVersion` (20251213) and `CFBundleShortVersionString` (0.90.0) created confusion
- Sparkle couldn't determine which version was newer

## Release Process

When creating a new release:

1. **Determine version**: `YYYYMMDD.RELEASE` format
   - Date: Current date in YYYYMMDD format (e.g., 20251230)
   - Release: Daily counter starting at 1 (e.g., 1 for first release of the day)

2. **Update Info.plist**:
   ```bash
   VERSION="20251230.1"
   /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" Info.plist
   /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $VERSION" Info.plist
   ```
   
   **Note:** The build system (`scripts/set-build-version.sh`) automatically ensures both fields match.

3. **Update Resources/whats-new.json** with new version entry:
   - Add release object with version, date, introduction, highlights, and improvements
   - See `RELEASE_NOTES.md` for structure details

4. **Generate HTML release notes** (optional but recommended):
   ```bash
   ./scripts/generate_release_notes.sh 20251230.1
   ```
   This creates styled HTML from whats-new.json for Sparkle's update window.

5. **Build release**: `make build-release`

6. **Sign and notarize**: `make sign-release`
   - Creates signed DMG and ZIP in `dist/`

7. **Update appcast.xml**:
   ```bash
   ./scripts/update_appcast.sh 20251230.1 dist/SAM-20251230.1.zip
   ```

8. **Commit changes**:
   ```bash
   git add Info.plist Resources/whats-new.json appcast.xml
   git commit -m "chore(release): prepare 20251230.1"
   ```

9. **Tag release**:
   ```bash
   git tag 20251230.1
   git push origin main --tags
   ```

10. **Upload to GitHub releases**:
    - GitHub Actions workflow (`.github/workflows/release.yml`) handles this automatically on tag push
    - Manual: Upload `dist/SAM-20251230.1.dmg` and `dist/SAM-20251230.1.zip` to GitHub release

See `RELEASE_NOTES.md` for details on the HTML release notes system.

## Migration Notes

**From:** 0.90.0 (CFBundleShortVersionString) + 20251213 (CFBundleVersion)  
**To:** 20251213.1 (both fields unified)

All future releases will use the unified YYYYMMDD.RELEASE scheme.
