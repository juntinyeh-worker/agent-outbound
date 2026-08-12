"""Memory tool for the Strands agent — persistent key-value store with semantic search."""

import json
import os
import time
from typing import Optional
from strands import tool

# In-memory store backed by a JSON file on persistent storage
_MEMORY_FILE = os.environ.get("AGENT_MEMORY_FILE", "/home/agent/workspace/.agent_memory.json")


def _load_memory() -> dict:
    """Load memory from persistent file."""
    if os.path.exists(_MEMORY_FILE):
        try:
            with open(_MEMORY_FILE, "r") as f:
                return json.load(f)
        except (json.JSONDecodeError, IOError):
            return {"entries": {}, "sessions": {}}
    return {"entries": {}, "sessions": {}}


def _save_memory(memory: dict):
    """Save memory to persistent file."""
    os.makedirs(os.path.dirname(_MEMORY_FILE), exist_ok=True)
    with open(_MEMORY_FILE, "w") as f:
        json.dump(memory, f, indent=2)


@tool
def memory_store(key: str, value: str, category: str = "general", session_id: str = "") -> str:
    """
    Store a key-value pair in persistent memory. Use this to remember important information
    across conversations: project context, decisions made, user preferences, task progress.

    Args:
        key: A descriptive key for retrieval (e.g., "project_structure", "user_preference_language").
        value: The information to store.
        category: Category for grouping (e.g., "project", "preference", "task", "context").
        session_id: Optional session ID to namespace memories.

    Returns:
        Confirmation message.
    """
    memory = _load_memory()

    entry = {
        "value": value,
        "category": category,
        "timestamp": time.time(),
        "updated_at": time.strftime("%Y-%m-%d %H:%M:%S UTC", time.gmtime()),
    }

    if session_id:
        if session_id not in memory["sessions"]:
            memory["sessions"][session_id] = {}
        memory["sessions"][session_id][key] = entry
    else:
        memory["entries"][key] = entry

    _save_memory(memory)
    return f"[ok] Stored memory: '{key}' in category '{category}'"


@tool
def memory_recall(query: str = "", key: str = "", category: str = "", session_id: str = "", limit: int = 10) -> str:
    """
    Recall information from persistent memory. Search by key, category, or text query.

    Args:
        query: Text to search for in keys and values (fuzzy match).
        key: Exact key to retrieve.
        category: Filter by category.
        session_id: Filter by session.
        limit: Maximum number of results to return (default 10).

    Returns:
        Matching memory entries as formatted text.
    """
    memory = _load_memory()

    results = []

    # Determine search space
    if session_id and session_id in memory.get("sessions", {}):
        search_space = memory["sessions"][session_id]
    elif session_id:
        return f"[info] No memories found for session: {session_id}"
    else:
        search_space = memory.get("entries", {})
        # Also include all session entries if no session filter
        for sid, entries in memory.get("sessions", {}).items():
            for k, v in entries.items():
                search_space[f"[{sid}] {k}"] = v

    # Exact key lookup
    if key:
        if key in search_space:
            entry = search_space[key]
            return f"**{key}** ({entry.get('category', 'general')}, {entry.get('updated_at', 'unknown')})\n{entry['value']}"
        return f"[info] No memory found for key: {key}"

    # Category filter
    if category:
        for k, entry in search_space.items():
            if entry.get("category") == category:
                results.append((k, entry))
    elif query:
        # Text search in keys and values
        query_lower = query.lower()
        for k, entry in search_space.items():
            score = 0
            if query_lower in k.lower():
                score += 2
            if query_lower in entry.get("value", "").lower():
                score += 1
            if query_lower in entry.get("category", "").lower():
                score += 1
            if score > 0:
                results.append((k, entry, score))
        # Sort by relevance
        results.sort(key=lambda x: x[2] if len(x) > 2 else 0, reverse=True)
    else:
        # Return all (recent first)
        results = [(k, entry) for k, entry in search_space.items()]
        results.sort(key=lambda x: x[1].get("timestamp", 0), reverse=True)

    if not results:
        return "[info] No memories found matching your query."

    # Format output
    output_lines = [f"Found {min(len(results), limit)} of {len(results)} memories:\n"]
    for item in results[:limit]:
        k = item[0]
        entry = item[1]
        value_preview = entry["value"][:200] + "..." if len(entry["value"]) > 200 else entry["value"]
        output_lines.append(f"• **{k}** [{entry.get('category', 'general')}] ({entry.get('updated_at', '')})")
        output_lines.append(f"  {value_preview}\n")

    return "\n".join(output_lines)
