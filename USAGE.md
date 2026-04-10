# Cicada Usage Guide

## Quick start

```powershell
cicada
```

This opens the default 4-agent team:

- Coder
- Reviewer
- Tester
- Researcher

with the monitor in a narrow right-hand column.

## Install safely

```powershell
git clone https://github.com/lewiswigmore/cicada.git
cd cicada
pwsh -File .\Install-Cicada.ps1
```

`Install-Cicada.ps1` is now a **local installer**. It installs from the files on
disk and does not fetch or execute a mutable remote script.

## Common commands

```powershell
cicada --team "coder,reviewer"
cicada --prompt "We are working on the MCP module"
cicada --yolo
cicada --autopilot
cicada --resume
cicada --continue
cicada --clear
cicada --doctor
cicada --update
```

## Modes

### Default mode

- Copilot runs interactively
- Cicada MCP tools are auto-approved
- other tool usage still follows Copilot's normal permission flow

### `--yolo`

- enables Copilot's full permission mode
- useful when you want agents to act without repeated approval prompts

### `--autopilot`

- enables Copilot autopilot continuation mode
- also turns on `--yolo`
- use this when you want agents to keep driving forward on their own

## Resume behavior

`cicada --resume` and `cicada --continue` are equivalent.

When a previous Cicada session was captured successfully, resume restores:

- team composition
- working directory
- monitor on/off state
- MCP on/off state
- prompt text
- yolo/autopilot flags
- saved Copilot session ID for each pane

That means Cicada can reopen the original Copilot sessions in the original slots
instead of starting fresh panes with new conversation histories.

## MCP-disabled mode

```powershell
cicada --no-mcp
```

Use this if Python is unavailable or if you want plain prompt-only agents.
In this mode, Cicada does **not** inject its own MCP server and also tells
Copilot to disable built-in and globally configured MCP servers for the session.

## Troubleshooting

### Check dependencies

```powershell
cicada --doctor
```

### Reset local state

```powershell
cicada --clear
```

### Update local install

```powershell
cicada --update
```

For git-based installs, this performs `git pull --ff-only`.

For module-copy installs, Cicada now refuses unsafe remote self-update and tells
you to reinstall from a local clone or immutable release archive instead.
