#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

"""
RealESRGAN Image Upscaling Script

Upscales images using RealESRGAN models.
Works with both CoreML and Python-generated Stable Diffusion images.

Usage:
    python3 upscale_image.py \
        --input path/to/image.png \
        --output path/to/upscaled.png \
        --model general \
        --scale 4
"""

import argparse
import sys
import os
from pathlib import Path

try:
    import cv2
    import numpy as np
    from basicsr.archs.rrdbnet_arch import RRDBNet
    from realesrgan import RealESRGANer
except ImportError as e:
    print(f"ERROR: Missing required package: {e}", file=sys.stderr)
    print("Install with: pip install basicsr realesrgan opencv-python", file=sys.stderr)
    sys.exit(1)


# Model configurations
MODELS = {
    'general': {
        'arch': RRDBNet(num_in_ch=3, num_out_ch=3, num_feat=64, num_block=23, num_grow_ch=32, scale=4),
        'url': 'https://github.com/xinntao/Real-ESRGAN/releases/download/v0.1.0/RealESRGAN_x4plus.pth',
        'scale': 4,
        'name': 'RealESRGAN_x4plus'
    },
    'anime': {
        'arch': RRDBNet(num_in_ch=3, num_out_ch=3, num_feat=64, num_block=6, num_grow_ch=32, scale=4),
        'url': 'https://github.com/xinntao/Real-ESRGAN/releases/download/v0.2.2.4/RealESRGAN_x4plus_anime_6B.pth',
        'scale': 4,
        'name': 'RealESRGAN_x4plus_anime_6B'
    },
    'general_x2': {
        'arch': RRDBNet(num_in_ch=3, num_out_ch=3, num_feat=64, num_block=23, num_grow_ch=32, scale=2),
        'url': 'https://github.com/xinntao/Real-ESRGAN/releases/download/v0.2.1/RealESRGAN_x2plus.pth',
        'scale': 2,
        'name': 'RealESRGAN_x2plus'
    }
}


def download_model(model_type: str, models_dir: Path) -> Path:
    """Download model if not already cached."""
    model_config = MODELS[model_type]
    model_filename = f"{model_config['name']}.pth"
    
    # Check bundled location first (in SAM.app/Contents/Resources/upscale_models/)
    script_path = Path(__file__).resolve()
    
    # Try SAM.app bundle location (development build)
    bundle_models = script_path.parent.parent / ".build" / "Build" / "Products" / "Debug" / "SAM.app" / "Contents" / "Resources" / "upscale_models" / model_filename
    if bundle_models.exists():
        print(f"Using bundled model: {bundle_models}")
        return bundle_models
    
    # Try SAM.app bundle location (release build)
    release_bundle = script_path.parent.parent / ".build" / "Build" / "Products" / "Release" / "SAM.app" / "Contents" / "Resources" / "upscale_models" / model_filename
    if release_bundle.exists():
        print(f"Using bundled model: {release_bundle}")
        return release_bundle
    
    # Try alternative bundle path (for running from installed SAM.app)
    if "SAM.app" in str(script_path):
        # We're inside SAM.app/Contents/Resources
        # Go up to Contents, then to Resources/upscale_models
        parts = script_path.parts
        try:
            app_index = parts.index("SAM.app")
            contents_path = Path(*parts[:app_index+1]) / "Contents" / "Resources" / "upscale_models" / model_filename
            if contents_path.exists():
                print(f"Using bundled model: {contents_path}")
                return contents_path
        except (ValueError, IndexError):
            pass
    
    # Fallback to cache directory
    model_path = models_dir / model_filename
    
    if model_path.exists():
        print(f"Using cached model: {model_path}")
        return model_path
    
    print(f"Downloading {model_type} model...")
    models_dir.mkdir(parents=True, exist_ok=True)
    
    import urllib.request
    urllib.request.urlretrieve(model_config['url'], model_path)
    print(f"Downloaded model to: {model_path}")
    
    return model_path


def upscale_image(
    input_path: str,
    output_path: str,
    model_type: str = 'general',
    outscale: int = 4,
    tile: int = 0,
    tile_pad: int = 10,
    pre_pad: int = 0,
    fp32: bool = False
) -> None:
    """
    Upscale an image using RealESRGAN.
    
    Args:
        input_path: Path to input image
        output_path: Path to save upscaled image
        model_type: Model to use ('general', 'anime', 'general_x2')
        outscale: Final upscaling factor (2 or 4)
        tile: Tile size (0 for no tiling, recommended: 400-800 for large images)
        tile_pad: Padding for tiles
        pre_pad: Pre-padding size
        fp32: Use fp32 precision (slower but more accurate)
    """
    # Validate inputs
    if not os.path.exists(input_path):
        raise FileNotFoundError(f"Input image not found: {input_path}")
    
    if model_type not in MODELS:
        raise ValueError(f"Unknown model type: {model_type}. Choose from: {list(MODELS.keys())}")
    
    # Set up model directory
    cache_dir = Path.home() / "Library" / "Caches" / "sam" / "upscaling-models"
    model_path = download_model(model_type, cache_dir)
    
    # Get model config
    model_config = MODELS[model_type]
    model_scale = model_config['scale']
    
    # Initialize upscaler
    print(f"Initializing RealESRGAN upscaler (model: {model_type}, scale: {outscale}x)...")
    upsampler = RealESRGANer(
        scale=model_scale,
        model_path=str(model_path),
        model=model_config['arch'],
        tile=tile,
        tile_pad=tile_pad,
        pre_pad=pre_pad,
        half=not fp32,  # Use half precision by default for speed
        gpu_id=0  # Use first GPU (Apple Silicon Neural Engine)
    )
    
    # Read input image
    print(f"Reading input image: {input_path}")
    img = cv2.imread(input_path, cv2.IMREAD_UNCHANGED)
    if img is None:
        raise ValueError(f"Failed to read image: {input_path}")
    
    # Get image info
    h, w = img.shape[:2]
    print(f"Input resolution: {w}×{h}")
    
    # Upscale
    print(f"Upscaling image...")
    try:
        output, _ = upsampler.enhance(img, outscale=outscale)
    except RuntimeError as error:
        print(f"ERROR: Upscaling failed: {error}", file=sys.stderr)
        if 'out of memory' in str(error):
            print("TIP: Try using --tile 400 to reduce memory usage", file=sys.stderr)
        raise
    
    # Save result
    output_h, output_w = output.shape[:2]
    print(f"Output resolution: {output_w}×{output_h}")
    
    os.makedirs(os.path.dirname(output_path), exist_ok=True)
    cv2.imwrite(output_path, output)
    print(f"Saved upscaled image: {output_path}")


def main():
    parser = argparse.ArgumentParser(
        description='Upscale images using RealESRGAN',
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  # Upscale with general model (4x)
  python3 upscale_image.py -i input.png -o output.png -m general -s 4
  
  # Upscale anime image (4x)
  python3 upscale_image.py -i anime.png -o upscaled.png -m anime -s 4
  
  # Upscale large image with tiling to reduce memory
  python3 upscale_image.py -i large.png -o output.png -m general -s 4 --tile 400
  
  # Use 2x upscaling for faster processing
  python3 upscale_image.py -i input.png -o output.png -m general_x2 -s 2
        """
    )
    
    parser.add_argument('-i', '--input', required=True, help='Path to input image')
    parser.add_argument('-o', '--output', required=True, help='Path to output upscaled image')
    parser.add_argument(
        '-m', '--model',
        choices=['general', 'anime', 'general_x2'],
        default='general',
        help='Model type to use (default: general)'
    )
    parser.add_argument(
        '-s', '--scale',
        type=int,
        choices=[2, 4],
        default=4,
        help='Output scale factor (default: 4)'
    )
    parser.add_argument(
        '--tile',
        type=int,
        default=0,
        help='Tile size (0 for no tiling). Use 400-800 for large images to reduce memory usage'
    )
    parser.add_argument(
        '--tile-pad',
        type=int,
        default=10,
        help='Tile padding (default: 10)'
    )
    parser.add_argument(
        '--pre-pad',
        type=int,
        default=0,
        help='Pre-padding size (default: 0)'
    )
    parser.add_argument(
        '--fp32',
        action='store_true',
        help='Use fp32 precision (slower but more accurate)'
    )
    
    args = parser.parse_args()
    
    try:
        upscale_image(
            input_path=args.input,
            output_path=args.output,
            model_type=args.model,
            outscale=args.scale,
            tile=args.tile,
            tile_pad=args.tile_pad,
            pre_pad=args.pre_pad,
            fp32=args.fp32
        )
        print("SUCCESS: Image upscaled successfully!")
        return 0
    except Exception as e:
        print(f"ERROR: {e}", file=sys.stderr)
        return 1


if __name__ == '__main__':
    sys.exit(main())
