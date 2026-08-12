"""Git operations tool for the Strands agent."""

import subprocess
import os
from strands import tool


@tool
def git_operation(operation: str, repo_url: str = "", branch: str = "", message: str = "", args: str = "") -> str:
    """
    Perform git operations: clone, status, add, commit, push, pull, log, diff, checkout, branch.

    Args:
        operation: One of: clone, status, add, commit, push, pull, log, diff, checkout, branch, init, fetch, merge, stash.
        repo_url: Repository URL (required for clone).
        branch: Branch name (for checkout, push, branch operations).
        message: Commit message (for commit operation).
        args: Additional arguments to pass to the git command.

    Returns:
        Git command output.
    """
    workspace = os.environ.get("AGENT_WORKSPACE", "/home/agent/workspace")
    os.makedirs(workspace, exist_ok=True)

    # Build the git command based on operation
    if operation == "clone":
        if not repo_url:
            return "[error] repo_url is required for clone operation"
        # Inject GH_TOKEN if available and URL is github
        token = os.environ.get("GH_TOKEN") or os.environ.get("GITHUB_TOKEN")
        if token and "github.com" in repo_url and "x-access-token" not in repo_url:
            repo_url = repo_url.replace("https://", f"https://x-access-token:{token}@")
        cmd = f"git clone {repo_url}"
        if branch:
            cmd += f" --branch {branch}"
        if args:
            cmd += f" {args}"
    elif operation == "status":
        cmd = "git status"
    elif operation == "add":
        target = args or "."
        cmd = f"git add {target}"
    elif operation == "commit":
        if not message:
            return "[error] message is required for commit operation"
        cmd = f'git commit -m "{message}"'
        if args:
            cmd += f" {args}"
    elif operation == "push":
        cmd = "git push"
        if branch:
            cmd += f" -u origin {branch}"
        if args:
            cmd += f" {args}"
    elif operation == "pull":
        cmd = "git pull"
        if branch:
            cmd += f" origin {branch}"
        if args:
            cmd += f" {args}"
    elif operation == "log":
        cmd = f"git log --oneline -20 {args or ''}".strip()
    elif operation == "diff":
        cmd = f"git diff {args or ''}".strip()
    elif operation == "checkout":
        if not branch:
            return "[error] branch is required for checkout operation"
        cmd = f"git checkout {branch}"
        if args:
            cmd += f" {args}"
    elif operation == "branch":
        if branch:
            cmd = f"git checkout -b {branch}"
        else:
            cmd = "git branch -a"
    elif operation == "init":
        cmd = "git init"
    elif operation == "fetch":
        cmd = f"git fetch {args or '--all'}".strip()
    elif operation == "merge":
        if not branch:
            return "[error] branch is required for merge operation"
        cmd = f"git merge {branch}"
    elif operation == "stash":
        cmd = f"git stash {args or ''}".strip()
    else:
        return f"[error] Unknown git operation: {operation}. Supported: clone, status, add, commit, push, pull, log, diff, checkout, branch, init, fetch, merge, stash"

    # Configure git user if not set
    setup_cmds = [
        "git config user.email 'strands-agent@openab.worker' 2>/dev/null || true",
        "git config user.name 'Strands Agent' 2>/dev/null || true",
    ]

    try:
        for setup in setup_cmds:
            subprocess.run(setup, shell=True, cwd=workspace, capture_output=True, timeout=10)

        result = subprocess.run(
            cmd,
            shell=True,
            capture_output=True,
            text=True,
            cwd=workspace,
            timeout=120,
            env={**os.environ, "GIT_TERMINAL_PROMPT": "0"},
        )

        output = ""
        if result.stdout:
            output += result.stdout
        if result.stderr:
            # Git often writes progress to stderr, include it
            output += f"\n{result.stderr}" if output else result.stderr

        if result.returncode != 0:
            output += f"\n[exit_code: {result.returncode}]"

        return output.strip() or f"[ok] {operation} completed successfully"

    except subprocess.TimeoutExpired:
        return f"[error] Git operation timed out: {cmd}"
    except Exception as e:
        return f"[error] Git operation failed: {e}"
