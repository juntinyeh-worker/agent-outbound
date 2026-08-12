"""Shell execution tool for the Strands agent."""

import subprocess
import os
from strands import tool


@tool
def shell_execute(command: str, working_dir: str = "", timeout: int = 120) -> str:
    """
    Execute a shell command and return stdout/stderr.

    Args:
        command: The shell command to execute.
        working_dir: Optional working directory. Defaults to /home/agent/workspace.
        timeout: Command timeout in seconds (default 120).

    Returns:
        Combined stdout and stderr output, plus exit code.
    """
    cwd = working_dir or os.environ.get("AGENT_WORKSPACE", "/home/agent/workspace")

    # Ensure workspace exists
    os.makedirs(cwd, exist_ok=True)

    try:
        result = subprocess.run(
            command,
            shell=True,
            capture_output=True,
            text=True,
            cwd=cwd,
            timeout=timeout,
            env={**os.environ, "HOME": "/home/agent", "PATH": os.environ.get("PATH", "/usr/local/bin:/usr/bin:/bin")},
        )

        output = ""
        if result.stdout:
            output += result.stdout
        if result.stderr:
            output += f"\n[stderr]\n{result.stderr}" if output else result.stderr

        output += f"\n[exit_code: {result.returncode}]"

        # Truncate very long outputs
        if len(output) > 50000:
            output = output[:25000] + "\n\n... (truncated) ...\n\n" + output[-25000:]

        return output

    except subprocess.TimeoutExpired:
        return f"[error] Command timed out after {timeout}s: {command}"
    except Exception as e:
        return f"[error] Failed to execute command: {e}"
