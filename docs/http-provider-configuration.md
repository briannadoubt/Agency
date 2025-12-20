# HTTP Provider Configuration Guide

This guide covers configuring HTTP-based model providers in Agency, enabling the use of local models (Ollama, llama.cpp, vLLM) or cloud APIs for agent flows.

## Overview

Agency supports two types of model providers:
- **CLI Providers**: External tools like Claude Code that manage their own agent loop
- **HTTP Providers**: OpenAI-compatible APIs where Agency manages the agent loop

## Supported Providers

### Local Model Servers

| Provider | Default URL | Tool Use Support |
|----------|-------------|------------------|
| Ollama | http://localhost:11434/v1 | Yes (llama3.2, qwen2.5) |
| llama.cpp server | http://localhost:8080/v1 | Model-dependent |
| vLLM | http://localhost:8000/v1 | Yes |
| LM Studio | http://localhost:1234/v1 | Model-dependent |
| LocalAI | http://localhost:8080/v1 | Yes |
| text-generation-webui | http://localhost:5000/v1 | Limited |

### Cloud APIs

| Provider | API Format | Notes |
|----------|------------|-------|
| OpenAI | Native | Full support |
| Anthropic | Custom | Use Claude Code CLI instead |
| Google Gemini | OpenAI-compatible | Via AI Studio |
| Groq | OpenAI-compatible | Fast inference |

## Configuration

### Ollama Setup

1. Install Ollama from [ollama.ai](https://ollama.ai)
2. Start the Ollama server:
   ```bash
   ollama serve
   ```
3. Pull a model that supports tool use:
   ```bash
   ollama pull llama3.2
   ```
4. Open Agency Settings → HTTP Providers
5. The Ollama section shows connection status automatically

### Custom OpenAI-Compatible Endpoints

1. Open Agency Settings → HTTP Providers
2. Click "Add Provider" in the Custom Endpoints section
3. Fill in the configuration:
   - **Name**: Display name for the provider
   - **Endpoint URL**: Base URL (e.g., `http://localhost:8080/v1`)
   - **Model**: Model identifier to use
   - **Requires API Key**: Enable if the server requires authentication
4. Click "Test Connection" to verify
5. Click "Add" to save

### API Key Storage

API keys are stored securely in the macOS Keychain:
- Keys are never stored in plain text or UserDefaults
- Each provider has its own Keychain entry
- Keys persist across app restarts

## Provider Capabilities

### HTTPProviderCapabilities

Providers declare their capabilities:

| Capability | Description |
|------------|-------------|
| `streaming` | Supports real-time SSE streaming |
| `toolUse` | Supports function/tool calling |
| `vision` | Supports image inputs |
| `costTracking` | Reports token usage for cost tracking |
| `jsonMode` | Supports structured JSON output |
| `systemMessages` | Supports system role messages |
| `local` | Local server (no API key required) |

### Checking Capabilities

In the Settings UI, each provider shows:
- Connection status (green check or red X)
- Server version (if available)
- Endpoint URL

## Model Requirements for Agent Flows

Not all models support the tool/function calling required for agent flows:

### Recommended Models for Tool Use

**Ollama:**
- `llama3.2` (3B/1B) - Good balance of speed and capability
- `qwen2.5` (various sizes) - Strong tool use support
- `mistral` (7B) - Good performance

**vLLM:**
- Any model with `--enable-auto-tool-choice`

### Models Without Tool Support

These models can still be used but won't execute tools:
- Base models without instruction tuning
- Models not trained on function calling
- Some smaller quantized models

## Troubleshooting

### Connection Failed

**Symptom**: "Cannot connect to Ollama. Is it running?"

**Solutions**:
1. Verify the server is running:
   ```bash
   curl http://localhost:11434/api/version
   ```
2. Check the endpoint URL is correct
3. Ensure no firewall is blocking the port

### Model Not Found

**Symptom**: "Model not found: llama3.2"

**Solutions**:
1. List available models:
   ```bash
   ollama list
   ```
2. Pull the missing model:
   ```bash
   ollama pull llama3.2
   ```

### Tool Calls Not Working

**Symptom**: Agent doesn't execute tools, just outputs text

**Possible causes**:
1. Model doesn't support tool use - try a different model
2. System prompt not formatted correctly
3. Max turns reached before tool execution

### Rate Limiting

**Symptom**: "Rate limited. Retry after X seconds."

**Solutions**:
1. Wait and retry
2. Reduce concurrent requests
3. Use a different provider or API key

### Timeout Errors

**Symptom**: "Request timed out."

**Solutions**:
1. Increase timeout in endpoint configuration
2. Use a faster model
3. Check server load and resources

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                      AgentRunner                                 │
├─────────────────────────────────────────────────────────────────┤
│  resolveExecutor() → GenericHTTPExecutor                        │
│                      ├── AgentLoopController (manages turns)    │
│                      │   └── ToolExecutionBridge (runs tools)   │
│                      └── AgentHTTPProvider (API interface)      │
└─────────────────────────────────────────────────────────────────┘
```

### Key Components

- **GenericHTTPExecutor**: Implements `AgentExecutor` for HTTP providers
- **AgentLoopController**: Manages multi-turn conversation with tool use
- **ToolExecutionBridge**: Executes tools (Read, Write, Edit, Bash, Glob, Grep)
- **AgentHTTPProvider**: Protocol for provider implementations

## Security Considerations

1. **Local servers**: Usually don't require authentication
2. **API keys**: Stored in Keychain, not in config files
3. **Tool execution**: Sandboxed to project directory
4. **Network access**: Limited to configured endpoints

## See Also

- [AGENTS.md](../AGENTS.md) - Full agent documentation
- [PROJECT_WORKFLOW.md](../PROJECT_WORKFLOW.md) - Workflow documentation
