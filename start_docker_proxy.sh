#!/bin/bash

# Check if .env file exists, otherwise create from template
if [ ! -f .env ]; then
    echo "Creating .env file from .env.example"
    cp .env.example .env
    echo "Please update the .env file with your specific settings if needed."
    echo "Press Enter to continue or Ctrl+C to abort and update the .env file first..."
    read
fi

# Set default MAX_TOKENS
MAX_TOKENS=8192

# Parse command line arguments
while [[ $# -gt 0 ]]; do
  case $1 in
    --max-tokens)
      MAX_TOKENS="$2"
      shift # past argument
      shift # past value
      ;;
    --build)
      BUILD="--build"
      shift # past argument
      ;;
    *)
      shift # past argument
      ;;
  esac
done

# Update MAX_TOKENS in the environment
export MAX_TOKENS

echo "Starting LiteLLM proxy Docker environment with MAX_TOKENS=$MAX_TOKENS"
echo "This will start:"
echo "  - LiteLLM Proxy on port 8000 (Anthropic to MLX converter)"
echo "  - LiteLLM Admin UI on port 4000"
echo "  - PostgreSQL on port 5432"
echo "  - Prometheus on port 9090"
echo "  - Grafana on port 3000"
echo ""
echo "Make sure your MLX server is running at http://localhost:11433"

# Start the docker-compose environment
docker-compose up -d $BUILD

echo ""
echo "Docker services started!"
echo ""
echo "Access points:"
echo "  - LiteLLM Proxy: http://localhost:8000"
echo "  - LiteLLM Admin UI: http://localhost:4000"
echo "  - Grafana: http://localhost:3000 (admin/admin)"
echo "  - Prometheus: http://localhost:9090"
echo ""
echo "To test the Anthropic to MLX conversion, use the test_claude_to_qwen.py script:"
echo "  ./test_claude_to_qwen.py"
echo ""
echo "To view logs:"
echo "  docker-compose logs -f litellm_proxy"
echo ""
echo "To stop all services:"
echo "  docker-compose down"