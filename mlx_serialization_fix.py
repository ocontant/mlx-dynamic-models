#!/usr/bin/env python3
"""
MLX Serialization Fix for LiteLLM

This script implements a workaround for the JSON serialization error that occurs
with MLX responses in LiteLLM:
'MockValSer' object cannot be converted to 'SchemaSerializer'

Usage:
    Include this in your LiteLLM config under router_settings.post_call_hooks
"""

import logging
import traceback
from typing import Dict, Any, List, Optional, Union

# Configure logging
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s'
)
logger = logging.getLogger("mlx_serialization_fix")

def fix_serialization_error(response_obj: Any) -> Any:
    """
    Fixes serialization issues with MLX model responses.
    If the serialization would fail, converts to a regular dictionary.
    """
    if response_obj is None:
        return response_obj
        
    try:
        # First attempt to just serialize it to detect issues
        try:
            # If this works, then no fix is needed
            if hasattr(response_obj, "model_dump_json"):
                response_obj.model_dump_json(exclude_none=True, exclude_unset=True)
            return response_obj
        except Exception as e:
            # If error contains MockValSer, apply our fix
            if "MockValSer" in str(e) and "SchemaSerializer" in str(e):
                logger.debug("Detected MockValSer serialization issue, applying fix")
                # Fall through to fix
            else:
                # For other errors, just log and return original
                logger.debug(f"Non-targeted serialization error: {e}")
                return response_obj
            
        # Apply the fix by converting to a regular dict
        from pydantic import BaseModel
        
        # Check if it's a Pydantic model or similar object that we can extract data from
        if hasattr(response_obj, "model_dump"):
            # Use model_dump to get a dict representation
            fixed_obj = response_obj.model_dump(exclude_none=True, exclude_unset=True)
            logger.debug("Successfully converted Pydantic object to dict")
            return fixed_obj
        elif hasattr(response_obj, "dict"):
            # Older Pydantic versions
            fixed_obj = response_obj.dict(exclude_none=True, exclude_unset=True)
            logger.debug("Successfully converted Pydantic object to dict (legacy)")
            return fixed_obj
        elif hasattr(response_obj, "__dict__"):
            # Regular Python object with __dict__
            fixed_obj = response_obj.__dict__
            logger.debug("Converted object using __dict__")
            return fixed_obj
        else:
            # Try direct dictionary conversion as a last resort
            fixed_obj = dict(response_obj)
            logger.debug("Converted object using direct dict conversion")
            return fixed_obj
            
    except Exception as e:
        logger.error(f"Error in serialization fix: {e}")
        logger.debug(traceback.format_exc())
        # Return original object if our fix fails
        return response_obj

def mlx_post_call_hook(
    response_obj: Any,
    **kwargs
) -> Any:
    """
    Post-call hook for LiteLLM to fix serialization issues with MLX model responses.
    This is called after the model response is received but before it's sent to the client.
    """
    try:
        logger.debug("Running post-call hook for MLX serialization fix")
        
        # Fix serialization issues in the response object
        fixed_response = fix_serialization_error(response_obj)
        
        # Return the fixed response
        return fixed_response
        
    except Exception as e:
        logger.error(f"Error in post-call hook: {e}")
        logger.debug(traceback.format_exc())
        # Return original response if our hook fails
        return response_obj