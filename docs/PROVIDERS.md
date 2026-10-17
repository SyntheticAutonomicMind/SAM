# AI Provider Guide

**Setting up and configuring AI providers in SAM**

---

## Overview

SAM connects to AI providers to power its conversation and tool capabilities. You can use cloud providers, local models, or a mix of both. This guide covers setup, configuration, and best practices for each provider.

---

## Quick Comparison

| Provider | Cost | Speed | Privacy | Best For |
|----------|------|-------|---------|----------|
| **OpenAI** | Pay-per-token | Fast | Cloud | General use, coding, creative writing |
| **Anthropic** | - | - | - | No direct provider. Use OpenRouter for Claude models. |
| **GitHub Copilot** | Subscription | Fast | Cloud | Developers with existing Copilot subscription |
| **DeepSeek** | Pay-per-token (low cost) | Fast | Cloud | Budget-friendly general use |
| **Google Gemini** | Pay-per-token | Fast | Cloud | Google ecosystem, multimodal |
| **MiniMax** | Pay-per-token | Fast | Cloud | Cost-effective, large context |
| **OpenRouter** | Varies by model | Varies | Cloud | Access models from multiple providers |
| **Ollama Cloud** | Pay-per-token | Varies | Cloud | Cloud-hosted Ollama models |
| **Z.AI (Chat)** | Pay-per-token | Fast | Cloud | GLM models, Chinese/English bilingual |
| **Z.AI (Coding)** | Pay-per-token | Fast | Cloud | GLM coding models |
| **MLX (Local)** | Free | Varies | Full privacy | Offline use, sensitive data, Apple Silicon |
| **llama.cpp (Local)** | Free | Fast | Full privacy | High-performance local, Apple Silicon |
| **Remote llama.cpp** | Free | Varies | Self-hosted | Self-hosted inference servers |
| **Custom Endpoint** | Varies | Varies | Self-hosted | Self-hosted servers, Ollama, LM Studio |

---

## Cloud Providers

### OpenAI

**What you get:** Leading frontier models with strong reasoning and coding

**Setup:**
1. Create an account at [platform.openai.com](https://platform.openai.com)
2. Go to API Keys and create a new key
3. In SAM Settings > AI Providers, add OpenAI
4. Paste your API key
5. Select your default model

**Model Recommendations:**
- Top-tier model - Best overall balance of speed, quality, and cost
- Fast model - Fast and cheap for simple tasks
- Reasoning model - For complex logic and math (slower, more expensive)

**Pricing:** See [openai.com/pricing](https://openai.com/pricing) for current rates.

---

### GitHub Copilot

**What you get:** Multiple model families via your Copilot subscription

**Setup:**
1. You need an active GitHub Copilot subscription (Individual, Business, or Enterprise)
2. In SAM Settings > AI Providers, add GitHub Copilot
3. Click "Sign in with GitHub"
4. SAM uses the GitHub device flow - you'll see a code to enter on github.com
5. After authorization, SAM automatically manages token refresh

**How It Works:**
- SAM authenticates via GitHub's device flow (no manual API key needed)
- Tokens are refreshed automatically in the background
- Available models depend on your Copilot subscription tier

**Advantages:**
- No separate API key or billing
- Uses your existing Copilot subscription
- Access to multiple model providers through one authentication

---

### DeepSeek

**What you get:** General-purpose and coding-optimized models

**Setup:**
1. Create an account at [platform.deepseek.com](https://platform.deepseek.com)
2. Create an API key
3. In SAM Settings > AI Providers, add DeepSeek
4. Paste your API key

**Model Recommendations:**
- General conversation and task models
- Coding-optimized variants

**Advantages:**
- Significantly lower cost than OpenAI or Anthropic
- Good quality for the price

---

### Google Gemini

**What you get:** State-of-the-art multimodal models with large context

**Setup:**
1. Get an API key from [aistudio.google.com](https://aistudio.google.com)
2. In SAM Settings > AI Providers, add Gemini
3. Paste your API key
4. Select your default model

**Model Recommendations:**
- Top-tier reasoning and long context models
- Fast and cost-effective variants
- Budget-friendly options for simple tasks

**Advantages:**
- Large context windows (up to 1M tokens on some models)
- Strong multimodal capabilities
- Competitive pricing

---

### MiniMax

**What you get:** Large-context models optimized for efficiency

**Setup:**
1. Create an account at [minimax.io](https://www.minimax.io)
2. Create an API key
3. In SAM Settings > AI Providers, add MiniMax
4. Paste your API key

**Model Recommendations:**
- Latest model - best quality
- Previous generation - still capable

**Advantages:**
- Large context windows (up to 1M+ tokens on M3)
- Competitive pricing
- Good tool use capabilities
- Supports thinking parameter for extended reasoning

---

### OpenRouter

**What you get:** Access to models from multiple providers through a single API.

**Setup:**
1. Create an account at [openrouter.ai](https://openrouter.ai)
2. Create an API key
3. In SAM Settings > AI Providers, add OpenRouter
4. Paste your API key
5. Browse available models

**Advantages:**
- One API key for dozens of providers
- Try different models without separate accounts
- Automatic routing and load balancing
- Pay-per-token across all models

**Recommended Model for New Users:**
- A MiniMax model - Excellent all-around performance with large context, strong reasoning, and competitive pricing. A great starting point when using OpenRouter.

---

### Ollama Cloud

**What you get:** Cloud-hosted Ollama models without managing your own server.

**Setup:**
1. Create an account at [ollama.com](https://ollama.com)
2. Create an API key
3. In SAM Settings > AI Providers, add Ollama Cloud
4. Paste your API key
5. Select a model from the available list

**Advantages:**
- No local infrastructure needed
- Access to popular Ollama models in the cloud
- Pay-per-token pricing

---

### Z.AI (Chat)

**What you get:** Z.AI's GLM models optimized for general conversation and reasoning.

**Setup:**
1. Create an account at [z.ai](https://z.ai)
2. Create an API key
3. In SAM Settings > AI Providers, add Z.AI (Chat)
4. Paste your API key

**Models:** Latest GLM family models

**Features:**
- Strong bilingual capabilities (Chinese/English)
- Chain-of-thought reasoning
- Competitive pricing

---

### Z.AI (Coding)

**What you get:** Z.AI's GLM models optimized for coding tasks.

**Setup:**
1. Create an account at [z.ai](https://z.ai)
2. Create an API key
3. In SAM Settings > AI Providers, add Z.AI (Coding)
4. Paste your API key

**Models:** Latest GLM family models

**Features:**
- Specialized for code generation and analysis
- Supports chain-of-thought reasoning for complex coding tasks
- Large context windows

---

## Local Models

### MLX (Apple Silicon Only)

**What you get:** Run language models directly on your Mac using Apple's MLX framework with Metal GPU acceleration.

**Requirements:**
- Apple Silicon Mac
- 8GB+ unified memory (16GB+ recommended)
- macOS 14.0+

**Setup:**
1. In SAM Settings > AI Providers, click Add Provider
2. Choose "Local MLX Model"
3. Browse available models
4. Click Download on your chosen model
5. Wait for the download to complete
6. The model is ready to use

**RAM Requirements:**
| Model Size | Minimum RAM | Recommended RAM |
|-----------|-------------|-----------------|
| 1-3B parameters | 4GB | 8GB |
| 7B parameters | 8GB | 16GB |
| 13B parameters | 16GB | 32GB |
| 30B+ parameters | 32GB | 64GB |
| 70B parameters | 64GB | 96GB+ |

**Performance Tips:**
- Larger models are more capable but slower
- Unified memory means the GPU shares RAM with the system
- Close other memory-intensive apps for best performance
- First generation is slower (model loading), subsequent ones are faster

**Advantages:**
- Complete privacy - nothing leaves your Mac
- No internet connection needed after download
- No per-token costs
- Fast inference on Apple Silicon

---

### llama.cpp (Apple Silicon)

**What you get:** High-performance GGUF inference with Metal GPU acceleration.

**Requirements:**
- Apple Silicon Mac
- 8GB+ RAM
- macOS 14.0+

**Setup:**
1. In SAM Settings > AI Providers, click Add Provider
2. Choose "Local llama.cpp Model"
3. Browse available models (Hugging Face GGUF)
4. Click Download on your chosen model
5. Wait for the download to complete
6. Configure sampler parameters (top-K, min-P, temperature, etc.) if desired
7. The model is ready to use

**Performance Advantages:**
- Optimized Metal GPU kernels for Apple Silicon
- Improved sampler chain (top-K, min-P, temperature, top-P, typical-P)
- Better memory management and KV cache handling
- Typically 20-40% faster than standard llama.cpp on Apple Silicon

**Advantages:**
- Complete privacy - nothing leaves your Mac
- No internet connection needed after download
- No per-token costs
- Best local inference performance on Apple Silicon

---

### Remote llama.cpp

**What you get:** Connect to a remote llama.cpp server (e.g., running on a GPU server) for local-model inference without local hardware requirements.

**Setup:**
1. Run a llama.cpp server on your remote machine:
   ```bash
   ./llama-server -m model.gguf --host 0.0.0.0 --port 8080
   ```
2. In SAM Settings > AI Providers, add Remote llama.cpp
3. Enter the server URL (e.g., `http://192.168.1.100:8080`)
4. Configure authentication if needed

**Use Cases:**
- Offload inference to a dedicated GPU server
- Run larger models than your local machine can handle
- Share a model server across multiple machines

---

## Custom Endpoints

### OpenAI-Compatible Servers

SAM can connect to any server that implements the OpenAI chat completions API. This includes:

- **Ollama** - `http://localhost:11434/v1`
- **LM Studio** - `http://localhost:1234/v1`
- **text-generation-webui** - `http://localhost:5000/v1`
- **vLLM** - `http://localhost:8000/v1`
- **Any OpenAI-compatible API**

**Setup:**
1. In SAM Settings > AI Providers, add a Custom provider
2. Enter the endpoint URL (e.g., `http://localhost:11434/v1`)
3. Enter an API key if required (some local servers don't need one)
4. Configure the model name
5. Test the connection

---

## Managing Multiple Providers

### Switching Between Providers

You can have multiple providers configured simultaneously and switch between them:
- Use the model selector in the toolbar to pick a different model/provider
- Switch mid-conversation - the history carries forward
- Each conversation remembers which model was last used

---

## Troubleshooting

### "Authentication failed"
- Verify your API key is correct
- For GitHub Copilot: try signing out and back in
- Check that your account has billing configured (cloud providers)

### "Model not found"
- The model may have been renamed or deprecated
- Refresh the model list in Settings
- Check the provider's documentation for current model names

### "Rate limited"
- You've exceeded the provider's rate limits
- Wait a moment and try again
- Consider upgrading your plan or using a different provider

### "Request too large"
- Your conversation has exceeded the model's context window
- Start a new conversation
- Use a model with a larger context window
- SAM's context management should handle this automatically, but very long conversations with many tool calls can hit limits

### Local model loading fails
- Ensure you have enough free RAM
- Try a smaller model
- Check that the model file isn't corrupted (re-download if needed)
- For MLX: verify you're on Apple Silicon
- For llama.cpp: verify you're on Apple Silicon
- For llama.cpp: verify the file is in GGUF format

---

## See Also

- [User Guide](USER_GUIDE.md) - Getting started with SAM
- [Features](FEATURES.md) - Complete feature reference
- [project-docs/API_FRAMEWORK.md](../project-docs/API_FRAMEWORK.md) - API implementation details
- [project-docs/API_INTEGRATION_SPECIFICATION.md](../project-docs/API_INTEGRATION_SPECIFICATION.md) - Provider integration specification
