#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

"""
Convert Stable Diffusion safetensors model to Core ML format for SAM.

This script handles the complete conversion pipeline:
1. Load safetensors checkpoint
2. Convert to HuggingFace diffusers format
3. Convert diffusers to Core ML using Apple's tools
4. Package for Swift ml-stable-diffusion framework

Usage:
    python3 scripts/convert_sd_to_coreml.py <input.safetensors> <output_dir>

Requirements:
    pip install torch torchvision diffusers transformers accelerate safetensors omegaconf coremltools
"""

import sys
import os
import argparse
import shutil
import tempfile
from pathlib import Path
import json


def check_dependencies():
    """Check if required packages are installed."""
    required = {
        'torch': 'torch',
        'diffusers': 'diffusers',
        'transformers': 'transformers',
        'safetensors': 'safetensors',
        'coremltools': 'coremltools',
    }
    
    missing = []
    for package, import_name in required.items():
        try:
            __import__(import_name)
        except ImportError:
            missing.append(package)
    
    if missing:
        print(f"ERROR: Missing required packages: {', '.join(missing)}", file=sys.stderr)
        print(f"Install with: pip3 install {' '.join(missing)}", file=sys.stderr)
        return False
    
    return True


def detect_model_type(safetensors_path: str) -> str:
    """
    Detect SD model type (SD 1.x, SD 2.x, or SDXL) from safetensors checkpoint.
    
    Returns:
        Model type string: 'sd1', 'sd2', or 'sdxl'
    """
    print("Detecting model architecture...")
    
    try:
        from safetensors import safe_open
        
        with safe_open(safetensors_path, framework="pt", device="cpu") as f:
            keys = list(f.keys())
        
        # Check for SDXL indicators
        if any('conditioner' in key for key in keys):
            print("Detected: Stable Diffusion XL")
            return 'sdxl'
        
        # Check for SD 2.x indicators (larger text encoder)
        if any('text_model.encoder.layers.23' in key for key in keys):
            print("Detected: Stable Diffusion 2.x")
            return 'sd2'
        
        # Default to SD 1.x
        print("Detected: Stable Diffusion 1.x")
        return 'sd1'
        
    except Exception as e:
        print(f"Warning: Could not detect model type: {e}", file=sys.stderr)
        print("Defaulting to SD 1.x", file=sys.stderr)
        return 'sd1'


def convert_to_diffusers(safetensors_path: str, diffusers_dir: str, model_type: str, lora_paths: list = None, lora_scales: list = None):
    """
    Convert safetensors checkpoint to HuggingFace diffusers format.
    
    Args:
        safetensors_path: Path to .safetensors checkpoint
        diffusers_dir: Output directory for diffusers format
        model_type: Model type ('sd1', 'sd2', or 'sdxl')
        lora_paths: Optional list of LoRA .safetensors paths to fuse
        lora_scales: Optional list of scales for each LoRA (default 1.0)
    """
    print(f"\nStep 1/3: Converting safetensors to diffusers format...")
    print(f"Input: {safetensors_path}")
    print(f"Output: {diffusers_dir}")
    
    if lora_paths:
        print(f"LoRAs to fuse: {len(lora_paths)}")
        for i, lora_path in enumerate(lora_paths):
            scale = lora_scales[i] if lora_scales and i < len(lora_scales) else 1.0
            print(f"  - {os.path.basename(lora_path)} (scale: {scale})")
    
    from diffusers import StableDiffusionPipeline, StableDiffusionXLPipeline
    
    try:
        # Use from_single_file for direct safetensors loading
        print("Loading checkpoint and converting...")
        
        # Select appropriate pipeline class
        if model_type == 'sdxl':
            PipelineClass = StableDiffusionXLPipeline
        else:
            PipelineClass = StableDiffusionPipeline
        
        # Load from safetensors file
        pipe = PipelineClass.from_single_file(
            safetensors_path,
            torch_dtype='auto',
            safety_checker=None,
            feature_extractor=None,
        )
        
        # Fuse LoRAs if provided
        if lora_paths:
            print("\nFusing LoRAs into model...")
            for i, lora_path in enumerate(lora_paths):
                scale = lora_scales[i] if lora_scales and i < len(lora_scales) else 1.0
                lora_name = os.path.basename(lora_path)
                
                print(f"Loading LoRA: {lora_name} (scale: {scale})")
                
                # Load LoRA weights
                pipe.load_lora_weights(lora_path)
                
                # Fuse into model (permanent)
                print(f"Fusing LoRA with scale {scale}...")
                pipe.fuse_lora(lora_scale=scale)
                
                # Unload LoRA adapter after fusion
                pipe.unload_lora_weights()
                
                print(f"  Successfully fused {lora_name}")
            
            print("All LoRAs fused into base model")
        
        # Save to diffusers format
        print(f"Saving diffusers pipeline to {diffusers_dir}...")
        pipe.save_pretrained(diffusers_dir)
        print("Diffusers conversion complete")
        
        return True
        
    except Exception as e:
        print(f"ERROR: Diffusers conversion failed: {e}", file=sys.stderr)
        import traceback
        traceback.print_exc()
        return False


def convert_to_coreml(diffusers_dir: str, coreml_dir: str, model_type: str):
    """
    Convert diffusers format to Core ML using coremltools.
    
    Args:
        diffusers_dir: Directory containing diffusers pipeline
        coreml_dir: Output directory for Core ML models
        model_type: Model type for optimization hints
    """
    print(f"\nStep 2/3: Converting diffusers to Core ML...")
    print(f"Input: {diffusers_dir}")
    print(f"Output: {coreml_dir}")
    print("This will take 10-30 minutes depending on your hardware...")
    
    try:
        import subprocess
        
        print("Using Apple's ml-stable-diffusion conversion tools...")
        
        # Determine location of ml-stable-diffusion tools
        # Priority:
        #   1. Bundled in SAM.app/Contents/Resources/python_coreml_stable_diffusion/
        #   2. In external/ml-stable-diffusion/python_coreml_stable_diffusion/
        
        # Check if running from bundled Python (inside SAM.app)
        python_path = sys.executable
        if "SAM.app/Contents/Resources/python_env" in python_path:
            # Use bundled tools in Resources/
            resources_dir = os.path.dirname(os.path.dirname(python_path))
            bundled_tools = os.path.join(resources_dir, "python_coreml_stable_diffusion")
            if os.path.exists(bundled_tools):
                tools_dir = resources_dir
                torch2coreml_path = os.path.join(bundled_tools, "torch2coreml.py")
            else:
                # Fallback to submodule in external/
                script_dir = os.path.dirname(os.path.abspath(__file__))
                project_root = os.path.dirname(script_dir)
                tools_dir = os.path.join(project_root, "external", "ml-stable-diffusion")
                torch2coreml_path = os.path.join(tools_dir, "python_coreml_stable_diffusion", "torch2coreml.py")
        else:
            # Running from source (use submodule)
            script_dir = os.path.dirname(os.path.abspath(__file__))
            project_root = os.path.dirname(script_dir)
            tools_dir = os.path.join(project_root, "external", "ml-stable-diffusion")
            torch2coreml_path = os.path.join(tools_dir, "python_coreml_stable_diffusion", "torch2coreml.py")
        
        if not os.path.exists(torch2coreml_path):
            raise FileNotFoundError(f"ml-stable-diffusion tools not found at {torch2coreml_path}")
        
        print(f"Using tools from: {tools_dir}")
        
        # Build command line arguments with PYTHONPATH set to tools directory
        env = os.environ.copy()
        env['PYTHONPATH'] = tools_dir + ':' + env.get('PYTHONPATH', '')
        
        cmd = [
            sys.executable,  # Use same Python interpreter
            torch2coreml_path,
            "--model-version", diffusers_dir,
            "-o", coreml_dir,
            "--compute-unit", "ALL",
            "--attention-implementation", "SPLIT_EINSUM",
            "--bundle-resources-for-swift-cli",
            "--convert-vae-decoder",  # Convert VAE decoder
            "--convert-text-encoder",  # Convert text encoder
            "--convert-unet",  # Convert UNet (main model)
        ]
        
        # Run conversion with updated PYTHONPATH
        print(f"Running: {' '.join(cmd)}")
        result = subprocess.run(cmd, capture_output=False, text=True, env=env)
        
        if result.returncode != 0:
            print(f"ERROR: Conversion failed with code {result.returncode}")
            return False
        
        print("✓ Core ML conversion complete")
        
        return True
        
    except Exception as e:
        print(f"ERROR: Core ML conversion failed: {e}", file=sys.stderr)
        import traceback
        traceback.print_exc()
        return False


def package_for_swift(coreml_dir: str, output_dir: str):
    """
    Reorganize Core ML models to SAM's expected directory structure.
    
    Apple's torch2coreml creates:
        coreml/Resources/*.mlmodelc + vocab.json + merges.txt
    
    SAM expects:
        original/compiled/*.mlmodelc + vocab.json + merges.txt
    
    Args:
        coreml_dir: Directory containing Core ML models from torch2coreml
        output_dir: Final output directory for the model
    """
    print(f"\nStep 3/3: Reorganizing for SAM compatibility...")
    
    # Check for Resources directory (created by torch2coreml)
    resources_dir = os.path.join(coreml_dir, "Resources")
    if not os.path.exists(resources_dir):
        print(f"ERROR: Resources directory not found at {resources_dir}")
        return False
    
    # Verify required models exist in Resources/
    required_models = ["Unet.mlmodelc", "TextEncoder.mlmodelc", "VAEDecoder.mlmodelc", "vocab.json", "merges.txt"]
    missing = []
    
    for model in required_models:
        path = os.path.join(resources_dir, model)
        if not os.path.exists(path):
            missing.append(model)
    
    if missing:
        print(f"ERROR: Missing required models: {missing}")
        return False
    
    # Create SAM's expected directory structure: original/compiled/
    compiled_dir = os.path.join(output_dir, "original", "compiled")
    os.makedirs(compiled_dir, exist_ok=True)
    
    print(f"Moving models from {resources_dir} to {compiled_dir}")
    
    # Move all .mlmodelc directories and tokenizer files
    import shutil
    for item in os.listdir(resources_dir):
        src_path = os.path.join(resources_dir, item)
        dst_path = os.path.join(compiled_dir, item)
        
        # Remove destination if it exists
        if os.path.exists(dst_path):
            if os.path.isdir(dst_path):
                shutil.rmtree(dst_path)
            else:
                os.remove(dst_path)
        
        # Move the item
        shutil.move(src_path, dst_path)
        print(f"  ✓ {item}")
    
    # Remove now-empty coreml directory
    if os.path.exists(coreml_dir):
        shutil.rmtree(coreml_dir)
        print(f"Cleaned up temporary {coreml_dir}")
    
    print(f"✓ Model packaged at: {compiled_dir}")
    print(f"✓ Structure: {output_dir}/original/compiled/")
    return True


def main():
    parser = argparse.ArgumentParser(
        description="Convert Stable Diffusion safetensors to Core ML",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  # Convert SD 1.5 model
  python3 convert_sd_to_coreml.py model.safetensors output/

  # Convert with explicit model type
  python3 convert_sd_to_coreml.py model.safetensors output/ --model-type sdxl

  # Convert with LoRA fusion
  python3 convert_sd_to_coreml.py model.safetensors output/ --lora lora1.safetensors --lora-scale 1.0

  # Convert with multiple LoRAs
  python3 convert_sd_to_coreml.py model.safetensors output/ --lora lora1.safetensors --lora lora2.safetensors --lora-scale 1.0 --lora-scale 0.8

Notes:
  - This requires significant disk space (~15-20GB) and RAM (~10-16GB)
  - Conversion typically takes 15-30 minutes
  - Ensure you have the latest coremltools: pip install -U coremltools
  - LoRA fusion is permanent - the LoRA is "baked into" the model
        """
    )
    
    parser.add_argument("input", help="Path to input .safetensors file")
    parser.add_argument("output", help="Output directory for Core ML model")
    parser.add_argument("--model-type", choices=['sd1', 'sd2', 'sdxl'],
                        help="Model type (auto-detected if not specified)")
    parser.add_argument("--lora", action="append", dest="loras",
                        help="Path to LoRA .safetensors file (can be specified multiple times)")
    parser.add_argument("--lora-scale", action="append", type=float, dest="lora_scales",
                        help="Scale for corresponding LoRA (default: 1.0)")
    parser.add_argument("--keep-diffusers", action="store_true",
                        help="Keep intermediate diffusers format")
    parser.add_argument("--skip-check", action="store_true",
                        help="Skip dependency checks")
    
    args = parser.parse_args()
    
    # Validate input
    if not os.path.exists(args.input):
        print(f"ERROR: Input file not found: {args.input}", file=sys.stderr)
        return 1
    
    if not args.input.endswith('.safetensors'):
        print(f"ERROR: Input must be .safetensors format, got: {args.input}", file=sys.stderr)
        return 1
    
    # Validate LoRAs if provided
    if args.loras:
        for lora_path in args.loras:
            if not os.path.exists(lora_path):
                print(f"ERROR: LoRA file not found: {lora_path}", file=sys.stderr)
                return 1
            if not lora_path.endswith('.safetensors'):
                print(f"ERROR: LoRA must be .safetensors format, got: {lora_path}", file=sys.stderr)
                return 1
        
        # Default scales to 1.0 if not provided
        if not args.lora_scales:
            args.lora_scales = [1.0] * len(args.loras)
        elif len(args.lora_scales) < len(args.loras):
            # Pad with 1.0 for missing scales
            args.lora_scales.extend([1.0] * (len(args.loras) - len(args.lora_scales)))
    
    # Check dependencies
    if not args.skip_check:
        print("Checking dependencies...")
        if not check_dependencies():
            return 1
        print("All dependencies found\n")
    
    # Detect model type
    model_type = args.model_type
    if not model_type:
        model_type = detect_model_type(args.input)
    
    # Create temporary directory for diffusers format
    temp_dir = tempfile.mkdtemp(prefix="sd_diffusers_")
    diffusers_dir = temp_dir if not args.keep_diffusers else os.path.join(args.output, "diffusers")
    
    try:
        # Step 1: Convert to diffusers (with LoRA fusion if requested)
        if not convert_to_diffusers(args.input, diffusers_dir, model_type, args.loras, args.lora_scales):
            return 1
        
        # Step 2: Convert to Core ML
        coreml_dir = os.path.join(args.output, "coreml")
        if not convert_to_coreml(diffusers_dir, coreml_dir, model_type):
            return 1
        
        # Step 3: Reorganize for SAM compatibility
        if not package_for_swift(coreml_dir, args.output):
            print("\nWarning: Failed to reorganize model structure")
            print("Model may not be compatible with SAM")
            return 1
        
        print(f"\n{'='*60}")
        print("SUCCESS: Model converted and ready for use!")
        if args.loras:
            print(f"LoRAs fused: {len(args.loras)}")
        print(f"{'='*60}")
        print(f"\nModel location: {args.output}/original/compiled/")
        print(f"\nThe model is now ready to use in SAM.")
        print(f"SAM will automatically detect it on next launch.")
        print(f"{'='*60}\n")
        
        return 0
        
    finally:
        # Cleanup temporary directory unless keeping diffusers
        if not args.keep_diffusers and os.path.exists(temp_dir):
            print(f"\nCleaning up temporary files...")
            shutil.rmtree(temp_dir)


if __name__ == "__main__":
    sys.exit(main())
