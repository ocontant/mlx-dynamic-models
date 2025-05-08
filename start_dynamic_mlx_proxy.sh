#!/bin/bash

# Default values
PORT=11432
HTTPS_PORT=11433  # HTTPS port for secure connections
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
ENABLE_HTTPS=false  # Flag to enable HTTPS support
SSL_DOMAIN="localhost"  # Default domain for SSL certificate

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
      shift # past argument
      ;;
    --enable-port-forward)
      ENABLE_PORT_FORWARD=true
      shift # past argument
      ;;
    --enable-https)
      ENABLE_HTTPS=true
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

# Generate dynamic config file with proper variable substitution
TMP_CONFIG=$(mktemp)

# Set appropriate additional ports based on parameters
if [[ "$USE_SUDO" == true && "$ENABLE_PORT_FORWARD" == false ]]; then
  # If using sudo and not port forwarding, bind directly to privileged ports
  ADDITIONAL_PORTS="[80, 443]  # Binding directly to privileged ports with sudo"
else
  # Otherwise, don't attempt to bind to privileged ports
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
      echo "Failed to generate SSL certificates. Make sure openssl is installed."
      echo "Continuing without HTTPS support."
      ENABLE_HTTPS=false
    else
      echo "SSL certificates generated successfully at ${SSL_DIR}"
      echo "Certificate is valid for: $SSL_DOMAIN"
    fi
  else
    echo "Using existing SSL certificates from ${SSL_DIR}"
    echo "Certificate is configured for: $SSL_DOMAIN"
  fi
  
  # If the domain is api.anthropic.com, suggest adding a hosts entry
  if [[ "$SSL_DOMAIN" == "api.anthropic.com" ]]; then
    echo ""
    echo "IMPORTANT: For local testing with api.anthropic.com, add the following entry to your /etc/hosts file:"
    echo "127.0.0.1  api.anthropic.com"
    echo ""
    echo "You can do this by running:"
    echo "sudo bash -c \"echo '127.0.0.1  api.anthropic.com' >> /etc/hosts\""
    echo ""
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
  # Determine target port based on protocol
  local TARGET_PORT=$PORT
  if [[ "$ENABLE_HTTPS" == true ]]; then
    echo "Setting up port forwarding from port 443 to HTTPS port $HTTPS_PORT..."
    TARGET_PORT=$HTTPS_PORT
  else
    echo "Setting up port forwarding from port 443 to HTTP port $PORT..."
  fi
  
  # Check if sudo is available
  if ! command -v sudo &> /dev/null; then
    echo "Error: sudo is required for port forwarding but is not available."
    return 1
  fi
  
  # Check if pfctl is available (macOS specific)
  if ! command -v pfctl &> /dev/null; then
    echo "Error: pfctl is required for port forwarding but is not available. This feature is macOS specific."
    return 1
  fi
  
  # Create a temporary pf configuration file
  local PF_RULES_FILE=$(mktemp)
  local ANCHOR_NAME="com.litellm.portforward"
  
  # Create the ruleset with minimal configuration
  cat > $PF_RULES_FILE << EOF
# Temporary port forwarding ruleset for LiteLLM Proxy
# Forward port 443 to port $TARGET_PORT

# Skip on loopback to prevent interference with other services
set skip on lo0

# Port forwarding rule
rdr pass inet proto tcp from any to any port 443 -> 127.0.0.1 port $TARGET_PORT
EOF

  # If we have a specific domain, add a helpful message
  if [[ "$SSL_DOMAIN" != "localhost" ]]; then
    echo "NOTE: For ${SSL_DOMAIN} to work, add this to your hosts file:"
    echo "127.0.0.1  ${SSL_DOMAIN}"
    echo ""
    echo "Run: sudo bash -c \"echo '127.0.0.1  ${SSL_DOMAIN}' >> /etc/hosts\""
  fi
  
  # Enable pf if not already enabled 
  PF_STATUS=$(sudo pfctl -s info 2>/dev/null | grep Status)
  if [[ "$PF_STATUS" != *"Enabled"* ]]; then
    echo "Enabling packet filter (pf)..."
    sudo pfctl -E 2>/dev/null || true
  fi
  
  # Try using sudo pfctl -e to make sure pf is fully enabled
  echo "Ensuring packet filter is fully enabled..."
  sudo pfctl -e 2>/dev/null || true
  
  # Add our rules in a separate anchor (minimal system impact)
  echo "Adding port forwarding rules..."
  # Try first without redirection to see any errors
  sudo pfctl -a "$ANCHOR_NAME" -f $PF_RULES_FILE
  
  # Verify the rules were applied
  echo "Verifying port forwarding rules..."
  PFCTL_OUTPUT=$(sudo pfctl -a "$ANCHOR_NAME" -s nat 2>/dev/null)
  echo "DEBUG: pfctl anchor output: '$PFCTL_OUTPUT'"
  
  if [[ -z "$PFCTL_OUTPUT" ]]; then
    echo "Failed to add rules to anchor. Trying direct rule application..."
    echo "DEBUG: Direct rule contents:"
    cat $PF_RULES_FILE
    
    # Try with more verbose output
    echo "Applying rules directly with pfctl..."
    sudo pfctl -v -f $PF_RULES_FILE
    
    # Check if it worked
    PFCTL_OUTPUT=$(sudo pfctl -s nat)
    echo "DEBUG: Direct pfctl output: '$PFCTL_OUTPUT'"
  fi
  
  # Check if port forwarding was set up successfully
  if echo "$PFCTL_OUTPUT" | grep -q "port 443 -> 127.0.0.1 port $TARGET_PORT"; then
    echo "✅ Port forwarding successfully set up: 443 -> $TARGET_PORT"
    # Store the anchor name for cleanup
    PF_ANCHOR_USED="$ANCHOR_NAME"
    export PF_ANCHOR_USED
    rm $PF_RULES_FILE
    return 0
  else
    echo "Failed to set up port forwarding. Make sure packet filter (pf) is enabled on your system."
    echo "Try running: sudo pfctl -E"
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
if [[ "$ENABLE_HTTPS" == true ]]; then
  echo "With HTTPS enabled on port $HTTPS_PORT"
fi
if [[ "$ENABLE_PORT_FORWARD" == true && $? -eq 0 ]]; then
  if [[ "$ENABLE_HTTPS" == true ]]; then
    echo "With port forwarding from 443 -> $HTTPS_PORT (HTTPS)"
  else
    echo "With port forwarding from 443 -> $PORT (HTTP)"
  fi
fi
echo "This proxy routes OpenAI API calls to MLX_LM server based on the requested model"
echo "All requests are processed through the pre-call hook to ensure models are loaded"
echo "MAX_TOKENS is set to $MAX_TOKENS"

# We don't need to reinstall dependencies every time
# Just make sure the PYTHONPATH includes current directory

# Build the command with appropriate options
LITELLM_CMD="litellm --config $TMP_CONFIG --port $PORT --detailed_debug"

# Add HTTPS options if enabled
if [[ "$ENABLE_HTTPS" == true ]]; then
  # LiteLLM uses --ssl_keyfile_path and --ssl_certfile_path (not ssl_keyfile/ssl_certfile)
  LITELLM_CMD="$LITELLM_CMD --ssl_keyfile_path $SSL_KEY --ssl_certfile_path $SSL_CERT --ssl_port $HTTPS_PORT"
  echo "Using SSL certificate: $SSL_CERT"
  echo "Using SSL key: $SSL_KEY"
fi

# Start with verbose logging to see the requests and responses
if [[ "$USE_SUDO" == true ]]; then
  echo "Running LiteLLM with sudo to bind to privileged ports..."
  sudo PYTHONPATH="$PWD:$PYTHONPATH" $LITELLM_CMD
else
  PYTHONPATH="$PWD:$PYTHONPATH" $LITELLM_CMD
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
    
    # Check if we stored an anchor name
    if [[ -n "$PF_ANCHOR_USED" ]]; then
      echo "Removing rules from anchor $PF_ANCHOR_USED..."
      sudo pfctl -a "$PF_ANCHOR_USED" -F all 2>/dev/null || true
    else
      # Try default anchor name
      echo "Removing rules from default anchor..."
      sudo pfctl -a "com.litellm.portforward" -F all 2>/dev/null || true
      
      # Also try clearing directly (backup method)
      echo "Clearing direct rules (if any)..."
      local PF_RULES_FILE=$(mktemp)
      echo "" > $PF_RULES_FILE
      sudo pfctl -f $PF_RULES_FILE 2>/dev/null || true
      rm $PF_RULES_FILE
    fi
    
    echo "Port forwarding rules have been removed."
    
    # Print verification
    echo "Verifying port forwarding removal:"
    sudo pfctl -s nat | grep "port 443" || echo "✅ No port 443 forwarding rules found"
  fi
  
  echo "Shutdown complete."
  exit 0
}

# Clean exit (will trigger the cleanup trap)
echo "LiteLLM proxy has stopped. Cleaning up..."