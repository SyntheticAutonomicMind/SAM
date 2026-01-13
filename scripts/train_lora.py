#!/usr/bin/env python3
"""
LoRA Training Script for SAM using MLX
Based on Silicon-Studio implementation
"""

import sys
import json
import argparse
from pathlib import Path


def main():
    parser = argparse.ArgumentParser(description='Train LoRA adapter using MLX')
    parser.add_argument('--model-path', required=True, help='Path to base model')
    parser.add_argument('--dataset', required=True, help='Path to training dataset (JSONL)')
    parser.add_argument('--output', required=True, help='Output directory for adapter')
    parser.add_argument('--rank', type=int, default=8, help='LoRA rank')
    parser.add_argument('--alpha', type=float, default=16.0, help='LoRA alpha')
    parser.add_argument('--lr', type=float, default=1e-4, help='Learning rate')
    parser.add_argument('--batch-size', type=int, default=4, help='Batch size')
    parser.add_argument('--epochs', type=int, default=3, help='Number of epochs')
    parser.add_argument('--max-seq-length', type=int, default=2048, help='Max sequence length')
    parser.add_argument('--lora-layers', type=int, default=8, help='Number of layers to apply LoRA')
    parser.add_argument('--lora-dropout', type=float, default=0.0, help='LoRA dropout')
    
    args = parser.parse_args()
    
    try:
        import mlx.core as mx
        import mlx.nn as nn
        import mlx.optimizers as optim
        from mlx_lm import load
        from mlx_lm.tuner import train, TrainingArgs
        from mlx_lm.tuner.datasets import load_local_dataset
        from mlx_lm.tuner.utils import linear_to_lora_layers
        from pathlib import Path
        
        print(f"🚀 Starting LoRA training", file=sys.stderr)
        print(f"   Model: {args.model_path}", file=sys.stderr)
        print(f"   Dataset: {args.dataset}", file=sys.stderr)
        print(f"   Output: {args.output}", file=sys.stderr)
        
        # Create output directory
        output_dir = Path(args.output)
        output_dir.mkdir(parents=True, exist_ok=True)
        
        # 1. Load model and tokenizer
        print(f"📦 Loading model from: {args.model_path}", file=sys.stderr)
        
        # mlx_lm.load expects repo_id OR local path
        # For local paths, we need to pass it directly (it auto-detects local vs HF)
        model_path = Path(args.model_path)
        
        if model_path.exists():
            print(f"   Loading from local path", file=sys.stderr)
            model, tokenizer, model_config = load(str(model_path), return_config=True)
        else:
            print(f"   ERROR: Model path does not exist: {args.model_path}", file=sys.stderr)
            raise FileNotFoundError(f"Model not found at: {args.model_path}")
        
        # Freeze base model
        model.freeze()
        print(f"✅ Model loaded and frozen", file=sys.stderr)
        
        # 1.5 Memory estimation and safety check
        import psutil
        available_ram_gb = psutil.virtual_memory().available / (1024**3)
        
        # Estimate adapter memory requirements
        # Formula: num_layers * rank * hidden_size * 4 projections * 2 (A and B matrices) * 4 bytes (float32)
        hidden_size = model_config.get("hidden_size", 2048)
        num_lora_layers = args.lora_layers
        estimated_adapter_mb = (num_lora_layers * args.rank * hidden_size * 4 * 2 * 4) / (1024**2)
        
        # Estimate total training memory (adapter + activations + gradients + optimizer states)
        # Rule of thumb: training needs ~4x adapter size
        estimated_training_gb = (estimated_adapter_mb * 4) / 1024
        
        print(f"💾 Memory estimation:", file=sys.stderr)
        print(f"   Available RAM: {available_ram_gb:.1f} GB", file=sys.stderr)
        print(f"   Adapter size: ~{estimated_adapter_mb:.0f} MB", file=sys.stderr)
        print(f"   Training needs: ~{estimated_training_gb:.1f} GB", file=sys.stderr)
        
        if estimated_training_gb > available_ram_gb * 0.7:
            print(f"⚠️  WARNING: Training may exceed available memory!", file=sys.stderr)
            print(f"   Recommended: Reduce rank to {int(args.rank * 0.5)} or fewer layers", file=sys.stderr)
            # Don't fail here - let user decide, but warn them
        
        # 2. Load dataset
        print(f"📊 Loading dataset...", file=sys.stderr)
        
        # MLX expects a directory with train.jsonl
        # Copy our dataset file to a temp directory
        import shutil
        import tempfile
        
        temp_dir = tempfile.mkdtemp()
        temp_train_path = Path(temp_dir) / "train.jsonl"
        shutil.copy(args.dataset, temp_train_path)
        print(f"   Staged dataset to {temp_train_path}", file=sys.stderr)
        
        # Load dataset
        from mlx_lm.tuner.datasets import CacheDataset
        train_set, val_set, test_set = load_local_dataset(Path(temp_dir), tokenizer, model_config)
        
        # Handle empty validation set
        if len(val_set) == 0:
            print(f"⚠️  Validation set empty, splitting train set...", file=sys.stderr)
            if hasattr(train_set, "_data"):
                raw_data = train_set._data
            else:
                raw_data = train_set
                
            if len(raw_data) > 1:
                split_idx = int(len(raw_data) * 0.9)
                if split_idx == len(raw_data):
                    split_idx = len(raw_data) - 1
                    
                train_raw = raw_data[:split_idx]
                val_raw = raw_data[split_idx:]
                
                from mlx_lm.tuner.datasets import create_dataset
                train_set = create_dataset(train_raw, tokenizer, model_config)
                val_set = create_dataset(val_raw, tokenizer, model_config)
            else:
                print(f"   Dataset too small, using same for validation", file=sys.stderr)
                val_set = train_set
        
        # Wrap in CacheDataset
        train_set = CacheDataset(train_set)
        val_set = CacheDataset(val_set)
        
        print(f"✅ Dataset loaded: {len(train_set)} train, {len(val_set)} val", file=sys.stderr)
        
        # 3. Calculate training steps
        steps_per_epoch = len(train_set) // args.batch_size
        if steps_per_epoch < 1:
            steps_per_epoch = 1
        total_iters = steps_per_epoch * args.epochs
        
        print(f"📈 Training plan:", file=sys.stderr)
        print(f"   {len(train_set)} samples", file=sys.stderr)
        print(f"   {steps_per_epoch} steps/epoch", file=sys.stderr)
        print(f"   {total_iters} total iterations", file=sys.stderr)
        
        # 4. Setup LoRA
        lora_config = {
            "rank": args.rank,
            "alpha": args.alpha,
            "scale": float(args.alpha / args.rank),
            "dropout": args.lora_dropout,
            "keys": ["self_attn.q_proj", "self_attn.k_proj", "self_attn.v_proj", "self_attn.o_proj"],
            "num_layers": args.lora_layers
        }
        
        print(f"🔧 Converting model to LoRA...", file=sys.stderr)
        print(f"   Rank: {args.rank}", file=sys.stderr)
        print(f"   Alpha: {args.alpha}", file=sys.stderr)
        print(f"   Layers: {args.lora_layers}", file=sys.stderr)
        
        linear_to_lora_layers(model, lora_config["num_layers"], lora_config)
        print(f"✅ Model converted to LoRA", file=sys.stderr)
        
        # 5. Setup training
        adapter_file = output_dir / "adapters.safetensors"
        training_args = TrainingArgs(
            batch_size=args.batch_size,
            iters=total_iters,
            adapter_file=str(adapter_file),
            max_seq_length=args.max_seq_length
        )
        
        optimizer = optim.Adam(learning_rate=args.lr)
        
        # Progress callback
        class ProgressCallback:
            def on_train_loss_report(self, train_info):
                if "iteration" in train_info:
                    step = train_info["iteration"]
                    loss = train_info.get("train_loss", 0.0)
                    progress = int((step / total_iters) * 100)
                    
                    # Output JSON progress for Swift to parse
                    print(json.dumps({
                        "type": "progress",
                        "step": step,
                        "total_steps": total_iters,
                        "loss": loss,
                        "progress": progress
                    }), flush=True)
                    
            def on_val_loss_report(self, val_info):
                if "val_loss" in val_info:
                    print(json.dumps({
                        "type": "validation",
                        "loss": val_info["val_loss"]
                    }), flush=True)
        
        callback = ProgressCallback()
        
        # 6. Train!
        print(f"🎯 Starting training...", file=sys.stderr)
        train(
            model=model,
            optimizer=optimizer,
            train_dataset=train_set,
            val_dataset=val_set,
            args=training_args,
            training_callback=callback
        )
        
        print(f"✅ Training complete!", file=sys.stderr)
        
        # 7. Save adapter config
        adapter_config = {
            "fine_tune_type": "lora",
            "num_layers": lora_config["num_layers"],
            "lora_parameters": {
                "rank": args.rank,
                "scale": lora_config["scale"],
                "dropout": 0.0,
                "keys": lora_config["keys"]
            }
        }
        
        config_path = output_dir / "adapter_config.json"
        with open(config_path, 'w') as f:
            json.dump(adapter_config, f, indent=2)
        
        print(f"💾 Saved adapter config to {config_path}", file=sys.stderr)
        
        # Clean up temp directory
        shutil.rmtree(temp_dir)
        
        # Output success
        print(json.dumps({
            "type": "complete",
            "adapter_path": str(adapter_file)
        }), flush=True)
        
        return 0
        
    except Exception as e:
        import traceback
        print(f"❌ Training failed: {e}", file=sys.stderr)
        traceback.print_exc(file=sys.stderr)
        print(json.dumps({
            "type": "error",
            "error": str(e)
        }), flush=True)
        return 1


if __name__ == "__main__":
    sys.exit(main())
