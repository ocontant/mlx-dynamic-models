# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository Overview

This repository contains a LiteLLM proxy setup that routes API requests between different LLM formats. The main use cases are:

1. Routing Anthropic Claude API requests to a local MLX-powered Qwen model
2. Routing OpenAI API requests to a local MLX-powered Qwen model 

The proxy handles format conversion and configuration automatically, allowing applications written for Claude or OpenAI to use local MLX models without code changes.

## Key Components

- **LiteLLM Proxy**: The core component that handles API request routing and format conversion
- **Docker Setup**: A complete environment including the proxy, admin UI, PostgreSQL, Prometheus, and Grafana
- **Configuration Files**: YAML files that define routing rules and model mappings
- **Startup Scripts**: Shell scripts to launch the proxy with different configurations
- **Test Scripts**: Python scripts to validate the proxy's functionality

## Common Commands

### Starting the Proxy

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

- `proxy_config.yaml`: Main configuration for Anthropic to MLX conversion
- `openai_to_mlx_config.yaml`: Configuration for OpenAI to MLX conversion
- `docker-compose.yml`: Docker environment configuration

## Prerequisites

- Python 3.11+
- LiteLLM package (`pip install litellm`)
- For Anthropic testing: Anthropic package (`pip install anthropic`)
- For OpenAI testing: OpenAI package (`pip install openai`)
- MLX server running at http://localhost:11433 with the Qwen model loaded
- For Docker setup: Docker and docker-compose installed

## Environment Variables

Key environment variables that can be configured:
- `MAX_TOKENS`: Maximum tokens to generate (default: 8192)
- `DETAILED_DEBUG`: Enable detailed logging (default: True in Docker setup)

## Troubleshooting

- If requests aren't working, check that the MLX server is running at http://localhost:11433
- For Docker issues, check logs with `docker-compose logs -f litellm_proxy`
- Verify the MAX_TOKENS header is being correctly passed in the requests
- Access the Admin UI at http://localhost:4000 for more detailed logs and API management