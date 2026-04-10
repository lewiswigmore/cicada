"""Cicada MCP server — FastMCP tools for multi-agent team coordination."""

import os
import sqlite3

from mcp.server.fastmcp import FastMCP

from . import db

MAX_ACTIVITY_TURNS = 10
MAX_ACTIVITY_CHARS = 280

# ── Identity from environment ───────────────────────────────────────────
ALIAS = os.environ.get("CICADA_ALIAS", "unknown")
TEAM_ID = os.environ.get("CICADA_TEAM_ID", "default")
DB_PATH = os.environ.get("CICADA_DB", os.path.expanduser("~/.cicada/cicada.db"))

# ── Lazy singleton connection ───────────────────────────────────────────
_conn: sqlite3.Connection | None = None


def _get_db() -> sqlite3.Connection:
    global _conn
    if _conn is None:
        os.makedirs(os.path.dirname(DB_PATH), exist_ok=True)
        _conn = db.init_db(DB_PATH)
    return _conn


def with_meta(result: dict) -> dict:
    """Append _meta (unread count, open tasks) to every tool response."""
    conn = _get_db()
    result["_meta"] = {
        "unread": db.get_unread_count(conn, TEAM_ID, ALIAS),
        "open_tasks": db.get_open_task_count(conn, TEAM_ID),
    }
    return result


# ── FastMCP server ──────────────────────────────────────────────────────
mcp = FastMCP("cicada")


@mcp.tool()
def list_team() -> dict:
    """Return the team roster: alias, role, title, and status for every agent in this team."""
    try:
        conn = _get_db()
        roster = db.get_team(conn, TEAM_ID)
        return with_meta({"team_id": TEAM_ID, "agents": roster})
    except Exception as e:
        return with_meta({"error": str(e)})


@mcp.tool()
def whoami() -> dict:
    """Return this agent's identity: alias, role, title, teammates, unread count, and open tasks."""
    try:
        conn = _get_db()
        me = db.get_agent(conn, TEAM_ID, ALIAS)
        if not me:
            return with_meta({"error": f"Agent '{ALIAS}' not found in team '{TEAM_ID}'"})
        roster = db.get_team(conn, TEAM_ID)
        teammates = [a["alias"] for a in roster if a["alias"] != ALIAS]
        return with_meta({
            "alias": me["alias"],
            "role": me["role"],
            "title": me["title"],
            "team_id": TEAM_ID,
            "teammates": teammates,
        })
    except Exception as e:
        return with_meta({"error": str(e)})


@mcp.tool()
def send_message(to: str | None, text: str, kind: str = "info") -> dict:
    """Send a message to a teammate (by alias) or broadcast to all (to=null).
    Kinds: info, request, response, review-feedback, broadcast."""
    try:
        valid_kinds = {"info", "request", "response", "review-feedback", "broadcast"}
        if kind not in valid_kinds:
            return with_meta({"error": f"Invalid kind. Must be one of: {valid_kinds}"})
        conn = _get_db()
        msg_id = db.send_message(conn, TEAM_ID, ALIAS, to, text, kind)
        return with_meta({"sent": True, "message_id": msg_id, "to": to or "broadcast"})
    except Exception as e:
        return with_meta({"error": str(e)})


@mcp.tool()
def get_messages(
    from_alias: str | None = None,
    kind: str | None = None,
    since: str | None = None,
    unread_only: bool = False,
) -> dict:
    """Read inbox messages (marks them as read). Filter by sender, kind, timestamp, or unread status."""
    try:
        conn = _get_db()
        msgs = db.get_messages(conn, TEAM_ID, ALIAS, from_alias, kind, since, unread_only)
        return with_meta({"messages": msgs, "count": len(msgs)})
    except Exception as e:
        return with_meta({"error": str(e)})


@mcp.tool()
def get_agent_activity(agent: str, limit: int = 5) -> dict:
    """Get summarized recent activity from a teammate's Copilot session.
    Returns short excerpts rather than full raw transcripts."""
    try:
        conn = _get_db()
        teammate = db.get_agent(conn, TEAM_ID, agent)
        if not teammate:
            return with_meta({"error": f"Agent '{agent}' not found in team"})

        session_id = teammate.get("copilot_session_id")
        if not session_id:
            return with_meta({
                "agent": agent,
                "turns": [],
                "note": "No copilot_session_id registered for this agent yet",
            })

        safe_limit = max(1, min(limit, MAX_ACTIVITY_TURNS))
        turns = _query_copilot_db(session_id, safe_limit)
        return with_meta({
            "agent": agent,
            "turns": turns,
            "count": len(turns),
            "limit_applied": safe_limit,
            "note": "Activity is summarized and server-side capped for privacy.",
        })
    except Exception as e:
        return with_meta({"error": str(e)})


@mcp.tool()
def list_tasks(status: str | None = None, claimed_by: str | None = None) -> dict:
    """View the task board. Optionally filter by status (open/claimed/done/blocked) or assignee."""
    try:
        conn = _get_db()
        tasks = db.list_tasks(conn, TEAM_ID, status, claimed_by)
        return with_meta({"tasks": tasks, "count": len(tasks)})
    except Exception as e:
        return with_meta({"error": str(e)})


@mcp.tool()
def create_task(title: str, description: str = "") -> dict:
    """Create a new task on the team board. This agent is recorded as the creator."""
    try:
        conn = _get_db()
        task_id = db.create_task(conn, TEAM_ID, title, description, ALIAS)
        return with_meta({"created": True, "task_id": task_id, "title": title})
    except Exception as e:
        return with_meta({"error": str(e)})


@mcp.tool()
def claim_task(task_id: int) -> dict:
    """Claim an open task. Fails if the task is already claimed or doesn't exist."""
    try:
        conn = _get_db()
        result = db.claim_task(conn, TEAM_ID, task_id, ALIAS)
        return with_meta(result)
    except Exception as e:
        return with_meta({"error": str(e)})


@mcp.tool()
def update_task(task_id: int, status: str) -> dict:
    """Update a task's status. Valid statuses: open, claimed, done, blocked."""
    try:
        conn = _get_db()
        result = db.update_task(conn, TEAM_ID, task_id, status, ALIAS)
        return with_meta(result)
    except Exception as e:
        return with_meta({"error": str(e)})


# ── Copilot session-store query ─────────────────────────────────────────
def _query_copilot_db(session_id: str, limit: int = 5) -> list[dict]:
    """Read-only query of Copilot's session-store.db for agent activity."""
    copilot_db = os.path.expanduser("~/.copilot/session-store.db")
    if not os.path.exists(copilot_db):
        return []
    conn = sqlite3.connect(copilot_db, timeout=3)
    conn.row_factory = sqlite3.Row
    rows = conn.execute(
        "SELECT user_message, assistant_response, timestamp "
        "FROM turns WHERE session_id = ? ORDER BY timestamp DESC LIMIT ?",
        (session_id, limit),
    ).fetchall()
    conn.close()
    return [
        {
            "timestamp": r["timestamp"],
            "user_summary": _summarize_turn_text(r["user_message"]),
            "assistant_summary": _summarize_turn_text(r["assistant_response"]),
        }
        for r in rows
    ]


def _summarize_turn_text(text: str | None) -> str:
    """Return a single-line excerpt instead of a full transcript payload."""
    if not text:
        return ""
    for line in text.splitlines():
        stripped = line.strip()
        if stripped:
            text = stripped
            break
    else:
        text = text.strip()
    if len(text) <= MAX_ACTIVITY_CHARS:
        return text
    return text[: MAX_ACTIVITY_CHARS - 3].rstrip() + "..."
