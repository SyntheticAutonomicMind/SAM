#!/usr/bin/env python3
"""
LoRA Training Script for SAM using Hugging Face Transformers + PEFT
Trains GGUF models by loading from Hugging Face, applying LoRA, merging weights, and converting to GGUF
"""

import sys
import json
import argparse
import subprocess
from pathlib import Path


def main():
    parser = argparse.ArgumentParser(description='Train LoRA adapter for GGUF models')
    parser.add_argument('--hf-model-id', required=True, help='Hugging Face model ID (e.g., TinyLlama/TinyLlama-1.1B-Chat-v1.0)')
    parser.add_argument('--dataset', required=True, help='Path to training dataset (JSONL)')
    parser.add_argument('--output', required=True, help='Output directory for merged model')
    parser.add_argument('--gguf-output', required=True, help='Path for final GGUF model')
    parser.add_argument('--rank', type=int, default=8, help='LoRA rank')
    parser.add_argument('--alpha', type=float, default=16.0, help='LoRA alpha')
    parser.add_argument('--lr', type=float, default=2e-4, help='Learning rate')
    parser.add_argument('--batch-size', type=int, default=1, help='Batch size')
    parser.add_argument('--epochs', type=int, default=3, help='Number of epochs')
    parser.add_argument('--max-seq-length', type=int, default=2048, help='Max sequence length')
    parser.add_argument('--gradient-accumulation-steps', type=int, default=4, help='Gradient accumulation steps')
    parser.add_argument('--quantization', type=str, default='f16', help='GGUF quantization type (f16, q4_k_m, q8_0, etc.)')
    
    args = parser.parse_args()
    
    try:
        import torch
        from transformers import AutoModelForCausalLM, AutoTokenizer, TrainingArguments
        from peft import LoraConfig, get_peft_model
        from trl import SFTTrainer
        from datasets import Dataset
        import os
        
        print(json.dumps({"type": "log", "message": "Starting LoRA training for GGUF model"}), file=sys.stderr, flush=True)
        print(json.dumps({"type": "log", "message": f"Hugging Face Model: {args.hf_model_id}"}), file=sys.stderr, flush=True)
        print(json.dumps({"type": "log", "message": f"Dataset: {args.dataset}"}), file=sys.stderr, flush=True)
        print(json.dumps({"type": "log", "message": f"Output: {args.output}"}), file=sys.stderr, flush=True)
        
        # Create output directory
        output_dir = Path(args.output)
        output_dir.mkdir(parents=True, exist_ok=True)
        
        # Merged model will be saved to output-merged/
        merged_dir = Path(f"{args.output}-merged")
        merged_dir.mkdir(parents=True, exist_ok=True)
        
        # 1. Load training data
        print(json.dumps({"type": "log", "message": "Loading training data"}), file=sys.stderr, flush=True)
        
        with open(args.dataset, 'r') as f:
            # SAM exports JSONL with {"text": "..."} format (same as MLX training)
            data = [json.loads(line) for line in f if line.strip()]
        
        if not data:
            raise ValueError("No training data found in dataset")
        
        dataset = Dataset.from_list(data)
        print(json.dumps({"type": "log", "message": f"Loaded {len(data)} training examples"}), file=sys.stderr, flush=True)
        
        # 2. Load model and tokenizer from Hugging Face
        print(json.dumps({"type": "log", "message": f"Downloading model from Hugging Face: {args.hf_model_id}"}), file=sys.stderr, flush=True)
        
        tokenizer = AutoTokenizer.from_pretrained(args.hf_model_id, trust_remote_code=True)
        if tokenizer.pad_token is None:
            tokenizer.pad_token = tokenizer.eos_token
        
        # Load model in FP32 for CPU training (or FP16 if GPU available)
        # Use low_cpu_mem_usage to reduce memory during loading
        model = AutoModelForCausalLM.from_pretrained(
            args.hf_model_id,
            trust_remote_code=True,
            torch_dtype=torch.float32,
            low_cpu_mem_usage=True,
        )
        
        print(json.dumps({"type": "log", "message": "Model loaded successfully"}), file=sys.stderr, flush=True)
        
        # 3. Configure LoRA
        print(json.dumps({"type": "log", "message": f"Configuring LoRA (rank={args.rank}, alpha={args.alpha})"}), file=sys.stderr, flush=True)
        
        lora_config = LoraConfig(
            r=args.rank,
            lora_alpha=args.alpha,
            target_modules=["q_proj", "k_proj", "v_proj", "o_proj"],  # Attention layers
            lora_dropout=0.05,
            bias="none",
            task_type="CAUSAL_LM",
        )
        
        model = get_peft_model(model, lora_config)
        
        # Print trainable parameters
        trainable_params = sum(p.numel() for p in model.parameters() if p.requires_grad)
        total_params = sum(p.numel() for p in model.parameters())
        print(json.dumps({
            "type": "log",
            "message": f"Trainable params: {trainable_params:,} / {total_params:,} ({100 * trainable_params / total_params:.2f}%)"
        }), file=sys.stderr, flush=True)
        
        # 4. Format dataset for training
        # SAM uses {"text": "..."} format - convert to plain text for SFTTrainer
        def format_text(example):
            return {"text": example["text"]}
        
        formatted_dataset = dataset.map(format_text)
        
        # 5. Training arguments
        print(json.dumps({"type": "log", "message": "Setting up training"}), file=sys.stderr, flush=True)
        
        training_args = TrainingArguments(
            output_dir=str(output_dir),
            num_train_epochs=args.epochs,
            per_device_train_batch_size=args.batch_size,
            gradient_accumulation_steps=args.gradient_accumulation_steps,
            learning_rate=args.lr,
            save_strategy="epoch",
            logging_steps=10,
            warmup_steps=10,
            report_to="none",
            use_cpu=True,  # Force CPU (MPS/CUDA can be enabled later if needed)
        )
        
        # 6. Create trainer
        trainer = SFTTrainer(
            model=model,
            train_dataset=formatted_dataset,
            args=training_args,
            formatting_func=lambda x: x["text"],
        )
        
        # 7. Train!
        print(json.dumps({"type": "log", "message": f"Starting training for {args.epochs} epochs"}), file=sys.stderr, flush=True)
        print(json.dumps({"type": "progress", "step": 0, "total_steps": len(formatted_dataset) * args.epochs, "loss": 0.0, "progress": 0}), flush=True)
        
        trainer.train()
        
        print(json.dumps({"type": "log", "message": "Training complete"}), file=sys.stderr, flush=True)
        
        # 8. Save LoRA adapter
        print(json.dumps({"type": "log", "message": "Saving LoRA adapter"}), file=sys.stderr, flush=True)
        trainer.model.save_pretrained(str(output_dir))
        tokenizer.save_pretrained(str(output_dir))
        
        # 9. Merge LoRA weights into base model
        print(json.dumps({"type": "log", "message": "Merging LoRA weights into base model"}), file=sys.stderr, flush=True)
        
        model = model.merge_and_unload()
        
        # 10. Save merged model
        print(json.dumps({"type": "log", "message": f"Saving merged model to {merged_dir}"}), file=sys.stderr, flush=True)
        
        model.save_pretrained(str(merged_dir), safe_serialization=True)
        tokenizer.save_pretrained(str(merged_dir))
        
        print(json.dumps({"type": "log", "message": "Merged model saved"}), file=sys.stderr, flush=True)
        
        # 11. Convert to GGUF using llama.cpp
        print(json.dumps({"type": "log", "message": "Converting merged model to GGUF"}), file=sys.stderr, flush=True)
        
        # Find llama.cpp conversion script
        script_dir = Path(__file__).parent.parent
        conversion_script = script_dir / "external" / "llama.cpp" / "convert_hf_to_gguf.py"
        
        if not conversion_script.exists():
            raise FileNotFoundError(f"llama.cpp conversion script not found at {conversion_script}")
        
        # Run conversion
        conversion_cmd = [
            sys.executable,  # Use same Python interpreter
            str(conversion_script),
            str(merged_dir),
            "--outfile", args.gguf_output,
            "--outtype", args.quantization
        ]
        
        print(json.dumps({"type": "log", "message": f"Running: {' '.join(conversion_cmd)}"}), file=sys.stderr, flush=True)
        
        result = subprocess.run(
            conversion_cmd,
            capture_output=True,
            text=True
        )
        
        if result.returncode != 0:
            print(json.dumps({"type": "log", "message": f"Conversion stdout: {result.stdout}"}), file=sys.stderr, flush=True)
            print(json.dumps({"type": "log", "message": f"Conversion stderr: {result.stderr}"}), file=sys.stderr, flush=True)
            raise RuntimeError(f"GGUF conversion failed with exit code {result.returncode}")
        
        print(json.dumps({"type": "log", "message": "GGUF conversion complete"}), file=sys.stderr, flush=True)
        
        # 12. Verify GGUF file was created
        gguf_path = Path(args.gguf_output)
        if not gguf_path.exists():
            raise FileNotFoundError(f"GGUF file not created at {gguf_path}")
        
        gguf_size_mb = gguf_path.stat().st_size / (1024 * 1024)
        print(json.dumps({"type": "log", "message": f"GGUF model created: {gguf_size_mb:.1f} MB"}), file=sys.stderr, flush=True)
        
        # Output success
        print(json.dumps({
            "type": "complete",
            "gguf_path": str(gguf_path),
            "merged_path": str(merged_dir),
            "size_mb": gguf_size_mb
        }), flush=True)
        
        return 0
        
    except Exception as e:
        import traceback
        print(json.dumps({"type": "log", "message": f"Training failed: {e}"}), file=sys.stderr, flush=True)
        traceback.print_exc(file=sys.stderr)
        print(json.dumps({
            "type": "error",
            "error": str(e)
        }), flush=True)
        return 1


if __name__ == "__main__":
    sys.exit(main())
