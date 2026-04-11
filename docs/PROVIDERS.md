# AI Provider Guide

Setting up and choosing AI providers in SAM.

---

## Overview

SAM supports both cloud and local AI providers. You can configure one provider or several, then switch between them depending on the task.

Current provider types in SAM:

- **OpenAI**
- **GitHub Copilot**
- **DeepSeek**
- **Google Gemini**
- **MiniMax**
- **OpenRouter**
- **Local MLX**
- **Local llama.cpp**
- **Custom OpenAI-compatible endpoints**

> Note: SAM does **not** currently expose a direct Anthropic provider. Claude-family models are available through providers such as GitHub Copilot and OpenRouter when those services offer them.

---

## Quick Comparison

| Provider | Type | Best For | Notes |
|----------|------|----------|-------|
| **OpenAI** | Cloud | General use, coding, writing | Broad model support |
| **GitHub Copilot** | Cloud | Existing Copilot subscribers | Access to multiple hosted models through GitHub |
| **DeepSeek** | Cloud | Cost-sensitive coding and general use | OpenAI-compatible API |
| **Google Gemini** | Cloud | Large context, multimodal use cases | Google-hosted models |
| **MiniMax** | Cloud | Large context and lower-cost experimentation | Supports large context windows |
| **OpenRouter** | Cloud | Access to many providers from one account | Unified gateway to many models |
| **MLX** | Local | Apple Silicon offline use | Best local experience on Apple Silicon |
| **llama.cpp** | Local | Offline use on Intel or Apple Silicon | Works with GGUF models |
| **Custom** | Cloud or self-hosted | OpenAI-compatible services | Good for Ollama, LM Studio, vLLM, and similar systems |

---

## Cloud Providers

### OpenAI

Use OpenAI when you want straightforward hosted model access with broad compatibility.

**Setup**
1. Create an API key at [platform.openai.com](https://platform.openai.com)
2. In SAM, open **Settings > AI Providers**
3. Add **OpenAI**
4. Paste your API key
5. Choose a default model

**Good fit for**
- General chat
- Coding help
- Writing and editing
- Reliable hosted inference

---

### GitHub Copilot

GitHub Copilot is a strong option if you already have a Copilot subscription.

**Setup**
1. Open **Settings > AI Providers**
2. Add **GitHub Copilot**
3. Sign in using GitHub device flow
4. Let SAM complete authorization and token storage

**Notes**
- No manual API key entry is required for the normal Copilot flow
- SAM handles token refresh automatically
- Available models depend on GitHub's current Copilot offerings and your subscription tier
- Claude-family models may be accessible here depending on GitHub availability

---

### DeepSeek

DeepSeek provides an OpenAI-compatible hosted API and can be a cost-effective option.

**Setup**
1. Create an API key at [platform.deepseek.com](https://platform.deepseek.com)
2. Add **DeepSeek** in SAM
3. Paste your API key
4. Choose a model

**Good fit for**
- General use
- Coding tasks
- Lower-cost cloud inference

---

### Google Gemini

Gemini is useful when you want large context windows and Google-hosted models.

**Setup**
1. Get an API key from [Google AI Studio](https://aistudio.google.com)
2. Add **Google Gemini** in SAM
3. Paste your API key
4. Select a default model

**Good fit for**
- Long-context work
- General reasoning
- Multimodal model access where supported

---

### MiniMax

MiniMax is another hosted provider with large-context options.

**Setup**
1. Create an account and API key through MiniMax
2. Add **MiniMax** in SAM
3. Paste your API key
4. Pick your preferred model

**Good fit for**
- Large-context conversations
- Comparative provider testing
- Cost/performance experimentation

---

### OpenRouter

OpenRouter gives SAM access to a broad catalog of hosted models through one API.

**Setup**
1. Create an account at [openrouter.ai](https://openrouter.ai)
2. Generate an API key
3. Add **OpenRouter** in SAM
4. Paste your API key
5. Choose from available models

**Notes**
- OpenRouter may expose models from multiple upstream providers
- SAM sends the required identification headers for OpenRouter requests
- Claude-family models may be available here depending on OpenRouter's catalog

---

## Local Providers

### MLX

MLX is the best local experience on Apple Silicon.

**Requirements**
- Apple Silicon Mac
- macOS 14.0+
- Enough unified memory for the model you want to run

**Setup**
1. Add **Local MLX** in **Settings > AI Providers**
2. Browse available models
3. Download the model you want
4. Select it as your active provider

**Why use it**
- Fully local inference
- Strong Apple Silicon performance
- Good privacy and offline capability

---

### llama.cpp

`llama.cpp` supports local GGUF models and works on both Apple Silicon and Intel Macs.

**Requirements**
- macOS 14.0+
- Enough RAM for your chosen model
- GGUF model files

**Setup**
1. Add **Local llama.cpp** in **Settings > AI Providers**
2. Select or download a compatible model
3. Configure model settings if needed

**Why use it**
- Works on Intel Macs
- Supports a wide range of local GGUF models
- Good fallback when MLX is unavailable

---

## Custom OpenAI-Compatible Endpoints

SAM can connect to any endpoint that speaks the OpenAI-compatible chat API.

Examples include:
- Ollama
- LM Studio
- text-generation-webui
- vLLM
- Self-hosted gateways and proxies

**Setup**
1. Add **Custom** in **Settings > AI Providers**
2. Enter the base URL
3. Add authentication if required
4. Configure model identifiers exposed by your server

This is the most flexible option if you run your own infrastructure.

---

## Choosing the Right Provider

### Choose local if you want:
- Maximum privacy
- Offline access
- No per-token billing
- Sensitive work to stay on your machine

### Choose cloud if you want:
- Faster setup
- Hosted model variety
- Higher-end proprietary models
- Less local resource usage

### Choose hybrid if you want:
- Local models for private work
- Cloud models for heavier tasks
- Flexibility by task type

---

## API Keys and Credentials

SAM stores provider credentials in the macOS Keychain.

That means:
- Keys are not stored in plain text documentation or config files
- Secrets stay local to your Mac
- Provider setup can be managed from the SAM interface

---

## Troubleshooting

### A provider validates but fails later

Many providers are validated with basic configuration checks first. The real test is the first live request.

Check:
- API key is correct
- Base URL is correct
- Selected model exists for that provider
- Network access is available

### A local model is missing

Check:
- The model finished downloading
- Your Mac has enough RAM for it
- The provider is enabled in Settings

### Copilot sign-in fails

Try signing out and reauthorizing through the device flow.

### A model is offered by a service but not directly by SAM

That usually means the model is accessed through an upstream provider like GitHub Copilot or OpenRouter rather than through a dedicated provider integration.

---

## See Also

- [Installation](INSTALLATION.md)
- [User Guide](USER_GUIDE.md)
- [Performance](PERFORMANCE.md)
- [Security](SECURITY.md)
