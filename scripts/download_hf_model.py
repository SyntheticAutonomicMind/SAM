#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

"""
Download HuggingFace model repository

Usage:
    python3 download_hf_model.py --repo "Tongyi-MAI/Z-Image-Turbo" --output ~/Library/Caches/sam/models/stable-diffusion/z-image-turbo
"""

import argparse
import sys
from pathlib import Path

try:
    from huggingface_hub import snapshot_download
except ImportError:
    print("ERROR: huggingface-hub not installed", file=sys.stderr)
    print("Install with: pip install huggingface-hub", file=sys.stderr)
    sys.exit(1)

def download_model(repo_id: str, output_dir: str, token: str = None):
    """Download HuggingFace model repository"""
    output_path = Path(output_dir)
    output_path.mkdir(parents=True, exist_ok=True)
    
    print(f"Downloading {repo_id} to {output_dir}")
    print("This may take several minutes for large models...")
    
    try:
        snapshot_download(
            repo_id=repo_id,
            local_dir=output_dir,
            local_dir_use_symlinks=False,
            token=token
        )
        print(f"SUCCESS: Model downloaded to {output_dir}")
        return 0
    except Exception as e:
        print(f"ERROR: Download failed: {e}", file=sys.stderr)
        return 1

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Download HuggingFace model repository")
    parser.add_argument("--repo", required=True, help="Repository ID (e.g., Tongyi-MAI/Z-Image-Turbo)")
    parser.add_argument("--output", required=True, help="Output directory")
    parser.add_argument("--token", help="HuggingFace API token (optional)")
    
    args = parser.parse_args()
    sys.exit(download_model(args.repo, args.output, args.token))
