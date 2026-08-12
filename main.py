"""
Strands Worker Agent — OpenAB compatible, deployed on AgentCore Runtime.

This agent provides coding, git, shell, file ops, search, planning, and memory tools.
It integrates with Discord/Telegram through OpenAB's agentcore-acp bridge.
Multi-turn conversation history is persisted to the workspace filesystem.
"""

import os
import logging

from strands import Agent
from strands.models import BedrockModel
from bedrock_agentcore.runtime import BedrockAgentCoreApp

from tools import (
    shell_execute,
    git_operation,
    read_file,
    write_file,
    list_directory,
    memory_store,
    memory_recall,
    think,
    grep_search,
    find_files,
)
from prompts import WORKER_AGENT_SYSTEM_PROMPT
from conversation import ConversationHistory

# Configure logging
logging.basicConfig(level=logging.INFO, format="%(asctime)s [%(levelname)s] %(name)s: %(message)s")
logger = logging.getLogger(__name__)

# Initialize the AgentCore application
app = BedrockAgentCoreApp()

# Configure the LLM model
MODEL_ID = os.environ.get("BEDROCK_MODEL_ID", "us.anthropic.claude-sonnet-4-20250514-v1:0")
bedrock_model = BedrockModel(model_id=MODEL_ID)

# Initialize conversation history (persisted to workspace)
conversation_history = ConversationHistory()

# All available tools
TOOLS = [
    # Planning
    think,
    # Search & navigation
    grep_search,
    find_files,
    list_directory,
    read_file,
    # Execution
    shell_execute,
    git_operation,
    # File manipulation
    write_file,
    # Memory
    memory_store,
    memory_recall,
]

# Create the agent with all tools
agent = Agent(
    model=bedrock_model,
    system_prompt=WORKER_AGENT_SYSTEM_PROMPT,
    tools=TOOLS,
)


@app.entrypoint
def invoke(payload):
    """
    Handle an incoming invocation from AgentCore Runtime.

    The payload contains:
    - 'prompt': The user's message
    - 'session_id': Thread/session identifier for multi-turn context

    OpenAB sends messages here via the agentcore-acp bridge.
    Each Discord thread / Telegram chat maps to a unique session_id,
    providing continuous multi-turn context.
    """
    user_input = payload.get("prompt", "")
    session_id = payload.get("session_id", "default")

    if not user_input:
        return "No prompt provided."

    logger.info(f"Received prompt (session={session_id}): {user_input[:100]}...")

    try:
        # Load conversation history for this session
        messages = conversation_history.get_messages(session_id)

        # Append the new user message
        messages.append({"role": "user", "content": [{"text": user_input}]})

        logger.info(f"Context: {len(messages)} messages in history")

        # Invoke agent with full conversation history
        response = agent(messages=messages)
        result = response.message["content"][0]["text"]

        # Persist this turn to history
        conversation_history.add_turn(session_id, user_input, result)

        logger.info(f"Response generated ({len(result)} chars), history saved")
        return result

    except Exception as e:
        logger.error(f"Agent error: {e}", exc_info=True)
        return f"Agent encountered an error: {e}"


if __name__ == "__main__":
    logger.info(f"Starting Strands Worker Agent (model={MODEL_ID})")
    logger.info(f"Tools: {[t.__name__ for t in TOOLS]}")
    app.run()
