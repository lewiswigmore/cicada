# Cicada — Copilot Instructions

This is a PowerShell + Python project that orchestrates multi-agent
GitHub Copilot CLI sessions in Windows Terminal.

## Project skills

Project-level skills are installed in `.agents/skills/` and provide
additional context for development work:

- **refactor** — code refactoring patterns and best practices
- **find-skills** — discover and install new agent skills
- **brainstorming** — structured ideation and problem-solving

Use `npx skills find <query>` to discover more skills.
Use `npx skills add <package> --skill <name> -y` to install locally.

## Key conventions

- PowerShell 7+ is required (pwsh, not Windows PowerShell 5).
- The `cicada_mcp/` directory is a Python package (installed via `pip install -e .`).
- CLI flags use `--flag` style only (no positional subcommands).
- All terminal output is emoji-free apart from the ASCII art logo.
- The `.agents/` directory and `skills-lock.json` are gitignored.
