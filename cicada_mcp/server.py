"""Cicada MCP server — FastMCP tools for multi-agent team coordination."""

import os
import sqlite3

from mcp.server.fastmcp import FastMCP

from . import db

MAX_ACTIVITY_TURNS = 10

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
mcp = FastMCP(
    "cicada",
    instructions=(
        "Cicada is a multi-agent team coordination server. "
        "Use these tools to collaborate with your teammates: "
        "check your identity, read the task board, claim and update tasks, "
        "and send messages to other agents. "
        "Always check the board for work before declaring you are done."
    ),
)


@mcp.tool()
def list_team() -> dict:
    """List all agents on your team with their alias, role, and current status."""
    try:
        conn = _get_db()
        roster = db.get_team(conn, TEAM_ID)
        return with_meta({"team_id": TEAM_ID, "agents": roster})
    except Exception as e:
        return with_meta({"error": str(e)})


@mcp.tool()
def whoami() -> dict:
    """Check your own identity, role, teammate list, and pending work summary."""
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
    """Send a message to a teammate by alias, or broadcast to the whole team (to=null). Use kind to categorize: info, request, response, review-feedback, broadcast."""
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
    """Read your inbox messages (marks them as read). Check unread_only=true first to see new messages from teammates."""
    try:
        conn = _get_db()
        msgs = db.get_messages(conn, TEAM_ID, ALIAS, from_alias, kind, since, unread_only)
        return with_meta({"messages": msgs, "count": len(msgs)})
    except Exception as e:
        return with_meta({"error": str(e)})


@mcp.tool()
def get_agent_activity(agent: str, limit: int = 5) -> dict:
    """Peek at a teammate's recent activity — messages they sent and tasks they claimed or updated."""
    try:
        conn = _get_db()
        teammate = db.get_agent(conn, TEAM_ID, agent)
        if not teammate:
            return with_meta({"error": f"Agent '{agent}' not found in team"})

        safe_limit = max(1, min(limit, MAX_ACTIVITY_TURNS))
        activity = db.get_agent_activity(conn, TEAM_ID, agent, safe_limit)
        return with_meta({
            "agent": agent,
            "activity": activity,
            "count": len(activity),
        })
    except Exception as e:
        return with_meta({"error": str(e)})


@mcp.tool()
def list_tasks(status: str | None = None, claimed_by: str | None = None) -> dict:
    """View all tasks on the shared team board. Filter by status (open/in-progress/done/blocked/needs-rework) or by assignee alias."""
    try:
        conn = _get_db()
        tasks = db.list_tasks(conn, TEAM_ID, status, claimed_by)
        return with_meta({"tasks": tasks, "count": len(tasks)})
    except Exception as e:
        return with_meta({"error": str(e)})


@mcp.tool()
def create_task(title: str, description: str = "") -> dict:
    """Add a new task to the shared team board for teammates to pick up."""
    try:
        conn = _get_db()
        task_id = db.create_task(conn, TEAM_ID, title, description, ALIAS)
        return with_meta({"created": True, "task_id": task_id, "title": title})
    except Exception as e:
        return with_meta({"error": str(e)})


@mcp.tool()
def claim_task(task_id: int) -> dict:
    """Claim an open or needs-rework task and mark it in-progress so other agents know you are working on it. Must claim before starting work."""
    try:
        conn = _get_db()
        result = db.claim_task(conn, TEAM_ID, task_id, ALIAS)
        return with_meta(result)
    except Exception as e:
        return with_meta({"error": str(e)})


@mcp.tool()
def update_task(task_id: int, status: str) -> dict:
    """Update a task's status to: open, in-progress, done, blocked, or needs-rework. Use needs-rework to send a task back for fixes after review or testing."""
    try:
        conn = _get_db()
        result = db.update_task(conn, TEAM_ID, task_id, status, ALIAS)
        return with_meta(result)
    except Exception as e:
        return with_meta({"error": str(e)})

