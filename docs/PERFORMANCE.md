# SAM Performance

Performance characteristics, resource expectations, and optimization guidance.

---

## Overview

SAM is a native macOS app, so its performance profile depends heavily on how you use it.

The biggest variables are:
- whether you use cloud or local models
- model size
- document usage
- web/tool activity
- hardware class, especially Apple Silicon vs Intel

---

## Resource Usage

### Memory usage

Typical RAM usage varies a lot by configuration.

| Configuration | Typical RAM Usage |
|--------------|------------------|
| Cloud providers only | 150MB-300MB |
| Cloud + documents and memory-heavy workflows | 200MB-500MB |
| Local 7B-class model (MLX) | 5GB-8GB |
| Local 13B-class model (MLX) | 10GB-16GB |
| Local 7B-class model (CachyLLama) | 4GB-7GB |
| Very large local models | much higher, depending on model size |

Local inference dominates memory usage because model weights must be loaded into memory. CachyLLama typically uses 15-20% less memory than standard llama.cpp for the same model.

### Disk usage

| Component | Typical Size |
|-----------|--------------|
| SAM app bundle | modest compared to model storage |
| Conversations and metadata | grows with usage |
| Per-conversation memory/vector data | depends on document and chat volume |
| Local model cache | often the largest storage consumer |

Local models are stored under:

```text
~/Library/Caches/sam-rewritten/models/
```

### Network usage

- Local-only workflows: minimal to none
- Cloud providers: depends on prompt and response volume
- Web research: depends on searches and fetches you request
- Update checks: small and periodic

---

## Hardware Guidance

### Apple Silicon

Apple Silicon provides the best local experience, especially with MLX and CachyLLama.

Best use cases:
- local models (MLX, CachyLLama)
- mixed local/cloud usage
- voice plus local inference
- document-heavy workflows with strong responsiveness

### Intel Macs

Intel remains usable for:
- cloud providers
- llama.cpp local models
- general SAM usage without MLX

If local inference matters a lot, Apple Silicon is the better experience.

---

## Local Model Expectations

Local performance depends on:
- model size
- quantization
- available RAM / unified memory
- current system load
- chosen engine (MLX vs CachyLLama vs llama.cpp)

### General guidance

- smaller models are faster and lighter
- larger models may improve quality but increase latency and memory usage
- MLX is usually the best option on Apple Silicon for quality
- CachyLLama is the best option on Apple Silicon for speed
- llama.cpp is the fallback for Intel or GGUF-specific local workflows

### Model engine comparison (Apple Silicon)

| Engine | Speed | Quality | Memory Efficiency | Best For |
|--------|-------|---------|-------------------|----------|
| **MLX** | Fast | Best | Good | General local use, quality priority |
| **CachyLLama** | Fastest | Very Good | Best | Speed priority, large models |
| **llama.cpp** | Moderate | Good | Good | Intel Macs, specific GGUF models |

---

## Performance Monitoring

SAM includes built-in visibility into performance-related state, including things like:
- memory usage
- context usage
- latency
- local inference-related metrics where available
- cost tracking per conversation

This helps you understand whether a slowdown is coming from the model, the prompt size, the document workload, or the surrounding system.

---

## Performance Tips

### For cloud usage

- keep conversations focused when possible
- start a fresh conversation for a completely different subject
- choose lighter models for simple work

### For local usage

- use smaller models when speed matters more than raw capability
- close other heavy apps if you are short on RAM
- prefer MLX or CachyLLama on Apple Silicon
- avoid oversized models for machines that do not have the headroom
- use quantized models (Q4_K_M, Q5_K_M) for better memory/speed tradeoff

### For document workflows

- import only what you need for the current task when possible
- very large documents increase indexing and retrieval work
- structured text is generally easier to process than poor-quality scanned content

### For voice workflows

- use a fast local model for responsive interaction
- enable streaming TTS for natural conversation flow
- select appropriate audio devices to avoid resampling overhead

---

## Context Size and Responsiveness

Longer context windows can improve continuity, but they also increase work for the model.

SAM manages this by:
- trimming older context
- recalling archived context when useful
- avoiding unbounded prompt growth
- using userContext for dynamic content (KV cache stability)

That balance is important for keeping long-lived conversations usable.

---

## Practical Recommendations

If you want the best overall experience:
- use Apple Silicon
- keep at least 16GB RAM available for local work
- use local models for privacy-sensitive tasks
- use cloud models when you want broader hosted capability
- let SAM's memory and retrieval features do the heavy lifting instead of pasting huge context blocks manually
- prefer CachyLLama for speed, MLX for quality on Apple Silicon

---

## See Also

- [Providers](PROVIDERS.md)
- [Memory](MEMORY.md)
- [Architecture](ARCHITECTURE.md)
- [Installation](INSTALLATION.md)