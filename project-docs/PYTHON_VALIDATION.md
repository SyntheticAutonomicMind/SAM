# Python Bundle Validation System

## Overview

SAM includes a comprehensive Python environment validation system to ensure builds are 100% complete and functional. The validation runs automatically during CI/CD builds and can also be run locally.

## Validation Script

**Location:** `scripts/validate_python_bundle.sh`

**Purpose:** Validates that the Python environment bundled in SAM.app is complete, properly configured, and all critical dependencies are installed and importable.

## What Gets Validated

### 1. Python Base Structure (python-build-standalone)
- ✓ `python_base/` directory exists
- ✓ `python_base/bin/` contains Python 3.12 executable
- ✓ `python_base/lib/` contains standard library
- ✓ Size is 40-60MB (validates complete extraction)

### 2. Virtual Environment Structure
- ✓ `python_env/` directory exists
- ✓ `python_env/bin/python3` wrapper script exists
- ✓ `pyvenv.cfg` is configured for relocatable installation
- ✓ Site-packages directory contains packages (10+ entries)

### 3. Python Interpreter Functionality
- ✓ Python interpreter executes successfully
- ✓ Python version is 3.12.x
- ✓ Standard library modules (sys, os, json) are importable

### 4. Critical ML Package Imports
The validation tests that all required machine learning packages can be imported:
- ✓ `torch` - PyTorch for ML models
- ✓ `torchvision` - Computer vision utilities
- ✓ `diffusers` - Stable Diffusion pipeline
- ✓ `transformers` - Hugging Face transformers
- ✓ `PIL` - Image processing
- ✓ `numpy` - Numerical computing
- ✓ `cv2` - OpenCV

### 5. Tool Scripts Presence
- ✓ `convert_sd_to_coreml.py` - Model conversion script
- ✓ `scripts/generate_image_diffusers.py` - Image generation
- ✓ `scripts/upscale_image.py` - Image upscaling

## Usage

### Local Development

```bash
# Validate Debug build
./scripts/validate_python_bundle.sh Debug

# Validate Release build
./scripts/validate_python_bundle.sh Release
```

### CI/CD Integration

The validation runs automatically in GitHub Actions workflows:

**build.yml:**
```yaml
- name: Build SAM (Debug)
  run: make build-debug

- name: Validate Python Bundle
  run: ./scripts/validate_python_bundle.sh Debug
```

**release.yml:**
```yaml
- name: Build release package
  run: make build-release

- name: Validate Python Bundle
  run: ./scripts/validate_python_bundle.sh Release
```

## Exit Codes

- **0** - Validation passed, Python environment is complete
- **1** - Validation failed, Python environment has issues

## What Happens on Failure

If validation fails:
1. The CI/CD build **fails immediately** (no artifact created)
2. Detailed error messages show which check failed
3. Suggestions for fixing the issue are provided

This ensures that **incomplete builds never get distributed**.

## Common Failure Scenarios

### Python Base Too Small
```
❌ FAIL: python_base is too small (20MB, expected 40-60MB)
This indicates incomplete Python installation
```
**Cause:** Download or extraction failure  
**Fix:** Clear cache and rebuild
```bash
rm -rf .python_cache
make clean && make build-debug
```

### Cannot Import Critical Package
```
❌ FAIL: Cannot import torch
```
**Cause:** Package installation failure during build  
**Fix:** Check network connectivity, clear Python cache
```bash
rm -rf .python_cache
rm -rf .build/Build/Products/Debug/SAM.app/Contents/Resources/python_*
make build-debug
```

### Missing Tool Scripts
```
❌ FAIL: Missing tool: generate_image_diffusers.py
```
**Cause:** Script copying failed in bundle_python_standalone.sh  
**Fix:** Verify script exists in `scripts/` directory
```bash
ls -la scripts/generate_image_diffusers.py
```

## Implementation Details

### Python-Build-Standalone

SAM uses [python-build-standalone](https://github.com/astral-sh/python-build-standalone) for a truly relocatable Python:
- **Version:** 3.12.12+20251120
- **Architecture:** aarch64 (Apple Silicon)
- **Variant:** install_only (includes bin/ directory)
- **Size:** ~49-56MB (base installation)

### Virtual Environment Structure

The bundled Python environment uses a layered approach:

```
SAM.app/Contents/Resources/
├── python_base/           # Standalone Python (49-56MB)
│   ├── bin/
│   │   └── python3.12
│   ├── lib/
│   │   └── python3.12/
│   └── include/
└── python_env/            # Virtual environment (~2GB with packages)
    ├── bin/
    │   ├── python3        # Wrapper script (sets PYTHONHOME)
    │   ├── python3.12     # Symlink to python3
    │   ├── python         # Symlink to python3
    │   └── python3.orig   # Real Python executable
    ├── lib/
    │   └── python3.12/
    │       └── site-packages/  # Installed packages
    └── pyvenv.cfg         # Relative paths for relocatability
```

### Wrapper Script

The `python3` wrapper sets critical environment variables:
```bash
export PYTHONHOME="$SCRIPT_DIR/../../python_base"
export PYTHONPATH="$SCRIPT_DIR/../lib/python3.12/site-packages${PYTHONPATH:+:$PYTHONPATH}"
exec "$SCRIPT_DIR/python3.orig" "$@"
```

This ensures:
- Python finds its standard library in `python_base`
- Installed packages in `python_env/lib/python3.12/site-packages` are discovered
- The environment is fully relocatable (no hardcoded paths)

## Troubleshooting

### Validation Takes Too Long
The validation script is designed to run in under 30 seconds. If it's taking longer:
1. Check if packages are still being installed
2. Verify Python interpreter isn't hanging
3. Check system resources (CPU, memory)

### False Positives
If validation fails but you believe the environment is correct:
1. Run the failing check manually
2. Inspect the actual error message
3. Verify file permissions (scripts must be executable)

### Debugging Validation
Enable verbose output:
```bash
bash -x ./scripts/validate_python_bundle.sh Debug
```

## Maintenance

### Updating Critical Packages List
To add new required packages to validation:

Edit `scripts/validate_python_bundle.sh`:
```bash
CRITICAL_PACKAGES=(
    "torch"
    "torchvision"
    "diffusers"
    "transformers"
    "PIL"
    "numpy"
    "cv2"
    "your_new_package"  # Add here
)
```

### Updating Size Thresholds
If Python-build-standalone version changes:

Edit size check in `scripts/validate_python_bundle.sh`:
```bash
if [ "$PYTHON_BASE_SIZE" -lt 30 ]; then  # Adjust threshold
    echo "❌ FAIL: python_base is too small"
```

## Related Documentation

- `scripts/bundle_python_standalone.sh` - Python bundling script
- `scripts/requirements.txt` - Python package dependencies
- `BUILDING.md` - Complete build instructions
- `.github/workflows/build.yml` - CI/CD build workflow

## Philosophy

> **SAM must be 100% complete when the build finishes or it should fail.**

The validation system enforces this by:
- **Failing fast** when issues are detected
- **Providing clear error messages** for debugging
- **Testing actual functionality** (not just file existence)
- **Integrating into CI/CD** to prevent distribution of incomplete builds

This ensures users always receive a fully-functional SAM application.
