#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

set -e

# Bundle Python virtual environment and ML dependencies into SAM.app
# Uses system Python + venv for a relocatable, self-contained environment
#
# DEPENDENCY MANAGEMENT:
# - All Python dependencies are managed via requirements.txt
# - requirements.in contains high-level dependencies
# - To update dependencies: edit requirements.in, then run pip-compile
# - Current pinned versions ensure compatibility (e.g., torch 2.0.1 with basicsr)
#

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# Accept build configuration as parameter (Debug or Release)
BUILD_CONFIG="${1:-Debug}"

APP_BUNDLE="$PROJECT_ROOT/.build/Build/Products/$BUILD_CONFIG/SAM.app"
PYTHON_DIR="$APP_BUNDLE/Contents/Resources/python_env"

echo "===================="
echo "Bundling Python into SAM.app ($BUILD_CONFIG)"
echo "===================="
echo ""
echo "Python venv: $PYTHON_DIR"
echo ""

# Check if app bundle exists
if [ ! -d "$APP_BUNDLE" ]; then
    echo "ERROR: SAM.app not found at $APP_BUNDLE"
    echo "Run 'make build-debug' first"
    exit 1
fi

# Check if system Python 3 exists
PYTHON_CMD=""
for py in python3.12 python3.11 python3.10 python3; do
    if command -v $py &> /dev/null; then
        # Check if it's at least Python 3.10
        if $py -c "import sys; sys.exit(0 if sys.version_info >= (3, 10) else 1)" 2>/dev/null; then
            PYTHON_CMD=$py
            break
        fi
    fi
done

if [ -z "$PYTHON_CMD" ]; then
    echo "ERROR: Python 3.10+ not found"
    echo "Install Python: brew install python@3.12"
    exit 1
fi

PYTHON_VERSION=$($PYTHON_CMD --version 2>&1 | cut -d' ' -f2)
echo "Using Python: $PYTHON_CMD ($PYTHON_VERSION)"
echo ""

# Create virtual environment with --copies to avoid symlinks
# Symlinks pointing outside the bundle violate macOS code signing rules
echo "Creating Python virtual environment (using --copies for code signing)..."
rm -rf "$PYTHON_DIR"
$PYTHON_CMD -m venv --copies "$PYTHON_DIR"

echo "✓ Virtual environment created (self-contained, no external symlinks)"
echo ""

# Activate venv
source "$PYTHON_DIR/bin/activate"

# Upgrade pip
echo "Upgrading pip..."
pip install --upgrade pip setuptools wheel --quiet

echo "✓ Pip upgraded"
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
echo "[1/2] Installing PyTorch..."
pip install torch==2.5.1 torchvision==0.20.1 || { 
    echo "ERROR: PyTorch installation failed"; 
    exit 1; 
}

echo ""
echo "[2/2] Installing diffusers from git (for Z-Image support)..."
# Step 2a: Install diffusers from git for ZImagePipeline support
pip install git+https://github.com/huggingface/diffusers.git || {
    echo "ERROR: Failed to install diffusers from git";
    exit 1;
}

echo ""
echo "[2/3] Installing remaining dependencies..."
# Step 2b: Install all other dependencies from requirements.txt
# PyTorch and diffusers already installed, so pip will skip them
pip install -r "$REQUIREMENTS_FILE" || { 
    echo "ERROR: Dependency installation failed"; 
    exit 1; 
}

echo ""
echo "✓ All dependencies installed"
echo ""

# Patch basicsr for torchvision compatibility
echo "Patching basicsr for torchvision 0.17.0 compatibility..."
python3 "$SCRIPT_DIR/patch_basicsr.py" "$PYTHON_DIR" || {
    echo "ERROR: Failed to patch basicsr"
    exit 1
}
echo ""

# Download Real-ESRGAN models
MODELS_DIR="$APP_BUNDLE/Contents/Resources/upscale_models"
echo "Downloading Real-ESRGAN upscaling models..."
mkdir -p "$MODELS_DIR"

# Download RealESRGAN_x4plus (general model)
if [ ! -f "$MODELS_DIR/RealESRGAN_x4plus.pth" ]; then
    echo "Downloading RealESRGAN_x4plus (general)..."
    curl -L "https://github.com/xinntao/Real-ESRGAN/releases/download/v0.1.0/RealESRGAN_x4plus.pth" \
         -o "$MODELS_DIR/RealESRGAN_x4plus.pth" || echo "WARNING: Failed to download RealESRGAN_x4plus"
else
    echo "✓ RealESRGAN_x4plus already downloaded"
fi

# Download RealESRGAN_x4plus_anime_6B (anime model)
if [ ! -f "$MODELS_DIR/RealESRGAN_x4plus_anime_6B.pth" ]; then
    echo "Downloading RealESRGAN_x4plus_anime_6B (anime)..."
    curl -L "https://github.com/xinntao/Real-ESRGAN/releases/download/v0.2.2.4/RealESRGAN_x4plus_anime_6B.pth" \
         -o "$MODELS_DIR/RealESRGAN_x4plus_anime_6B.pth" || echo "WARNING: Failed to download RealESRGAN_x4plus_anime_6B"
else
    echo "✓ RealESRGAN_x4plus_anime_6B already downloaded"
fi

# Download RealESRNet_x4plus (for 2x scaling base)
if [ ! -f "$MODELS_DIR/RealESRNet_x4plus.pth" ]; then
    echo "Downloading RealESRNet_x4plus (base for 2x)..."
    curl -L "https://github.com/xinntao/Real-ESRGAN/releases/download/v0.1.1/RealESRNet_x4plus.pth" \
         -o "$MODELS_DIR/RealESRNet_x4plus.pth" || echo "WARNING: Failed to download RealESRNet_x4plus"
else
    echo "✓ RealESRNet_x4plus already downloaded"
fi

echo "✓ Upscaling models ready"
echo ""

# Deactivate venv
deactivate

# Copy ml-stable-diffusion tools into Resources for bundled access
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TOOLS_SRC="$SCRIPT_DIR/python_coreml_stable_diffusion"
TOOLS_DST="$PYTHON_DIR/../python_coreml_stable_diffusion"

echo "Copying ml-stable-diffusion tools..."
if [ -d "$TOOLS_SRC" ]; then
    rm -rf "$TOOLS_DST"
    cp -R "$TOOLS_SRC" "$TOOLS_DST"
    echo "✓ ml-stable-diffusion tools copied to Resources/"
else
    echo "WARNING: $TOOLS_SRC not found, skipping"
fi

# Copy conversion script into Resources for bundled access
CONVERT_SCRIPT_SRC="$SCRIPT_DIR/convert_sd_to_coreml.py"
CONVERT_SCRIPT_DST="$PYTHON_DIR/../convert_sd_to_coreml.py"

echo "Copying conversion script..."
if [ -f "$CONVERT_SCRIPT_SRC" ]; then
    cp "$CONVERT_SCRIPT_SRC" "$CONVERT_SCRIPT_DST"
    chmod +x "$CONVERT_SCRIPT_DST"
    echo "✓ Conversion script copied to Resources/"
else
    echo "WARNING: $CONVERT_SCRIPT_SRC not found, skipping"
fi

# Create scripts directory and copy all generation scripts
SCRIPTS_DIR="$PYTHON_DIR/../scripts"
mkdir -p "$SCRIPTS_DIR"

echo "Copying generation scripts..."

# Copy generate_image_diffusers.py
GEN_SCRIPT_SRC="$SCRIPT_DIR/generate_image_diffusers.py"
GEN_SCRIPT_DST="$SCRIPTS_DIR/generate_image_diffusers.py"
if [ -f "$GEN_SCRIPT_SRC" ]; then
    cp "$GEN_SCRIPT_SRC" "$GEN_SCRIPT_DST"
    chmod +x "$GEN_SCRIPT_DST"
    echo "✓ Generation script copied: generate_image_diffusers.py"
else
    echo "WARNING: $GEN_SCRIPT_SRC not found, skipping"
fi

# Copy quantize_diffusion_model.py
QUANT_SCRIPT_SRC="$SCRIPT_DIR/quantize_diffusion_model.py"
QUANT_SCRIPT_DST="$SCRIPTS_DIR/quantize_diffusion_model.py"
if [ -f "$QUANT_SCRIPT_SRC" ]; then
    cp "$QUANT_SCRIPT_SRC" "$QUANT_SCRIPT_DST"
    chmod +x "$QUANT_SCRIPT_DST"
    echo "✓ Quantization script copied: quantize_diffusion_model.py"
else
    echo "WARNING: $QUANT_SCRIPT_SRC not found, skipping"
fi

# Copy upscale_image.py
UPSCALE_SCRIPT_SRC="$SCRIPT_DIR/upscale_image.py"
UPSCALE_SCRIPT_DST="$SCRIPTS_DIR/upscale_image.py"
if [ -f "$UPSCALE_SCRIPT_SRC" ]; then
    cp "$UPSCALE_SCRIPT_SRC" "$UPSCALE_SCRIPT_DST"
    chmod +x "$UPSCALE_SCRIPT_DST"
    echo "✓ Upscaling script copied: upscale_image.py"
else
    echo "WARNING: $UPSCALE_SCRIPT_SRC not found, skipping"
fi

echo "✓ All scripts bundled"
echo ""

# Create version file
cat > "$PYTHON_DIR/SAM_BUNDLE_INFO.txt" << EOF
Python Version: $PYTHON_VERSION
Bundled: $(date)
Dependencies:
  - torch (CPU-only)
  - diffusers
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

Usage:
  source $PYTHON_DIR/bin/activate
  python scripts/convert_sd_to_coreml.py ...
  python scripts/generate_image_diffusers.py ...
  python scripts/upscale_image.py ...
EOF

echo "===================="
echo "Python bundle complete!"
echo "===================="
echo "Virtual environment: $PYTHON_DIR"
echo "Size: $(du -sh "$PYTHON_DIR" | cut -f1)"
echo ""
echo "To use:"
echo "  $PYTHON_DIR/bin/python3 scripts/convert_sd_to_coreml.py ..."
echo "===================="
