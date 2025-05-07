#!/usr/bin/env python3
"""
MLX_LM Server Wrapper

This script manages MLX_LM server instances:
1. A small autocomplete model (always running)
2. A dynamic larger model that changes based on user requests

Requirements:
- Python 3.11+
- Flask
- Requests
- psutil
- mlx_lm (installed separately)

Usage:
    python mlx_lm_wrapper.py [--autocomplete-model MODEL] [--autocomplete-port PORT]
                             [--dynamic-port PORT] [--host HOST]
"""

import argparse
import os
import signal
import subprocess
import time
import logging
import threading
import requests
from flask import Flask, request, jsonify
from typing import Optional, Tuple

# Configure logging
logging.basicConfig(
    level=logging.INFO, format="%(asctime)s - %(name)s - %(levelname)s - %(message)s"
)
logger = logging.getLogger("mlx_lm_wrapper")

# Global state
app = Flask(__name__)
current_model: Optional[str] = None
model_process: Optional[subprocess.Popen] = None
autocomplete_process: Optional[subprocess.Popen] = None
model_lock = threading.Lock()

# Configuration
DEFAULT_AUTOCOMPLETE_MODEL = "mlx-community/Qwen2.5-Coder-3B-8bit"
MANAGEMENT_PORT = 11400
DEFAULT_AUTOCOMPLETE_PORT = 11401
DEFAULT_DYNAMIC_PORT = 11402
DEFAULT_HOST = "127.0.0.1"


def start_mlx_server(
    model_name: str, port: int, max_tokens: int = 8192
) -> subprocess.Popen:
    """Start an MLX_LM server for the specified model."""
    logger.info(f"Starting MLX_LM server for model {model_name} on port {port}")

    # Format model name correctly for mlx-lm.server
    if not model_name.startswith("mlx-community/"):
        if model_name.startswith("openai/mlx-community/"):
            model_name = model_name[7:]  # Remove "openai/" prefix
        elif not model_name.startswith("mlx-community/"):
            model_name = f"mlx-community/{model_name}"

    # Extract base model name without mlx-community/ prefix for logging
    base_model_name = model_name.split("/")[-1]

    # Build command to start mlx-lm.server
    cmd = [
        "mlx_lm.server",
        "--model",
        model_name,
        "--port",
        str(port),
        "--host",
        DEFAULT_HOST,
        "--max-tokens",
        str(max_tokens),
        "--log-file",
        f"mlx_server_{base_model_name}_{port}.log",
    ]

    # Start the process
    process = subprocess.Popen(
        cmd,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        bufsize=1,
        preexec_fn=os.setsid,  # Create a new process group
    )

    # Wait for server to start (simple polling)
    max_retries = 60
    retries = 0
    while retries < max_retries:
        try:
            response = requests.get(f"http://{DEFAULT_HOST}:{port}/v1/models")
            if response.status_code == 200:
                logger.info(
                    f"MLX_LM server for {base_model_name} on port {port} is ready!"
                )
                return process
        except requests.exceptions.ConnectionError:
            pass

        retries += 1
        time.sleep(1)

        # Check if process died
        if process.poll() is not None:
            stderr = process.stderr.read() if process.stderr else "No stderr output"
            logger.error(f"Failed to start MLX_LM server: {stderr}")
            raise RuntimeError(
                f"Failed to start MLX_LM server for {model_name}: {stderr}"
            )

    # If we get here, the server didn't start in time
    logger.error(f"Timed out waiting for MLX_LM server on port {port} to start")
    kill_process(process)
    raise TimeoutError(f"Timed out waiting for MLX_LM server for {model_name} to start")


def kill_process(process: Optional[subprocess.Popen]) -> None:
    """Safely kill a process and its children."""
    if process is None or process.poll() is not None:
        return

    try:
        # Get the process group ID
        pgid = os.getpgid(process.pid)

        # Kill the entire process group
        os.killpg(pgid, signal.SIGTERM)

        # Wait for up to 5 seconds
        for _ in range(5):
            if process.poll() is not None:
                return
            time.sleep(1)

        # Force kill if still running
        if process.poll() is None:
            os.killpg(pgid, signal.SIGKILL)
    except (ProcessLookupError, PermissionError) as e:
        logger.warning(f"Error killing process: {e}")


def switch_model(new_model: str) -> Tuple[bool, str]:
    """Switch the dynamic model to a new model if needed."""
    global current_model, model_process

    with model_lock:
        # If we're already running the requested model, just return success
        if (
            current_model == new_model
            and model_process
            and model_process.poll() is None
        ):
            logger.info(f"Model {new_model} is already running")
            return True, "Model already running"

        # Stop the current model if it's running
        if model_process is not None:
            logger.info(f"Stopping current model {current_model}")
            kill_process(model_process)
            model_process = None
            current_model = None

        # Start the new model
        try:
            model_process = start_mlx_server(
                new_model, args.dynamic_port, max_tokens=8192
            )
            current_model = new_model
            return True, "Model switched successfully"
        except Exception as e:
            logger.error(f"Failed to start model {new_model}: {e}")
            return False, f"Failed to start model: {str(e)}"


@app.route("/status", methods=["GET"])
def status():
    """Return the status of the MLX_LM servers."""
    autocomplete_status = (
        "running"
        if (autocomplete_process and autocomplete_process.poll() is None)
        else "stopped"
    )

    dynamic_status = (
        "running" if (model_process and model_process.poll() is None) else "stopped"
    )

    return jsonify(
        {
            "autocomplete": {
                "status": autocomplete_status,
                "model": args.autocomplete_model,
                "port": args.autocomplete_port,
            },
            "dynamic": {
                "status": dynamic_status,
                "model": current_model,
                "port": args.dynamic_port,
            },
        }
    )


@app.route("/load_model", methods=["POST"])
def load_model():
    """Endpoint to load or switch models."""
    data = request.json
    if not data or "model" not in data:
        return jsonify({"error": "Missing 'model' field"}), 400

    success, message = switch_model(data["model"])
    if success:
        return jsonify({"status": "success", "message": message}), 200
    else:
        return jsonify({"status": "error", "message": message}), 500


def start_servers():
    """Start the autocomplete server and initialize management API."""
    global autocomplete_process

    # Start the autocomplete model server
    try:
        autocomplete_process = start_mlx_server(
            args.autocomplete_model,
            args.autocomplete_port,
            max_tokens=100,  # Lower token count for autocomplete model
        )
        logger.info(
            f"Autocomplete model server started on port {args.autocomplete_port}"
        )
    except Exception as e:
        logger.error(f"Failed to start autocomplete model server: {e}")
        return False

    return True


def cleanup():
    """Cleanup function to kill all processes on exit."""
    logger.info("Cleaning up processes...")
    kill_process(model_process)
    kill_process(autocomplete_process)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="MLX_LM Server Wrapper")
    parser.add_argument(
        "--autocomplete-model",
        default=DEFAULT_AUTOCOMPLETE_MODEL,
        help=f"Autocomplete model to use (default: {DEFAULT_AUTOCOMPLETE_MODEL})",
    )
    parser.add_argument(
        "--autocomplete-port",
        type=int,
        default=DEFAULT_AUTOCOMPLETE_PORT,
        help=f"Port for autocomplete model server (default: {DEFAULT_AUTOCOMPLETE_PORT})",
    )
    parser.add_argument(
        "--dynamic-port",
        type=int,
        default=DEFAULT_DYNAMIC_PORT,
        help=f"Port for dynamic model server (default: {DEFAULT_DYNAMIC_PORT})",
    )
    parser.add_argument(
        "--management-port",
        type=int,
        default={MANAGEMENT_PORT},
        help="Port for management API (default: 11400)",
    )
    parser.add_argument(
        "--host",
        default=DEFAULT_HOST,
        help=f"Host to bind servers to (default: {DEFAULT_HOST})",
    )

    args = parser.parse_args()

    # Register cleanup handler
    import atexit

    atexit.register(cleanup)

    # Start the servers
    if start_servers():
        logger.info(
            f"Started MLX_LM wrapper with autocomplete model: {args.autocomplete_model}"
        )
        logger.info(
            f"Management API running on http://{args.host}:{args.management_port}"
        )
        logger.info("Use /load_model endpoint to load dynamic models")

        # Run the Flask app for model management
        app.run(host=args.host, port=args.management_port, debug=False)
    else:
        logger.error("Failed to start MLX_LM wrapper")
        cleanup()
