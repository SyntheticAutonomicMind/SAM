#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

"""
Patch diffusers DPMSolverMultistepScheduler to fix IndexError

The issue: dpm_solver_first_order_update accesses self.sigmas[self.step_index + 1]
without bounds checking, causing IndexError when step_index equals len(sigmas) - 1

The fix: Add bounds check and use final sigma when at boundary
"""

import sys
from pathlib import Path

def patch_dpmsolver(python_env_path: str):
    """Patch diffusers DPMSolverMultistepScheduler IndexError bug."""
    
    # Find diffusers scheduler file
    site_packages = Path(python_env_path) / "lib" / "python3.12" / "site-packages"
    scheduler_file = site_packages / "diffusers" / "schedulers" / "scheduling_dpmsolver_multistep.py"
    
    if not scheduler_file.exists():
        print(f"ERROR: Could not find {scheduler_file}")
        return False
    
    # Read file
    content = scheduler_file.read_text()
    
    # Check if already patched
    if "# SAM PATCH: bounds check" in content:
        print("✓ diffusers DPMSolver already patched for IndexError fix")
        return True
    
    # Apply patch to line 856
    old_line = "        sigma_t, sigma_s = self.sigmas[self.step_index + 1], self.sigmas[self.step_index]"
    new_lines = """        # SAM PATCH: bounds check to prevent IndexError
        # Original issue: step_index + 1 can exceed sigma array bounds
        if self.step_index + 1 >= len(self.sigmas):
            # At final step, use last sigma
            sigma_t = self.sigmas[-1]
            sigma_s = self.sigmas[self.step_index]
        else:
            sigma_t, sigma_s = self.sigmas[self.step_index + 1], self.sigmas[self.step_index]"""
    
    if old_line not in content:
        print(f"WARNING: Expected line not found in {scheduler_file}")
        print(f"File might already be patched or have a different version")
        return True
    
    # Replace the line
    patched_content = content.replace(old_line, new_lines)
    
    # Write back
    scheduler_file.write_text(patched_content)
    print(f"✓ Patched diffusers DPMSolver at {scheduler_file}")
    print(f"  Added bounds check to prevent IndexError")
    
    return True

if __name__ == "__main__":
    if len(sys.argv) != 2:
        print("Usage: patch_diffusers_dpmsolver.py <python_env_path>")
        sys.exit(1)
    
    success = patch_dpmsolver(sys.argv[1])
    sys.exit(0 if success else 1)
