"""
Strands Worker Agent — OpenAB compatible, deployed on AgentCore Runtime.

This agent provides coding, git, shell, file ops, and memory tools.
It integrates with Discord/Telegram through OpenAB's agentcore-acp bridge.
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
)
from prompts import WORKER_AGENT_SYSTEM_PROMPT

# Configure logging
logging.basicConfig(level=logging.INFO, format="%(asctime)s [%(levelname)s] %(name)s: %(message)s")
logger = logging.getLogger(__name__)

# Initialize the AgentCore application
app = BedrockAgentCoreApp()

# Configure the LLM model
MODEL_ID = os.environ.get("BEDROCK_MODEL_ID", "us.anthropic.claude-sonnet-4-20250514-v1:0")
bedrock_model = BedrockModel(model_id=MODEL_ID)

# Create the agent with all tools
agent = Agent(
    model=bedrock_model,
    system_prompt=WORKER_AGENT_SYSTEM_PROMPT,
    tools=[
        shell_execute,
        git_operation,
        read_file,
        write_file,
        list_directory,
        memory_store,
        memory_recall,
    ],
)


@app.entrypoint
def invoke(payload):
    """
    Handle an incoming invocation from AgentCore Runtime.

    The payload contains a 'prompt' field with the user's message.
    OpenAB sends messages here via the agentcore-acp bridge.
    """
    user_input = payload.get("prompt", "")
    session_id = payload.get("session_id", "")

    if not user_input:
        return "No prompt provided."

    logger.info(f"Received prompt (session={session_id}): {user_input[:100]}...")

    try:
        response = agent(user_input)
        result = response.message["content"][0]["text"]
        logger.info(f"Response generated ({len(result)} chars)")
        return result
    except Exception as e:
        logger.error(f"Agent error: {e}", exc_info=True)
        return f"Agent encountered an error: {e}"


if __name__ == "__main__":
    logger.info(f"Starting Strands Worker Agent (model={MODEL_ID})")
    app.run()
