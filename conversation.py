"""Conversation history — provides multi-turn context for the Strands agent.

AgentCore keeps the same microVM alive per session, but the Strands Agent
itself is stateless per invocation. This module persists conversation history
to the filesystem so the agent has full multi-turn context.

Usage in main.py:
    from conversation import ConversationHistory
    history = ConversationHistory()

    # Before invoking the agent, build the messages array:
    messages = history.get_messages(session_id)
    messages.append({"role": "user", "content": [{"text": user_input}]})

    response = agent(messages=messages)

    # After response, save the turn:
    history.add_turn(session_id, user_input, response_text)
"""

import json
import os
import time
from typing import List, Dict, Any, Optional


class ConversationHistory:
    """Manages multi-turn conversation history with persistent file storage."""

    def __init__(self, storage_dir: Optional[str] = None, max_turns: int = 50, max_context_chars: int = 100_000):
        """
        Args:
            storage_dir: Directory to store conversation files. Defaults to workspace/.conversations/
            max_turns: Maximum number of turns to keep per session (older ones are evicted).
            max_context_chars: Maximum total characters to include in context (prevents token overflow).
        """
        self.storage_dir = storage_dir or os.path.join(
            os.environ.get("AGENT_WORKSPACE", "/home/agent/workspace"),
            ".conversations"
        )
        self.max_turns = max_turns
        self.max_context_chars = max_context_chars
        os.makedirs(self.storage_dir, exist_ok=True)

    def _session_file(self, session_id: str) -> str:
        """Get the file path for a session's history."""
        # Sanitize session_id for filesystem
        safe_id = "".join(c if c.isalnum() or c in "-_" else "_" for c in session_id)
        return os.path.join(self.storage_dir, f"{safe_id}.json")

    def _load_session(self, session_id: str) -> Dict[str, Any]:
        """Load a session from disk."""
        filepath = self._session_file(session_id)
        if os.path.exists(filepath):
            try:
                with open(filepath, "r") as f:
                    return json.load(f)
            except (json.JSONDecodeError, IOError):
                return {"turns": [], "created_at": time.time()}
        return {"turns": [], "created_at": time.time()}

    def _save_session(self, session_id: str, data: Dict[str, Any]):
        """Save a session to disk."""
        filepath = self._session_file(session_id)
        with open(filepath, "w") as f:
            json.dump(data, f, indent=2)

    def add_turn(self, session_id: str, user_message: str, assistant_response: str):
        """
        Record a conversation turn (user + assistant pair).

        Args:
            session_id: Unique session/thread identifier.
            user_message: What the user said.
            assistant_response: What the agent replied.
        """
        session = self._load_session(session_id)

        session["turns"].append({
            "user": user_message,
            "assistant": assistant_response,
            "timestamp": time.time(),
        })

        # Evict old turns if over limit
        if len(session["turns"]) > self.max_turns:
            session["turns"] = session["turns"][-self.max_turns:]

        session["updated_at"] = time.time()
        self._save_session(session_id, session)

    def get_messages(self, session_id: str) -> List[Dict[str, Any]]:
        """
        Get conversation history formatted as Bedrock message array.

        Returns messages in the format expected by Strands Agent:
        [
            {"role": "user", "content": [{"text": "..."}]},
            {"role": "assistant", "content": [{"text": "..."}]},
            ...
        ]

        Applies context window management — trims old messages if total
        characters exceed max_context_chars.

        Args:
            session_id: Unique session/thread identifier.

        Returns:
            List of message dicts ready for the agent.
        """
        session = self._load_session(session_id)
        turns = session.get("turns", [])

        if not turns:
            return []

        # Build messages from most recent backward, respecting char budget
        messages = []
        total_chars = 0

        for turn in reversed(turns):
            user_text = turn["user"]
            assistant_text = turn["assistant"]
            turn_chars = len(user_text) + len(assistant_text)

            if total_chars + turn_chars > self.max_context_chars and messages:
                break  # Stop adding older turns

            # Prepend (since we're iterating in reverse)
            messages.insert(0, {"role": "assistant", "content": [{"text": assistant_text}]})
            messages.insert(0, {"role": "user", "content": [{"text": user_text}]})
            total_chars += turn_chars

        return messages

    def get_summary(self, session_id: str) -> str:
        """
        Get a brief summary of the conversation history for a session.

        Args:
            session_id: Unique session/thread identifier.

        Returns:
            Summary string with turn count and time range.
        """
        session = self._load_session(session_id)
        turns = session.get("turns", [])

        if not turns:
            return f"[no history for session {session_id}]"

        first_time = time.strftime("%Y-%m-%d %H:%M", time.gmtime(turns[0]["timestamp"]))
        last_time = time.strftime("%Y-%m-%d %H:%M", time.gmtime(turns[-1]["timestamp"]))

        return f"Session {session_id}: {len(turns)} turns ({first_time} → {last_time})"

    def clear_session(self, session_id: str):
        """Clear history for a session."""
        filepath = self._session_file(session_id)
        if os.path.exists(filepath):
            os.remove(filepath)

    def list_sessions(self) -> List[str]:
        """List all active session IDs."""
        sessions = []
        for filename in os.listdir(self.storage_dir):
            if filename.endswith(".json"):
                sessions.append(filename[:-5])
        return sessions
