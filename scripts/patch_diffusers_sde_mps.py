#!/usr/bin/env python3
"""
Patch diffusers DPMSolver SDE scheduler to fix black images on MPS.

Issue: SDE schedulers have two problems on MPS:
1. Random noise generation on MPS can produce NaN/inf values
2. sqrt() operations in SDE math can produce NaN if input is slightly negative

Fix:
1. Generate noise on CPU, then move to MPS
2. Clamp sqrt inputs to be non-negative to prevent NaN
"""

import sys
from pathlib import Path


def patch_dpmsolver_sde_for_mps(scheduler_file: Path) -> bool:
    """
    Patch DPMSolver scheduler to fix SDE on MPS.
    
    Args:
        scheduler_file: Path to scheduling_dpmsolver_multistep.py
    
    Returns:
        True if patch was applied or already present, False on error
    """
    if not scheduler_file.exists():
        print(f"ERROR: Scheduler file not found: {scheduler_file}")
        return False
    
    # Read the file
    content = scheduler_file.read_text()
    
    # Check if already patched
    if "# MPS RNG FIX:" in content:
        print(f"✓ Scheduler already patched: {scheduler_file}")
        return True
    
    # Patch 1: Fix noise generation
    original_noise = """        if self.config.algorithm_type in ["sde-dpmsolver", "sde-dpmsolver++"] and variance_noise is None:
            noise = randn_tensor(
                model_output.shape, generator=generator, device=model_output.device, dtype=torch.float32
            )"""
    
    patched_noise = """        if self.config.algorithm_type in ["sde-dpmsolver", "sde-dpmsolver++"] and variance_noise is None:
            # MPS RNG FIX: Generate noise on CPU to avoid MPS precision issues
            noise_device = "cpu" if str(model_output.device) == "mps" else model_output.device
            noise = randn_tensor(
                model_output.shape, generator=generator, device=noise_device, dtype=torch.float32
            )
            # Move noise to target device if it was generated on CPU
            if noise_device == "cpu" and model_output.device != "cpu":
                noise = noise.to(device=model_output.device)"""
    
    if original_noise not in content:
        print(f"ERROR: Could not find noise generation code in {scheduler_file}")
        return False
    
    content = content.replace(original_noise, patched_noise)
    
    # Patch 2: Fix sqrt operations in sde-dpmsolver++
    original_sde_pp = """        elif self.config.algorithm_type == "sde-dpmsolver++":
            assert noise is not None
            x_t = (
                (sigma_t / sigma_s * torch.exp(-h)) * sample
                + (alpha_t * (1 - torch.exp(-2.0 * h))) * model_output
                + sigma_t * torch.sqrt(1.0 - torch.exp(-2 * h)) * noise
            )"""
    
    patched_sde_pp = """        elif self.config.algorithm_type == "sde-dpmsolver++":
            assert noise is not None
            # MPS PRECISION FIX: Clamp sqrt input to prevent NaN from precision errors
            sqrt_input = torch.clamp(1.0 - torch.exp(-2 * h), min=0.0)
            x_t = (
                (sigma_t / sigma_s * torch.exp(-h)) * sample
                + (alpha_t * (1 - torch.exp(-2.0 * h))) * model_output
                + sigma_t * torch.sqrt(sqrt_input) * noise
            )"""
    
    if original_sde_pp not in content:
        print(f"ERROR: Could not find sde-dpmsolver++ code in {scheduler_file}")
        return False
    
    content = content.replace(original_sde_pp, patched_sde_pp)
    
    # Patch 3: Fix sqrt operations in sde-dpmsolver
    original_sde = """        elif self.config.algorithm_type == "sde-dpmsolver":
            assert noise is not None
            x_t = (
                (alpha_t / alpha_s) * sample
                - 2.0 * (sigma_t * (torch.exp(h) - 1.0)) * model_output
                + sigma_t * torch.sqrt(torch.exp(2 * h) - 1.0) * noise
            )"""
    
    patched_sde = """        elif self.config.algorithm_type == "sde-dpmsolver":
            assert noise is not None
            # MPS PRECISION FIX: Clamp sqrt input to prevent NaN from precision errors
            sqrt_input = torch.clamp(torch.exp(2 * h) - 1.0, min=0.0)
            x_t = (
                (alpha_t / alpha_s) * sample
                - 2.0 * (sigma_t * (torch.exp(h) - 1.0)) * model_output
                + sigma_t * torch.sqrt(sqrt_input) * noise
            )"""
    
    if original_sde not in content:
        print(f"ERROR: Could not find sde-dpmsolver code in {scheduler_file}")
        return False
    
    content = content.replace(original_sde, patched_sde)
    
    # Write back
    scheduler_file.write_text(content)
    print(f"✓ Patched diffusers DPMSolver SDE for MPS at {scheduler_file}")
    print(f"  Fixed: 1) CPU RNG for noise generation on MPS")
    print(f"  Fixed: 2) Clamped sqrt inputs to prevent NaN in SDE math")
    
    return True


def main():
    """Main entry point"""
    if len(sys.argv) < 2:
        print("Usage: patch_diffusers_sde_mps.py <path_to_diffusers_schedulers>")
        sys.exit(1)
    
    schedulers_dir = Path(sys.argv[1])
    scheduler_file = schedulers_dir / "scheduling_dpmsolver_multistep.py"
    
    success = patch_dpmsolver_sde_for_mps(scheduler_file)
    sys.exit(0 if success else 1)


if __name__ == "__main__":
    main()
