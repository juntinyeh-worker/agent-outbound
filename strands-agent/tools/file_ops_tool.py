"""File operations tools for the Strands agent."""

import os
from strands import tool


@tool
def read_file(file_path: str, start_line: int = 0, end_line: int = 0) -> str:
    """
    Read the contents of a file.

    Args:
        file_path: Path to the file to read (relative to workspace or absolute).
        start_line: Optional start line (1-indexed). 0 means from beginning.
        end_line: Optional end line (1-indexed). 0 means to end of file.

    Returns:
        File contents (with line numbers if partial read).
    """
    workspace = os.environ.get("AGENT_WORKSPACE", "/home/agent/workspace")

    # Resolve path
    if not os.path.isabs(file_path):
        file_path = os.path.join(workspace, file_path)

    if not os.path.exists(file_path):
        return f"[error] File not found: {file_path}"

    if not os.path.isfile(file_path):
        return f"[error] Not a file: {file_path}"

    # Check file size
    size = os.path.getsize(file_path)
    if size > 1_000_000:  # 1MB limit
        return f"[error] File too large ({size} bytes). Use start_line/end_line to read a portion."

    try:
        with open(file_path, "r", encoding="utf-8", errors="replace") as f:
            lines = f.readlines()

        if start_line > 0 or end_line > 0:
            start = max(0, start_line - 1)
            end = end_line if end_line > 0 else len(lines)
            selected = lines[start:end]
            # Include line numbers for partial reads
            numbered = [f"{start + i + 1:4d} | {line}" for i, line in enumerate(selected)]
            return "".join(numbered)
        else:
            return "".join(lines)

    except Exception as e:
        return f"[error] Failed to read file: {e}"


@tool
def write_file(file_path: str, content: str, mode: str = "overwrite") -> str:
    """
    Write content to a file. Creates parent directories if needed.

    Args:
        file_path: Path to the file (relative to workspace or absolute).
        content: The content to write.
        mode: Write mode - "overwrite" (default), "append", or "insert_at:N" where N is line number.

    Returns:
        Success or error message.
    """
    workspace = os.environ.get("AGENT_WORKSPACE", "/home/agent/workspace")

    # Resolve path
    if not os.path.isabs(file_path):
        file_path = os.path.join(workspace, file_path)

    try:
        # Create parent directories
        os.makedirs(os.path.dirname(file_path), exist_ok=True)

        if mode == "overwrite":
            with open(file_path, "w", encoding="utf-8") as f:
                f.write(content)
        elif mode == "append":
            with open(file_path, "a", encoding="utf-8") as f:
                f.write(content)
        elif mode.startswith("insert_at:"):
            line_num = int(mode.split(":")[1])
            if os.path.exists(file_path):
                with open(file_path, "r", encoding="utf-8") as f:
                    lines = f.readlines()
            else:
                lines = []

            # Insert at specified line
            insert_idx = max(0, min(line_num - 1, len(lines)))
            content_lines = content.splitlines(keepends=True)
            if content_lines and not content_lines[-1].endswith("\n"):
                content_lines[-1] += "\n"
            lines[insert_idx:insert_idx] = content_lines

            with open(file_path, "w", encoding="utf-8") as f:
                f.writelines(lines)
        else:
            return f"[error] Unknown mode: {mode}. Use 'overwrite', 'append', or 'insert_at:N'"

        size = os.path.getsize(file_path)
        return f"[ok] Written {size} bytes to {file_path}"

    except Exception as e:
        return f"[error] Failed to write file: {e}"


@tool
def list_directory(dir_path: str = "", recursive: bool = False, max_depth: int = 2) -> str:
    """
    List contents of a directory.

    Args:
        dir_path: Directory path (relative to workspace or absolute). Defaults to workspace root.
        recursive: If True, list recursively up to max_depth.
        max_depth: Maximum recursion depth (default 2).

    Returns:
        Directory listing with file types and sizes.
    """
    workspace = os.environ.get("AGENT_WORKSPACE", "/home/agent/workspace")

    # Resolve path
    if not dir_path:
        dir_path = workspace
    elif not os.path.isabs(dir_path):
        dir_path = os.path.join(workspace, dir_path)

    if not os.path.exists(dir_path):
        return f"[error] Directory not found: {dir_path}"

    if not os.path.isdir(dir_path):
        return f"[error] Not a directory: {dir_path}"

    skip_dirs = {".git", "node_modules", "__pycache__", ".venv", "venv", ".cache", "dist", "build", "target"}

    def list_dir(path, prefix="", depth=0):
        entries = []
        try:
            items = sorted(os.listdir(path))
        except PermissionError:
            return [f"{prefix}[permission denied]"]

        for item in items:
            if item in skip_dirs:
                continue

            full_path = os.path.join(path, item)
            if os.path.isdir(full_path):
                entries.append(f"{prefix}{item}/")
                if recursive and depth < max_depth:
                    entries.extend(list_dir(full_path, prefix + "  ", depth + 1))
            else:
                size = os.path.getsize(full_path)
                if size > 1_000_000:
                    size_str = f"{size / 1_000_000:.1f}MB"
                elif size > 1000:
                    size_str = f"{size / 1000:.1f}KB"
                else:
                    size_str = f"{size}B"
                entries.append(f"{prefix}{item} ({size_str})")

        return entries

    entries = list_dir(dir_path)

    if not entries:
        return f"[empty directory] {dir_path}"

    # Limit output
    if len(entries) > 200:
        entries = entries[:200]
        entries.append(f"\n... ({len(entries) - 200} more entries truncated)")

    return "\n".join(entries)
