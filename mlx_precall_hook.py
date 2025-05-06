#!/usr/bin/env python3
"""
MLX Pre-Call Hook for LiteLLM

This script implements a pre-call hook for LiteLLM that:
1. Extracts the requested MLX model from incoming requests
2. Communicates with the MLX-LM wrapper to ensure the model is loaded
3. Waits for the model to be ready before allowing the request to proceed

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
from typing import Dict, Any, List, Optional, Union

# Configure logging
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s'
)
logger = logging.getLogger("mlx_precall_hook")

# Configuration
MLX_WRAPPER_URL = os.environ.get("MLX_WRAPPER_URL", "http://127.0.0.1:11435")
DYNAMIC_MODEL_PORT = int(os.environ.get("MLX_DYNAMIC_PORT", 11433))
AUTOCOMPLETE_MODEL_PORT = int(os.environ.get("MLX_AUTOCOMPLETE_PORT", 11434))
# How long to wait for model to load
MAX_WAIT_TIME = int(os.environ.get("MLX_MAX_WAIT_TIME", 300))  # seconds

def extract_model_name(request_data: Dict[str, Any]) -> Optional[str]:
    """Extract the model name from the request data."""
    # Extract from model field
    model = request_data.get("model", "")
    
    # If it's already an MLX model, return it
    if "mlx-community" in model:
        return model
    
    # Check for routing through litellm_params
    litellm_params = request_data.get("litellm_params", {})
    if litellm_params and "model" in litellm_params:
        model = litellm_params["model"]
        if "mlx-community" in model:
            return model
    
    # If we didn't find an MLX model, return None
    return None

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
    if max_tokens and max_tokens <= 64:
        return True
    
    return False

def wait_for_model_ready(model_name: str, port: int) -> bool:
    """Poll the MLX-LM server until the model is ready."""
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

def ensure_model_loaded(model_name: str) -> bool:
    """Ensure the requested model is loaded in the MLX-LM wrapper."""
    try:
        # Request model loading
        response = requests.post(
            f"{MLX_WRAPPER_URL}/load_model",
            json={"model": model_name},
            timeout=10
        )
        
        if response.status_code != 200:
            logger.error(f"Failed to request model loading: {response.text}")
            return False
        
        # Wait for the model to be ready
        return wait_for_model_ready(model_name, DYNAMIC_MODEL_PORT)
    except requests.exceptions.RequestException as e:
        logger.error(f"Error communicating with MLX wrapper: {e}")
        return False

def mlx_pre_call_hook(
    request_data: Dict[str, Any],
    **kwargs
) -> Dict[str, Any]:
    """Pre-call hook for LiteLLM to ensure the requested MLX model is loaded."""
    logger.info(f"Processing request: {request_data.get('model', 'unknown model')}")
    
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
    else:
        logger.error(f"Failed to load model {model_name}")
        # Optionally raise an exception to fail the request
        # raise Exception(f"Failed to load model {model_name}")
    
    return request_data

# For testing the hook directly
if __name__ == "__main__":
    # Example request data
    test_request = {
        "model": "openai/mlx-community/Qwen2.5-32B-Instruct-8bit",
        "api_base": f"http://127.0.0.1:{DYNAMIC_MODEL_PORT}/v1",
        "litellm_params": {
            "model": "openai/mlx-community/Qwen2.5-32B-Instruct-8bit",
        },
        "max_tokens": 1024
    }
    
    # Test the hook
    result = mlx_pre_call_hook(test_request)
    print(f"Hook result: {result}")