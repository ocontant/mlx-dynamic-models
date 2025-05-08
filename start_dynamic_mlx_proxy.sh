#!/bin/bash

# Default values
PORT=11432
MANAGEMENT_PORT=11400  # Management port
AUTOCOMPLETE_PORT=11401  # Autocomplete port
DYNAMIC_PORT=11402  # Dynamic port
MAX_TOKENS=8192
AUTOCOMPLETE_MODEL="mlx-community/Qwen2.5-Coder-3B-8bit"
DEFAULT_MODEL="mlx-community/Qwen2.5-Coder-32B-Instruct-8bit"
PYTHON_VERSION="3.11.12"
MLX_ENV_NAME="mlx"
REQUIREMENTS_FILE="requirements.txt"
USE_SUDO=false  # Flag to control sudo usage for LiteLLM
ENABLE_PORT_FORWARD=false  # Flag to enable port forwarding from 443 to LiteLLM port

# Trap to handle shutdown and cleanup
trap cleanup SIGINT SIGTERM EXIT

# Create a default requirements file if it doesn't exist
if [ ! -f "$REQUIREMENTS_FILE" ]; then
  cat > $REQUIREMENTS_FILE << EOF
flask>=3.1.0
huggingface-hub>=0.31.1
pydantic>=2.11.4
typing-extensions>=4.13.2
litellm>=1.34.5
anthropic>=0.3.1
openai>=1.77.0
requests>=2.32.3
psutil>=7.0.0
mlx>=0.25.1
mlx-lm>=0.24.0
prometheus-client>=0.21.1
python-dotenv>=1.1.0
EOF
  echo "Created default $REQUIREMENTS_FILE"
fi

# Function to download a model using huggingface-cli
download_model() {
  local model_name="$1"
  echo "Downloading model: $model_name"
  
  # Check if huggingface-cli is installed
  if ! command -v huggingface-cli &> /dev/null; then
    echo "Error: huggingface-cli not found. Please install it first with 'pip install huggingface_hub'."
    return 1
  fi
  
  # Download the model
  huggingface-cli download "$model_name" --local-dir "$HOME/.cache/huggingface/hub"
  
  if [ $? -eq 0 ]; then
    echo "Model $model_name downloaded successfully."
    return 0
  else
    echo "Failed to download model $model_name."
    return 1
  fi
}

# Function to check and install system dependencies
check_system_dependencies() {
  local os_type=$(uname -s)
  local missing_deps=()
  
  echo "Checking system dependencies..."
  
  case "$os_type" in
    Darwin)  # macOS
      # Check for Homebrew
      if ! command -v brew &> /dev/null; then
        missing_deps+=("Homebrew (package manager)")
      fi
      
      # Check for pyenv and pyenv-virtualenv
      if ! command -v pyenv &> /dev/null; then
        missing_deps+=("pyenv")
      fi
      
      if ! pyenv commands 2>/dev/null | grep -q virtualenv; then
        missing_deps+=("pyenv-virtualenv")
      fi
      ;;
      
    Linux)  # Linux
      # Check for common build tools
      if ! command -v make &> /dev/null; then
        missing_deps+=("build-essential")
      fi
      
      # Check for pyenv
      if ! command -v pyenv &> /dev/null; then
        missing_deps+=("pyenv")
      fi
      
      # Check for curl
      if ! command -v curl &> /dev/null; then
        missing_deps+=("curl")
      fi
      ;;
      
    MINGW*|MSYS*|CYGWIN*)  # Windows
      echo "Windows detected. Some features may not work as expected."
      echo "Please make sure you have installed:"
      echo "- Python 3.11+ (from python.org)"
      echo "- Git for Windows"
      echo "- Visual Studio Build Tools"
      return 0
      ;;
      
    *)
      echo "Unsupported operating system: $os_type"
      return 1
      ;;
  esac
  
  # If there are missing dependencies, offer to install them
  if [ ${#missing_deps[@]} -gt 0 ]; then
    echo "The following dependencies are missing:"
    for dep in "${missing_deps[@]}"; do
      echo "- $dep"
    done
    
    read -p "Do you want to install these dependencies? (Y/n): " answer
    answer=${answer:-Y}  # Default to Y if empty
    
    if [[ "$answer" =~ ^[Yy] ]]; then
      case "$os_type" in
        Darwin)  # macOS
          # Install Homebrew if missing
          if ! command -v brew &> /dev/null; then
            echo "Installing Homebrew..."
            /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
          fi
          
          # Install pyenv and pyenv-virtualenv
          if ! command -v pyenv &> /dev/null; then
            echo "Installing pyenv..."
            brew install pyenv
          fi
          
          if ! pyenv commands 2>/dev/null | grep -q virtualenv; then
            echo "Installing pyenv-virtualenv..."
            brew install pyenv-virtualenv
          fi
          
          # Add pyenv to shell
          echo "Adding pyenv to your shell configuration..."
          echo 'eval "$(pyenv init --path)"' >> ~/.zprofile
          echo 'eval "$(pyenv init -)"' >> ~/.zshrc
          echo 'eval "$(pyenv virtualenv-init -)"' >> ~/.zshrc
          ;;
          
        Linux)
          # Install dependencies based on distribution
          if command -v apt-get &> /dev/null; then
            echo "Installing dependencies using apt..."
            sudo apt-get update
            sudo apt-get install -y make build-essential libssl-dev zlib1g-dev libbz2-dev \
              libreadline-dev libsqlite3-dev wget curl llvm libncurses5-dev libncursesw5-dev \
              xz-utils tk-dev libffi-dev liblzma-dev python-openssl git
            
            # Install pyenv
            if ! command -v pyenv &> /dev/null; then
              curl https://pyenv.run | bash
              echo 'export PYENV_ROOT="$HOME/.pyenv"' >> ~/.bashrc
              echo 'export PATH="$PYENV_ROOT/bin:$PATH"' >> ~/.bashrc
              echo 'eval "$(pyenv init --path)"' >> ~/.bashrc
              echo 'eval "$(pyenv init -)"' >> ~/.bashrc
              echo 'eval "$(pyenv virtualenv-init -)"' >> ~/.bashrc
            fi
          elif command -v yum &> /dev/null; then
            echo "Installing dependencies using yum..."
            sudo yum install -y gcc make patch zlib-devel bzip2 bzip2-devel readline-devel \
              sqlite sqlite-devel openssl-devel tk-devel libffi-devel xz-devel git curl
            
            # Install pyenv
            if ! command -v pyenv &> /dev/null; then
              curl https://pyenv.run | bash
              echo 'export PYENV_ROOT="$HOME/.pyenv"' >> ~/.bashrc
              echo 'export PATH="$PYENV_ROOT/bin:$PATH"' >> ~/.bashrc
              echo 'eval "$(pyenv init --path)"' >> ~/.bashrc
              echo 'eval "$(pyenv init -)"' >> ~/.bashrc
              echo 'eval "$(pyenv virtualenv-init -)"' >> ~/.bashrc
            fi
          else
            echo "Unsupported Linux distribution. Please install dependencies manually."
            return 1
          fi
          ;;
      esac
      
      echo "Dependencies installed. You may need to restart your shell or terminal."
      echo "After restarting, run this script again with the --install-dependencies flag."
      return 2  # Signal to exit and restart
    else
      echo "Skipping dependency installation. Some features may not work."
      return 1
    fi
  fi
  
  echo "All system dependencies are satisfied."
  return 0
}

# Function to install Python environment and dependencies
install_dependencies() {
  # First check system dependencies
  check_system_dependencies
  local sys_deps_result=$?
  
  if [ $sys_deps_result -eq 2 ]; then
    echo "Please restart your shell and run this script again."
    exit 0
  elif [ $sys_deps_result -eq 1 ]; then
    echo "WARNING: Missing system dependencies. Continuing but some features may not work."
  fi
  
  # Ensure pyenv is in PATH
  if command -v pyenv &> /dev/null; then
    eval "$(pyenv init -)"
    if pyenv commands 2>/dev/null | grep -q virtualenv; then
      eval "$(pyenv virtualenv-init -)"
    fi
  else
    echo "Error: pyenv not found in PATH. Please install pyenv and try again."
    exit 1
  fi
  
  # Install Python version if not installed
  if ! pyenv versions | grep -q $PYTHON_VERSION; then
    echo "Installing Python $PYTHON_VERSION..."
    pyenv install $PYTHON_VERSION
    if [ $? -ne 0 ]; then
      echo "Failed to install Python $PYTHON_VERSION. Please check for errors."
      exit 1
    fi
  fi
  
  # Create or update virtualenv
  if ! pyenv virtualenvs 2>/dev/null | grep -q $MLX_ENV_NAME; then
    echo "Creating virtualenv $MLX_ENV_NAME with Python $PYTHON_VERSION..."
    pyenv virtualenv $PYTHON_VERSION $MLX_ENV_NAME
  else
    echo "Virtualenv $MLX_ENV_NAME already exists."
  fi
  
  # Activate the virtualenv and install dependencies
  echo "Activating virtualenv and installing dependencies..."
  eval "$(pyenv init -)"
  if pyenv commands 2>/dev/null | grep -q virtualenv; then
    eval "$(pyenv virtualenv-init -)"
  fi
  pyenv activate $MLX_ENV_NAME
  
  # Install requirements
  echo "Installing Python dependencies from $REQUIREMENTS_FILE..."
  pip install --upgrade pip
  pip install -r $REQUIREMENTS_FILE
  
  echo "All dependencies installed successfully."
  echo "To activate this environment manually, run: pyenv activate $MLX_ENV_NAME"
  
  # Give instructions for next steps
  echo ""
  echo "Next steps:"
  echo "1. Download a model with: $0 --download-model mlx-community/Qwen2.5-Coder-3B-8bit"
  echo "2. Start the proxy server with: $0"
  echo ""
  
  return 0
}

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
    --download-model)
      MODEL_TO_DOWNLOAD="$2"
      download_model "$MODEL_TO_DOWNLOAD"
      exit $?
      ;;
    --install-dependencies)
      install_dependencies
      exit $?
      ;;
    --use-sudo)
      USE_SUDO=true
      shift # past argument
      ;;
    --enable-port-forward)
      ENABLE_PORT_FORWARD=true
      shift # past argument
      ;;
    --help)
      echo "Usage: $0 [options]"
      echo ""
      echo "Options:"
      echo "  --port PORT                    Set the LiteLLM proxy port (default: 11432)"
      echo "  --management-port PORT         Set the management API port (default: 11400)"
      echo "  --dynamic-port PORT            Set the dynamic model port (default: 11402)"
      echo "  --autocomplete-port PORT       Set the autocomplete model port (default: 11401)"
      echo "  --max-tokens TOKENS            Set the maximum tokens for generation (default: 8192)"
      echo "  --autocomplete-model MODEL     Set the autocomplete model (default: mlx-community/Qwen2.5-Coder-3B-8bit)"
      echo "  --default-model MODEL          Set the default model (default: mlx-community/Qwen2.5-Coder-32B-Instruct-8bit)"
      echo "  --download-model MODEL         Download a model from Hugging Face"
      echo "  --install-dependencies         Install pyenv, Python and all required dependencies"
      echo "  --use-sudo                     Run LiteLLM proxy with sudo to bind to privileged ports"
      echo "  --enable-port-forward          Enable port forwarding from port 443 to LiteLLM port"
      echo "  --help                         Show this help message"
      exit 0
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

# Generate dynamic config file with proper variable substitution
TMP_CONFIG=$(mktemp)

cat > $TMP_CONFIG << EOF
model_list:
  # Route any OpenAI model to MLX using OpenAI-compatible endpoints
  - model_name: gpt-*
    litellm_params:
      model: mlx-community/Qwen2.5-Coder-32B-Instruct-8bit
      api_base: http://localhost:${DYNAMIC_PORT}/v1
      api_key: "not-needed"  # Local MLX server doesn't need auth, but LiteLLM requires this
      max_tokens: ${MAX_TOKENS}
      headers: {"MAX_TOKENS": "${MAX_TOKENS}"}
      custom_llm_provider: "openai"  # Use standard OpenAI provider with custom API base
  
  # Route Anthropic models to MLX with format conversion
  - model_name: claude-*
    litellm_params:
      model: mlx-community/Qwen2.5-Coder-32B-Instruct-8bit
      api_base: http://localhost:${DYNAMIC_PORT}/v1
      api_key: "not-needed"  # Local MLX server doesn't need auth, but LiteLLM requires this
      max_tokens: ${MAX_TOKENS}
      headers: {"MAX_TOKENS": "${MAX_TOKENS}"}
      custom_llm_provider: "openai"
      original_api_provider: "anthropic"
      convert_to_openai: true
  
  # Route Google models to MLX with format conversion
  - model_name: gemini-*
    litellm_params:
      model: mlx-community/Qwen2.5-Coder-32B-Instruct-8bit
      api_base: http://localhost:${DYNAMIC_PORT}/v1
      api_key: "not-needed"  # Local MLX server doesn't need auth, but LiteLLM requires this
      max_tokens: ${MAX_TOKENS}
      headers: {"MAX_TOKENS": "${MAX_TOKENS}"}
      custom_llm_provider: "openai"
      original_api_provider: "google"
      convert_to_openai: true
  
  # Route xAI models to MLX with format conversion
  - model_name: grok-*
    litellm_params:
      model: mlx-community/Qwen2.5-Coder-32B-Instruct-8bit
      api_base: http://localhost:${DYNAMIC_PORT}/v1
      api_key: "not-needed"  # Local MLX server doesn't need auth, but LiteLLM requires this
      max_tokens: ${MAX_TOKENS}
      headers: {"MAX_TOKENS": "${MAX_TOKENS}"}
      custom_llm_provider: "openai"
      original_api_provider: "xai"
      convert_to_openai: true

  # Direct MLX community references using fallback to ensure proper model handling
  - model_name: mlx-community/*
    litellm_params:
      # The model will be extracted from the request by our pre-call hook
      # This is just a fallback value that won't typically be used
      model: "mlx-community/Qwen2.5-Coder-32B-Instruct-8bit"
      api_base: http://localhost:${DYNAMIC_PORT}/v1
      api_key: "not-needed"  # Local MLX server doesn't need auth, but LiteLLM requires this
      max_tokens: ${MAX_TOKENS}
      headers: {"MAX_TOKENS": "${MAX_TOKENS}"}
      custom_llm_provider: "openai"
  
  # Map autocomplete requests to the dedicated autocomplete model server
  - model_name: gpt-autocomplete
    litellm_params:
      model: ${AUTOCOMPLETE_MODEL}
      api_base: http://localhost:${AUTOCOMPLETE_PORT}/v1
      api_key: "not-needed"  # Local MLX server doesn't need auth, but LiteLLM requires this
      max_tokens: 64
      headers: {"MAX_TOKENS": "64"}
      custom_llm_provider: "openai"

router_settings:
  # Use our pre-call hook to ensure the requested model is loaded
  pre_call_hooks: ["mlx_precall_hook.mlx_pre_call_hook"]
  # Use our post-call hook to fix serialization issues
  post_call_hooks: ["mlx_serialization_fix.mlx_post_call_hook"]
  
  # Enable format translations between different APIs
  # These settings allow LiteLLM to recognize requests from different API formats
  api_aliases:
    # Map Anthropic API endpoints to OpenAI format
    /v1/messages: /v1/chat/completions
    # Map Google/Gemini API endpoints
    /v1/generateContent: /v1/chat/completions
    # Map other endpoints as needed
    /v1/generate: /v1/chat/completions
  
server_settings:
  # Allow any model name format to be processed
  allowed_model_names: ["*"]
  
  # Enable proxy to handle any requests
  openai_api_base: /v1
  
  # Allow all API formats to be processed
  allowed_routes: 
    - "/v1/chat/completions"
    - "/v1/completions"
    - "/v1/models"
    - "/v1/messages"           # Anthropic format
    - "/v1/generateContent"    # Google/Gemini format
    - "/v1/generate"           # Generic generation endpoint
    
  # Proxy settings for port bindings
  host: "127.0.0.1"
  port: ${PORT}
  additional_ports: [80, 443]  # Bind to standard HTTP/HTTPS ports for hostname redirection
    
  # Default environment variables
  environment_variables:
    # Always pass max_tokens in the header
    headers: {"MAX_TOKENS": "${MAX_TOKENS}"}
    # Configuration for the MLX wrapper
    MLX_WRAPPER_URL: "http://127.0.0.1:${MANAGEMENT_PORT}"
    MLX_DYNAMIC_PORT: "${DYNAMIC_PORT}"
    MLX_AUTOCOMPLETE_PORT: "${AUTOCOMPLETE_PORT}"
    MLX_MAX_WAIT_TIME: "300"
  
  # Custom endpoint for completions (autocomplete)
  completion_to_chat_map: true
  
  # Format translation settings
  api_format_conversion: true
EOF

# Set environment variables for the MLX wrapper
export MLX_WRAPPER_URL="http://127.0.0.1:$MANAGEMENT_PORT"
export MLX_DYNAMIC_PORT="$DYNAMIC_PORT"
export MLX_AUTOCOMPLETE_PORT="$AUTOCOMPLETE_PORT"
export MLX_MAX_WAIT_TIME="300"

# Start the MLX_LM wrapper in the background
echo "Starting MLX_LM wrapper with:"
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
echo "Waiting for MLX_LM wrapper to start..."
sleep 5

# Check if wrapper is still running
if ! kill -0 $WRAPPER_PID 2>/dev/null; then
  echo "MLX_LM wrapper failed to start. Check the logs for errors."
  exit 1
fi

# Start loading the default model
echo "Pre-loading default model: $DEFAULT_MODEL..."
curl -X POST "http://127.0.0.1:$MANAGEMENT_PORT/load_model" \
  -H "Content-Type: application/json" \
  -d "{\"model\": \"$DEFAULT_MODEL\"}"

# Function to set up port forwarding
setup_port_forwarding() {
  echo "Setting up port forwarding from port 443 to $PORT..."
  
  # Check if sudo is available and we have permissions
  if ! command -v sudo &> /dev/null; then
    echo "Error: sudo is required for port forwarding but is not available."
    return 1
  fi
  
  # Create a temporary pfctl rules file
  local PF_RULES_FILE=$(mktemp)
  echo "rdr pass on lo0 inet proto tcp from any to any port 443 -> 127.0.0.1 port $PORT" > $PF_RULES_FILE
  
  # Enable pfctl if not already enabled
  sudo pfctl -e 2>/dev/null || true
  
  # Load the rules
  sudo pfctl -f $PF_RULES_FILE
  
  # Check if port forwarding was set up successfully
  if sudo pfctl -s nat | grep -q "port 443 -> 127.0.0.1 port $PORT"; then
    echo "Port forwarding successfully set up: 443 -> $PORT"
    rm $PF_RULES_FILE
    return 0
  else
    echo "Failed to set up port forwarding."
    rm $PF_RULES_FILE
    return 1
  fi
}

# Set up port forwarding if requested
if [[ "$ENABLE_PORT_FORWARD" == true ]]; then
  setup_port_forwarding
  if [ $? -ne 0 ]; then
    echo "WARNING: Failed to set up port forwarding. Continuing without it."
  fi
fi

# Start the LiteLLM proxy server
echo "Starting LiteLLM proxy server on port $PORT"
if [[ "$ENABLE_PORT_FORWARD" == true && $? -eq 0 ]]; then
  echo "With port forwarding from 443 -> $PORT"
fi
echo "This proxy routes OpenAI API calls to MLX_LM server based on the requested model"
echo "All requests are processed through the pre-call hook to ensure models are loaded"
echo "MAX_TOKENS is set to $MAX_TOKENS"

# We don't need to reinstall dependencies every time
# Just make sure the PYTHONPATH includes current directory

# Start with verbose logging to see the requests and responses
if [[ "$USE_SUDO" == true ]]; then
  echo "Running LiteLLM with sudo to bind to privileged ports..."
  sudo PYTHONPATH="$PWD:$PYTHONPATH" litellm --config $TMP_CONFIG --port $PORT --detailed_debug
else
  PYTHONPATH="$PWD:$PYTHONPATH" litellm --config $TMP_CONFIG --port $PORT --detailed_debug
fi

# Define cleanup function to handle graceful shutdown
cleanup() {
  echo "Shutting down all processes..."
  
  # Kill the wrapper process if it exists
  if [ -n "$WRAPPER_PID" ] && kill -0 $WRAPPER_PID 2>/dev/null; then
    echo "Stopping MLX_LM wrapper (PID: $WRAPPER_PID)..."
    kill -TERM $WRAPPER_PID
    # Wait for it to terminate
    wait $WRAPPER_PID 2>/dev/null || true
  fi
  
  # Kill any remaining mlx_lm.server processes
  echo "Checking for any remaining mlx_lm.server processes..."
  pkill -f "mlx_lm.server" || true
  
  # Clean up the temporary file
  if [ -f "$TMP_CONFIG" ]; then
    echo "Removing temporary config file..."
    rm $TMP_CONFIG
  fi
  
  # Remove port forwarding rules if they were set up
  if [[ "$ENABLE_PORT_FORWARD" == true ]]; then
    echo "Removing port forwarding rules..."
    # Create a temporary empty rules file
    local PF_RULES_FILE=$(mktemp)
    echo "" > $PF_RULES_FILE
    # Apply the empty rules file to clear forwarding
    sudo pfctl -f $PF_RULES_FILE 2>/dev/null || true
    rm $PF_RULES_FILE
  fi
  
  echo "Shutdown complete."
  exit 0
}

# Clean exit (will trigger the cleanup trap)
echo "LiteLLM proxy has stopped. Cleaning up..."