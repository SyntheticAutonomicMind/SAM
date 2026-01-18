# CLIO Integration with SAM API - Proxy Mode Usage

## Overview

SAM now supports **per-request proxy mode** for external tools like CLIO (Command Line Intelligence Orchestrator). This allows CLIO to use SAM as a pure LLM proxy without SAM's tools, prompts, or session management.

## How It Works

There are two ways to enable proxy mode:

### Option 1: Global Proxy Mode (UI Toggle)
- Enable in SAM UI: Preferences → API Server → "Proxy Mode"
- **Affects all API requests** when enabled
- Not ideal for mixed usage scenarios

### Option 2: Per-Request Proxy Mode (Recommended for CLIO)
- Set `sam_config.bypass_processing = true` in your request
- **Only affects that specific request**
- Perfect for tools that manage their own context/tools

## CLIO Usage Example

### Basic Request with Proxy Bypass

```bash
curl -X POST http://127.0.0.1:8080/api/chat/completions \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer YOUR_API_TOKEN" \
  -d '{
    "model": "github_copilot/gpt-4.1",
    "messages": [
      {"role": "user", "content": "What is the capital of France?"}
    ],
    "stream": true,
    "sam_config": {
      "bypass_processing": true
    }
  }'
```

### What Happens with `bypass_processing: true`

1. ✅ **NO SAM system prompts** - Your messages go directly to the LLM
2. ✅ **NO MCP tools** - SAM's 14 tools with 46+ operations are bypassed
3. ✅ **NO memory/context injection** - No SAM conversation history added
4. ✅ **NO session management** - No SAM conversation tracking
5. ✅ **Pure 1:1 passthrough** - Exactly like calling OpenAI API directly

### What Still Works

- ✅ **All LLM providers** - OpenAI, Anthropic, GitHub Copilot, DeepSeek, local models
- ✅ **Streaming responses** - Real-time token streaming
- ✅ **Standard OpenAI format** - Compatible with any OpenAI client library
- ✅ **CLIO's own tools** - CLIO can send its own tools in the request

## Python Example (for CLIO)

```python
import requests
import json

def call_sam_proxy(messages, model="github_copilot/gpt-4.1", stream=True):
    """
    Call SAM in proxy mode - pure LLM passthrough without SAM processing
    """
    url = "http://127.0.0.1:8080/api/chat/completions"
    headers = {
        "Content-Type": "application/json",
        "Authorization": f"Bearer {YOUR_API_TOKEN}"
    }
    
    payload = {
        "model": model,
        "messages": messages,
        "stream": stream,
        "sam_config": {
            "bypass_processing": True  # THIS IS THE KEY FIELD
        }
    }
    
    response = requests.post(url, headers=headers, json=payload, stream=stream)
    
    if stream:
        for line in response.iter_lines():
            if line:
                line_str = line.decode('utf-8')
                if line_str.startswith('data: '):
                    data = line_str[6:]  # Remove 'data: ' prefix
                    if data != '[DONE]':
                        chunk = json.loads(data)
                        if 'choices' in chunk and len(chunk['choices']) > 0:
                            delta = chunk['choices'][0].get('delta', {})
                            if 'content' in delta:
                                yield delta['content']
    else:
        result = response.json()
        return result['choices'][0]['message']['content']

# Usage example
messages = [
    {"role": "user", "content": "Explain Python decorators"}
]

for token in call_sam_proxy(messages):
    print(token, end='', flush=True)
```

## Available Models

SAM supports multiple providers. Use these model identifiers:

### Discovering Models and Their Capabilities

**Get all available models with capabilities:**
```bash
curl http://localhost:8080/v1/models
```

**Response includes:**
```json
{
  "object": "list",
  "data": [
    {
      "id": "github_copilot/gpt-4.1",
      "object": "model",
      "created": 1705557600,
      "owned_by": "github",
      "context_window": 128000,
      "max_completion_tokens": 32000,
      "max_request_tokens": 96000
    }
  ]
}
```

**Get specific model details:**
```bash
curl http://localhost:8080/v1/models/github_copilot/gpt-4.1
```

### Model Capability Fields

- **context_window**: Maximum total tokens (input + output)
- **max_completion_tokens**: Maximum tokens for model response
- **max_request_tokens**: Maximum tokens for input messages
- **is_premium**: Whether this is a premium model (GitHub Copilot billing tier)
- **premium_multiplier**: Billing multiplier for premium models (e.g., 1.5x)

**Use these to right-size your requests:**
1. Query model capabilities before making requests
2. Calculate token count of your messages
3. Ensure `message_tokens + desired_output_tokens <= context_window`
4. Track premium model usage for billing purposes

### Remote Providers
- **GitHub Copilot**: `github_copilot/gpt-4.1`, `github_copilot/gpt-4o`, `github_copilot/o1-preview`
- **OpenAI**: `openai/gpt-4`, `openai/gpt-4-turbo`, `openai/gpt-3.5-turbo`
- **Anthropic**: `anthropic/claude-3-5-sonnet`, `anthropic/claude-3-opus`
- **DeepSeek**: `deepseek/deepseek-coder`, `deepseek/deepseek-chat`
- **Google**: `gemini/gemini-2.5-pro`, `gemini/gemini-1.5-flash`

### Local Models (if you have them installed)
- **MLX**: `mlx/mlx-community/Llama-3.2-3B-Instruct-4bit`
- **GGUF**: `lmstudio-community/Llama-3.2-3B-Instruct-GGUF`

## API Authentication

SAM requires API authentication for external requests:

1. **Set API token** in SAM UI: Preferences → API Server → "API Token"
2. **Include in requests**: `Authorization: Bearer YOUR_TOKEN`
3. **Internal bypass**: CLIO can use `X-SAM-Internal: true` header if running on same machine

## Differences from Standard SAM Mode

| Feature | Standard Mode | Proxy Mode (`bypass_processing: true`) |
|---------|---------------|---------------------------------------|
| System prompts | ✅ Applied | ❌ Bypassed |
| MCP tools | ✅ Available | ❌ Bypassed |
| Memory/RAG | ✅ Injected | ❌ Bypassed |
| Session tracking | ✅ Tracked | ❌ Bypassed |
| Response format | OpenAI-compatible | OpenAI-compatible |
| Streaming | ✅ Supported | ✅ Supported |
| Provider routing | ✅ Automatic | ✅ Automatic |

## Benefits for CLIO

1. **No interference** - SAM won't inject prompts or context CLIO doesn't want
2. **CLIO manages tools** - CLIO can send its own tools in the request
3. **CLIO manages sessions** - No SAM conversation state to manage
4. **Pure LLM responses** - Exactly what CLIO expects from an LLM API
5. **Multi-provider access** - Use SAM's configured providers without configuration

## Troubleshooting

### "Proxy mode not working"
- Verify `sam_config.bypass_processing` is `true` (not `"true"` string)
- Check SAM logs: `tail -f ~/Library/Logs/SAM/sam.log`

### "Still seeing SAM tools"
- Ensure you're sending the field with the correct snake_case: `bypass_processing`
- Not camelCase: `bypassProcessing`

### "Authentication failed"
- Set API token in SAM Preferences
- Include `Authorization: Bearer TOKEN` header
- Or use `X-SAM-Internal: true` for local requests

## Implementation Details

- **Added in**: SAM v20260118.2
- **Field**: `sam_config.bypass_processing` (boolean, optional)
- **Code**: `Sources/APIFramework/SAMAPIServer.swift:handleChatCompletion()`
- **Fallback**: If not specified, uses global `serverProxyMode` setting

## Questions?

See SAM documentation or open an issue at: https://github.com/SyntheticAutonomicMind/SAM
