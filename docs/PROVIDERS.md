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
| **Anthropic** | Pay-per-token | Fast | Cloud | Long documents, reasoning, analysis |
| **GitHub Copilot** | Subscription | Fast | Cloud | Developers with existing Copilot subscription |
| **DeepSeek** | Pay-per-token (low cost) | Fast | Cloud | Budget-friendly general use |
| **Google Gemini** | Pay-per-token | Fast | Cloud | Google ecosystem, multimodal |
| **MiniMax** | Pay-per-token | Fast | Cloud | Cost-effective, large context |
| **OpenRouter** | Varies by model | Varies | Cloud | Access to 100+ models |
| **MLX (Local)** | Free | Varies | Full privacy | Offline use, sensitive data, Apple Silicon |
| **llama.cpp (Local)** | Free | Varies | Full privacy | Offline use, Intel or Apple Silicon |
| **Custom Endpoint** | Varies | Varies | Self-hosted | Self-hosted servers, Ollama, LM Studio |

---

## Cloud Providers

### OpenAI

**What you get:** GPT-4o, GPT-4, GPT-3.5 Turbo, o1, o3 reasoning models

**Setup:**
1. Create an account at [platform.openai.com](https://platform.openai.com)
2. Go to API Keys and create a new key
3. In SAM Settings > AI Providers, add OpenAI
4. Paste your API key
5. Select your default model

**Model Recommendations:**
- **GPT-4o** - Best overall balance of speed, quality, and cost
- **GPT-3.5 Turbo** - Fast and cheap for simple tasks
- **o1 / o3** - Reasoning models for complex logic and math (slower, more expensive)

**Pricing:** See [openai.com/pricing](https://openai.com/pricing) for current rates.

---

### Anthropic (Claude)

**What you get:** Claude 4 Sonnet, Claude 4 Opus, Claude 3.5 Sonnet

**Setup:**
1. Create an account at [console.anthropic.com](https://console.anthropic.com)
2. Go to API Keys and create a new key
3. In SAM Settings > AI Providers, add Anthropic
4. Paste your API key
5. Select your default model

**Model Recommendations:**
- **Claude 4 Sonnet** - Best balance for most tasks
- **Claude 4 Opus** - Maximum capability (more expensive)
- **Claude 3.5 Sonnet** - Good quality at lower cost

**Extended Thinking:** Claude models support extended thinking, which shows the AI's reasoning process step by step. SAM displays these thinking blocks in collapsible sections.

**Long Context:** Claude supports context windows up to 200K tokens, making it excellent for analyzing long documents.

**Pricing:** See [anthropic.com/pricing](https://anthropic.com/pricing) for current rates.

---

### GitHub Copilot

**What you get:** Access to GPT-4o, Claude 3.5 Sonnet, o1, and other models through your Copilot subscription.

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

**What you get:** DeepSeek Chat, DeepSeek Coder

**Setup:**
1. Create an account at [platform.deepseek.com](https://platform.deepseek.com)
2. Create an API key
3. In SAM Settings > AI Providers, add DeepSeek
4. Paste your API key

**Model Recommendations:**
- **DeepSeek Chat** - General conversation and tasks
- **DeepSeek Coder** - Optimized for coding tasks

**Advantages:**
- Significantly lower cost than OpenAI or Anthropic
- Good quality for the price

---

### Google Gemini

**What you get:** Gemini 2.5 Pro, Gemini 2.5 Flash, Gemini 2.0 Flash

**Setup:**
1. Get an API key from [aistudio.google.com](https://aistudio.google.com)
2. In SAM Settings > AI Providers, add Gemini
3. Paste your API key
4. Select your default model

**Model Recommendations:**
- **Gemini 2.5 Pro** - Top-tier reasoning and long context
- **Gemini 2.5 Flash** - Fast and cost-effective
- **Gemini 2.0 Flash** - Budget-friendly for simple tasks

**Advantages:**
- Large context windows (up to 1M tokens on some models)
- Strong multimodal capabilities
- Competitive pricing

---

### MiniMax

**What you get:** MiniMax-M2.7, MiniMax-M2.5, and high-speed variants

**Setup:**
1. Create an account at [minimax.io](https://www.minimax.io)
2. Create an API key
3. In SAM Settings > AI Providers, add MiniMax
4. Paste your API key

**Model Recommendations:**
- **MiniMax-M2.7** - Latest model, best quality
- **MiniMax-M2.7-highspeed** - Faster variant with slightly lower quality
- **MiniMax-M2.5** - Previous generation, still capable

**Advantages:**
- 128K token context window
- Competitive pricing
- Good tool use capabilities

---

### OpenRouter

**What you get:** Access to 100+ models from multiple providers through a single API.

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

---

## Local Models

### MLX (Apple Silicon Only)

**What you get:** Run language models directly on your Mac using Apple's MLX framework with Metal GPU acceleration.

**Requirements:**
- Apple Silicon Mac (M1, M2, M3, M4)
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

### llama.cpp (Any Mac)

**What you get:** Run GGUF-format models on any Mac, including Intel.

**Requirements:**
- Any Mac (Apple Silicon or Intel)
- 8GB+ RAM
- macOS 14.0+

**Setup:**
1. Download a GGUF model file (from Hugging Face or other sources)
2. In SAM Settings > AI Providers, add llama.cpp
3. Point to the model file location
4. Configure context size and other parameters

**Advantages:**
- Works on Intel Macs (unlike MLX)
- Supports GGUF quantized models for lower memory usage
- Wide model compatibility

**Limitations:**
- Generally slower than MLX on Apple Silicon
- Manual model file management

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
2. Enter the endpoint URL
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

### Strategy Recommendations

| Use Case | Recommended Approach |
|----------|---------------------|
| **Daily use** | Cloud provider (GPT-4o or Claude) for quality and speed |
| **Sensitive content** | Local model (MLX) for complete privacy |
| **Budget-conscious** | DeepSeek, MiniMax, or local models for routine tasks, GPT-4o for complex ones |
| **Coding** | Claude or GPT-4o for best tool use, DeepSeek Coder for budget |
| **Long documents** | Claude (200K context), Gemini (1M context), or local models with large context |
| **Offline use** | Local models (MLX or llama.cpp) |
| **Experimentation** | OpenRouter for access to many models |

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
- For llama.cpp: verify the file is in GGUF format

---

## See Also

- [User Guide](USER_GUIDE.md) - Getting started with SAM
- [Features](FEATURES.md) - Complete feature reference
- [project-docs/API_FRAMEWORK.md](../project-docs/API_FRAMEWORK.md) - API implementation details
- [project-docs/API_INTEGRATION_SPECIFICATION.md](../project-docs/API_INTEGRATION_SPECIFICATION.md) - Provider integration specification
- [project-docs/MLX_INTEGRATION.md](../project-docs/MLX_INTEGRATION.md) - MLX implementation details
