# Anthropic to MLX Qwen Proxy

This setup uses LiteLLM to create a proxy that takes requests in Anthropic Claude format and routes them to a local MLX-powered Qwen model.

## Overview

- Accepts requests using the Anthropic API format
- Routes all `claude-*` model requests to `mlx-community/Qwen2.5-Coder-32B-Instruct-8bit`
- Automatically injects `MAX_TOKENS` header to override the mlx-lm.server default of 100 tokens
- Communicates with the MLX server at http://localhost:11433

## Setup Options

You can run the proxy either directly on your host or using Docker.

### Prerequisites

- The MLX server should be running at http://localhost:11433 with the Qwen model loaded

### Direct Host Setup

1. Ensure you have Python 3.11+ installed and the LiteLLM package:
   ```
   pip install litellm anthropic
   ```

2. Start the proxy using the provided script:
   ```bash
   ./start_anthropic_to_qwen.sh [--port PORT] [--max-tokens MAX_TOKENS]
   ```

### Docker Setup

A complete Docker environment is provided that includes:
- LiteLLM proxy (Anthropic to MLX converter)
- LiteLLM Admin UI
- PostgreSQL database
- Prometheus for metrics
- Grafana for dashboards

To start:

1. Make sure Docker and docker-compose are installed

2. Run the startup script:
   ```bash
   ./start_docker_proxy.sh [--max-tokens MAX_TOKENS] [--build]
   ```
   
   The `--build` flag will force rebuilding of the images.

3. Access the services:
   - LiteLLM Proxy: http://localhost:8000
   - LiteLLM Admin UI: http://localhost:4000
   - Grafana Dashboard: http://localhost:3000 (login: admin/admin)
   - Prometheus: http://localhost:9090

## Usage

### Starting the Proxy (Direct Host Method)

Run the proxy server:

```bash
./start_anthropic_to_qwen.sh [--port PORT] [--max-tokens MAX_TOKENS]
```

Options:
- `--port`: Port to run the proxy on (default: 8000)
- `--max-tokens`: Maximum number of tokens to generate (default: 8192)

Example:
```bash
# Run on port 8080 with max_tokens=4096
./start_anthropic_to_qwen.sh --port 8080 --max-tokens 4096
```

### Testing the Proxy

A test script is included to verify the setup:

```bash
./test_claude_to_qwen.py [--port PORT] [--prompt PROMPT] [--max-tokens MAX_TOKENS]
```

Example:
```bash
# Send a custom prompt and limit output to 1000 tokens
./test_claude_to_qwen.py --prompt "Write a short story about a robot learning to paint" --max-tokens 1000
```

### Using with Anthropic Client

```python
from anthropic import Anthropic

# Point to the proxy server
client = Anthropic(
    api_key="dummy-key",  # Key doesn't matter
    base_url="http://localhost:8000/v1"  # Proxy URL
)

# Use as if you're using Claude
message = client.messages.create(
    model="claude-3-opus-20240229",  # Will be routed to Qwen
    max_tokens=2048,
    messages=[{"role": "user", "content": "Your prompt here"}]
)

print(message.content[0].text)
```

## Configuration

### Main Configuration

The configuration is stored in `proxy_config.yaml`. Key settings:

- Maps all Claude models (`claude-*`) to the local Qwen model
- Sets headers to override default max_tokens
- Configures the provider map to convert Anthropic format to OpenAI format

### Docker Environment Variables

For the Docker setup, you can configure the services by editing the `.env` file (copied from `.env.example` on first run).

## Monitoring and Management

When using the Docker setup, you can:

1. Monitor proxy performance in Grafana at http://localhost:3000
2. Manage API keys and view logs in the Admin UI at http://localhost:4000
3. See detailed metrics in Prometheus at http://localhost:9090

## Troubleshooting

- If requests aren't working, check that the MLX server is running at http://localhost:11433
- Use the `--detailed_debug` flag (already set in the start script) to see detailed logs
- Verify the MAX_TOKENS header is being correctly passed in the requests
- For Docker issues, check the logs with `docker-compose logs -f litellm_proxy`

## Docker Commands

- View logs: `docker-compose logs -f [service_name]`
- Stop all services: `docker-compose down`
- Restart a service: `docker-compose restart [service_name]`