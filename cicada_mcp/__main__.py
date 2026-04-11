"""Cicada MCP server CLI. Usage: python -m cicada_mcp [serve|init|bind-session|check-pending]"""

import sys


def main():
    if len(sys.argv) < 2:
        print("Usage: python -m cicada_mcp [serve|init|bind-session|check-pending]")
        print("  serve          — Run MCP server (stdio transport)")
        print("  init           — Initialize team database")
        print("  bind-session   — Bind an agent to a Copilot session")
        print("  check-pending  — Check pending work for an agent (JSON output)")
        sys.exit(1)

    cmd = sys.argv[1]

    if cmd == "serve":
        from .server import mcp

        mcp.run(transport="stdio")

    elif cmd == "init":
        import argparse
        import json
        import os
        from collections import Counter

        from . import db

        parser = argparse.ArgumentParser()
        parser.add_argument("--team-id", required=True)
        parser.add_argument("--work-dir", required=True)
        parser.add_argument(
            "--agents", required=True, help="Comma-separated role list"
        )
        parser.add_argument(
            "--db", default=None, help="DB path (default: ~/.cicada/cicada.db)"
        )
        args = parser.parse_args(sys.argv[2:])

        db_path = args.db or os.path.expanduser("~/.cicada/cicada.db")
        os.makedirs(os.path.dirname(db_path), exist_ok=True)

        conn = db.init_db(db_path)
        roles = args.agents.split(",")

        # Load role configs from roles.json if available
        roles_file = os.path.join(args.work_dir, "roles.json")
        script_dir = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
        if not os.path.exists(roles_file):
            roles_file = os.path.join(script_dir, "roles.json")

        role_configs = {}
        if os.path.exists(roles_file):
            with open(roles_file) as f:
                role_configs = json.load(f)

        # Build agents config with alias auto-suffixing for duplicates
        role_counts = Counter(roles)
        role_seen: Counter = Counter()
        agents_config = []
        for i, role in enumerate(roles):
            role_seen[role] += 1
            if role_counts[role] > 1:
                alias = f"{role}-{role_seen[role]}"
            else:
                alias = role

            rc = role_configs.get(role, {})
            agents_config.append(
                {
                    "agent_id": f"{args.team_id}-{i}",
                    "alias": alias,
                    "role": role,
                    "title": rc.get("title", role.capitalize()),
                    "color": rc.get("color", "#888888"),
                }
            )

        db.register_team(conn, args.team_id, args.work_dir, agents_config)
        conn.close()

        aliases = ", ".join(a["alias"] for a in agents_config)
        print(f"[cicada-mcp] Team {args.team_id} initialized: {aliases}")

    elif cmd == "bind-session":
        import argparse
        import os

        from . import db

        parser = argparse.ArgumentParser()
        parser.add_argument("--team-id", required=True)
        parser.add_argument("--alias", required=True)
        parser.add_argument("--session-id", required=True)
        parser.add_argument(
            "--db", default=None, help="DB path (default: ~/.cicada/cicada.db)"
        )
        args = parser.parse_args(sys.argv[2:])

        db_path = args.db or os.path.expanduser("~/.cicada/cicada.db")
        os.makedirs(os.path.dirname(db_path), exist_ok=True)

        conn = db.init_db(db_path)
        updated = db.set_agent_session(
            conn, args.team_id, args.alias, args.session_id
        )
        conn.close()

        if updated:
            print(
                f"[cicada-mcp] Bound {args.alias} to Copilot session {args.session_id}"
            )
        else:
            print(
                f"[cicada-mcp] Agent {args.alias} not found in team {args.team_id}",
                file=sys.stderr,
            )
            sys.exit(1)

    elif cmd == "check-pending":
        import argparse
        import json
        import os

        from . import db

        parser = argparse.ArgumentParser()
        parser.add_argument("--team-id", required=True)
        parser.add_argument("--alias", required=True)
        parser.add_argument(
            "--db", default=None, help="DB path (default: ~/.cicada/cicada.db)"
        )
        args = parser.parse_args(sys.argv[2:])

        db_path = args.db or os.path.expanduser("~/.cicada/cicada.db")
        if not os.path.exists(db_path):
            print(json.dumps({"unread": 0, "open_tasks": 0, "claimed_tasks": 0}))
            sys.exit(0)

        conn = db.init_db(db_path)
        summary = db.get_pending_summary(conn, args.team_id, args.alias)
        conn.close()
        print(json.dumps(summary))

    else:
        print(f"Unknown command: {cmd}")
        sys.exit(1)


if __name__ == "__main__":
    main()
