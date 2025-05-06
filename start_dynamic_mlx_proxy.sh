#!/bin/bash

# Default values
PORT=8000
MANAGEMENT_PORT=11435
DYNAMIC_PORT=11433
AUTOCOMPLETE_PORT=11434
MAX_TOKENS=8192
AUTOCOMPLETE_MODEL="mlx-community/Qwen1.5-1.8B-Chat-8bit"
DEFAULT_MODEL="mlx-community/Qwen2.5-Coder-32B-Instruct-8bit"

# Parse command line arguments
while [[ $# -gt 0 ]]; do
  case $1 in
    --port)
      PORT="$2"
      shift # past argument
      shift # past value
      ;;
    --management-port)
      MANAGEMENT_PORT="$2"
      shift # past argument
      shift # past value
      ;;
    --dynamic-port)
      DYNAMIC_PORT="$2"
      shift # past argument
      shift # past value
      ;;
    --autocomplete-port)
      AUTOCOMPLETE_PORT="$2"
      shift # past argument
      shift # past value
      ;;
    --max-tokens)
      MAX_TOKENS="$2"
      shift # past argument
      shift # past value
      ;;
    --autocomplete-model)
      AUTOCOMPLETE_MODEL="$2"
      shift # past argument
      shift # past value
      ;;
    --default-model)
      DEFAULT_MODEL="$2"
      shift # past argument
      shift # past value
      ;;
    *)
      # For backward compatibility
      if [[ "$1" =~ ^[0-9]+$ ]]; then
        PORT="$1"
      fi
      shift # past argument
      ;;
  esac
done

# Create a temporary config file with the specified MAX_TOKENS
TMP_CONFIG=$(mktemp)
cat dynamic_mlx_config.yaml | sed "s/\"MAX_TOKENS\": \"[0-9]*\"/\"MAX_TOKENS\": \"$MAX_TOKENS\"/g" > $TMP_CONFIG

# Set environment variables for the MLX wrapper
export MLX_WRAPPER_URL="http://127.0.0.1:$MANAGEMENT_PORT"
export MLX_DYNAMIC_PORT="$DYNAMIC_PORT"
export MLX_AUTOCOMPLETE_PORT="$AUTOCOMPLETE_PORT"
export MLX_MAX_WAIT_TIME="300"

# Start the MLX-LM wrapper in the background
echo "Starting MLX-LM wrapper with:"
echo "  - Autocomplete model: $AUTOCOMPLETE_MODEL on port $AUTOCOMPLETE_PORT"
echo "  - Dynamic model port: $DYNAMIC_PORT"
echo "  - Management API on port $MANAGEMENT_PORT"

python mlx_lm_wrapper.py \
  --autocomplete-model "$AUTOCOMPLETE_MODEL" \
  --autocomplete-port "$AUTOCOMPLETE_PORT" \
  --dynamic-port "$DYNAMIC_PORT" \
  --management-port "$MANAGEMENT_PORT" &

# Store the PID of the wrapper
WRAPPER_PID=$!

# Wait for the wrapper to start
echo "Waiting for MLX-LM wrapper to start..."
sleep 5

# Check if wrapper is still running
if ! kill -0 $WRAPPER_PID 2>/dev/null; then
  echo "MLX-LM wrapper failed to start. Check the logs for errors."
  exit 1
fi

# Start loading the default model
echo "Pre-loading default model: $DEFAULT_MODEL..."
curl -X POST "http://127.0.0.1:$MANAGEMENT_PORT/load_model" \
  -H "Content-Type: application/json" \
  -d "{\"model\": \"$DEFAULT_MODEL\"}"

# Start the LiteLLM proxy server
echo "Starting LiteLLM proxy server on port $PORT"
echo "This proxy routes OpenAI API calls to MLX-LM server based on the requested model"
echo "All requests are processed through the pre-call hook to ensure models are loaded"
echo "MAX_TOKENS is set to $MAX_TOKENS"

# Start with verbose logging to see the requests and responses
PYTHONPATH="$PWD:$PYTHONPATH" litellm --config $TMP_CONFIG --port $PORT --detailed_debug

# When litellm exits, kill the wrapper
kill $WRAPPER_PID

# Clean up the temporary file
rm $TMP_CONFIG