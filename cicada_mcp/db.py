"""Cicada MCP — SQLite schema and query layer."""

import json
import sqlite3
from datetime import datetime, timezone

SCHEMA_VERSION = 1

_SCHEMA_SQL = """
CREATE TABLE IF NOT EXISTS schema_version (
    version    INTEGER PRIMARY KEY,
    applied_at TEXT DEFAULT (datetime('now'))
);

CREATE TABLE IF NOT EXISTS teams (
    team_id     TEXT PRIMARY KEY,
    launched_at TEXT NOT NULL,
    work_dir    TEXT NOT NULL,
    status      TEXT DEFAULT 'running',
    config      TEXT
);

CREATE TABLE IF NOT EXISTS agents (
    agent_id           TEXT PRIMARY KEY,
    team_id            TEXT NOT NULL REFERENCES teams(team_id),
    alias              TEXT NOT NULL,
    role               TEXT NOT NULL,
    title              TEXT NOT NULL,
    color              TEXT,
    copilot_session_id TEXT,
    status             TEXT DEFAULT 'active',
    UNIQUE(team_id, alias)
);

CREATE TABLE IF NOT EXISTS messages (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    team_id     TEXT NOT NULL REFERENCES teams(team_id),
    from_alias  TEXT NOT NULL,
    to_alias    TEXT,
    kind        TEXT NOT NULL DEFAULT 'info',
    payload     TEXT NOT NULL,
    read        INTEGER DEFAULT 0,
    reply_to    INTEGER REFERENCES messages(id),
    created_at  TEXT DEFAULT (datetime('now'))
);
CREATE INDEX IF NOT EXISTS idx_msg_team ON messages(team_id, created_at);
CREATE INDEX IF NOT EXISTS idx_msg_to   ON messages(to_alias, read);

CREATE TABLE IF NOT EXISTS tasks (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    team_id     TEXT NOT NULL REFERENCES teams(team_id),
    title       TEXT NOT NULL,
    description TEXT,
    status      TEXT DEFAULT 'open',
    claimed_by  TEXT,
    created_by  TEXT NOT NULL,
    created_at  TEXT DEFAULT (datetime('now')),
    updated_at  TEXT DEFAULT (datetime('now'))
);
CREATE INDEX IF NOT EXISTS idx_tasks_team ON tasks(team_id, status);

CREATE TABLE IF NOT EXISTS task_events (
    id         INTEGER PRIMARY KEY AUTOINCREMENT,
    team_id    TEXT NOT NULL REFERENCES teams(team_id),
    task_id    INTEGER NOT NULL REFERENCES tasks(id),
    event      TEXT NOT NULL,
    agent      TEXT NOT NULL,
    detail     TEXT,
    created_at TEXT DEFAULT (datetime('now'))
);
CREATE INDEX IF NOT EXISTS idx_taskevt_team ON task_events(team_id, agent, created_at);
"""


def init_db(db_path: str) -> sqlite3.Connection:
    """Create all v1 tables if they don't exist. Returns an open connection."""
    conn = sqlite3.connect(db_path, timeout=10)
    conn.execute("PRAGMA journal_mode=WAL")
    conn.execute("PRAGMA foreign_keys=ON")
    conn.row_factory = sqlite3.Row
    conn.executescript(_SCHEMA_SQL)

    # Migrate legacy 'claimed' status to 'in-progress'
    conn.execute(
        "UPDATE tasks SET status = 'in-progress' WHERE status = 'claimed'"
    )

    # Record schema version (idempotent)
    existing = conn.execute(
        "SELECT version FROM schema_version WHERE version = ?", (SCHEMA_VERSION,)
    ).fetchone()
    if not existing:
        conn.execute(
            "INSERT INTO schema_version (version) VALUES (?)", (SCHEMA_VERSION,)
        )
    conn.commit()
    return conn


def register_team(
    db: sqlite3.Connection,
    team_id: str,
    work_dir: str,
    agents_config: list[dict],
) -> None:
    """Insert a team and its agents. Skips if team already exists."""
    now = datetime.now(timezone.utc).isoformat()
    existing_sessions: dict[str, str] = {}
    try:
        db.execute(
            "INSERT INTO teams (team_id, launched_at, work_dir, config) VALUES (?, ?, ?, ?)",
            (team_id, now, work_dir, json.dumps(agents_config)),
        )
    except sqlite3.IntegrityError:
        rows = db.execute(
            "SELECT alias, copilot_session_id FROM agents WHERE team_id = ?",
            (team_id,),
        ).fetchall()
        existing_sessions = {
            r["alias"]: r["copilot_session_id"]
            for r in rows
            if r["copilot_session_id"]
        }
        # Team already exists — update config instead
        db.execute(
            "UPDATE teams SET config = ?, work_dir = ?, status = 'running' WHERE team_id = ?",
            (json.dumps(agents_config), work_dir, team_id),
        )
        # Remove old agents for re-registration
        db.execute("DELETE FROM agents WHERE team_id = ?", (team_id,))

    for agent in agents_config:
        session_id = agent.get("copilot_session_id") or existing_sessions.get(
            agent["alias"]
        )
        db.execute(
            "INSERT OR REPLACE INTO agents (agent_id, team_id, alias, role, title, color, copilot_session_id) "
            "VALUES (?, ?, ?, ?, ?, ?, ?)",
            (
                agent["agent_id"],
                team_id,
                agent["alias"],
                agent["role"],
                agent["title"],
                agent.get("color"),
                session_id,
            ),
        )
    db.commit()


def set_agent_session(
    db: sqlite3.Connection, team_id: str, alias: str, session_id: str
) -> bool:
    """Persist the Copilot session ID for an agent."""
    cur = db.execute(
        "UPDATE agents SET copilot_session_id = ? WHERE team_id = ? AND alias = ?",
        (session_id, team_id, alias),
    )
    db.commit()
    return cur.rowcount > 0


def get_team(db: sqlite3.Connection, team_id: str) -> list[dict]:
    """Return team roster — all agents for a team."""
    rows = db.execute(
        "SELECT alias, role, title, color, status, copilot_session_id "
        "FROM agents WHERE team_id = ? ORDER BY alias",
        (team_id,),
    ).fetchall()
    return [dict(r) for r in rows]


def get_agent(db: sqlite3.Connection, team_id: str, alias: str) -> dict | None:
    """Return a single agent by team + alias."""
    row = db.execute(
        "SELECT agent_id, alias, role, title, color, status, copilot_session_id "
        "FROM agents WHERE team_id = ? AND alias = ?",
        (team_id, alias),
    ).fetchone()
    return dict(row) if row else None


def send_message(
    db: sqlite3.Connection,
    team_id: str,
    from_alias: str,
    to_alias: str | None,
    text: str,
    kind: str = "info",
    reply_to: int | None = None,
) -> int:
    """Insert a message. Returns the new message id."""
    cur = db.execute(
        "INSERT INTO messages (team_id, from_alias, to_alias, kind, payload, reply_to) "
        "VALUES (?, ?, ?, ?, ?, ?)",
        (team_id, from_alias, to_alias, kind, text, reply_to),
    )
    db.commit()
    return cur.lastrowid


def get_messages(
    db: sqlite3.Connection,
    team_id: str,
    to_alias: str,
    from_alias: str | None = None,
    kind: str | None = None,
    since: str | None = None,
    unread_only: bool = False,
) -> list[dict]:
    """Fetch messages for an agent and mark them as read."""
    clauses = ["team_id = ?", "(to_alias = ? OR to_alias IS NULL)"]
    params: list = [team_id, to_alias]

    if from_alias:
        clauses.append("from_alias = ?")
        params.append(from_alias)
    if kind:
        clauses.append("kind = ?")
        params.append(kind)
    if since:
        clauses.append("created_at >= ?")
        params.append(since)
    if unread_only:
        clauses.append("read = 0")

    where = " AND ".join(clauses)
    query = (
        "SELECT id, from_alias, to_alias, kind, payload, read, reply_to, created_at "
        + "FROM messages WHERE "
        + where
        + " ORDER BY created_at ASC"
    )
    rows = db.execute(query, params).fetchall()
    result = [dict(r) for r in rows]

    # Mark fetched messages as read
    if result:
        ids = [r["id"] for r in result]
        placeholders = ",".join("?" * len(ids))
        query = "UPDATE messages SET read = 1 WHERE id IN (" + placeholders + ")"
        db.execute(query, ids)
        db.commit()

    return result


def get_unread_count(db: sqlite3.Connection, team_id: str, alias: str) -> int:
    """Count unread messages for an agent (direct + broadcasts)."""
    row = db.execute(
        "SELECT COUNT(*) as cnt FROM messages "
        "WHERE team_id = ? AND (to_alias = ? OR to_alias IS NULL) AND read = 0",
        (team_id, alias),
    ).fetchone()
    return row["cnt"] if row else 0


def get_open_task_count(db: sqlite3.Connection, team_id: str) -> int:
    """Count open tasks for a team."""
    row = db.execute(
        "SELECT COUNT(*) as cnt FROM tasks WHERE team_id = ? AND status = 'open'",
        (team_id,),
    ).fetchone()
    return row["cnt"] if row else 0


def get_pending_summary(
    db: sqlite3.Connection, team_id: str, alias: str
) -> dict:
    """Return pending work counts for an agent: unread messages, open tasks, needs-rework tasks, and in-progress tasks."""
    unread = get_unread_count(db, team_id, alias)
    open_tasks = get_open_task_count(db, team_id)
    row = db.execute(
        "SELECT COUNT(*) as cnt FROM tasks "
        "WHERE team_id = ? AND status = 'in-progress' AND claimed_by = ?",
        (team_id, alias),
    ).fetchone()
    in_progress_tasks = row["cnt"] if row else 0
    # Count needs-rework tasks (available for any implementer to re-claim)
    row = db.execute(
        "SELECT COUNT(*) as cnt FROM tasks "
        "WHERE team_id = ? AND status = 'needs-rework'",
        (team_id,),
    ).fetchone()
    rework_tasks = row["cnt"] if row else 0
    return {
        "unread": unread,
        "open_tasks": open_tasks,
        "in_progress_tasks": in_progress_tasks,
        "rework_tasks": rework_tasks,
    }


def create_task(
    db: sqlite3.Connection,
    team_id: str,
    title: str,
    description: str,
    created_by: str,
) -> int:
    """Insert a task. Returns the new task id."""
    cur = db.execute(
        "INSERT INTO tasks (team_id, title, description, created_by) VALUES (?, ?, ?, ?)",
        (team_id, title, description, created_by),
    )
    task_id = cur.lastrowid
    db.execute(
        "INSERT INTO task_events (team_id, task_id, event, agent, detail) VALUES (?, ?, 'created', ?, ?)",
        (team_id, task_id, created_by, title[:120]),
    )
    db.commit()
    return task_id


def list_tasks(
    db: sqlite3.Connection,
    team_id: str,
    status: str | None = None,
    claimed_by: str | None = None,
) -> list[dict]:
    """List tasks with optional filters."""
    clauses = ["team_id = ?"]
    params: list = [team_id]

    if status:
        clauses.append("status = ?")
        params.append(status)
    if claimed_by:
        clauses.append("claimed_by = ?")
        params.append(claimed_by)

    where = " AND ".join(clauses)
    query = (
        "SELECT id, title, description, status, claimed_by, created_by, created_at, updated_at "
        + "FROM tasks WHERE "
        + where
        + " ORDER BY created_at DESC"
    )
    rows = db.execute(query, params).fetchall()
    return [dict(r) for r in rows]


def claim_task(
    db: sqlite3.Connection, team_id: str, task_id: int, alias: str
) -> dict:
    """Claim an open or needs-rework task. Uses a transaction to prevent races."""
    row = db.execute(
        "SELECT id, status, claimed_by FROM tasks WHERE id = ? AND team_id = ?",
        (task_id, team_id),
    ).fetchone()

    if not row:
        return {"success": False, "error": "Task not found"}
    if row["status"] not in ("open", "needs-rework"):
        return {
            "success": False,
            "error": f"Task already {row['status']} by {row['claimed_by']}",
        }

    cur = db.execute(
        "UPDATE tasks SET status = 'in-progress', claimed_by = ?, "
        "updated_at = datetime('now') WHERE id = ? AND status IN ('open', 'needs-rework')",
        (alias, task_id),
    )
    if cur.rowcount == 0:
        # Race: another agent claimed it between our SELECT and UPDATE
        return {"success": False, "error": "Lost race — claimed by another agent"}
    db.execute(
        "INSERT INTO task_events (team_id, task_id, event, agent, detail) VALUES (?, ?, 'claimed', ?, 'in-progress')",
        (team_id, task_id, alias),
    )
    db.commit()
    return {"success": True, "task_id": task_id, "claimed_by": alias}


def update_task(
    db: sqlite3.Connection, team_id: str, task_id: int, status: str, alias: str
) -> dict:
    """Update task status. Valid statuses: open, in-progress, done, blocked, needs-rework."""
    valid = {"open", "in-progress", "done", "blocked", "needs-rework"}
    if status not in valid:
        return {"success": False, "error": f"Invalid status. Must be one of: {valid}"}

    row = db.execute(
        "SELECT id FROM tasks WHERE id = ? AND team_id = ?", (task_id, team_id)
    ).fetchone()
    if not row:
        return {"success": False, "error": "Task not found"}

    # needs-rework and open clear claimed_by so the task appears on the board for (re-)claim
    # in-progress requires claimed_by — use claim_task instead of update_task for that transition
    if status == "in-progress":
        return {"success": False, "error": "Use claim_task to move a task to in-progress"}
    if status in ("needs-rework", "open"):
        db.execute(
            "UPDATE tasks SET status = ?, claimed_by = NULL, updated_at = datetime('now') WHERE id = ?",
            (status, task_id),
        )
    else:
        db.execute(
            "UPDATE tasks SET status = ?, updated_at = datetime('now') WHERE id = ?",
            (status, task_id),
        )
    db.execute(
        "INSERT INTO task_events (team_id, task_id, event, agent, detail) VALUES (?, ?, 'status_changed', ?, ?)",
        (team_id, task_id, alias, status),
    )
    db.commit()
    return {"success": True, "task_id": task_id, "status": status, "updated_by": alias}


def get_agent_activity(
    db: sqlite3.Connection, team_id: str, alias: str, limit: int = 10
) -> list[dict]:
    """Get recent activity for an agent from messages sent and task events."""
    # Recent messages sent by this agent
    msgs = db.execute(
        "SELECT payload, to_alias, kind, created_at FROM messages "
        "WHERE team_id = ? AND from_alias = ? ORDER BY created_at DESC LIMIT ?",
        (team_id, alias, limit),
    ).fetchall()

    # Recent task events by this agent
    evts = db.execute(
        "SELECT e.event, e.detail, e.created_at, t.title FROM task_events e "
        "JOIN tasks t ON t.id = e.task_id "
        "WHERE e.team_id = ? AND e.agent = ? ORDER BY e.created_at DESC LIMIT ?",
        (team_id, alias, limit),
    ).fetchall()

    activity: list[dict] = []
    for m in msgs:
        target = m["to_alias"] or "broadcast"
        text = m["payload"][:120] if m["payload"] else ""
        activity.append({
            "type": "message",
            "time": m["created_at"],
            "summary": f"Sent {m['kind']} to {target}: {text}",
        })
    for e in evts:
        title = e["title"][:60] if e["title"] else ""
        activity.append({
            "type": "task",
            "time": e["created_at"],
            "summary": f"{e['event']} — {title} [{e['detail']}]",
        })

    activity.sort(key=lambda x: x["time"], reverse=True)
    return activity[:limit]
