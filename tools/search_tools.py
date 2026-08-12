"""Search tools — grep and find for navigating codebases."""

import os
import re
import fnmatch
from strands import tool


@tool
def grep_search(pattern: str, path: str = "", file_glob: str = "", case_sensitive: bool = False, max_results: int = 50) -> str:
    """
    Search for a regex pattern in files. Like grep -rn.

    Use this to find:
    - Function/class definitions
    - Usages of a symbol
    - Error messages or log strings
    - Config values or TODO comments

    Args:
        pattern: Regex pattern to search for.
        path: Directory to search in (relative to workspace or absolute). Defaults to workspace root.
        file_glob: Optional file filter (e.g., "*.py", "*.ts", "*.yaml"). Empty = all files.
        case_sensitive: Whether the search is case-sensitive (default: False).
        max_results: Maximum number of matching lines to return (default: 50).

    Returns:
        Matching lines with file paths and line numbers.
    """
    workspace = os.environ.get("AGENT_WORKSPACE", "/home/agent/workspace")

    if not path:
        search_path = workspace
    elif not os.path.isabs(path):
        search_path = os.path.join(workspace, path)
    else:
        search_path = path

    if not os.path.exists(search_path):
        return f"[error] Path not found: {search_path}"

    skip_dirs = {".git", "node_modules", "__pycache__", ".venv", "venv", ".cache", "dist", "build", "target", ".mypy_cache"}
    skip_extensions = {".pyc", ".pyo", ".so", ".dylib", ".bin", ".exe", ".png", ".jpg", ".gif", ".ico", ".woff", ".ttf"}

    flags = 0 if case_sensitive else re.IGNORECASE
    try:
        compiled = re.compile(pattern, flags)
    except re.error as e:
        return f"[error] Invalid regex pattern: {e}"

    results = []
    files_searched = 0

    for root, dirs, files in os.walk(search_path):
        # Skip excluded directories
        dirs[:] = [d for d in dirs if d not in skip_dirs]

        for filename in files:
            # Skip binary extensions
            ext = os.path.splitext(filename)[1].lower()
            if ext in skip_extensions:
                continue

            # Apply file glob filter
            if file_glob and not fnmatch.fnmatch(filename, file_glob):
                continue

            filepath = os.path.join(root, filename)
            rel_path = os.path.relpath(filepath, workspace)
            files_searched += 1

            try:
                with open(filepath, "r", encoding="utf-8", errors="ignore") as f:
                    for line_num, line in enumerate(f, 1):
                        if compiled.search(line):
                            results.append(f"{rel_path}:{line_num}: {line.rstrip()}")
                            if len(results) >= max_results:
                                break
            except (IOError, OSError):
                continue

            if len(results) >= max_results:
                break

        if len(results) >= max_results:
            break

    if not results:
        return f"[no matches] Pattern '{pattern}' not found in {files_searched} files searched."

    header = f"Found {len(results)} matches (searched {files_searched} files):\n"
    output = header + "\n".join(results)

    if len(results) >= max_results:
        output += f"\n\n[truncated — showing first {max_results} results]"

    return output


@tool
def find_files(name_pattern: str = "", path: str = "", file_type: str = "", max_results: int = 50) -> str:
    """
    Find files by name pattern. Like find + glob matching.

    Use this to:
    - Discover project structure
    - Find config files (*.yaml, *.toml, *.json)
    - Locate test files
    - Find files by extension

    Args:
        name_pattern: Glob pattern for filename (e.g., "*.py", "test_*", "Dockerfile*"). Empty = all files.
        path: Directory to search (relative to workspace or absolute). Defaults to workspace root.
        file_type: Filter by type: "file", "dir", or "" (both).
        max_results: Maximum number of results (default: 50).

    Returns:
        List of matching file/directory paths with sizes.
    """
    workspace = os.environ.get("AGENT_WORKSPACE", "/home/agent/workspace")

    if not path:
        search_path = workspace
    elif not os.path.isabs(path):
        search_path = os.path.join(workspace, path)
    else:
        search_path = path

    if not os.path.exists(search_path):
        return f"[error] Path not found: {search_path}"

    skip_dirs = {".git", "node_modules", "__pycache__", ".venv", "venv", ".cache", "dist", "build", "target"}

    results = []

    for root, dirs, files in os.walk(search_path):
        dirs[:] = [d for d in dirs if d not in skip_dirs]

        # Check directories
        if file_type != "file":
            for d in dirs:
                if not name_pattern or fnmatch.fnmatch(d, name_pattern):
                    rel_path = os.path.relpath(os.path.join(root, d), workspace)
                    results.append(f"{rel_path}/")
                    if len(results) >= max_results:
                        break

        # Check files
        if file_type != "dir":
            for filename in files:
                if not name_pattern or fnmatch.fnmatch(filename, name_pattern):
                    filepath = os.path.join(root, filename)
                    rel_path = os.path.relpath(filepath, workspace)
                    size = os.path.getsize(filepath)
                    if size > 1_000_000:
                        size_str = f"{size / 1_000_000:.1f}MB"
                    elif size > 1000:
                        size_str = f"{size / 1000:.1f}KB"
                    else:
                        size_str = f"{size}B"
                    results.append(f"{rel_path} ({size_str})")
                    if len(results) >= max_results:
                        break

        if len(results) >= max_results:
            break

    if not results:
        filter_desc = f" matching '{name_pattern}'" if name_pattern else ""
        return f"[no results] No files{filter_desc} found in {search_path}"

    output = "\n".join(results)
    if len(results) >= max_results:
        output += f"\n\n[truncated — showing first {max_results} results]"

    return output
