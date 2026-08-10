#!/usr/bin/env python3
"""
Strands Agent ACP Wrapper

Bridges OpenAB's ACP JSON-RPC protocol (over stdio) to a Strands Agent
backed by Amazon Bedrock models.

Protocol: JSON-RPC 2.0 over stdin/stdout (one JSON object per line)
Compatible with: OpenAB agentcore-bridge and local [agent] mode
"""

import sys
import json
import os
import logging
from typing import Any

from strands import Agent
from strands.models.bedrock import BedrockModel

# --- Configuration via environment variables ---
MODEL_ID = os.environ.get("BEDROCK_MODEL_ID", "us.anthropic.claude-sonnet-4-20250514")
AWS_REGION = os.environ.get("AWS_REGION", "us-east-1")
AGENT_NAME = os.environ.get("AGENT_NAME", "strands-bedrock-agent")
AGENT_VERSION = os.environ.get("AGENT_VERSION", "0.1.0")
SYSTEM_PROMPT = os.environ.get(
    "SYSTEM_PROMPT",
    "You are a helpful AI assistant. Answer questions clearly and concisely."
)
LOG_LEVEL = os.environ.get("LOG_LEVEL", "WARNING")

# --- Logging (stderr only, stdout is for JSON-RPC) ---
logging.basicConfig(
    stream=sys.stderr,
    level=getattr(logging, LOG_LEVEL.upper(), logging.WARNING),
    format="%(asctime)s [%(levelname)s] %(message)s"
)
logger = logging.getLogger(__name__)

# --- Agent initialization ---
def create_agent() -> Agent:
    """Create a Strands agent with Bedrock model."""
    model = BedrockModel(
        model_id=MODEL_ID,
        region_name=AWS_REGION,
    )
    agent = Agent(
        model=model,
        system_prompt=SYSTEM_PROMPT,
    )
    logger.info(f"Agent initialized: model={MODEL_ID}, region={AWS_REGION}")
    return agent


# --- Session state ---
class SessionManager:
    """Manages conversation sessions (one per OAB thread)."""

    def __init__(self):
        self.sessions: dict[str, Agent] = {}

    def get_or_create(self, session_id: str) -> Agent:
        if session_id not in self.sessions:
            self.sessions[session_id] = create_agent()
            logger.info(f"New session created: {session_id}")
        return self.sessions[session_id]

    def destroy(self, session_id: str) -> None:
        if session_id in self.sessions:
            del self.sessions[session_id]
            logger.info(f"Session destroyed: {session_id}")


sessions = SessionManager()


# --- ACP Protocol Handlers ---

def handle_initialize(params: dict) -> dict:
    """Handle ACP initialize request."""
    return {
        "protocolVersion": "2024-11-05",
        "serverInfo": {
            "name": AGENT_NAME,
            "version": AGENT_VERSION,
        },
        "capabilities": {
            "streaming": False,
            "toolCalling": False,
        },
    }


def handle_session_prompt(params: dict) -> dict:
    """Handle ACP session/prompt request — main conversation handler."""
    session_id = params.get("sessionId", "default")
    messages = params.get("messages", [])

    if not messages:
        return {
            "messages": [{
                "role": "assistant",
                "content": "No message provided."
            }]
        }

    # Extract the last user message
    last_message = messages[-1]
    content = last_message.get("content", "")

    # Handle content that may be a list of content blocks
    if isinstance(content, list):
        text_parts = []
        for block in content:
            if isinstance(block, dict) and block.get("type") == "text":
                text_parts.append(block.get("text", ""))
            elif isinstance(block, str):
                text_parts.append(block)
        content = "\n".join(text_parts)

    logger.info(f"[{session_id}] Prompt: {content[:100]}...")

    # Get or create session agent
    agent = sessions.get_or_create(session_id)

    try:
        result = agent(content)
        response_text = result.message if hasattr(result, 'message') else str(result)
        logger.info(f"[{session_id}] Response: {response_text[:100]}...")
    except Exception as e:
        logger.error(f"[{session_id}] Agent error: {e}")
        response_text = f"⚠️ Agent error: {str(e)}"

    return {
        "messages": [{
            "role": "assistant",
            "content": response_text,
        }]
    }


def handle_session_stop(params: dict) -> dict:
    """Handle ACP session/stop request."""
    session_id = params.get("sessionId", "default")
    sessions.destroy(session_id)
    return {}


def handle_unknown(method: str, params: dict) -> dict:
    """Handle unknown methods gracefully."""
    logger.warning(f"Unknown method: {method}")
    return {}


# --- Method dispatch ---
HANDLERS = {
    "initialize": handle_initialize,
    "session/prompt": handle_session_prompt,
    "session/stop": handle_session_stop,
    "notifications/initialized": lambda p: None,  # no-op notification
    "shutdown": lambda p: {},
}


def process_request(request: dict) -> dict | None:
    """Process a single JSON-RPC request and return a response."""
    method = request.get("method", "")
    params = request.get("params", {})
    request_id = request.get("id")

    handler = HANDLERS.get(method, lambda p: handle_unknown(method, p))
    result = handler(params)

    # Notifications (no id) don't get a response
    if request_id is None:
        return None

    if result is None:
        result = {}

    return {
        "jsonrpc": "2.0",
        "id": request_id,
        "result": result,
    }


def main():
    """Main loop: read JSON-RPC from stdin, write responses to stdout."""
    logger.info("ACP wrapper started, waiting for requests...")

    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue

        try:
            request = json.loads(line)
        except json.JSONDecodeError as e:
            logger.error(f"Invalid JSON: {e}")
            continue

        response = process_request(request)

        if response is not None:
            sys.stdout.write(json.dumps(response) + "\n")
            sys.stdout.flush()

        # Exit on shutdown
        if request.get("method") == "shutdown":
            logger.info("Shutdown received, exiting.")
            break


if __name__ == "__main__":
    main()
