#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

set -e

# Bundle Python using python-build-standalone for true relocatable Python
# This solves the hardcoded Homebrew path issue by using pre-built relocatable binaries
#
# python-build-standalone: https://github.com/indygreg/python-build-standalone
# Used by: uv, Rye, PyOxidizer, and other Python distribution tools
#

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# Accept build configuration as parameter (Debug or Release)
BUILD_CONFIG="${1:-Debug}"

APP_BUNDLE="$PROJECT_ROOT/.build/Build/Products/$BUILD_CONFIG/SAM.app"
RESOURCES_DIR="$APP_BUNDLE/Contents/Resources"
PYTHON_DIR="$RESOURCES_DIR/python_env"

# Python version to download
PYTHON_VERSION="3.12.12"
PYTHON_BUILD_DATE="20251120"

# python-build-standalone release info
# Format: cpython-{version}+{build_date}-{arch}-{os}-{variant}.tar.gz
PYTHON_ARCH="aarch64"  # Apple Silicon
PYTHON_OS="apple-darwin"
PYTHON_VARIANT="install_only"  # Includes Python executable (install_only_stripped has no bin/)

PYTHON_RELEASE="cpython-${PYTHON_VERSION}+${PYTHON_BUILD_DATE}-${PYTHON_ARCH}-${PYTHON_OS}-${PYTHON_VARIANT}"
PYTHON_DOWNLOAD_URL="https://github.com/astral-sh/python-build-standalone/releases/download/${PYTHON_BUILD_DATE}/${PYTHON_RELEASE}.tar.gz"

# Cache directory for downloaded Python
PYTHON_CACHE_DIR="$PROJECT_ROOT/.python_cache"
PYTHON_CACHE_FILE="$PYTHON_CACHE_DIR/${PYTHON_RELEASE}.tar.gz"
PYTHON_EXTRACTED_DIR="$PYTHON_CACHE_DIR/${PYTHON_RELEASE}"

echo "===================="
echo "Bundling Python (standalone) into SAM.app ($BUILD_CONFIG)"
echo "===================="
echo ""
echo "Python Version: $PYTHON_VERSION"
echo "Build: $PYTHON_BUILD_DATE"
echo "Architecture: $PYTHON_ARCH"
echo "Variant: $PYTHON_VARIANT"
echo ""

# Check if app bundle exists
if [ ! -d "$APP_BUNDLE" ]; then
    echo "ERROR: SAM.app not found at $APP_BUNDLE"
    echo "Run 'make build-debug' or 'make build-release' first"
    exit 1
fi

# Download python-build-standalone if not cached
if [ ! -f "$PYTHON_CACHE_FILE" ]; then
    echo "Downloading python-build-standalone..."
    echo "URL: $PYTHON_DOWNLOAD_URL"
    mkdir -p "$PYTHON_CACHE_DIR"
    
    curl -L "$PYTHON_DOWNLOAD_URL" -o "$PYTHON_CACHE_FILE" || {
        echo "ERROR: Failed to download Python"
        echo "URL: $PYTHON_DOWNLOAD_URL"
        exit 1
    }
    
    # Verify download isn't corrupted (check size > 10MB)
    FILE_SIZE=$(stat -f%z "$PYTHON_CACHE_FILE" 2>/dev/null || echo "0")
    if [ "$FILE_SIZE" -lt 10000000 ]; then
        echo "ERROR: Downloaded file is too small ($FILE_SIZE bytes), likely corrupted"
        rm -f "$PYTHON_CACHE_FILE"
        exit 1
    fi
    
    echo "SUCCESS: Downloaded Python ($PYTHON_VERSION) - ${FILE_SIZE} bytes"
else
    echo "SUCCESS: Using cached Python download"
fi

# Extract Python - ALWAYS validate bin/ directory exists
STANDALONE_PYTHON="$PYTHON_EXTRACTED_DIR/python"
PYTHON_BIN_CHECK="$STANDALONE_PYTHON/bin/python3.12"

if [ ! -f "$PYTHON_BIN_CHECK" ]; then
    echo "Cache invalid or incomplete - re-extracting Python..."
    rm -rf "$PYTHON_EXTRACTED_DIR"
    mkdir -p "$PYTHON_EXTRACTED_DIR"
    
    tar -xzf "$PYTHON_CACHE_FILE" -C "$PYTHON_EXTRACTED_DIR" || {
        echo "ERROR: Failed to extract Python archive"
        echo "Archive may be corrupted. Removing cache..."
        rm -f "$PYTHON_CACHE_FILE"
        rm -rf "$PYTHON_EXTRACTED_DIR"
        exit 1
    }
    
    # Verify extraction succeeded
    if [ ! -f "$PYTHON_BIN_CHECK" ]; then
        echo "ERROR: Extraction failed - python3.12 not found at $PYTHON_BIN_CHECK"
        echo "Archive may be corrupted. Removing cache..."
        rm -f "$PYTHON_CACHE_FILE"
        rm -rf "$PYTHON_EXTRACTED_DIR"
        exit 1
    fi
    
    echo "SUCCESS: Python extracted and validated"
else
    echo "SUCCESS: Using cached Python extraction (validated)"
fi

echo ""

# Verify the python directory exists
if [ ! -d "$STANDALONE_PYTHON" ]; then
    echo "ERROR: Extracted Python not found at $STANDALONE_PYTHON"
    ls -la "$PYTHON_EXTRACTED_DIR"
    exit 1
fi

# Verify critical directories exist
if [ ! -d "$STANDALONE_PYTHON/bin" ]; then
    echo "ERROR: bin/ directory missing from extracted Python"
    echo "Cache is corrupted. Run: rm -rf .python_cache"
    exit 1
fi

if [ ! -d "$STANDALONE_PYTHON/lib" ]; then
    echo "ERROR: lib/ directory missing from extracted Python"
    echo "Cache is corrupted. Run: rm -rf .python_cache"
    exit 1
fi

# Copy standalone Python to app bundle as base for venv
BUNDLED_PYTHON_BASE="$RESOURCES_DIR/python_base"
echo "Copying standalone Python to app bundle..."

# CRITICAL: Remove existing python_base completely, including protected files
# Use rm -rf with force flags to remove everything
if [ -d "$BUNDLED_PYTHON_BASE" ]; then
    echo "Removing existing python_base..."
    # Strip extended attributes from destination first
    xattr -cr "$BUNDLED_PYTHON_BASE" 2>/dev/null || true
    # Remove with force
    chmod -R u+w "$BUNDLED_PYTHON_BASE" 2>/dev/null || true
    rm -rf "$BUNDLED_PYTHON_BASE" || {
        echo "ERROR: Failed to remove existing python_base"
        echo "Attempting forced removal..."
        sudo rm -rf "$BUNDLED_PYTHON_BASE" || {
            echo "ERROR: Cannot remove protected python_base directory"
            echo "Manual cleanup required: sudo rm -rf $BUNDLED_PYTHON_BASE"
            exit 1
        }
    }
fi

# Strip extended attributes from source that may block copying
# com.apple.provenance can prevent certain directories from being copied
xattr -cr "$STANDALONE_PYTHON" 2>/dev/null || true

# Use ditto for reliable copying on macOS (handles symlinks, attributes, etc.)
ditto "$STANDALONE_PYTHON" "$BUNDLED_PYTHON_BASE" || {
    echo "ERROR: Failed to copy Python to app bundle"
    echo ""
    echo "This can happen if:"
    echo "  1. Previous build left protected files"
    echo "  2. System Integrity Protection (SIP) restrictions"
    echo ""
    echo "Try cleaning build artifacts first:"
    echo "  make clean"
    echo "  rm -rf .build/Build/Products/Debug/SAM.app"
    echo ""
    exit 1
}

# CRITICAL: Verify bin/ directory was copied
if [ ! -d "$BUNDLED_PYTHON_BASE/bin" ]; then
    echo "ERROR: bin/ directory missing after copy"
    echo "This is a critical failure. Debugging info:"
    echo "Source: $STANDALONE_PYTHON"
    echo "Destination: $BUNDLED_PYTHON_BASE"
    ls -la "$STANDALONE_PYTHON/" || true
    ls -la "$BUNDLED_PYTHON_BASE/" || true
    exit 1
fi

# CRITICAL: Verify lib/ directory was copied
if [ ! -d "$BUNDLED_PYTHON_BASE/lib" ]; then
    echo "ERROR: lib/ directory missing after copy"
    exit 1
fi

echo "SUCCESS: Standalone Python bundled to Resources/python_base/"
echo ""

# Find Python executable in standalone build
# python-build-standalone structure: python/bin/python3
PYTHON_EXEC="$BUNDLED_PYTHON_BASE/bin/python3.12"

if [ ! -f "$PYTHON_EXEC" ]; then
    echo "ERROR: Python executable not found at $PYTHON_EXEC"
    echo "Available files in bin/:"
    ls -la "$BUNDLED_PYTHON_BASE/bin/" || echo "bin/ directory doesn't exist"
    exit 1
fi

# Verify Python works and is relocatable
echo "Verifying bundled Python..."
PYTHON_TEST_VERSION=$("$PYTHON_EXEC" --version 2>&1)
echo "Python version: $PYTHON_TEST_VERSION"

# Check that Python has no external dependencies (should be self-contained)
echo "Checking Python dependencies..."
PYTHON_DEPS=$(otool -L "$PYTHON_EXEC" 2>/dev/null || echo "")
if echo "$PYTHON_DEPS" | grep -q "/opt/homebrew\|/usr/local"; then
    echo "WARNING: Python has external dependencies:"
    echo "$PYTHON_DEPS"
    echo ""
    echo "This may cause issues on other systems."
else
    echo "SUCCESS: Python is self-contained (no Homebrew/external dependencies)"
fi

echo ""

# Create virtual environment using bundled Python
echo "Creating Python virtual environment from bundled Python..."
rm -rf "$PYTHON_DIR"
"$PYTHON_EXEC" -m venv "$PYTHON_DIR" || {
    echo "ERROR: Failed to create virtual environment"
    exit 1
}

# Verify venv was created
if [ ! -d "$PYTHON_DIR/bin" ]; then
    echo "ERROR: Virtual environment bin/ directory not created"
    exit 1
fi

# Fix symlinks to be relative (required for code signing)
# The venv creates absolute symlinks which break code signing
echo "Fixing symlinks to be relative..."
cd "$PYTHON_DIR/bin"

# Remove absolute symlinks and create relative ones
# python3 -> ../../python_base/bin/python3.12 (relative)
if [ -L python3 ]; then
    rm python3
fi
ln -s ../../python_base/bin/python3.12 python3

# python -> python3 (relative)
if [ -L python ]; then
    rm python
fi
ln -s python3 python

# python3.12 -> python3 (relative)
if [ -L python3.12 ]; then
    rm python3.12
fi
ln -s python3 python3.12

cd - > /dev/null

# Verify symlinks work
if [ ! -f "$PYTHON_DIR/bin/python3" ]; then
    echo "ERROR: python3 symlink is broken"
    ls -la "$PYTHON_DIR/bin/"
    exit 1
fi

echo "SUCCESS: Virtual environment created from bundled Python"
echo "SUCCESS: Symlinks converted to relative paths"
echo ""

# Create wrapper scripts that set PYTHONHOME before launching Python
# This is CRITICAL because python-build-standalone has /install hardcoded
echo "Creating Python wrapper scripts with PYTHONHOME..."
cd "$PYTHON_DIR/bin"

# Save the original python3 symlink
if [ -L python3.orig ]; then
    rm python3.orig
fi
mv python3 python3.orig

# Create wrapper script for python3
cat > python3 << 'WRAPPER_EOF'
#!/bin/bash
# Python wrapper that sets PYTHONHOME and PYTHONPATH for relocatable python-build-standalone

# Get the directory containing this script
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# Python base is two directories up from bin, then into python_base
export PYTHONHOME="$SCRIPT_DIR/../../python_base"
# CRITICAL: Add venv's site-packages to PYTHONPATH so installed packages are found
# Without this, packages installed in the venv (cv2, basicsr, etc.) won't be importable
export PYTHONPATH="$SCRIPT_DIR/../lib/python3.12/site-packages${PYTHONPATH:+:$PYTHONPATH}"

# Execute the real Python with all arguments
exec "$SCRIPT_DIR/python3.orig" "$@"
WRAPPER_EOF
chmod +x python3

# Update python and python3.12 symlinks to point to wrapper
rm python python3.12
ln -s python3 python
ln -s python3 python3.12

cd - > /dev/null

echo "SUCCESS: Python wrapper scripts created"
echo ""

# Fix pyvenv.cfg to use relative paths (CRITICAL for relocatability)
# The venv creates absolute paths which break when app is moved
echo "Fixing pyvenv.cfg for relocatable installation..."
cat > "$PYTHON_DIR/pyvenv.cfg" << EOF
home = ../python_base/bin
include-system-site-packages = false
version = $PYTHON_VERSION
executable = ../python_base/bin/python3.12
EOF

echo "SUCCESS: pyvenv.cfg rewritten with relative paths"
echo ""

# Set PYTHONHOME to the bundled python_base (required for venv to find standard library)
export PYTHONHOME="$BUNDLED_PYTHON_BASE"
export PATH="$PYTHON_DIR/bin:$PATH"

# Verify we're using the venv Python
VENV_PYTHON="$PYTHON_DIR/bin/python3"
echo "Using venv Python: $VENV_PYTHON"
echo ""

# Upgrade pip
echo "Upgrading pip..."
"$VENV_PYTHON" -m pip install --upgrade pip setuptools wheel --quiet

echo "SUCCESS: Pip upgraded"
echo ""

# Install ML dependencies from requirements.txt
REQUIREMENTS_FILE="$SCRIPT_DIR/requirements.txt"

if [ ! -f "$REQUIREMENTS_FILE" ]; then
    echo "ERROR: requirements.txt not found at $REQUIREMENTS_FILE"
    exit 1
fi

echo "Installing ML dependencies from requirements.txt (this takes 3-5 minutes)..."
echo "Using: $REQUIREMENTS_FILE"
echo ""

# Step 1: Install PyTorch from regular PyPI (macOS gets CPU version by default)
echo "[1/3] Installing PyTorch..."
"$VENV_PYTHON" -m pip install torch==2.5.1 torchvision==0.20.1 || { 
    echo "ERROR: PyTorch installation failed"; 
    exit 1; 
}

echo ""
echo "[2/3] Installing diffusers from git (for Z-Image support)..."
# Step 2a: Install diffusers from git for ZImagePipeline support
"$VENV_PYTHON" -m pip install git+https://github.com/huggingface/diffusers.git || {
    echo "ERROR: Failed to install diffusers from git";
    exit 1;
}

echo ""
echo "[3/3] Installing remaining dependencies..."
# Step 2b: Install all other dependencies from requirements.txt
# PyTorch and diffusers already installed, so pip will skip them
"$VENV_PYTHON" -m pip install -r "$REQUIREMENTS_FILE" || { 
    echo "ERROR: Dependency installation failed"; 
    exit 1; 
}

echo ""
echo "SUCCESS: All dependencies installed"
echo ""

# Patch basicsr for torchvision compatibility
echo "Patching basicsr for torchvision 0.17.0 compatibility..."
python3 "$SCRIPT_DIR/patch_basicsr.py" "$PYTHON_DIR" || {
    echo "ERROR: Failed to patch basicsr"
    exit 1
}
echo ""

# Patch diffusers DPMSolver for IndexError fix
echo "Patching diffusers DPMSolver for IndexError fix..."
python3 "$SCRIPT_DIR/patch_diffusers_dpmsolver.py" "$PYTHON_DIR" || {
    echo "ERROR: Failed to patch diffusers"
    exit 1
}
echo ""

# Patch diffusers DPMSolver SDE for MPS RNG fix
echo "Patching diffusers DPMSolver SDE for MPS RNG fix..."
python3 "$SCRIPT_DIR/patch_diffusers_sde_mps.py" "$PYTHON_DIR/lib/python3.12/site-packages/diffusers/schedulers" || {
    echo "ERROR: Failed to patch diffusers SDE for MPS"
    exit 1
}
echo ""

# Download Real-ESRGAN models
MODELS_DIR="$RESOURCES_DIR/upscale_models"
echo "Downloading Real-ESRGAN upscaling models..."
mkdir -p "$MODELS_DIR"

# Download RealESRGAN_x4plus (general model)
if [ ! -f "$MODELS_DIR/RealESRGAN_x4plus.pth" ]; then
    echo "Downloading RealESRGAN_x4plus (general)..."
    curl -L "https://github.com/xinntao/Real-ESRGAN/releases/download/v0.1.0/RealESRGAN_x4plus.pth" \
         -o "$MODELS_DIR/RealESRGAN_x4plus.pth" || echo "WARNING: Failed to download RealESRGAN_x4plus"
else
    echo "SUCCESS: RealESRGAN_x4plus already downloaded"
fi

# Download RealESRGAN_x4plus_anime_6B (anime model)
if [ ! -f "$MODELS_DIR/RealESRGAN_x4plus_anime_6B.pth" ]; then
    echo "Downloading RealESRGAN_x4plus_anime_6B (anime)..."
    curl -L "https://github.com/xinntao/Real-ESRGAN/releases/download/v0.2.2.4/RealESRGAN_x4plus_anime_6B.pth" \
         -o "$MODELS_DIR/RealESRGAN_x4plus_anime_6B.pth" || echo "WARNING: Failed to download RealESRGAN_x4plus_anime_6B"
else
    echo "SUCCESS: RealESRGAN_x4plus_anime_6B already downloaded"
fi

# Download RealESRNet_x4plus (for 2x scaling base)
if [ ! -f "$MODELS_DIR/RealESRNet_x4plus.pth" ]; then
    echo "Downloading RealESRNet_x4plus (base for 2x)..."
    curl -L "https://github.com/xinntao/Real-ESRGAN/releases/download/v0.1.1/RealESRNet_x4plus.pth" \
         -o "$MODELS_DIR/RealESRNet_x4plus.pth" || echo "WARNING: Failed to download RealESRNet_x4plus"
else
    echo "SUCCESS: RealESRNet_x4plus already downloaded"
fi

echo "SUCCESS: Upscaling models ready"
echo ""

# Unset PYTHONHOME for the rest of the script (no longer needed)
unset PYTHONHOME

# Copy ml-stable-diffusion tools from submodule into Resources for bundled access
TOOLS_SRC="$PROJECT_ROOT/external/ml-stable-diffusion/python_coreml_stable_diffusion"
TOOLS_DST="$RESOURCES_DIR/python_coreml_stable_diffusion"

echo "Copying ml-stable-diffusion tools from submodule..."
if [ -d "$TOOLS_SRC" ]; then
    rm -rf "$TOOLS_DST"
    cp -R "$TOOLS_SRC" "$TOOLS_DST"
    echo "SUCCESS: ml-stable-diffusion tools copied to Resources/"
else
    echo "ERROR: $TOOLS_SRC not found. Did you initialize the submodule?"
    echo "Run: git submodule update --init --recursive"
    exit 1
fi

# Copy conversion script into Resources for bundled access
CONVERT_SCRIPT_SRC="$SCRIPT_DIR/convert_sd_to_coreml.py"
CONVERT_SCRIPT_DST="$RESOURCES_DIR/convert_sd_to_coreml.py"

echo "Copying conversion script..."
if [ -f "$CONVERT_SCRIPT_SRC" ]; then
    cp "$CONVERT_SCRIPT_SRC" "$CONVERT_SCRIPT_DST"
    chmod +x "$CONVERT_SCRIPT_DST"
    echo "SUCCESS: Conversion script copied to Resources/"
else
    echo "WARNING: $CONVERT_SCRIPT_SRC not found, skipping"
fi

# Create scripts directory and copy all generation scripts
SCRIPTS_DIR="$RESOURCES_DIR/scripts"
mkdir -p "$SCRIPTS_DIR"

echo "Copying generation scripts..."

# Copy generate_image_diffusers.py
GEN_SCRIPT_SRC="$SCRIPT_DIR/generate_image_diffusers.py"
GEN_SCRIPT_DST="$SCRIPTS_DIR/generate_image_diffusers.py"
if [ -f "$GEN_SCRIPT_SRC" ]; then
    cp "$GEN_SCRIPT_SRC" "$GEN_SCRIPT_DST"
    chmod +x "$GEN_SCRIPT_DST"
    echo "SUCCESS: Generation script copied: generate_image_diffusers.py"
else
    echo "WARNING: $GEN_SCRIPT_SRC not found, skipping"
fi

# Copy quantize_diffusion_model.py
QUANT_SCRIPT_SRC="$SCRIPT_DIR/quantize_diffusion_model.py"
QUANT_SCRIPT_DST="$SCRIPTS_DIR/quantize_diffusion_model.py"
if [ -f "$QUANT_SCRIPT_SRC" ]; then
    cp "$QUANT_SCRIPT_SRC" "$QUANT_SCRIPT_DST"
    chmod +x "$QUANT_SCRIPT_DST"
    echo "SUCCESS: Quantization script copied: quantize_diffusion_model.py"
else
    echo "WARNING: $QUANT_SCRIPT_SRC not found, skipping"
fi

# Copy upscale_image.py
UPSCALE_SCRIPT_SRC="$SCRIPT_DIR/upscale_image.py"
UPSCALE_SCRIPT_DST="$SCRIPTS_DIR/upscale_image.py"
if [ -f "$UPSCALE_SCRIPT_SRC" ]; then
    cp "$UPSCALE_SCRIPT_SRC" "$UPSCALE_SCRIPT_DST"
    chmod +x "$UPSCALE_SCRIPT_DST"
    echo "SUCCESS: Upscaling script copied: upscale_image.py"
else
    echo "WARNING: $UPSCALE_SCRIPT_SRC not found, skipping"
fi

# Copy train_lora.py (MLX training)
TRAIN_MLX_SCRIPT_SRC="$SCRIPT_DIR/train_lora.py"
TRAIN_MLX_SCRIPT_DST="$SCRIPTS_DIR/train_lora.py"
if [ -f "$TRAIN_MLX_SCRIPT_SRC" ]; then
    cp "$TRAIN_MLX_SCRIPT_SRC" "$TRAIN_MLX_SCRIPT_DST"
    chmod +x "$TRAIN_MLX_SCRIPT_DST"
    echo "SUCCESS: MLX training script copied: train_lora.py"
else
    echo "WARNING: $TRAIN_MLX_SCRIPT_SRC not found, skipping"
fi

# Copy train_lora_gguf.py (GGUF training)
TRAIN_GGUF_SCRIPT_SRC="$SCRIPT_DIR/train_lora_gguf.py"
TRAIN_GGUF_SCRIPT_DST="$SCRIPTS_DIR/train_lora_gguf.py"
if [ -f "$TRAIN_GGUF_SCRIPT_SRC" ]; then
    cp "$TRAIN_GGUF_SCRIPT_SRC" "$TRAIN_GGUF_SCRIPT_DST"
    chmod +x "$TRAIN_GGUF_SCRIPT_DST"
    echo "SUCCESS: GGUF training script copied: train_lora_gguf.py"
else
    echo "WARNING: $TRAIN_GGUF_SCRIPT_SRC not found, skipping"
fi

echo "SUCCESS: All scripts bundled"
echo ""

# Create version file
VENV_PYTHON_VERSION=$("$PYTHON_DIR/bin/python3" --version 2>&1 | cut -d' ' -f2)

cat > "$PYTHON_DIR/SAM_BUNDLE_INFO.txt" << EOF
Python Version: $VENV_PYTHON_VERSION
Source: python-build-standalone (relocatable)
Build: $PYTHON_BUILD_DATE
Bundled: $(date)

Dependencies:
  - torch (CPU-only)
  - diffusers (from git - Z-Image support)
  - transformers
  - safetensors
  - coremltools
  - omegaconf
  - accelerate
  - peft
  - scipy, scikit-learn, matplotlib
  - invisible-watermark, pytest
  - diffusionkit (for ml-stable-diffusion)
  - basicsr (for image processing)
  - realesrgan (for upscaling)
  - gfpgan (for face restoration)

ml-stable-diffusion:
  - Apple's Core ML conversion tools
  - Located: Resources/python_coreml_stable_diffusion/

Image Generation Scripts:
  - generate_image_diffusers.py (Python diffusers engine)
  - convert_sd_to_coreml.py (CoreML conversion)
  - upscale_image.py (Image upscaling)
  - Located: Resources/scripts/

Image Upscaling:
  - Real-ESRGAN models
  - Located: Resources/upscale_models/

Base Python:
  - Standalone Python (no system dependencies)
  - Located: Resources/python_base/

Usage:
  source $PYTHON_DIR/bin/activate
  python scripts/convert_sd_to_coreml.py ...
  python scripts/generate_image_diffusers.py ...
  python scripts/upscale_image.py ...
EOF

echo "===================="
echo "Python bundle complete!"
echo "===================="
echo "Python base: $BUNDLED_PYTHON_BASE"
echo "Virtual environment: $PYTHON_DIR"
echo "Total size: $(du -sh "$RESOURCES_DIR" | cut -f1)"
echo ""
echo "Verification:"
echo "  Python is RELOCATABLE (python-build-standalone)"
echo "  No Homebrew dependencies"
echo "  Self-contained within SAM.app"
echo ""
echo "To use:"
echo "  $PYTHON_DIR/bin/python3 scripts/generate_image_diffusers.py ..."
echo "===================="
