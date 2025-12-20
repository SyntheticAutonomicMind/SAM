#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

"""
Python Diffusers Stable Diffusion Generation Script

Generates images using Python diffusers library with full scheduler support.
Uses .safetensors models from SAM models directory.

Features:
- Compel prompt weighting: (important subject:1.3) (background:0.7)
- Long prompt support (exceeds 77 token limit)
- Full scheduler support

Usage:
    python3 generate_image_diffusers.py \
        --model ~/Library/Caches/sam/models/stable-diffusion/model-name/model.safetensors \
        --prompt "a serene mountain landscape" \
        --output image.png \
        --scheduler dpm++_sde_karras \
        --steps 25 \
        --guidance 7.5
"""

import argparse
import sys
import os
import json
import psutil
from pathlib import Path
from typing import Optional, Tuple, Any

try:
    import torch
    from PIL import Image
    from diffusers import (
        StableDiffusionPipeline,
        StableDiffusionImg2ImgPipeline,
        ZImagePipeline,
        AutoPipelineForText2Image,
        AutoPipelineForImage2Image,
        DPMSolverMultistepScheduler,
        EulerDiscreteScheduler,
        EulerAncestralDiscreteScheduler,
        DDIMScheduler,
        PNDMScheduler,
        LMSDiscreteScheduler,
        FlowMatchEulerDiscreteScheduler,
        FlowMatchHeunDiscreteScheduler
    )
    import importlib
    from safetensors.torch import load_file, save_file
except ImportError as e:
    print(f"ERROR: Missing required package: {e}", file=sys.stderr)
    print("Install with: pip install torch diffusers transformers accelerate safetensors", file=sys.stderr)
    sys.exit(1)

# Optional: Compel for prompt weighting and long prompts
# Syntax: (emphasized word:1.3), (de-emphasized:0.5), word++, word--
COMPEL_AVAILABLE = False
try:
    from compel import Compel, ReturnedEmbeddingsType
    COMPEL_AVAILABLE = True
    print("Compel available: prompt weighting and long prompts enabled")
except ImportError:
    print("Note: Install 'compel' for prompt weighting: (important:1.3) syntax")


def process_prompt_with_compel(
    pipe: Any,
    prompt: str,
    negative_prompt: str = "",
    is_sdxl: bool = False
) -> Tuple[Any, Any]:
    """
    Process prompts with Compel for weighting and long prompt support.
    
    Compel enables:
    - Prompt weighting: (important subject:1.3), (less important:0.7)
    - Shortcuts: word++ (=1.1), word-- (=0.9)
    - Long prompts: Splits prompts exceeding 77 tokens
    
    Args:
        pipe: The diffusers pipeline
        prompt: Main prompt with optional Compel syntax
        negative_prompt: Negative prompt with optional Compel syntax
        is_sdxl: Whether this is an SDXL model (needs different handling)
        
    Returns:
        Tuple of (prompt_embeds, negative_prompt_embeds) for SDXL
        Tuple of (prompt_embeds, negative_prompt_embeds) for SD 1.x
    """
    if not COMPEL_AVAILABLE:
        return None, None
    
    try:
        if is_sdxl:
            # SDXL has two text encoders
            compel = Compel(
                tokenizer=[pipe.tokenizer, pipe.tokenizer_2],
                text_encoder=[pipe.text_encoder, pipe.text_encoder_2],
                returned_embeddings_type=ReturnedEmbeddingsType.PENULTIMATE_HIDDEN_STATES_NON_NORMALIZED,
                requires_pooled=[False, True]
            )
            
            prompt_embeds, pooled_prompt_embeds = compel(prompt)
            if negative_prompt:
                neg_embeds, neg_pooled = compel(negative_prompt)
            else:
                neg_embeds, neg_pooled = compel("")
                
            return {
                "prompt_embeds": prompt_embeds,
                "pooled_prompt_embeds": pooled_prompt_embeds,
                "negative_prompt_embeds": neg_embeds,
                "negative_pooled_prompt_embeds": neg_pooled
            }, None
        else:
            # SD 1.x has single text encoder
            compel = Compel(
                tokenizer=pipe.tokenizer,
                text_encoder=pipe.text_encoder
            )
            
            prompt_embeds = compel.build_conditioning_tensor(prompt)
            if negative_prompt:
                neg_embeds = compel.build_conditioning_tensor(negative_prompt)
            else:
                neg_embeds = compel.build_conditioning_tensor("")
            
            # Pad to same length for classifier-free guidance
            [prompt_embeds, neg_embeds] = compel.pad_conditioning_tensors_to_same_length(
                [prompt_embeds, neg_embeds]
            )
            
            return prompt_embeds, neg_embeds
            
    except Exception as e:
        print(f"Warning: Compel processing failed ({e}), using standard prompts")
        return None, None


def remap_fp8_weights(safetensors_path):
    """
    Remap FP8 model weights from fused QKV to split Q/K/V format.
    FP8 quantized models use fused attention.qkv.weight but diffusers expects split weights.
    
    Returns the path to use (either original or remapped file).
    """
    import torch
    print(f"Checking for FP8 weight remapping: {safetensors_path}")
    
    # Load weights
    state_dict = load_file(safetensors_path)
    
    # Check if remapping is needed (has fused QKV weights)
    needs_remap = any('.attention.qkv.weight' in key for key in state_dict.keys())
    
    if not needs_remap:
        print("No weight remapping needed")
        return safetensors_path
    
    print("FP8 model with fused QKV weights detected - splitting into to_q/to_k/to_v")
    
    # Remap keys and split QKV weights
    remapped = {}
    for key, value in state_dict.items():
        if '.attention.qkv.weight' in key:
            # Split fused QKV weight into separate Q, K, V weights
            # QKV is typically concatenated along dim 0: [3*hidden_dim, ...]
            hidden_dim = value.shape[0] // 3
            q, k, v = torch.split(value, hidden_dim, dim=0)
            
            # Create separate keys
            base_key = key.replace('.qkv.weight', '')
            remapped[f'{base_key}.to_q.weight'] = q
            remapped[f'{base_key}.to_k.weight'] = k
            remapped[f'{base_key}.to_v.weight'] = v
            print(f"  Split {key} -> to_q/to_k/to_v ({q.shape})")
        elif '.attention.out.weight' in key:
            # Rename out -> to_out.0
            new_key = key.replace('.out.weight', '.to_out.0.weight')
            remapped[new_key] = value
        elif '.attention.q_norm.weight' in key:
            # Rename q_norm -> norm_q
            new_key = key.replace('.q_norm.weight', '.norm_q.weight')
            remapped[new_key] = value
        elif '.attention.k_norm.weight' in key:
            # Rename k_norm -> norm_k
            new_key = key.replace('.k_norm.weight', '.norm_k.weight')
            remapped[new_key] = value
        else:
            # Keep other weights as-is
            remapped[key] = value
    
    # Save remapped weights to a temporary file
    remapped_path = safetensors_path.parent / f"{safetensors_path.stem}_remapped.safetensors"
    
    # Only save if not already exists (to avoid re-processing)
    if not remapped_path.exists():
        save_file(remapped, str(remapped_path))
        print(f"Saved remapped weights ({len(remapped)} keys) to: {remapped_path}")
    else:
        print(f"Using existing remapped weights: {remapped_path}")
    
    return remapped_path


# Scheduler mapping
# NOTE: All DPM++ variants use solver_order=1 and lower_order_final=True to avoid IndexError
# (IndexError: index N is out of bounds for dimension 0 with size N)
# This is a known issue with second-order updates in DPMSolverMultistepScheduler on MPS
# lower_order_final=True uses first-order on final step to avoid the index error
SCHEDULERS = {
    'dpm++': {
        'class': DPMSolverMultistepScheduler,
        # solver_order=1, lower_order_final=True avoids IndexError on final step
        'config': {'use_karras_sigmas': False, 'algorithm_type': 'dpmsolver++', 'solver_order': 1, 'lower_order_final': True}
    },
    'dpm++_karras': {
        'class': DPMSolverMultistepScheduler,
        # solver_order=1, lower_order_final=True avoids IndexError on final step
        'config': {'use_karras_sigmas': True, 'algorithm_type': 'dpmsolver++', 'solver_order': 1, 'lower_order_final': True}
    },
    'dpm++_sde': {
        'class': DPMSolverMultistepScheduler,
        # solver_order=1, lower_order_final=True avoids IndexError on final step
        'config': {'use_karras_sigmas': False, 'algorithm_type': 'sde-dpmsolver++', 'solver_order': 1, 'lower_order_final': True}
    },
    'dpm++_sde_karras': {
        'class': DPMSolverMultistepScheduler,
        # solver_order=1, lower_order_final=True avoids IndexError on final step
        'config': {'use_karras_sigmas': True, 'algorithm_type': 'sde-dpmsolver++', 'solver_order': 1, 'lower_order_final': True}
    },
    'euler': {
        'class': EulerDiscreteScheduler,
        'config': {}
    },
    'euler_a': {
        'class': EulerAncestralDiscreteScheduler,
        'config': {}
    },
    'euler_ancestral': {
        'class': EulerAncestralDiscreteScheduler,
        'config': {}
    },
    'ddim': {
        'class': DDIMScheduler,
        'config': {}
    },
    'ddim_uniform': {
        'class': DDIMScheduler,
        'config': {'timestep_spacing': 'linspace'}
    },
    'pndm': {
        'class': PNDMScheduler,
        'config': {}
    },
    'lms': {
        'class': LMSDiscreteScheduler,
        'config': {}
    },
    'flow_match_euler': {
        'class': FlowMatchEulerDiscreteScheduler,
        'config': {}
    },
    'flow_match_heun': {
        'class': FlowMatchHeunDiscreteScheduler,
        'config': {}
    }
}


# Pipeline name mapping for renamed/aliased pipelines
# Maps model_index.json _class_name to actual diffusers class name
PIPELINE_NAME_MAPPING = {
    # Add mappings here if pipelines are renamed in future diffusers versions
}


def detect_pipeline_class(model_path: Path, is_img2img: bool = False):
    """
    Detect appropriate pipeline class for the model.
    
    Reads model_index.json to determine pipeline type dynamically.
    Supports Stable Diffusion, Z-Image, Qwen-Image, and other diffusion models.
    
    Args:
        model_path: Path to model (.safetensors file or directory)
        is_img2img: Whether to use img2img pipeline variant
        
    Returns:
        tuple: (PipelineClass, model_type_name)
    """
    # Default to Stable Diffusion
    default_pipeline = StableDiffusionImg2ImgPipeline if is_img2img else StableDiffusionPipeline
    default_type = "Stable Diffusion"
    
    # If loading from single file, use default (can't detect from single file)
    if model_path.is_file():
        print(f"Loading from single file - using default {default_type} pipeline")
        return default_pipeline, default_type
    
    # Try to read model_index.json from directory
    model_index_path = model_path / "model_index.json"
    if not model_index_path.exists():
        print(f"No model_index.json found - using default {default_type} pipeline")
        return default_pipeline, default_type
    
    try:
        with open(model_index_path, 'r') as f:
            model_index = json.load(f)
        
        # Get pipeline class name
        pipeline_class_name = model_index.get('_class_name', '')
        if not pipeline_class_name:
            print(f"No _class_name in model_index.json - using default {default_type} pipeline")
            return default_pipeline, default_type
        
        print(f"Detected pipeline class: {pipeline_class_name}")
        
        # Check if pipeline name needs mapping (e.g., ZImagePipeline -> QwenImagePipeline)
        actual_pipeline_name = PIPELINE_NAME_MAPPING.get(pipeline_class_name, pipeline_class_name)
        if actual_pipeline_name != pipeline_class_name:
            print(f"Mapped pipeline name: {pipeline_class_name} -> {actual_pipeline_name}")
        
        # For img2img mode, try to find img2img variant
        if is_img2img:
            # Try common img2img naming patterns
            img2img_variants = [
                actual_pipeline_name.replace('Pipeline', 'Img2ImgPipeline'),
                actual_pipeline_name + 'Img2Img',
                # Add more patterns as needed
            ]
            
            for variant_name in img2img_variants:
                try:
                    # Try to import the variant
                    module = importlib.import_module('diffusers')
                    if hasattr(module, variant_name):
                        PipelineClass = getattr(module, variant_name)
                        print(f"Using img2img variant: {variant_name}")
                        return PipelineClass, actual_pipeline_name.replace('Pipeline', '')
                except Exception as e:
                    continue
            
            # If no img2img variant found, warn and use base pipeline
            print(f"Warning: No img2img variant found for {actual_pipeline_name}, using text-to-image pipeline")
        
        # Try to dynamically import the pipeline class
        try:
            module = importlib.import_module('diffusers')
            if hasattr(module, actual_pipeline_name):
                PipelineClass = getattr(module, actual_pipeline_name)
                model_type = actual_pipeline_name.replace('Pipeline', '')
                print(f"Successfully loaded pipeline: {actual_pipeline_name}")
                return PipelineClass, model_type
            else:
                print(f"Warning: Pipeline class '{actual_pipeline_name}' not found in diffusers, using default")
                return default_pipeline, default_type
        except Exception as e:
            print(f"Warning: Failed to import pipeline '{actual_pipeline_name}': {e}")
            return default_pipeline, default_type
            
    except Exception as e:
        print(f"Error reading model_index.json: {e}")
        return default_pipeline, default_type


def should_use_low_memory(model_path: Path) -> bool:
    """
    Determine if low_cpu_mem_usage should be enabled based on system RAM and model size.
    
    Args:
        model_path: Path to model directory or file
        
    Returns:
        True if model size > 80% of available system RAM, False otherwise
    """
    try:
        # Get system RAM in bytes
        system_ram = psutil.virtual_memory().total
        system_ram_gb = system_ram / (1024**3)
        
        # Calculate model size
        model_size = 0
        if model_path.is_file():
            # Single file model
            model_size = model_path.stat().st_size
        elif model_path.is_dir():
            # Directory-based model - sum all files
            for file_path in model_path.rglob('*'):
                if file_path.is_file():
                    model_size += file_path.stat().st_size
        
        model_size_gb = model_size / (1024**3)
        
        # Use low memory if model is >75% of RAM
        # This leaves headroom for OS and other processes
        threshold = system_ram * 0.75
        use_low_mem = model_size > threshold
        
        print(f"\n=== Memory Detection ===")
        print(f"System RAM: {system_ram_gb:.2f} GB")
        print(f"Model size: {model_size_gb:.2f} GB ({model_size_gb/system_ram_gb*100:.1f}% of RAM)")
        print(f"Low memory mode: {'ENABLED' if use_low_mem else 'DISABLED'} (threshold: 75% of RAM)")
        print(f"======================\n")
        
        return use_low_mem
        
    except Exception as e:
        print(f"Warning: Failed to detect memory requirements: {e}")
        print("Defaulting to low_cpu_mem_usage=False for compatibility")
        return False


def get_scheduler(scheduler_name: str, pipeline_config):
    """Get scheduler instance from name, ensuring compatibility."""
    if scheduler_name not in SCHEDULERS:
        raise ValueError(f"Unknown scheduler: {scheduler_name}. Choose from: {list(SCHEDULERS.keys())}")
    
    scheduler_info = SCHEDULERS[scheduler_name]
    
    # Get base configuration from pipeline, but filter out incompatible keys
    # Some schedulers (like Z-Image's) have custom parameters that don't work with standard schedulers
    config_dict = dict(pipeline_config)
    
    # Remove keys that are specific to certain schedulers and might cause incompatibility
    # Flow-matching schedulers have different configs than diffusion schedulers
    # CRITICAL: steps_offset causes off-by-one errors in DPMSolverMultistep when ignored
    # (IndexError: index 26 is out of bounds for dimension 0 with size 26)
    incompatible_keys = ['mu', 'timestep_type', 'rescale_betas_zero_snr', 'variance_type', 
                        'clip_sample', 'clip_sample_range', 'thresholding', 'dynamic_thresholding_ratio',
                        'sample_max_value', 'prediction_type', 'steps_offset']
    for key in incompatible_keys:
        config_dict.pop(key, None)
    
    try:
        return scheduler_info['class'].from_config(
            config_dict,
            **scheduler_info['config']
        )
    except Exception as e:
        # If scheduler creation fails, try with minimal config
        print(f"Warning: Failed to create scheduler with pipeline config ({e}), using defaults")
        return scheduler_info['class'](**scheduler_info['config'])


def generate_image(
    model_path: str,
    prompt: str,
    output_path: str,
    negative_prompt: str = "",
    scheduler: str = "dpm++_sde_karras",
    steps: int = 25,
    guidance_scale: float = 7.5,
    width: int = 512,
    height: int = 512,
    seed: Optional[int] = None,
    num_images: int = 1,
    input_image: Optional[str] = None,
    strength: float = 0.75,
    device: str = "auto",
    lora_paths: Optional[list] = None,
    lora_weights: Optional[list] = None
) -> None:
    """
    Generate images using diffusers pipeline (text-to-image or image-to-image).
    
    Args:
        model_path: Path to .safetensors model file or directory
        prompt: Text prompt for generation
        output_path: Path to save generated image (or base path for multiple images)
        negative_prompt: Negative prompt
        scheduler: Scheduler name (dpm++_sde_karras, euler, etc.)
        steps: Number of inference steps
        guidance_scale: Guidance scale
        width: Image width (text-to-image only)
        height: Image height (text-to-image only)
        seed: Random seed (None for random)
        num_images: Number of images to generate
        input_image: Path to input image for img2img (None for text-to-image)
        strength: Denoising strength for img2img (0.0-1.0, lower=more like input)
        device: Compute device ("auto", "mps", "cpu")
        lora_paths: List of paths to LoRA .safetensors files
        lora_weights: List of weights for each LoRA (0.0-1.0, default 1.0)
    """
    # Check if model exists
    model_path = Path(model_path)
    if not model_path.exists():
        raise FileNotFoundError(f"Model not found: {model_path}")
    
    # Determine if img2img mode
    is_img2img = input_image is not None
    init_img = None
    
    if is_img2img:
        input_image_path = Path(input_image)
        if not input_image_path.exists():
            raise FileNotFoundError(f"Input image not found: {input_image_path}")
        
        # Load and prepare input image
        init_img = Image.open(input_image_path).convert("RGB")
        print(f"Input image loaded: {input_image_path} ({init_img.size[0]}x{init_img.size[1]})")
        
        # Resize to match target dimensions for consistency
        if init_img.size != (width, height):
            print(f"Resizing input image from {init_img.size[0]}x{init_img.size[1]} to {width}x{height}")
            init_img = init_img.resize((width, height), Image.Resampling.LANCZOS)
    
    # Determine device based on parameter
    if device == "auto":
        # Auto-detect best available device
        if torch.backends.mps.is_available():
            device = "mps"
            print("Auto-selected: Apple Silicon (MPS) acceleration")
        elif torch.cuda.is_available():
            device = "cuda"
            print("Auto-selected: CUDA GPU acceleration")
        else:
            device = "cpu"
            print("Auto-selected: CPU")
    elif device == "mps":
        if not torch.backends.mps.is_available():
            print("Warning: MPS requested but not available, falling back to CPU")
            device = "cpu"
        else:
            print("Using Apple Silicon (MPS) acceleration")
    elif device == "cpu":
        print("Using CPU")
    else:
        print(f"Unknown device '{device}', using CPU")
        device = "cpu"
    
    # Load pipeline with appropriate precision
    # NOTE: MPS requires float32 to avoid black images
    # NOTE: CPU offloading will be enabled for large models
    print(f"Loading model from: {model_path}")
    
    # Detect appropriate pipeline class for this model
    PipelineClass, model_type = detect_pipeline_class(model_path, is_img2img)
    print(f"Using {model_type} pipeline ({'img2img' if is_img2img else 'txt2img'} mode)")
    
    # Check if this is a multi-part diffusers model
    is_multipart = (model_path / "model_index.json").exists() if model_path.is_dir() else False
    
    # For multi-part models with transformer, check for FP8 weight remapping
    if is_multipart:
        transformer_dir = model_path / "transformer"
        if transformer_dir.exists():
            transformer_weights = transformer_dir / "diffusion_pytorch_model.safetensors"
            if transformer_weights.exists():
                # Remap FP8 weights if needed (creates remapped file)
                remapped_weights = remap_fp8_weights(transformer_weights)
                
                # If remapped file was created, update the original symlink
                if remapped_weights != transformer_weights:
                    # Backup original if not already backed up
                    backup_path = transformer_dir / "diffusion_pytorch_model_original.safetensors"
                    if not backup_path.exists():
                        os.rename(transformer_weights, backup_path)
                        print(f"Backed up original weights to: {backup_path}")
                    
                    # Create symlink from original name to remapped file
                    if transformer_weights.exists():
                        transformer_weights.unlink()
                    os.symlink(remapped_weights.name, transformer_weights)
                    print(f"Created symlink: {transformer_weights} -> {remapped_weights}")
    
    try:
        # Determine if we should use low memory mode based on system RAM and model size
        use_low_memory = should_use_low_memory(model_path)
        
        # Determine optimal dtype for device
        # MPS precision notes:
        # - float16: Causes black images due to precision issues  
        # - bfloat16: ONLY works for Z-Image/flow-matching models on MPS
        # - float32: Required for standard SD 1.x/2.x and SDXL models on MPS
        
        # Check if this is a Z-Image/flow-matching model (only these can use bfloat16 on MPS)
        is_zimage = "zimage" in model_type.lower() or "qwen" in model_type.lower() or "flow" in model_type.lower()
        
        if device == "mps":
            if is_zimage:
                # Z-Image/flow-matching models can use bfloat16 on MPS
                mps_bf16_supported = hasattr(torch.backends, 'mps') and torch.backends.mps.is_available()
                if mps_bf16_supported:
                    try:
                        test_tensor = torch.tensor([1.0], dtype=torch.bfloat16, device="mps")
                        del test_tensor
                        dtype = torch.bfloat16
                        print("NOTE: Using bfloat16 on MPS (optimal for Z-Image/flow-matching models)")
                    except Exception:
                        dtype = torch.float32
                        print("NOTE: MPS bfloat16 not available, using float32")
                else:
                    dtype = torch.float32
                    print("NOTE: MPS requires float32 precision")
            else:
                # Standard SD 1.x/2.x and SDXL models need float32 on MPS
                # bfloat16 causes black images for these models
                dtype = torch.float32
                print("NOTE: Using float32 on MPS (required for standard SD models)")
        elif device == "cuda":
            dtype = torch.bfloat16 if torch.cuda.is_bf16_supported() else torch.float16
        else:
            # CPU mode: Use float16 for large models to reduce memory usage
            # float32 would require 2x memory which may exceed system RAM
            if use_low_memory:
                dtype = torch.float16
                print("NOTE: Using float16 on CPU for large model (memory optimization)")
            else:
                dtype = torch.float32
        
        print(f"Using dtype: {dtype} for device: {device}")
        
        if model_path.is_file() and model_path.suffix in ['.safetensors', '.ckpt']:
            # Load from single file
            # NOTE: safety_checker disabled to avoid torch.load CVE-2025-32434
            pipe = PipelineClass.from_single_file(
                str(model_path),
                torch_dtype=dtype,
                use_safetensors=True,
                safety_checker=None,
                feature_extractor=None,
                low_cpu_mem_usage=use_low_memory
            )
        else:
            # Load from directory
            # Try specific pipeline class first
            try:
                pipe = PipelineClass.from_pretrained(
                    str(model_path),
                    torch_dtype=dtype,
                    safety_checker=None,
                    low_cpu_mem_usage=use_low_memory
                )
            except Exception as e:
                # If specific pipeline fails (e.g., due to version mismatch), use AutoPipeline
                print(f"Warning: Failed to load with {PipelineClass.__name__}: {e}")
                print("Falling back to AutoPipeline for automatic detection...")
                
                AutoPipelineClass = AutoPipelineForImage2Image if is_img2img else AutoPipelineForText2Image
                pipe = AutoPipelineClass.from_pretrained(
                    str(model_path),
                    torch_dtype=dtype,
                    low_cpu_mem_usage=use_low_memory
                )
                print(f"Successfully loaded with AutoPipeline: {type(pipe).__name__}")
        
        # Set scheduler based on model type and requested scheduler
        original_scheduler_class = type(pipe.scheduler).__name__
        print(f"Original scheduler: {original_scheduler_class}")
        
        # Detect SDXL models (have dual text encoders)
        is_sdxl = hasattr(pipe, 'tokenizer_2') and pipe.tokenizer_2 is not None
        
        # Fix black images on MPS: SDXL and standard SD models need float32 precision
        # MPS has precision issues with float16 in diffusion models causing black images
        if device == "mps" and not is_zimage:
            if is_sdxl:
                # SDXL: Convert ALL components (UNet, text encoders, VAE) to float32
                print("NOTE: Converting SDXL pipeline to float32 for MPS compatibility")
                if hasattr(pipe, 'unet') and pipe.unet is not None:
                    pipe.unet = pipe.unet.to(dtype=torch.float32)
                    print(f"  UNet: {pipe.unet.dtype}")
                if hasattr(pipe, 'text_encoder') and pipe.text_encoder is not None:
                    pipe.text_encoder = pipe.text_encoder.to(dtype=torch.float32)
                    print(f"  Text Encoder 1: {pipe.text_encoder.dtype}")
                if hasattr(pipe, 'text_encoder_2') and pipe.text_encoder_2 is not None:
                    pipe.text_encoder_2 = pipe.text_encoder_2.to(dtype=torch.float32)
                    print(f"  Text Encoder 2: {pipe.text_encoder_2.dtype}")
                if hasattr(pipe, 'vae') and pipe.vae is not None:
                    pipe.vae = pipe.vae.to(dtype=torch.float32)
                    print(f"  VAE: {pipe.vae.dtype}")
            elif hasattr(pipe, 'vae'):
                # Standard SD 1.x/2.x: VAE needs float32 on MPS
                print("NOTE: Converting VAE to float32 for MPS compatibility")
                pipe.vae = pipe.vae.to(dtype=torch.float32)
                print(f"  VAE: {pipe.vae.dtype}")
        
        # Detect if this is a flow-matching model
        is_flow_matching = 'FlowMatch' in original_scheduler_class or original_scheduler_class == 'FlowMatchEulerDiscreteScheduler'
        
        # Determine if we should change the scheduler
        should_use_original = False
        
        # CRITICAL: SDE schedulers are INCOMPATIBLE with MPS
        # They produce all-black images due to VAE decode issues with SDE-generated latents
        # This is a known MPS limitation - prevent users from hitting this issue
        if device == "mps" and scheduler in ['dpm++_sde', 'dpm++_sde_karras']:
            print(f"ERROR: SDE schedulers ({scheduler}) are not supported on Apple Silicon (MPS)")
            print(f"SDE schedulers produce black images on MPS due to precision issues.")
            print(f"Please use one of these schedulers instead:")
            print(f"  - euler (recommended for SDXL)")
            print(f"  - dpm++ or dpm++_karras (recommended for SD 1.5)")
            print(f"  - euler_a, ddim, pndm, lms")
            raise ValueError(f"Scheduler '{scheduler}' is not compatible with MPS device. Use 'euler' or 'dpm++' instead.")
        
        # Flow-matching models (Z-Image, FLUX, etc.) use different sampling
        if is_flow_matching:
            # Only allow flow-match schedulers for flow-matching models
            if scheduler not in ['flow_match_euler', 'flow_match_heun']:
                print(f"Warning: Model uses flow-matching ({original_scheduler_class}).")
                print(f"Requested scheduler '{scheduler}' may not work correctly.")
                print(f"Using original scheduler to ensure compatibility.")
                should_use_original = True
        
        # Some pipelines (like Z-Image) have strict scheduler requirements
        if model_type.lower() in ["zimage", "flux", "sd3"]:
            if scheduler not in ['flow_match_euler', 'flow_match_heun']:
                print(f"Preserving original scheduler for {model_type} model")
                should_use_original = True
        
        # NOTE: EDMDPMSolverMultistepScheduler produces garbage on MPS
        # The UI should limit scheduler options for SDXL models
        # We only warn here - do NOT silently change user's scheduler selection
        if original_scheduler_class == 'EDMDPMSolverMultistepScheduler' and device == "mps":
            print(f"WARNING: {original_scheduler_class} may produce poor results on MPS")
            print(f"Consider using 'euler' scheduler for SDXL models on MPS")
        
        if not should_use_original:
            print(f"Setting scheduler: {scheduler}")
            pipe.scheduler = get_scheduler(scheduler, pipe.scheduler.config)
        else:
            print(f"Using scheduler: {type(pipe.scheduler).__name__}")
        
        # Enable attention slicing early for SDXL on MPS (before device placement)
        # This prevents memory spikes during generation
        if device == "mps" and is_sdxl:
            print("NOTE: Enabling attention slicing for SDXL on MPS")
            pipe.enable_attention_slicing()
        
        # Enable CPU offloading BEFORE moving to device if low memory mode was used
        # This prevents loading entire model into device memory at once
        if use_low_memory and device == "mps":
            print(f"\nEnabling sequential CPU offloading for memory efficiency...")
            print(f"Model components will be loaded to MPS sequentially during inference")
            pipe.enable_sequential_cpu_offload()
            print(f"Sequential CPU offloading enabled")
            print(f"Note: This will be slower but use significantly less memory\n")
            # Don't call pipe.to(device) when using CPU offloading
        elif use_low_memory and device == "cpu":
            # For CPU with large models, enable attention slicing and keep on CPU
            print(f"\nLarge model on CPU - enabling memory optimizations...")
            pipe.enable_attention_slicing()
            print(f"Attention slicing enabled")
            # Model is already on CPU by default, no need to move
            print(f"Model loaded on CPU with memory optimizations")
        else:
            # Try to move to device, with CPU offloading fallback for large models
            try:
                pipe = pipe.to(device)
                print(f"Model loaded on {device}")
            except (RuntimeError, NotImplementedError) as e:
                error_str = str(e).lower()
                if "out of memory" in error_str or "mps" in error_str:
                    print(f"Warning: Failed to load on {device} ({e})")
                    print("Enabling CPU offloading for large model...")
                    # Enable sequential CPU offloading for models too large for device memory
                    pipe.enable_sequential_cpu_offload()
                    device = "cpu"  # Generator needs to match offload device
                    print("CPU offloading enabled - inference will be slower but memory-efficient")
                elif "meta tensor" in error_str or "to_empty" in error_str:
                    # FP8 models and meta-device models need special handling
                    print(f"Detected meta tensor model (likely FP8/quantized format)")
                    print("Enabling CPU offloading for quantized model...")
                    pipe.enable_model_cpu_offload()
                    device = "cpu"  # Generator needs to match offload device
                    print("CPU offloading enabled for quantized model")
                else:
                    # Re-raise the original error
                    raise e
        
        # Enable memory optimizations
        if device == "mps":
            # Only enable if not already enabled (SDXL enables it earlier)
            if not is_sdxl:
                pipe.enable_attention_slicing()
        elif device == "cuda":
            try:
                pipe.enable_xformers_memory_efficient_attention()
            except Exception:
                print("Warning: xformers not available, using standard attention")
        
        # Load LoRAs if provided
        if lora_paths:
            print(f"\n=== Loading LoRAs ===")
            # Default weights to 1.0 if not specified
            if lora_weights is None:
                lora_weights = [1.0] * len(lora_paths)
            elif len(lora_weights) < len(lora_paths):
                # Pad with 1.0 if fewer weights than paths
                lora_weights = lora_weights + [1.0] * (len(lora_paths) - len(lora_weights))
            
            loaded_adapters = []
            for i, lora_path in enumerate(lora_paths):
                lora_path = Path(lora_path)
                if not lora_path.exists():
                    print(f"Warning: LoRA not found, skipping: {lora_path}")
                    continue
                
                weight = lora_weights[i] if i < len(lora_weights) else 1.0
                adapter_name = f"lora_{i}"
                
                try:
                    # Load LoRA using diffusers' built-in method
                    pipe.load_lora_weights(str(lora_path), adapter_name=adapter_name)
                    loaded_adapters.append((adapter_name, weight))
                    print(f"Loaded LoRA: {lora_path.name} (weight: {weight})")
                except Exception as e:
                    print(f"Warning: Failed to load LoRA {lora_path.name}: {e}")
            
            # Set adapter weights if multiple LoRAs loaded
            if len(loaded_adapters) > 1:
                adapter_names = [a[0] for a in loaded_adapters]
                adapter_weights_list = [a[1] for a in loaded_adapters]
                pipe.set_adapters(adapter_names, adapter_weights=adapter_weights_list)
                print(f"Set {len(loaded_adapters)} adapters with custom weights")
            elif len(loaded_adapters) == 1:
                # For single LoRA, scale its influence
                adapter_name, weight = loaded_adapters[0]
                if weight != 1.0:
                    pipe.set_adapters([adapter_name], adapter_weights=[weight])
                    print(f"Set adapter weight to {weight}")
            
            print(f"========================\n")
    
    except Exception as e:
        print(f"Error loading model: {e}")
        raise
    
    # Set seed
    generator = None
    if seed is not None:
        generator = torch.Generator(device=device).manual_seed(seed)
        print(f"Using seed: {seed}")
    else:
        print("Using random seed")
    
    # Check if this is an SDXL model (has dual text encoders)
    is_sdxl = hasattr(pipe, 'tokenizer_2') and pipe.tokenizer_2 is not None
    
    # Check if we should skip Compel (flow-matching models don't use standard text encoders)
    skip_compel = model_type.lower() in ["zimage", "flux", "sd3", "qwenimage"]
    
    # Process prompts with Compel if available and appropriate
    prompt_embeds = None
    negative_embeds = None
    use_compel = COMPEL_AVAILABLE and not skip_compel and hasattr(pipe, 'tokenizer')
    
    if use_compel:
        print("Processing prompts with Compel (supports weighting and long prompts)")
        compel_result = process_prompt_with_compel(pipe, prompt, negative_prompt, is_sdxl)
        if compel_result[0] is not None:
            if is_sdxl and isinstance(compel_result[0], dict):
                # SDXL returns a dict with all embeddings
                prompt_embeds = compel_result[0]
                print("Using Compel embeddings for SDXL")
            else:
                prompt_embeds, negative_embeds = compel_result
                print("Using Compel embeddings for SD 1.x")
    
    # Generate image
    print(f"Generating {num_images} image(s)...")
    print(f"  Mode: {'Image-to-Image' if is_img2img else 'Text-to-Image'}")
    print(f"  Prompt: {prompt}")
    print(f"  Negative: {negative_prompt}")
    if is_img2img:
        print(f"  Input Image: {input_image}")
        print(f"  Strength: {strength} (0.0=no change, 1.0=full generation)")
    else:
        print(f"  Resolution: {width}×{height}")
    print(f"  Steps: {steps}")
    print(f"  Guidance: {guidance_scale}")
    if use_compel and prompt_embeds is not None:
        print(f"  Compel: ENABLED (prompt weighting active)")
    
    with torch.inference_mode():
        if is_img2img:
            # Image-to-Image generation
            if isinstance(prompt_embeds, dict):
                # SDXL with Compel
                result = pipe(
                    image=init_img,
                    strength=strength,
                    num_inference_steps=steps,
                    guidance_scale=guidance_scale,
                    num_images_per_prompt=num_images,
                    generator=generator,
                    **prompt_embeds
                )
            elif prompt_embeds is not None:
                # SD 1.x with Compel
                result = pipe(
                    image=init_img,
                    strength=strength,
                    prompt_embeds=prompt_embeds,
                    negative_prompt_embeds=negative_embeds,
                    num_inference_steps=steps,
                    guidance_scale=guidance_scale,
                    num_images_per_prompt=num_images,
                    generator=generator
                )
            else:
                # Standard prompts
                result = pipe(
                    prompt=prompt,
                    image=init_img,
                    strength=strength,
                    negative_prompt=negative_prompt if negative_prompt else None,
                    num_inference_steps=steps,
                    guidance_scale=guidance_scale,
                    num_images_per_prompt=num_images,
                    generator=generator
                )
        else:
            # Text-to-Image generation
            if isinstance(prompt_embeds, dict):
                # SDXL with Compel
                result = pipe(
                    num_inference_steps=steps,
                    guidance_scale=guidance_scale,
                    width=width,
                    height=height,
                    num_images_per_prompt=num_images,
                    generator=generator,
                    **prompt_embeds
                )
            elif prompt_embeds is not None:
                # SD 1.x with Compel
                result = pipe(
                    prompt_embeds=prompt_embeds,
                    negative_prompt_embeds=negative_embeds,
                    num_inference_steps=steps,
                    guidance_scale=guidance_scale,
                    width=width,
                    height=height,
                    num_images_per_prompt=num_images,
                    generator=generator
                )
            else:
                # Standard prompts
                result = pipe(
                    prompt=prompt,
                    negative_prompt=negative_prompt if negative_prompt else None,
                    num_inference_steps=steps,
                    guidance_scale=guidance_scale,
                    width=width,
                    height=height,
                    num_images_per_prompt=num_images,
                    generator=generator
                )
    
    images = result.images
    
    # Save images
    output_path = Path(output_path)
    output_path.parent.mkdir(parents=True, exist_ok=True)
    
    saved_paths = []
    if num_images == 1:
        images[0].save(output_path)
        saved_paths.append(str(output_path))
        print(f"Saved image: {output_path}")
    else:
        base_name = output_path.stem
        ext = output_path.suffix
        for i, image in enumerate(images):
            path = output_path.parent / f"{base_name}_{i+1}{ext}"
            image.save(path)
            saved_paths.append(str(path))
            print(f"Saved image {i+1}: {path}")
    
    # Output JSON result for Swift to parse
    result_json = {
        "success": True,
        "images": saved_paths,
        "metadata": {
            "mode": "img2img" if is_img2img else "txt2img",
            "prompt": prompt,
            "negative_prompt": negative_prompt,
            "scheduler": scheduler,
            "steps": steps,
            "guidance_scale": guidance_scale,
            "width": width,
            "height": height,
            "seed": seed,
            "num_images": num_images,
            "input_image": str(input_image) if input_image else None,
            "strength": strength if is_img2img else None
        }
    }
    print("\n--- RESULT JSON ---")
    print(json.dumps(result_json, indent=2))
    print("--- END RESULT ---")


def main():
    parser = argparse.ArgumentParser(
        description='Generate images using Python diffusers',
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=f"""
Schedulers:
  {', '.join(SCHEDULERS.keys())}

Examples:
  # Generate with DPM++ 2M SDE Karras (recommended)
  python3 generate_image_diffusers.py \\
    -m ~/Library/Caches/sam/models/stable-diffusion/model-name/model.safetensors \\
    -p "a serene mountain landscape at sunset" \\
    -o output.png \\
    -s dpm++_sde_karras

  # Generate with Euler Ancestral
  python3 generate_image_diffusers.py \\
    -m ~/Library/Caches/sam/models/stable-diffusion/model-name/model.safetensors \\
    -p "anime character portrait" \\
    -n "blurry, low quality" \\
    -o anime.png \\
    -s euler_a \\
    --steps 30

  # Generate multiple images with same prompt
  python3 generate_image_diffusers.py \\
    -m ~/Library/Caches/sam/models/stable-diffusion/model-name/model.safetensors \\
    -p "cute cat" \\
    -o cat.png \\
    --num-images 4
        """
    )
    
    parser.add_argument('-m', '--model', required=True, help='Path to .safetensors model file')
    parser.add_argument('-p', '--prompt', required=True, help='Text prompt')
    parser.add_argument('-o', '--output', required=True, help='Output image path')
    parser.add_argument('-n', '--negative-prompt', default='', help='Negative prompt')
    parser.add_argument(
        '-s', '--scheduler',
        choices=list(SCHEDULERS.keys()),
        default='euler',
        help='Scheduler to use (default: euler). Note: SDE schedulers are not supported on MPS.'
    )
    parser.add_argument('--steps', type=int, default=25, help='Number of inference steps (default: 25)')
    parser.add_argument('--guidance', type=float, default=7.5, help='Guidance scale (default: 7.5)')
    parser.add_argument('--width', type=int, default=512, help='Image width (default: 512)')
    parser.add_argument('--height', type=int, default=512, help='Image height (default: 512)')
    parser.add_argument('--seed', type=int, default=None, help='Random seed (default: random)')
    parser.add_argument('--num-images', type=int, default=1, help='Number of images to generate (default: 1)')
    parser.add_argument('-i', '--input-image', default=None, help='Input image for img2img (default: None for txt2img)')
    parser.add_argument('--strength', type=float, default=0.75, help='Denoising strength for img2img (default: 0.75, range: 0.0-1.0)')
    parser.add_argument('--device', type=str, choices=['auto', 'mps', 'cpu'], default='auto', help='Compute device (default: auto)')
    parser.add_argument('--lora', action='append', dest='lora_paths', help='Path to LoRA .safetensors file (can be specified multiple times)')
    parser.add_argument('--lora-weight', action='append', type=float, dest='lora_weights', help='Weight for corresponding LoRA (0.0-1.0, default: 1.0)')
    
    args = parser.parse_args()
    
    try:
        generate_image(
            model_path=args.model,
            prompt=args.prompt,
            output_path=args.output,
            negative_prompt=args.negative_prompt,
            scheduler=args.scheduler,
            steps=args.steps,
            guidance_scale=args.guidance,
            width=args.width,
            height=args.height,
            seed=args.seed,
            num_images=args.num_images,
            input_image=args.input_image,
            strength=args.strength,
            device=args.device,
            lora_paths=args.lora_paths,
            lora_weights=args.lora_weights
        )
        print("\nSUCCESS: Image(s) generated successfully!")
        return 0
    except Exception as e:
        print(f"\nERROR: {e}", file=sys.stderr)
        import traceback
        traceback.print_exc()
        return 1


if __name__ == '__main__':
    sys.exit(main())
