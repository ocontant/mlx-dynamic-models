# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository Overview

This repository contains a LiteLLM proxy setup that routes API requests between different LLM formats. The main use cases are:

1. Routing Anthropic Claude API requests to a local MLX-powered Qwen model
2. Routing OpenAI API requests to a local MLX-powered Qwen model 

The proxy handles format conversion and configuration automatically, allowing applications written for Claude or OpenAI to use local MLX models without code changes.

## Key Components

- **LiteLLM Proxy**: The core component that handles API request routing and format conversion
- **MLX LM Wrapper**: A management layer for MLX models that handles model loading and serving
- **Pre-call Hook**: Custom hook to ensure models are properly loaded before requests are processed
- **Docker Setup**: A complete environment including the proxy, admin UI, PostgreSQL, Prometheus, and Grafana
- **Configuration Files**: YAML files that define routing rules and model mappings
- **Startup Scripts**: Shell scripts to launch the proxy with different configurations
- **Test Scripts**: Python scripts to validate the proxy's functionality

## Common Commands

### Starting the Proxy

#### Dynamic MLX Proxy (supports model switching):
```bash
./start_dynamic_mlx_proxy.sh [--port PORT] [--max-tokens MAX_TOKENS] [--autocomplete-model MODEL] [--default-model MODEL] [--enable-port-forward] [--use-sudo]
```

Additional parameters:
- `--enable-port-forward`: Set up port forwarding from port 443 to the LiteLLM port using macOS pfctl
- `--use-sudo`: Run LiteLLM proxy with sudo to allow binding directly to privileged ports

#### Direct Host Method (Anthropic to Qwen):
```bash
./start_anthropic_to_qwen.sh [--port PORT] [--max-tokens MAX_TOKENS]
```

#### Direct Host Method (OpenAI to MLX):
```bash
./start_openai_to_mlx.sh [--port PORT] [--max-tokens MAX_TOKENS]
```

#### Docker Setup:
```bash
./start_docker_proxy.sh [--max-tokens MAX_TOKENS] [--build]
```

### Working with Models

```bash
# Download a model from Hugging Face
./start_dynamic_mlx_proxy.sh --download-model mlx-community/Qwen2.5-Coder-3B-8bit

# Install required dependencies
./start_dynamic_mlx_proxy.sh --install-dependencies
```

### Testing the Proxy

#### Testing Anthropic to Qwen:
```bash
./test_claude_to_qwen.py [--port PORT] [--prompt PROMPT] [--max-tokens MAX_TOKENS]
```

#### Testing OpenAI to MLX:
```bash
python test_openai_to_mlx.py
```

### Docker Management

```bash
# View logs
docker-compose logs -f litellm_proxy

# Stop all services
docker-compose down

# Restart a specific service
docker-compose restart litellm_proxy
```

## Important Configuration Files

- `dynamic_mlx_config.yaml`: Configuration template for the dynamic model server
- `proxy_config.yaml`: Main configuration for Anthropic to MLX conversion
- `openai_to_mlx_config.yaml`: Configuration for OpenAI to MLX conversion
- `docker-compose.yml`: Docker environment configuration

## LiteLLM Integration Details

The proxy uses LiteLLM's custom provider feature to connect to MLX models with the OpenAI API format:

```yaml
model_list:
  - model_name: gpt-*
    litellm_params:
      model: mlx-community/Qwen2.5-Coder-32B-Instruct-8bit
      api_base: http://localhost:11402/v1
      api_key: "placeholder"  # Required even for local servers with no auth
      max_tokens: 8192
      headers: {"MAX_TOKENS": "8192"}
      custom_llm_provider: "openai"
```

This configuration tells LiteLLM to use the OpenAI provider but with a custom API base URL, allowing for seamless integration with any model that implements the OpenAI API format. Note that even though our local MLX server doesn't require authentication, we must provide a placeholder API key for LiteLLM to function correctly.

### Custom Provider Resolution

Here's how the system reconciles different model naming formats:

1. **LiteLLM Configuration**: Uses `custom_llm_provider: "openai"` to tell LiteLLM to treat the endpoint as an OpenAI-compatible API 
2. **Pre-call Hook**: Extracts and normalizes model names to ensure they're in the correct `mlx-community/model-name` format
3. **MLX LM Wrapper**: Strips provider prefixes before passing model names to mlx_lm.server

This allows for flexible model referencing while maintaining compatibility with all the different systems.

## Prerequisites

- Python 3.11+
- LiteLLM package (`pip install litellm`)
- MLX package (`pip install mlx mlx-lm`)
- For Anthropic testing: Anthropic package (`pip install anthropic`)
- For OpenAI testing: OpenAI package (`pip install openai`)
- For Docker setup: Docker and docker-compose installed

## Environment Variables

Key environment variables that can be configured:
- `MAX_TOKENS`: Maximum tokens to generate (default: 8192)
- `DETAILED_DEBUG`: Enable detailed logging (default: True in Docker setup)
- `MLX_WRAPPER_URL`: URL for the MLX wrapper management API
- `MLX_DYNAMIC_PORT`: Port for the dynamic model server
- `MLX_AUTOCOMPLETE_PORT`: Port for the autocomplete model server

## Troubleshooting

- If requests aren't working, check the MLX server logs for errors
- Verify that the pre-call hook is properly loading the requested model
- For Docker issues, check logs with `docker-compose logs -f litellm_proxy`
- Verify the MAX_TOKENS header is being correctly passed in the requests
- Access the Admin UI at http://localhost:4000 for more detailed logs and API management

## Process Management

The system is designed with graceful shutdown handling:

1. The main script (`start_dynamic_mlx_proxy.sh`) manages the lifecycle of all components
2. If the LiteLLM proxy exits, it will automatically terminate the MLX wrapper
3. If the MLX wrapper exits unexpectedly, the pre-call hook will detect this and shut down the LiteLLM proxy
4. Signal trapping ensures proper cleanup of all processes on script termination

This ensures that all components are properly terminated and no orphaned processes are left running.