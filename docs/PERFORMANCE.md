# SAM Performance

**Performance characteristics, resource usage, and optimization tips**

---

## Overview

SAM is a native macOS application optimized for Apple Silicon. This document covers what to expect in terms of resource usage, how to monitor performance, and how to optimize for your hardware.

---

## Resource Usage

### Memory (RAM)

SAM's memory usage depends heavily on your configuration:

| Configuration | Typical RAM Usage |
|--------------|------------------|
| **Cloud providers only** | 150-300 MB |
| **Cloud + documents** | 200-500 MB |
| **Local 7B model (MLX)** | 5-8 GB |
| **Local 13B model (MLX)** | 10-16 GB |
| **Local 70B model (MLX)** | 40-70 GB |

**Why local models use so much RAM:** Language models must be loaded entirely into memory for inference. On Apple Silicon, this uses unified memory shared between CPU and GPU. The model weights dominate memory usage.

### CPU Usage

- **Idle:** Near zero - SAM uses no CPU when waiting for input
- **Cloud AI response:** Minimal - mostly network I/O and rendering
- **Local model inference:** High - one-time burst during generation, drops when complete
- **Document import:** Brief spike during text extraction and embedding generation

### Disk Space

| Component | Size |
|-----------|------|
| **SAM.app** | ~60 MB |
| **Conversations** | 10 KB - 1 MB each (varies by length) |
| **Vector databases** | 1-50 MB per conversation (with documents) |
| **Local models** | 2-70 GB each (depends on model size) |

### Network

- **Cloud providers:** Varies with conversation length and model
- **Local models:** Zero (completely offline)
- **Update checks:** Minimal (periodic Sparkle appcast fetch)
- **Web operations:** Only when explicitly requested

---

## Performance Monitoring

SAM includes built-in performance monitoring visible in the app:

### Available Metrics

| Metric | What It Shows |
|--------|-------------|
| **RSS (Memory)** | Current resident set size - how much RAM SAM is using |
| **Tokens/sec** | Inference speed for local models |
| **Context usage** | How many tokens are used vs. the model's maximum |
| **API latency** | Response time for cloud provider requests |

### Viewing Performance

Performance metrics are available in the app interface. Enable the performance display in Settings or through the conversation view options.

---

## Performance by Hardware

### Apple Silicon (M1/M2/M3/M4)

Best experience across the board:

| Task | M1 | M2 | M3 | M4 |
|------|----|----|----|----|
| **Cloud AI chat** | Excellent | Excellent | Excellent | Excellent |
| **Local 7B model** | Good (20-30 tok/s) | Good (25-40 tok/s) | Great (30-50 tok/s) | Great (35-60 tok/s) |
| **Local 13B model** | Adequate (10-20 tok/s) | Good (15-25 tok/s) | Good (20-35 tok/s) | Great (25-40 tok/s) |
| **Document import** | Fast | Fast | Fast | Fast |
| **Voice recognition** | Real-time | Real-time | Real-time | Real-time |

*Token rates are approximate and vary by model, quantization, and context length.*

### Intel Macs

| Task | Performance |
|------|------------|
| **Cloud AI chat** | Excellent (same as Apple Silicon) |
| **Local llama.cpp** | Adequate (5-15 tok/s for 7B) |
| **MLX models** | Not available |
| **Document import** | Good |
| **Voice recognition** | Real-time |

---

## Optimization Tips

### For Cloud Providers

1. **Keep conversations focused** - Long conversations with lots of context cost more tokens and are slower
2. **Use appropriate models** - GPT-3.5 or DeepSeek for simple tasks, GPT-4o or Claude for complex ones
3. **Start new conversations** for new topics - don't reuse conversations for unrelated tasks

### For Local Models

1. **Choose the right model size** - Bigger isn't always better. A well-tuned 7B model is faster and often sufficient
2. **Use quantized models** - 4-bit quantization significantly reduces memory usage with minimal quality loss
3. **Close other apps** - Free up unified memory for the model
4. **Monitor memory pressure** - Activity Monitor shows if you're swapping to disk (very slow)
5. **MLX over llama.cpp** on Apple Silicon - MLX is optimized for Apple's Metal GPU

### For Documents

1. **Smaller documents process faster** - Split very large documents if possible
2. **PDF quality matters** - Scanned PDFs with poor OCR will produce poor search results
3. **Text formats are fastest** - .txt and .md import almost instantly

### General

1. **Update SAM regularly** - Performance improvements ship in every release
2. **Restart after long sessions** - If memory usage seems high, restart SAM to reclaim memory
3. **Check Activity Monitor** - If SAM seems slow, check for memory pressure or other processes competing for resources

---

## Context Window Management

The context window is the total amount of text the AI can consider at once. SAM manages this automatically, but understanding it helps you get better results.

### How Context Fills Up

```
Context Window (e.g., 128K tokens)
┌──────────────────────────────────────┐
│ System prompt (~2-5K)                │
│ Tool definitions (~3-5K)             │
│ Conversation history (grows)         │
│ Document context (from RAG)          │
│ Available space for response         │
└──────────────────────────────────────┘
```

As conversations get longer, more of the context window is used by history. SAM's context archival system helps by archiving and summarizing older messages, but very long conversations eventually hit limits.

### When Context Matters

- **Short conversations:** No concerns - plenty of space
- **Medium conversations (50-100 messages):** SAM compresses older messages automatically
- **Long conversations (100+ messages):** Consider starting a new conversation for new topics
- **Document-heavy conversations:** RAG retrieval is more efficient than stuffing the full document into context

---

## See Also

- [User Guide](USER_GUIDE.md) - Getting started with SAM
- [Providers Guide](PROVIDERS.md) - Choosing the right provider for performance
- [Memory System](MEMORY.md) - How context and memory management works
- [Architecture](ARCHITECTURE.md) - Technical architecture overview
