# Contributing to Cicada

## Project Structure

```
Cicada.psd1          # PowerShell module manifest
Cicada.psm1          # CLI entrypoint — handles help, doctor, update, version,
                     #   uninstall directly; dispatches launch/resume to Invoke-Cicada
Invoke-Cicada.ps1    # Core launcher — flag parsing, WT layout, pane orchestration
Start-Agent.ps1      # Per-pane agent wrapper — role config, Copilot invocation
Watch-Sessions.ps1   # Live monitor sidebar — reads session DB and state files
Install-Cicada.ps1   # Local installer — module copy, pip install, profile setup
roles.json           # Agent role definitions (coder, reviewer, tester, researcher)
cicada_mcp/          # Python MCP server package
  __main__.py        #   CLI entry (serve, init, bind-session)
  server.py          #   FastMCP tool definitions
  db.py              #   SQLite schema and query layer
pyproject.toml       # Python package metadata for cicada-mcp
```

## Local State

Cicada stores runtime state in a few locations. Useful to know when debugging:

- `~/.copilot/cicada-state.json` — team and session metadata for the last launch
- `~/.copilot/session-state/` — Copilot CLI session directories
- `~/.copilot/session-store.db` — session history used by the monitor
- `~/.cicada/cicada.db` — MCP SQLite database (messages, tasks, team state)
- `~/.cicada/mcp-config-*.json` — per-agent MCP server configuration

Use `cicada --clear` to wipe state and start fresh.

## Setting Up

**Requirements:**

- Windows 10/11 with Windows Terminal
- PowerShell 7+ (`pwsh`)
- Git
- GitHub Copilot CLI (`copilot`) with an active Copilot entitlement
- Python 3.10+ (optional — needed for MCP coordination features)

**Dev setup:**

```powershell
git clone https://github.com/lewiswigmore/cicada.git
cd cicada
pwsh -File .\Install-Cicada.ps1
```

After the installer finishes, restart `pwsh` (or run `Import-Module Cicada` in your current session).

Make sure you're authenticated with Copilot:

```powershell
copilot auth
```

If you have Python available, the installer sets up `cicada-mcp` automatically. For manual Python dev:

```powershell
python -m pip install -e .
```

Verify everything works:

```powershell
cicada --doctor
```

## Running and Testing

There is no automated test suite yet. Validation is manual. What to check depends on what you changed:

- `cicada --doctor` — always run this; confirms dependencies and configuration.
- `cicada --no-mcp` — good enough for PowerShell-only changes.
- `cicada` — full launch with MCP; use when touching Python code, layout, or agent startup.
- `cicada --resume` — if you touched session restore or state handling.
- `cicada --clear` — if you touched cleanup or state reset logic.

At minimum, `cicada --doctor` should pass and a basic launch should work before submitting a PR.

## Code Style

### PowerShell

- Functions and parameters use PascalCase. Local variables follow existing patterns in each script.
- Use `[CmdletBinding()]` for script entry points and cmdlet-like functions.
- CLI flags use `--flag` style only — no positional subcommands.
- All terminal output is emoji-free (the ASCII art logo is the sole exception).
- Use `Write-Host` for user-facing output with appropriate colors.
- Use section-divider comments in longer scripts to separate logical blocks.

### Python

- snake_case for functions and variables.
- Type hints on function signatures.
- Standard library imports first, then third-party, then local.
- The MCP server uses FastMCP decorators — follow the existing patterns in `server.py`.

## Submitting a PR

1. Fork the repository and create a branch from `main`.
2. Keep changes focused — one logical change per PR.
3. Make sure `cicada --doctor` passes and a basic launch works.
4. Write a clear PR description explaining what changed and why.
5. Link the relevant issue if one exists.

For bug fixes, describe the steps to reproduce the issue.
For new features, explain the use case.

## Questions

Open an issue if something is unclear or you want to discuss an approach before writing code.
