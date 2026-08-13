#!/usr/bin/env python3
"""
strands-acp — ACP (Agent Client Protocol) stdio adapter for the Strands Worker Agent.

Speaks JSON-RPC over stdin/stdout (ACP protocol) so OpenAB can invoke
the Strands agent with all tools (shell, git, file ops, search, memory, think).

Protocol:
  stdin  → JSON-RPC requests (initialize, session/prompt, session/cancel)
  stdout ← JSON-RPC responses + notifications (thinking, progress)
"""

import sys
import json
import os
import logging
import traceback

# Ensure output is unbuffered
sys.stdout = open(sys.stdout.fileno(), 'w', buffering=1)
sys.stderr = open(sys.stderr.fileno(), 'w', buffering=1)

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    stream=sys.stderr,  # Logs go to stderr, ACP messages go to stdout
)
logger = logging.getLogger("strands-acp")

# Lazy-load the agent (avoids import time blocking ACP init)
_agent = None
_conversation_history = None


def get_agent():
    """Lazy-initialize the Strands agent."""
    global _agent, _conversation_history
    if _agent is None:
        logger.info("Initializing Strands agent...")
        from strands import Agent
        from strands.models import BedrockModel

        from tools import (
            shell_execute, git_operation, read_file, write_file,
            list_directory, memory_store, memory_recall, think,
            grep_search, find_files,
        )
        from prompts import WORKER_AGENT_SYSTEM_PROMPT
        from conversation import ConversationHistory

        model_id = os.environ.get("BEDROCK_MODEL_ID", "us.anthropic.claude-sonnet-4-20250514-v1:0")
        logger.info(f"Using model: {model_id}")

        bedrock_model = BedrockModel(model_id=model_id)

        _agent = Agent(
            model=bedrock_model,
            system_prompt=WORKER_AGENT_SYSTEM_PROMPT,
            tools=[
                think, grep_search, find_files, list_directory,
                read_file, shell_execute, git_operation, write_file,
                memory_store, memory_recall,
            ],
        )
        _conversation_history = ConversationHistory()
        logger.info("Strands agent ready.")
    return _agent, _conversation_history


def send_response(msg_id, result):
    """Send a JSON-RPC response."""
    response = {"jsonrpc": "2.0", "id": msg_id, "result": result}
    line = json.dumps(response)
    sys.stdout.write(line + "\n")
    sys.stdout.flush()


def send_error(msg_id, code, message):
    """Send a JSON-RPC error."""
    response = {
        "jsonrpc": "2.0",
        "id": msg_id,
        "error": {"code": code, "message": message},
    }
    line = json.dumps(response)
    sys.stdout.write(line + "\n")
    sys.stdout.flush()


def send_notification(method, params):
    """Send a JSON-RPC notification (no id)."""
    notif = {"jsonrpc": "2.0", "method": method, "params": params}
    line = json.dumps(notif)
    sys.stdout.write(line + "\n")
    sys.stdout.flush()


def handle_initialize(msg_id, params):
    """Handle ACP initialize request."""
    send_response(msg_id, {
        "name": "strands-worker-agent",
        "version": "1.0.0",
        "capabilities": {
            "streaming": False,
            "tools": True,
            "thinking": True,
        },
    })


def handle_prompt(msg_id, params):
    """Handle ACP session/prompt request."""
    raw_prompt = params.get("prompt", "")
    session_id = params.get("sessionId", "default")

    # ACP prompt can be a string or a list of content blocks
    if isinstance(raw_prompt, list):
        # Extract text from content blocks
        texts = [block.get("text", "") for block in raw_prompt if block.get("type") == "text"]
        prompt = "\n".join(texts)
    else:
        prompt = str(raw_prompt)

    if not prompt:
        send_error(msg_id, -32602, "Missing 'prompt' parameter")
        return

    logger.info(f"Prompt received (session={session_id}): {prompt[:100]}...")

    try:
        agent, history = get_agent()

        # Send thinking notification
        send_notification("notifications/thinking", {"content": "Processing..."})

        # Invoke agent with just the prompt (let Strands handle its own context)
        response = agent(prompt)
        result_text = response.message["content"][0]["text"]

        # Save to history for future reference
        history.add_turn(session_id, prompt, result_text)

        logger.info(f"Response generated ({len(result_text)} chars)")

        # Send ACP response
        send_response(msg_id, {
            "content": [{"type": "text", "text": result_text}],
        })

    except Exception as e:
        logger.error(f"Agent error: {traceback.format_exc()}")
        send_error(msg_id, -32000, f"Agent error: {str(e)}")


def handle_cancel(msg_id, params):
    """Handle ACP session/cancel request."""
    send_response(msg_id, {"cancelled": True})


def main():
    """Main ACP stdio loop."""
    logger.info("strands-acp adapter starting (stdio mode)")

    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue

        try:
            msg = json.loads(line)
        except json.JSONDecodeError as e:
            logger.error(f"Invalid JSON: {e}")
            continue

        msg_id = msg.get("id")
        method = msg.get("method", "")

        logger.info(f"← {method} (id={msg_id})")

        if method == "initialize":
            handle_initialize(msg_id, msg.get("params", {}))
        elif method == "session/new":
            # OpenAB creates a new session before sending prompts
            send_response(msg_id, {"sessionId": msg.get("params", {}).get("sessionId", "default")})
        elif method == "session/prompt":
            handle_prompt(msg_id, msg.get("params", {}))
        elif method == "session/cancel":
            handle_cancel(msg_id, msg.get("params", {}))
        elif method == "session/end":
            send_response(msg_id, {})
        elif method == "shutdown":
            send_response(msg_id, {})
            break
        elif method == "notifications/initialized":
            # Notification from client, no response needed
            pass
        else:
            # For any unknown method, respond with empty success rather than error
            # This prevents breaking on new ACP methods we haven't implemented
            logger.warning(f"Unknown method: {method} — responding with empty result")
            send_response(msg_id, {})

    logger.info("strands-acp adapter shutting down")


if __name__ == "__main__":
    main()
