#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

"""
Patch basicsr to work with torchvision 0.17.0

The issue: basicsr 1.4.2 tries to import from torchvision.transforms.functional_tensor
but in torchvision 0.17.0+ it's torchvision.transforms._functional_tensor (with underscore)

This script patches the import statement in basicsr's degradations.py
"""

import sys
from pathlib import Path

def patch_basicsr(python_env_path: str):
    """Patch basicsr to use correct torchvision import."""
    
    # Find basicsr degradations.py
    site_packages = Path(python_env_path) / "lib" / "python3.12" / "site-packages"
    degradations_file = site_packages / "basicsr" / "data" / "degradations.py"
    
    if not degradations_file.exists():
        print(f"ERROR: Could not find {degradations_file}")
        return False
    
    # Read file
    content = degradations_file.read_text()
    
    # Check if already patched
    if "from torchvision.transforms._functional_tensor import rgb_to_grayscale" in content:
        print("✓ basicsr already patched for torchvision compatibility")
        return True
    
    # Apply patch
    old_import = "from torchvision.transforms.functional_tensor import rgb_to_grayscale"
    new_import = "from torchvision.transforms._functional_tensor import rgb_to_grayscale"
    
    if old_import not in content:
        print(f"WARNING: Expected import not found in {degradations_file}")
        print(f"File might already be patched or have a different structure")
        return True
    
    # Replace the import
    patched_content = content.replace(old_import, new_import)
    
    # Write back
    degradations_file.write_text(patched_content)
    
    print(f"✓ Patched basicsr for torchvision 0.17.0 compatibility")
    print(f"  Changed: functional_tensor - _functional_tensor")
    
    return True

if __name__ == "__main__":
    if len(sys.argv) != 2:
        print("Usage: patch_basicsr.py <python_env_path>")
        sys.exit(1)
    
    python_env = sys.argv[1]
    success = patch_basicsr(python_env)
    sys.exit(0 if success else 1)
