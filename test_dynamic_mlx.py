#!/usr/bin/env python3
"""
Test script for the dynamic MLX-LM proxy

This script demonstrates:
1. Using the standard OpenAI client to access the proxy
2. Requesting different models to trigger dynamic loading
3. Using the autocomplete endpoint for quick completion requests

Usage:
    python test_dynamic_mlx.py [--port PORT] [--prompt PROMPT] [--model MODEL] [--max-tokens MAX_TOKENS]
"""

import argparse
import time
import os
import sys
from typing import Dict, Any, Optional

try:
    from openai import OpenAI
except ImportError:
    print("OpenAI package not found. Installing it now...")
    os.system("pip install openai")
    from openai import OpenAI

def parse_args():
    parser = argparse.ArgumentParser(description="Test the dynamic MLX-LM proxy")
    parser.add_argument("--port", type=int, default=8000, help="Port where the proxy is running")
    parser.add_argument("--prompt", type=str, default="Write a Python function that calculates the Fibonacci sequence.", 
                        help="Prompt to send to the model")
    parser.add_argument("--model", type=str, default="mlx-community/Qwen2.5-Coder-32B-Instruct-8bit",
                        help="Model to use for the request")
    parser.add_argument("--max-tokens", type=int, default=1024, 
                        help="Maximum number of tokens to generate")
    parser.add_argument("--autocomplete", action="store_true",
                        help="Use autocomplete mode (shorter outputs)")
    return parser.parse_args()

def test_chat_completion(client: OpenAI, model: str, prompt: str, max_tokens: int) -> None:
    """Test a chat completion request."""
    print(f"Testing chat completion with model: {model}")
    print(f"Prompt: {prompt}")
    print(f"Max tokens: {max_tokens}")
    print("-" * 50)
    
    try:
        start_time = time.time()
        response = client.chat.completions.create(
            model=model,
            messages=[
                {"role": "system", "content": "You are a helpful assistant."},
                {"role": "user", "content": prompt}
            ],
            max_tokens=max_tokens,
            temperature=0.7,
        )
        duration = time.time() - start_time
        
        print(f"\nResponse received in {duration:.2f} seconds:")
        print("-" * 50)
        print(response.choices[0].message.content)
        print("-" * 50)
        print(f"Finished: {response.choices[0].finish_reason}")
        print(f"Model: {response.model}")
        
    except Exception as e:
        print(f"Error during chat completion: {e}")

def test_autocomplete(client: OpenAI, prompt: str) -> None:
    """Test an autocomplete request."""
    print(f"Testing autocomplete with prompt: {prompt}")
    print("-" * 50)
    
    try:
        start_time = time.time()
        response = client.completions.create(
            model="gpt-autocomplete",  # Special model that routes to autocomplete server
            prompt=prompt,
            max_tokens=32,
            temperature=0.3,
            stop=["\n\n"],  # Stop generation at double newline
        )
        duration = time.time() - start_time
        
        print(f"\nResponse received in {duration:.2f} seconds:")
        print("-" * 50)
        print(prompt + response.choices[0].text)
        print("-" * 50)
        print(f"Finished: {response.choices[0].finish_reason}")
        print(f"Model: {response.model}")
        
    except Exception as e:
        print(f"Error during autocomplete: {e}")

def check_model_status(port: int) -> Optional[Dict[str, Any]]:
    """Check the status of the MLX-LM wrapper."""
    import requests
    try:
        response = requests.get(f"http://localhost:11435/status")
        if response.status_code == 200:
            return response.json()
        else:
            print(f"Error getting status: {response.status_code}")
            return None
    except Exception as e:
        print(f"Error connecting to MLX-LM wrapper: {e}")
        return None

def main():
    args = parse_args()
    
    # Initialize the OpenAI client with our proxy
    client = OpenAI(
        api_key="dummy-key",  # API key is ignored by the proxy
        base_url=f"http://localhost:{args.port}/v1"  # Point to the LiteLLM proxy
    )
    
    # Check MLX-LM wrapper status
    print("Checking MLX-LM wrapper status...")
    status = check_model_status(args.port)
    if status:
        print(f"Autocomplete model: {status['autocomplete']['model']} ({status['autocomplete']['status']})")
        print(f"Dynamic model: {status['dynamic']['model']} ({status['dynamic']['status']})")
        print("-" * 50)
    
    # Run tests
    if args.autocomplete:
        test_autocomplete(client, args.prompt)
    else:
        test_chat_completion(client, args.model, args.prompt, args.max_tokens)
    
    return 0

if __name__ == "__main__":
    sys.exit(main())