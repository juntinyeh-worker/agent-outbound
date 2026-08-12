"""Think tool — allows the agent to plan and reason before acting.

This tool gives the agent a scratchpad to think through complex problems
step by step before executing commands. The output is not shown to the user,
it's purely for the agent's internal reasoning.
"""

from strands import tool


@tool
def think(thought: str) -> str:
    """
    Use this tool to think through a problem step by step before acting.
    Call this BEFORE executing complex multi-step tasks to:
    - Break down the problem into steps
    - Identify what information you need
    - Plan the order of operations
    - Consider edge cases and potential failures
    - Decide which tools to use and in what order

    The content of your thinking is internal and helps you reason better.

    Args:
        thought: Your step-by-step reasoning about how to approach the task.

    Returns:
        Acknowledgment that thinking was recorded.
    """
    # The value is in the LLM articulating its plan — the tool itself is a no-op
    return "[thinking recorded — proceed with your plan]"
