#!/bin/bash

# Cache sudo credentials at the beginning to avoid password prompts getting mixed with output
if [[ "$EUID" -ne 0 ]]; then
    echo "Caching sudo credentials for later use..."
    sudo -v
fi
# Default values
PORT=11432
HTTPS_PORT=11433  # HTTPS port for secure connections
MANAGEMENT_PORT=11400  # Management port
AUTOCOMPLETE_PORT=11401  # Autocomplete port
DYNAMIC_PORT=11402  # Dynamic port
MAX_TOKENS=8192
AUTOCOMPLETE_MODEL="mlx-community/Qwen2.5-Coder-3B-8bit"
DEFAULT_MODEL="mlx-community/Qwen2.5-Coder-32B-Instruct-8bit"
SSL_DOMAIN="localhost"  # Default domain for SSL certificate

# Boolean flags (string representation)
USE_SUDO=false
ENABLE_PORT_FORWARD=false
ENABLE_HTTPS=false

# Numeric boolean flags (0=false, 1=true)
USE_SUDO_BOOL=0
ENABLE_PORT_FORWARD_BOOL=0
ENABLE_HTTPS_BOOL=0

# Dependencies
PYTHON_VERSION="3.11.12"
MLX_ENV_NAME="mlx"
REQUIREMENTS_FILE="requirements.txt"

# Define cleanup function to handle graceful shutdown
function cleanup() {
  line_up
  echo "Shutting down all processes..."
  
  # Kill any LiteLLM instances
  if [ ${#LITELLM_PIDS[@]} -gt 0 ]; then
    echo "Stopping LiteLLM instances..."
    for pid in "${LITELLM_PIDS[@]}"; do
      if kill -0 $pid 2>/dev/null; then
        echo "  - Stopping LiteLLM instance (PID: $pid)..."
        kill -TERM $pid 2>/dev/null
        wait $pid 2>/dev/null || true
      fi
    done
  fi
  
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
  
  # Clean up the temporary config file
  if [ -f "$TMP_CONFIG" ]; then
    echo "Removing temporary config file..."
    rm $TMP_CONFIG
  fi
  
  # Remove port forwarding rules if they were set up
  if (( ENABLE_PORT_FORWARD_BOOL )); then
    echo "Removing port forwarding rules..."
    
    # Check if we stored an anchor name
    if [[ -n "$PF_ANCHOR_USED" ]]; then
      echo "Removing rules from anchor $PF_ANCHOR_USED..."
      sudo /sbin/pfctl -a "$PF_ANCHOR_USED" -F all 2>/dev/null || true
    else
      # Try default anchor name
      echo "Removing rules from default anchor..."
      sudo /sbin/pfctl -a "com.litellm.portforward" -F all 2>/dev/null || true
      
      # Also try clearing directly (backup method)
      echo "Clearing direct rules (if any)..."
      local PF_RULES_FILE=$(mktemp)
      echo "" > $PF_RULES_FILE
      sudo /sbin/pfctl -f $PF_RULES_FILE 2>/dev/null || true
      rm $PF_RULES_FILE
    fi
    
    echo "Port forwarding rules have been removed."
    
    # Print verification
    if (( ENABLE_HTTPS_BOOL )); then
      echo "Verifying port forwarding removal..."
      sudo /sbin/pfctl -s nat | grep -E "port (80|443)" || echo "✅ No HTTP/HTTPS port forwarding rules found"
    else
      echo "Verifying port forwarding removal..."
      sudo /sbin/pfctl -s nat | grep "port 80" || echo "✅ No HTTP port forwarding rules found"
    fi
  fi
  
  echo "Shutdown complete."
  line_down
  exit 0
}

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

# Decorator 
function line_up () {
  echo "-----------------------------------------------------------"
  echo ""
}
function line_down () {
  echo ""
  echo "-----------------------------------------------------------"
}
function line_error_up () {
  echo "+++++++"
  echo ""
}
function line_error_down () {
  echo ""
  echo "+++++++"
}

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
    --https-port)
      HTTPS_PORT="$2"
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
      USE_SUDO_BOOL=1
      shift # past argument
      ;;
    --enable-port-forward) 
      ENABLE_PORT_FORWARD=true
      ENABLE_PORT_FORWARD_BOOL=1
      shift # past argument
      ;;
    --enable-https)
      ENABLE_HTTPS=true
      ENABLE_HTTPS_BOOL=1
      shift # past argument
      ;;
    --ssl-domain)
      SSL_DOMAIN="$2"
      shift # past argument
      shift # past value
      ;;
    --help)
      echo "Usage: $0 [options]"
      echo ""
      echo "Options:"
      echo "  --port PORT                    Set the LiteLLM proxy HTTP port (default: 11432)"
      echo "  --https-port PORT              Set the LiteLLM proxy HTTPS port (default: 11433)"
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
      echo "  --enable-https                 Enable HTTPS support with self-signed certificates"
      echo "  --ssl-domain DOMAIN            Domain name for SSL certificate (default: localhost)"
      echo "                                 Example: --ssl-domain api.anthropic.com"
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

# Check for mutual exclusivity between USE_SUDO and ENABLE_PORT_FORWARD
if (( USE_SUDO_BOOL && ENABLE_PORT_FORWARD_BOOL )); then
  line_error_up
  echo "ERROR: --use-sudo and --enable-port-forward cannot be used together."
  echo "       Use either --use-sudo to bind directly to privileged ports,"
  echo "       or --enable-port-forward to set up port forwarding from privileged ports."
  line_error_down
  exit 1
fi

# Generate dynamic config file with proper variable substitution
TMP_CONFIG=$(mktemp)

# Set appropriate ports based on whether we're using sudo
if (( USE_SUDO_BOOL )); then
  # If using sudo, bind directly to privileged ports
  HTTP_BIND_PORT=80
  HTTPS_BIND_PORT=443
  ADDITIONAL_PORTS="[]  # Not using additional_ports as we're binding directly"
  echo "Using sudo to bind directly to privileged ports: HTTP=80, HTTPS=443"
else
  # Otherwise, use the regular high ports
  HTTP_BIND_PORT=$PORT
  HTTPS_BIND_PORT=$HTTPS_PORT
  ADDITIONAL_PORTS="[]  # Not binding to privileged ports"
fi

# Setup SSL certificate directories
SSL_DIR="$(pwd)/ssl"
SSL_CERT="${SSL_DIR}/cert.pem"
SSL_KEY="${SSL_DIR}/key.pem"

# Create SSL certificates if HTTPS is enabled
if [[ "$ENABLE_HTTPS" == true ]]; then
  # Create SSL directory if it doesn't exist
  if [ ! -d "$SSL_DIR" ]; then
    mkdir -p "$SSL_DIR"
  fi
  
  # Define subject alternative names based on domain
  if [[ "$SSL_DOMAIN" == "localhost" ]]; then
    SAN_EXTENSIONS="subjectAltName=DNS:localhost,IP:127.0.0.1"
  else
    # For custom domains, include both the domain and localhost
    SAN_EXTENSIONS="subjectAltName=DNS:$SSL_DOMAIN,DNS:localhost,IP:127.0.0.1"
  fi
  
  # Create a certificate name that includes the domain to avoid conflicts
  CERT_SUFFIX=$(echo "$SSL_DOMAIN" | tr -d '.' | tr -d ':')
  SSL_CERT="${SSL_DIR}/cert_${CERT_SUFFIX}.pem"
  SSL_KEY="${SSL_DIR}/key_${CERT_SUFFIX}.pem"
  
  # Check if certificates already exist
  if [ ! -f "$SSL_CERT" ] || [ ! -f "$SSL_KEY" ]; then
    echo "Generating self-signed SSL certificates for domain: $SSL_DOMAIN..."
    
    # Generate a self-signed certificate valid for 365 days
    openssl req -x509 -newkey rsa:4096 -keyout "$SSL_KEY" -out "$SSL_CERT" -days 365 -nodes \
      -subj "/CN=$SSL_DOMAIN" -addext "$SAN_EXTENSIONS"
    
    if [ $? -ne 0 ]; then
      line_up
      echo "Failed to generate SSL certificates. Make sure openssl is installed."
      echo "Continuing without HTTPS support."
      line_down
      ENABLE_HTTPS=false
    else
      line_up
      echo "SSL certificates generated successfully at ${SSL_DIR}"
      echo "Certificate is valid for: $SSL_DOMAIN"
      line_down
    fi
  else
    line_up
    echo "Using existing SSL certificates from ${SSL_DIR}"
    echo "Certificate is configured for: $SSL_DOMAIN"
    line_down
  fi
fi

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
  additional_ports: ${ADDITIONAL_PORTS}
    
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
line_down
sleep 5


# Check if wrapper is still running
if ! kill -0 $WRAPPER_PID 2>/dev/null; then
  line_up
  echo "MLX_LM wrapper failed to start. Check the logs for errors."
  line_down
  exit 1
fi

# Start loading the default model
echo ""
echo "Pre-loading default model: $DEFAULT_MODEL..."
curl -X POST "http://127.0.0.1:$MANAGEMENT_PORT/load_model" \
  -H "Content-Type: application/json" \
  -d "{\"model\": \"$DEFAULT_MODEL\"}"

# Function to set up port forwarding for HTTP and HTTPS
setup_port_forwarding() {
  line_up
  echo "Setting up port forwarding:"
  
  # We'll use only localhost interface (lo0) for port forwarding
  echo "Setting up localhost-only port forwarding (no external network exposure)"
  
  # Display info about forwarding configuration
  if (( ENABLE_HTTPS_BOOL )); then
    echo "• HTTP:  127.0.0.1:80  → 127.0.0.1:$PORT     (localhost only)"
    echo "• HTTPS: 127.0.0.1:443 → 127.0.0.1:$HTTPS_PORT (localhost only)"
  else
    echo "• HTTP:  127.0.0.1:80 → 127.0.0.1:$PORT     (localhost only)"
  fi
  
  # Check if sudo is available
  if ! command -v sudo &> /dev/null; then
    line_error_up
    echo "Error: sudo is required for port forwarding but is not available."
    line_error_down
    return 1
  fi
  
  # Check if /sbin/pfctl is available (macOS specific)
  if ! command -v /sbin/pfctl &> /dev/null; then
    line_error_up
    echo "Error: /sbin/pfctl is required for port forwarding but is not available."
    echo "This feature is macOS specific."
    line_error_down
    return 1
  fi
  
  # Create a temporary pf configuration file
  local PF_RULES_FILE=$(mktemp)
  local ANCHOR_NAME="com.litellm.portforward"
  
  # Create a simplified localhost-only ruleset for macOS
  cat > $PF_RULES_FILE << EOF
# Temporary port forwarding ruleset for LiteLLM Proxy (localhost only)

# HTTP forwarding for localhost only
rdr on lo0 proto tcp from any to 127.0.0.1 port 80 -> 127.0.0.1 port $PORT
EOF

  # Add HTTPS rules if enabled
  if (( ENABLE_HTTPS_BOOL )); then
    cat >> $PF_RULES_FILE << EOF

# HTTPS forwarding for localhost only
rdr on lo0 proto tcp from any to 127.0.0.1 port 443 -> 127.0.0.1 port $HTTPS_PORT
EOF
  else
    # HTTP-only rules already added above
    echo "" >> $PF_RULES_FILE
  fi
  
  # Add domain-specific message if applicable
  if [[ "$SSL_DOMAIN" != "localhost" && (( ENABLE_HTTPS_BOOL )) ]]; then
    echo ""
    echo "NOTE: For ${SSL_DOMAIN} to work, add this to your hosts file:"
    echo "127.0.0.1  ${SSL_DOMAIN}"
    echo ""
  fi
  
  # Explicitly enable pf (this might require user confirmation)
  echo "Enabling packet filter (pf)..."
  sudo /sbin/pfctl -E 2>/dev/null || true
  
  # Double-check if pf is now enabled
  PF_STATUS=$(sudo /sbin/pfctl -s info 2>/dev/null | grep Status)
  if [[ "$PF_STATUS" != *"Enabled"* ]]; then
    echo "Failed to enable packet filter. Please run 'sudo /sbin/pfctl -E' manually."
    return 1
  else
    echo "✅ Packet filter (pf) is now enabled"  
  fi
  
  # Add our rules in a separate anchor (minimal system impact)
  echo "Adding port forwarding rules..."
  # Try first without redirection to see any errors
  sudo /sbin/pfctl -a "$ANCHOR_NAME" -f $PF_RULES_FILE
  sleep 1

  # Verify the rules were applied
  echo "Verifying port forwarding rules..."
  PFCTL_OUTPUT=$(sudo /sbin/pfctl -a "$ANCHOR_NAME" -s nat 2>/dev/null)
  
  if [[ -z "$PFCTL_OUTPUT" ]]; then
    line_error_up
    echo "Failed to add rules to anchor. Trying direct rule application..."
    line_error_down
    
    # Try with more verbose output
    echo "Applying rules directly with /sbin/pfctl..."
    sudo /sbin/pfctl -v -f $PF_RULES_FILE
    
    # Check if it worked
    PFCTL_OUTPUT=$(sudo /sbin/pfctl -s nat)
  fi
  
  # Print current NAT rules for inspection
  echo "Current NAT rules after setup:"
  echo "$PFCTL_OUTPUT"
  
  # Try several grep patterns to detect the rules, since pfctl output format can vary
  HTTP_FORWARDING=$(echo "$PFCTL_OUTPUT" | grep -E "port.*80.*->.*$PORT" || true)
  
  # Then verify HTTPS if enabled
  HTTPS_FORWARDING=""
  if (( ENABLE_HTTPS_BOOL )); then
    HTTPS_FORWARDING=$(echo "$PFCTL_OUTPUT" | grep -E "port.*443.*->.*$HTTPS_PORT" || true)
  fi
  
  # Check if we see any rules, regardless of the format
  if [[ -n "$PFCTL_OUTPUT" ]]; then
    echo "✅ Port forwarding rules appear to be loaded"
    
    if [[ -n "$HTTP_FORWARDING" ]]; then
      echo "✅ HTTP port forwarding verified: 80 → $PORT"
    else
      echo "Note: HTTP port forwarding loaded but not detected in verification output"
    fi
    
    if (( ENABLE_HTTPS_BOOL )); then
      if [[ -n "$HTTPS_FORWARDING" ]]; then
        echo "✅ HTTPS port forwarding verified: 443 → $HTTPS_PORT"
      else
        echo "Note: HTTPS port forwarding loaded but not detected in verification output"
      fi
    fi
    
    # Store the anchor name for cleanup
    PF_ANCHOR_USED="$ANCHOR_NAME"
    export PF_ANCHOR_USED
    rm $PF_RULES_FILE
    return 0
  else
    line_error_up
    echo "Failed to set up port forwarding. Rules were loaded but not detected."
    echo "Try running: ./test_pf.sh --test"
    line_error_down
    rm $PF_RULES_FILE
    return 1
  fi
  
  line_down
}


# Array to store PIDs of all LiteLLM instances
declare -a LITELLM_PIDS=()

# Function to start LiteLLM instances and track their PIDs
start_litellm() {
  local instance_name="$1"
  local config_file="$2"
  local port="$3"
  shift 3
  
  # Array for additional arguments
  local args=()
  
  # Create base command 
  args=("--config" "$config_file" "--port" "$port" "--detailed_debug")
  
  # Add any additional arguments
  for arg_pair in "$@"; do
    # Parse the arg pair format ["--flag" "value"]
    if [[ "$arg_pair" == *"["* ]]; then
      # Extract values from the format ["--flag" "value"]
      local flag=$(echo "$arg_pair" | sed -E 's/\[\s*"([^"]*)".*$/\1/')
      local value=$(echo "$arg_pair" | sed -E 's/.*"[^"]*"\s*"([^"]*)".*$/\1/')
      
      args+=("$flag" "$value")
    else
      # Just add the argument as is
      args+=("$arg_pair")
    fi
  done
  
  # Print the command for debugging
  echo "Starting $instance_name LiteLLM instance on port $port"
  
  # Determine if we need sudo (for privileged ports)
  local needs_sudo=0
  if (( USE_SUDO_BOOL )) && (( port < 1024 )); then
    needs_sudo=1
    echo "Command: sudo litellm ${args[*]} (using sudo for privileged port)"
  else
    echo "Command: litellm ${args[*]}"
  fi
  
  # Start LiteLLM in background with or without sudo as needed
  # Set PYTHONPATH for the current environment
  export PYTHONPATH="$PWD:$PYTHONPATH"
  
  if (( needs_sudo )); then
    # Use sudo -E to preserve environment variables
    # Build a quoted command string to handle array elements properly
    local cmd_str="litellm"
    for arg in "${args[@]}"; do
      cmd_str="$cmd_str '$arg'"
    done
    # Run with sudo -E to preserve environment variables
    sudo -E bash -c "$cmd_str" &
  else
    litellm "${args[@]}" &
  fi
  
  # Store the PID
  local pid=$!
  LITELLM_PIDS+=($pid)
  
  # Check if process is running after a brief delay
  sleep 2
  if ! kill -0 $pid 2>/dev/null; then
    line_error_up
    echo "ERROR: LiteLLM $instance_name instance failed to start."
    echo "Please check the logs for more information."
    line_error_down
    return 1
  fi
  
  echo "✅ LiteLLM $instance_name instance started with PID: $pid"
  return 0
}

# Set up port forwarding if requested
if (( ENABLE_PORT_FORWARD_BOOL )); then
  setup_port_forwarding
  if [ $? -ne 0 ]; then
    line_error_up
    echo "ERROR: Failed to set up port forwarding. Exiting."
    line_error_down
    exit 1
  fi
fi

# Start the LiteLLM proxy server
echo ""
line_up

# Start HTTP server
echo "Starting HTTP Instance"
if (( ENABLE_PORT_FORWARD_BOOL )); then
  echo "With port forwarding from 80 -> $PORT (HTTP)"
elif (( USE_SUDO_BOOL )); then
  echo "Binding directly to privileged port 80 (HTTP) using sudo"
fi

# Start HTTP instance
start_litellm "HTTP" "$TMP_CONFIG" "$HTTP_BIND_PORT"
if [ $? -ne 0 ]; then
  line_error_up
  echo "ERROR: Failed to start HTTP instance. Exiting."
  line_error_down
  exit 1
fi

# If HTTPS is enabled, start a separate instance
if (( ENABLE_HTTPS_BOOL )); then
  echo "Starting HTTPS Instance"
  if (( ENABLE_PORT_FORWARD_BOOL )); then
    echo "With port forwarding from 443 -> $HTTPS_PORT (HTTPS-enabled)"
  elif (( USE_SUDO_BOOL )); then
    echo "Binding directly to privileged port 443 (HTTPS) using sudo"
  fi
  
  # Start HTTPS server with SSL certificates
  start_litellm "HTTPS" "$TMP_CONFIG" "$HTTPS_BIND_PORT" "--ssl_keyfile_path" "$SSL_KEY" "--ssl_certfile_path" "$SSL_CERT"
  if [ $? -ne 0 ]; then
    line_error_up
    echo "ERROR: Failed to start HTTPS instance."
    echo "HTTP instance will continue running."
    line_error_down
  fi
fi

echo "This proxy routes OpenAI API calls to MLX_LM server based on the requested model"
echo "All requests are processed through the pre-call hook to ensure models are loaded"
echo "MAX_TOKENS is set to $MAX_TOKENS"
line_down

# We don't need to reinstall dependencies every time
# Just make sure the PYTHONPATH includes current directory

# Wait for LiteLLM processes to complete
wait