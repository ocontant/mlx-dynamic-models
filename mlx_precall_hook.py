#!/usr/bin/env python3
"""
MLX Pre-Call Hook for LiteLLM

This script implements a pre-call hook for LiteLLM that:
1. Extracts the requested MLX model from incoming requests
2. Communicates with the MLX_LM wrapper to ensure the model is loaded
3. Waits for the model to be ready before allowing the request to proceed
4. Monitors wrapper availability and terminates if wrapper is down

Usage:
    Include this in your LiteLLM config under router_settings.pre_call_hooks

Requirements:
    - Python 3.11+
    - Requests
"""

import os
import time
import logging
import requests
import sys
import signal
from typing import Dict, Any, List, Optional, Union

# Configure logging
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s'
)
logger = logging.getLogger("mlx_precall_hook")

# Configuration
MLX_WRAPPER_URL = os.environ.get("MLX_WRAPPER_URL", "http://127.0.0.1:11400")
DYNAMIC_MODEL_PORT = int(os.environ.get("MLX_DYNAMIC_PORT", 11402))
AUTOCOMPLETE_MODEL_PORT = int(os.environ.get("MLX_AUTOCOMPLETE_PORT", 11401))
# How long to wait for model to load
MAX_WAIT_TIME = int(os.environ.get("MLX_MAX_WAIT_TIME", 300))  # seconds

# Track wrapper availability
WRAPPER_AVAILABILITY_CHECK_COUNT = 0
WRAPPER_MAX_FAILURES = 3  # Number of consecutive failures before terminating

def extract_model_name(request_data: Dict[str, Any]) -> Optional[str]:
    """
    Extract the model name from the request data.
    
    With openai_compatible provider, we just need to make sure the model name
    is in the correct format for the MLX-LM server.
    """
    # Extract from model field
    model = request_data.get("model", "")
    
    # If it's already an MLX model with mlx-community prefix, return it
    if model.startswith("mlx-community/"):
        return model
    
    # Check for routing through litellm_params
    litellm_params = request_data.get("litellm_params", {})
    if litellm_params and "model" in litellm_params:
        model = litellm_params["model"]
        if model.startswith("mlx-community/"):
            return model
    
    # Handle various formats
    if "/" in model:
        parts = model.split("/")
        # Check if it has a provider prefix with mlx-community
        if len(parts) > 2 and parts[-2] == "mlx-community":
            # Just return mlx-community/model part
            return f"mlx-community/{parts[-1]}"
        # For other formats, extract the model name
        base_model_name = parts[-1]
        return f"mlx-community/{base_model_name}"
    
    # For bare model names, add the mlx-community prefix
    return f"mlx-community/{model}"

def is_autocomplete_request(request_data: Dict[str, Any]) -> bool:
    """Determine if this is an autocomplete request."""
    # Check if the endpoint is for completions (vs chat)
    endpoint = request_data.get("endpoint", "")
    if endpoint == "/v1/completions":
        return True
    
    # Check for special header or parameter indicating autocomplete
    headers = request_data.get("headers", {})
    if headers.get("X-Autocomplete") == "true":
        return True
    
    # Check for low max_tokens which often indicates autocomplete
    max_tokens = request_data.get("max_tokens", 0)
    if max_tokens and max_tokens <= 100:
        return True
    
    return False

def wait_for_model_ready(model_name: str, port: int) -> bool:
    """Poll the MLX_LM server until the model is ready."""
    start_time = time.time()
    while (time.time() - start_time) < MAX_WAIT_TIME:
        try:
            # Check if server is responding
            response = requests.get(f"http://127.0.0.1:{port}/v1/models")
            if response.status_code == 200:
                logger.info(f"Model {model_name} is ready on port {port}")
                return True
        except requests.exceptions.ConnectionError:
            pass
        
        # Retry after a short delay
        time.sleep(1)
    
    logger.error(f"Timed out waiting for model {model_name} to be ready")
    return False

def check_wrapper_availability() -> bool:
    """Check if the MLX wrapper is available and terminate if it's not after multiple failures."""
    global WRAPPER_AVAILABILITY_CHECK_COUNT
    
    try:
        response = requests.get(f"{MLX_WRAPPER_URL}/status", timeout=2)
        if response.status_code == 200:
            # Reset counter on success
            WRAPPER_AVAILABILITY_CHECK_COUNT = 0
            return True
    except requests.RequestException:
        # Increment failure counter
        WRAPPER_AVAILABILITY_CHECK_COUNT += 1
        logger.warning(f"Failed to connect to MLX wrapper. Failure {WRAPPER_AVAILABILITY_CHECK_COUNT}/{WRAPPER_MAX_FAILURES}")
        
        # If we've reached the maximum failures, terminate the process
        if WRAPPER_AVAILABILITY_CHECK_COUNT >= WRAPPER_MAX_FAILURES:
            logger.critical("MLX wrapper is unavailable. Terminating LiteLLM proxy.")
            # Signal parent process to shut down (handled by shell trap)
            os.kill(os.getppid(), signal.SIGTERM)
            # Also exit this process
            sys.exit(1)
    
    return False

def ensure_model_loaded(model_name: str) -> bool:
    """Ensure the requested model is loaded in the MLX_LM wrapper."""
    # First check if the wrapper is available
    if not check_wrapper_availability():
        logger.error("MLX wrapper is unavailable, cannot load model")
        return False
        
    try:
        # Request model loading
        # Make sure to pass the model name with the provider prefix intact 
        # The wrapper will handle stripping it
        response = requests.post(
            f"{MLX_WRAPPER_URL}/load_model",
            json={"model": model_name},
            timeout=10
        )
        
        if response.status_code != 200:
            logger.error(f"Failed to request model loading: {response.text}")
            return False
        
        # For waiting, we don't need to worry about the provider prefix
        # as we're just checking if the server is responsive
        return wait_for_model_ready(model_name, DYNAMIC_MODEL_PORT)
    except requests.exceptions.RequestException as e:
        logger.error(f"Error communicating with MLX wrapper: {e}")
        # Check wrapper availability again after a communication error
        check_wrapper_availability()
        return False

def mlx_pre_call_hook(
    request_data: Dict[str, Any],
    **kwargs
) -> Dict[str, Any]:
    """Pre-call hook for LiteLLM to ensure the requested MLX model is loaded."""
    logger.info(f"Processing request: {request_data.get('model', 'unknown model')}")
    
    # No need to modify the request parameters
    # Let LiteLLM handle streaming and parameter processing
    
    # Check if this is an autocomplete request
    if is_autocomplete_request(request_data):
        logger.info("Detected autocomplete request, routing to autocomplete model")
        # Modify the request to use the autocomplete model port
        api_base = request_data.get("api_base", "")
        if api_base:
            # Replace port in the API base
            request_data["api_base"] = api_base.replace(
                f":{DYNAMIC_MODEL_PORT}", 
                f":{AUTOCOMPLETE_MODEL_PORT}"
            )
        return request_data
    
    # For normal requests, extract the model name
    model_name = extract_model_name(request_data)
    if not model_name:
        logger.warning("Could not extract MLX model name from request")
        return request_data
    
    # Ensure the model is loaded
    if ensure_model_loaded(model_name):
        logger.info(f"Model {model_name} is loaded and ready")
        
        # Make sure the litellm_params have the correct model name
        # This ensures LiteLLM uses the actual requested model, not just a pattern match
        if "litellm_params" in request_data:
            request_data["litellm_params"]["model"] = model_name
            logger.info(f"Updated litellm_params.model to {model_name}")
    else:
        logger.error(f"Failed to load model {model_name}")
        # Optionally raise an exception to fail the request
        # raise Exception(f"Failed to load model {model_name}")
    
    return request_data

# For testing the hook directly
if __name__ == "__main__":
    # Example request data
    test_request = {
        "model": "openai/mlx-community/Qwen2.5-Coder-3B-Instruct-8bit",
        "api_base": f"http://127.0.0.1:{DYNAMIC_MODEL_PORT}/v1",
        "litellm_params": {
            "model": "openai/mlx-community/Qwen2.5-Coder-3B-Instruct-8bit",
        },
        "max_tokens": 1024
    }
    
    # Test the hook
    result = mlx_pre_call_hook(test_request)
    print(f"Hook result: {result}")
