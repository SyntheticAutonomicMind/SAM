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

1. Determine today's date: `YYYYMMDD`
2. Increment release counter (or use 1 for first daily release)
3. Update `Info.plist`:
   ```bash
   /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString 20251213.1" Info.plist
   /usr/libexec/PlistBuddy -c "Set :CFBundleVersion 20251213.1" Info.plist
   ```
4. Update `Resources/whats-new.json` with new version entry
5. Run `make production` (automatically updates `appcast.xml`)
6. Verify appcast.xml has correct version
7. Upload DMG to GitHub releases as `SAM-20251213.1.dmg`
8. Tag release: `git tag v20251213.1 && git push --tags`

## Migration Notes

**From:** 0.90.0 (CFBundleShortVersionString) + 20251213 (CFBundleVersion)  
**To:** 20251213.1 (both fields unified)

All future releases will use the unified YYYYMMDD.RELEASE scheme.
