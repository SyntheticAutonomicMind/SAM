# SAM Scripts

Utility scripts for maintaining SAM dependencies and infrastructure.

## Image Generation Scripts

SAM uses Apple's [ml-stable-diffusion](https://github.com/apple/ml-stable-diffusion) for CoreML-based image generation. The ml-stable-diffusion tools are integrated as a git submodule at `external/ml-stable-diffusion/`.

### convert_sd_to_coreml.py

Wrapper script for converting Stable Diffusion models to CoreML format using Apple's ml-stable-diffusion tools.

**Location:** Automatically detects ml-stable-diffusion tools:
- When bundled: `SAM.app/Contents/Resources/python_coreml_stable_diffusion/`
- When running from source: `external/ml-stable-diffusion/python_coreml_stable_diffusion/`

**Dependencies:**
- The SAM fork of ml-stable-diffusion: https://github.com/SyntheticAutonomicMind/ml-stable-diffusion
- Branch: `sam-modifications` (includes fp16/fp32 fallback patch)
- Initialized via: `git submodule update --init --recursive`

### SAM-Specific Utilities

These scripts extend ml-stable-diffusion functionality:

- **attention.py** - Custom attention mechanisms
- **mixed_bit_compression_apply.py** - Apply mixed-bit compression to models
- **mixed_bit_compression_pre_analysis.py** - Pre-analyze models for compression
- **multilingual_projection.py** - Multilingual text encoder support

## sync-org-repos.sh

Syncs SyntheticAutonomicMind org-forked dependencies with their upstream sources.

### Usage

**Sync all repos:**
```bash
./scripts/sync-org-repos.sh
```

**Sync specific repo:**
```bash
./scripts/sync-org-repos.sh mlx-swift
```

### Managed Repositories

The script syncs these org repos with upstream:

| Org Repo | Upstream Source |
|----------|----------------|
| mlx-swift | ml-explore/mlx-swift |
| mlx-swift-examples | ml-explore/mlx-swift-examples |
| ml-stable-diffusion | apple/ml-stable-diffusion |
| swift-transformers | huggingface/swift-transformers |
| swift-http-types | apple/swift-http-types |
| async-http-client | swift-server/async-http-client |
| swift-crypto | apple/swift-crypto |
| swift-log | apple/swift-log |
| vapor | vapor/vapor |
| SQLite.swift | stephencelis/SQLite.swift |
| swift-markdown | apple/swift-markdown |
| ZIPFoundation | weichsel/ZIPFoundation |
| Sparkle | sparkle-project/Sparkle |

### What It Does

1. Clones each org repo to temporary directory
2. Adds upstream remote
3. Fetches latest upstream changes
4. Attempts merge with upstream/main or upstream/master
5. Pushes merged changes back to org repo
6. Cleans up temporary directory

### Conflict Handling

If merge conflicts are detected, the script:
- Skips automatic merge
- Keeps temporary directory for manual resolution
- Reports error in summary

You can then manually resolve conflicts in the temp directory and push.

### Output

The script provides color-coded output:
- 🟢 Green: Successfully synced
- 🟡 Yellow: Already up-to-date (skipped)
- 🔴 Red: Errors or conflicts

### Recommended Schedule

Run weekly or before major dependency updates:
```bash
# Weekly cron job (Sunday at midnight)
0 0 * * 0 /path/to/SAM/scripts/sync-org-repos.sh
```

### GitHub Actions Alternative

For automated syncing, see `.github/workflows/sync-upstream.yml` template in Priority 4 documentation.

## Future Scripts

This directory will contain additional utility scripts as needed for:
- Testing infrastructure
- Build automation
- Deployment tasks
- Dependency management
