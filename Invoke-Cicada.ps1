#Requires -Version 5.1
<#
.SYNOPSIS
    Launch a team of Copilot agents in Windows Terminal.
.DESCRIPTION
    Opens Windows Terminal with role-assigned Copilot agent panes in an adaptive
    grid layout (1-6 agents) with an optional live monitor sidebar on the right.
    Supports MCP-based inter-agent coordination via the cicada_mcp package.
.PARAMETER NoMonitor
    Disable the sidebar session monitor.
.PARAMETER NoMcp
    Disable Cicada MCP injection and block Copilot's built-in/global MCP servers
    for these sessions.
.PARAMETER Team
    Comma-separated role names for custom team composition (1-6 agents).
    e.g. "coder,reviewer" or "coder,coder,tester"
.PARAMETER WorkingDirectory
    Starting directory. Default: current directory.
.PARAMETER Resume
    Resume the last Cicada session, reusing saved Copilot session IDs when available.
.PARAMETER Clear
    Delete session-state directories for sessions launched by Cicada and reset the state file.
.PARAMETER Yolo
    Enable all Copilot permissions — passes --yolo to each agent.
.PARAMETER Autopilot
    Enable Copilot autopilot continuation mode. Implies --yolo.
.PARAMETER Prompt
    Shared context prepended to every agent's system prompt on launch.
    e.g. "We are working on the auth module in src/auth/"
.EXAMPLE
    cicada                              # default 4-agent team + monitor
    cicada --yolo                       # auto-approve all tools, paths, and URLs
    cicada --autopilot                  # autopilot mode (implies --yolo)
    cicada --continue                   # alias for --resume
    cicada --team "coder,reviewer"      # 2-agent team
    cicada --no-mcp                     # launch without any MCP servers
    cicada -Resume                      # relaunch last session
    cicada -Clear                       # clean up Cicada session data
#>
[CmdletBinding()]
param(
    [switch]$NoMonitor,
    [switch]$NoMcp,
    [string]$Team,
    [string]$WorkingDirectory,
    [switch]$Resume,
    [switch]$Clear,
    [switch]$Yolo,
    [switch]$Autopilot,
    [string]$Prompt
)

# --- Clear: remove Cicada sessions and state ---

if ($Clear) {
    $stateFile = "$HOME\.copilot\cicada-state.json"
    $sessionDir = "$HOME\.copilot\session-state"
    $removed = 0

    if (Test-Path $stateFile) {
        try {
            $state = Get-Content $stateFile -Raw | ConvertFrom-Json
            $sessionIds = @($state.panes | Where-Object { $_.sessionId } | ForEach-Object { $_.sessionId })
            foreach ($sid in $sessionIds) {
                $path = Join-Path $sessionDir $sid
                if (Test-Path $path) {
                    Remove-Item $path -Recurse -Force -ErrorAction SilentlyContinue
                    $removed++
                }
            }
        } catch {
            Write-Warning "Could not parse state file: $_"
        }
        Remove-Item $stateFile -Force -ErrorAction SilentlyContinue
        Write-Host "[CICADA] Cleared $removed session(s) and reset state." -ForegroundColor Cyan
    } else {
        Write-Host "[CICADA] No state file found — nothing to clear." -ForegroundColor DarkGray
    }

    # Best-effort: mark running teams as exited in cicada.db
    $cicadaDb = "$HOME\.cicada\cicada.db"
    if ((Test-Path $cicadaDb) -and (Get-Command python -ErrorAction SilentlyContinue)) {
        try {
            $dbPath = $cicadaDb -replace '\\', '/'
            & python -c "
import sqlite3
conn = sqlite3.connect('$dbPath')
conn.execute(""UPDATE teams SET status = 'exited' WHERE status = 'running'"")
conn.commit()
conn.close()
" 2>$null
            Write-Host "[CICADA] Marked running teams as exited in cicada.db" -ForegroundColor DarkGray
        } catch {
            # Best-effort — ignore failures
        }
    }

    # Clean up MCP config files
    Get-ChildItem "$HOME\.cicada\mcp-config-*.json" -ErrorAction SilentlyContinue | Remove-Item -Force

    return
}

# --- Validation ---

if (-not (Get-Command wt -ErrorAction SilentlyContinue)) {
    Write-Error "Windows Terminal (wt.exe) not found. Install: winget install Microsoft.WindowsTerminal"
    return
}

# --- Resume: reload last session config ---

$stateFile = "$HOME\.copilot\cicada-state.json"
$saved = $null

# Auto-detect dead sessions: if no flags passed and state says 'running' but no WT window, offer resume
if (-not $Resume -and -not $Clear -and (Test-Path $stateFile)) {
    try {
        $prev = Get-Content $stateFile -Raw | ConvertFrom-Json
        if ($prev.status -eq 'running') {
            # Check if any WindowsTerminal process is alive (best-effort check)
            $wtAlive = Get-Process WindowsTerminal -ErrorAction SilentlyContinue
            if (-not $wtAlive) {
                Write-Host ""
                Write-Host "  Previous Cicada session ended." -ForegroundColor Yellow
                $teamDesc = if ($prev.team) { $prev.team } else { "default" }
                Write-Host "  Team: $teamDesc | Dir: $($prev.workDir)" -ForegroundColor DarkGray
                Write-Host ""
                $answer = Read-Host "  Resume? [Y/N]"
                if ($answer -match '^[Yy]') {
                    $Resume = [switch]::new($true)
                } else {
                    # Mark as acknowledged so we don't ask again
                    $prev.status = 'exited'
                    $prev | ConvertTo-Json -Depth 4 | Set-Content $stateFile -Encoding UTF8
                }
                Write-Host ""
            }
        }
    } catch {
        # Corrupt state — ignore
    }
}

if ($Resume) {
    if (-not (Test-Path $stateFile)) {
        Write-Error "No previous session found. Run 'cicada' first."
        return
    }
    $saved = Get-Content $stateFile -Raw | ConvertFrom-Json
    if ($saved.noMonitor -eq $true) { $NoMonitor = [switch]::new($true) }
    if ($saved.noMcp -eq $true) { $NoMcp = [switch]::new($true) }
    if ($saved.yolo -eq $true) { $Yolo = [switch]::new($true) }
    if ($saved.autopilot -eq $true) {
        $Autopilot = [switch]::new($true)
        $Yolo = [switch]::new($true)
    }
    if ($saved.team) { $Team = $saved.team }
    if ($saved.prompt) { $Prompt = [string]$saved.prompt }
    $WorkingDirectory = if ($saved.workDir) { $saved.workDir } else { (Get-Location).Path }
    Write-Host "[RESUME] Relaunching session" -ForegroundColor Yellow
}

$wd = if ($WorkingDirectory) { $WorkingDirectory } else { (Get-Location).Path }
if (-not (Test-Path $wd -PathType Container)) {
    Write-Error "Working directory not found: $wd"
    return
}
$wd = (Resolve-Path $wd).Path

if (-not (Get-Command copilot -ErrorAction SilentlyContinue)) {
    Write-Error "'copilot' not found in PATH. Install: winget install GitHub.CopilotCLI"
    return
}

# --- Load team from roles.json ---

$rolesFile = "$PSScriptRoot\roles.json"
if (-not (Test-Path $rolesFile)) {
    Write-Error "Missing config: roles.json not found in $PSScriptRoot"
    return
}

$allRoles = Get-Content $rolesFile -Raw | ConvertFrom-Json

# Dynamic team composition
if ($Team) {
    $teamRoles = @($Team -split ',' | ForEach-Object { $_.Trim().ToLower() } | Where-Object { $_ })
} else {
    $teamRoles = @('coder', 'reviewer', 'tester', 'researcher')
}

if ($teamRoles.Count -eq 0) {
    Write-Error "No roles specified. Use --team with comma-separated role names."
    return
}
if ($teamRoles.Count -gt 6) {
    Write-Error "Cicada supports 1-6 agents. Got $($teamRoles.Count). Use --team to select fewer."
    return
}

# Generate aliases (auto-suffix duplicates like coder-1, coder-2)
$roleCounts = @{}
foreach ($r in $teamRoles) { $roleCounts[$r] = ($roleCounts[$r] -as [int]) + 1 }
$roleSeen = @{}
$savedPanesByAlias = @{}
if ($saved -and $saved.panes) {
    foreach ($pane in $saved.panes) {
        if ($pane.alias) { $savedPanesByAlias[[string]$pane.alias] = $pane }
    }
}

$paneConfigs = @()
foreach ($rn in $teamRoles) {
    $role = $allRoles.$rn
    if (-not $role) {
        Write-Error "Role '$rn' not found in roles.json"
        return
    }
    if ($role.color -notmatch '^#[0-9A-Fa-f]{6}$') {
        Write-Error "Invalid color for role '$rn': $($role.color). Must be #RRGGBB hex."
        return
    }
    if ($role.title -match '[;`"''&|<>]') {
        Write-Error "Invalid title for role '$rn': contains shell metacharacters."
        return
    }
    $roleSeen[$rn] = ($roleSeen[$rn] -as [int]) + 1
    $alias = if ($roleCounts[$rn] -gt 1) { "$rn-$($roleSeen[$rn])" } else { $rn }

    $paneConfigs += @{
        Color     = $role.color
        Title     = $role.title
        Role      = $rn
        Alias     = $alias
        SessionId = if ($savedPanesByAlias.ContainsKey($alias)) { [string]$savedPanesByAlias[$alias].sessionId } else { $null }
    }
}
$Panes = $paneConfigs.Count

# --- MCP Setup (unless --no-mcp) ---

$mcpConfigPath = $null
$cicadaDb = "$HOME\.cicada\cicada.db"
$sessionGuid = if ($saved -and $saved.sessionGuid) { [string]$saved.sessionGuid } else { [guid]::NewGuid().ToString('N').Substring(0, 12) }

$mcpEnabled = $false
if (-not $NoMcp) {
    $pythonCmd = Get-Command python -ErrorAction SilentlyContinue
    if ($pythonCmd) {
        $agentsList = ($paneConfigs | ForEach-Object { $_.Alias }) -join ','

        # Ensure ~/.cicada/ exists
        $cicadaDir = "$HOME\.cicada"
        if (-not (Test-Path $cicadaDir)) { New-Item $cicadaDir -ItemType Directory -Force | Out-Null }

        # Initialize team in cicada.db via Python MCP package
        $initResult = & python -m cicada_mcp init --team-id $sessionGuid --work-dir $wd --agents $agentsList --db $cicadaDb 2>&1
        if ($LASTEXITCODE -eq 0) {
            Write-Host "  $initResult" -ForegroundColor DarkGray

            # Generate per-agent MCP configs with identity baked into env block
            # Use absolute python path — Copilot rewrites bare "python -m X" to "pipx run X"
            $pythonAbsPath = $pythonCmd.Source
            foreach ($cfg in $paneConfigs) {
                $agentConfigPath = "$cicadaDir\mcp-config-$sessionGuid-$($cfg.Alias).json"
                $mcpConfig = @{
                    mcpServers = @{
                        cicada = @{
                            type    = "stdio"
                            command = $pythonAbsPath
                            args    = @("-m", "cicada_mcp", "serve")
                            env     = @{
                                CICADA_ALIAS   = $cfg.Alias
                                CICADA_TEAM_ID = $sessionGuid
                                CICADA_DB      = $cicadaDb
                            }
                        }
                    }
                }
                $mcpConfig | ConvertTo-Json -Depth 4 | Set-Content $agentConfigPath -Encoding UTF8
            }
            $mcpEnabled = $true
        } else {
            Write-Warning "MCP init failed. Launching without MCP tools."
            Write-Warning "  $initResult"
        }
    } else {
        Write-Host "  [MCP] Python not found — launching without MCP tools" -ForegroundColor DarkGray
    }
}

# --- Write state for monitor ---

$stateFile = "$HOME\.copilot\cicada-state.json"
$state = @{
    sessionGuid = $sessionGuid
    launchedAt  = (Get-Date -Format 'o')
    workDir     = $wd
    team        = ($paneConfigs | ForEach-Object { $_.Role }) -join ','
    noMonitor   = [bool]$NoMonitor
    noMcp       = [bool]$NoMcp
    yolo        = [bool]$Yolo
    autopilot   = [bool]$Autopilot
    prompt      = $Prompt
    mcpConfig   = if ($mcpEnabled) { "$cicadaDir\mcp-config-$sessionGuid-*.json" } else { $null }
    cicadaDb    = $cicadaDb
    status      = 'launching'
    panes       = @(for ($i = 0; $i -lt $paneConfigs.Count; $i++) {
        @{
            index = $i
            role  = $paneConfigs[$i].Role
            alias = $paneConfigs[$i].Alias
            color = $paneConfigs[$i].Color
            title = $paneConfigs[$i].Title
            sessionId = $paneConfigs[$i].SessionId
        }
    })
}
$state | ConvertTo-Json -Depth 4 | Set-Content $stateFile -Encoding UTF8

# --- Per-pane argument builder ---

$agentScript = "$PSScriptRoot\Start-Agent.ps1"
$script:paneIdx = 0

function NextAgentPane {
    $cfg = $paneConfigs[$script:paneIdx]
    $script:paneIdx++
    $cmd = "--tabColor `"$($cfg.Color)`" --title `"$($cfg.Title)`" -d `"$wd`" pwsh -NoExit -File `"$agentScript`" -Role $($cfg.Role) -Alias $($cfg.Alias) -StateFile `"$stateFile`""
    if ($mcpEnabled) {
        $agentMcpPath = "$cicadaDir\mcp-config-$sessionGuid-$($cfg.Alias).json"
        $cmd += " -McpConfigPath `"$agentMcpPath`" -CicadaDb `"$cicadaDb`" -TeamId `"$sessionGuid`""
    }
    if ($cfg.SessionId) {
        $cmd += " -ResumeSessionId `"$($cfg.SessionId)`""
    }
    if ($Yolo) {
        $cmd += " -Yolo"
    }
    if ($Autopilot) {
        $cmd += " -Autopilot"
    }
    if ($Prompt) {
        $escaped = $Prompt -replace '"', '\"'
        $cmd += " -Prompt `"$escaped`""
    }
    return $cmd
}

# --- Build wt argument string ---
# Adaptive layout for 1-6 agents with optional monitor column on the right.
# WT split-pane -s is the fraction of the CURRENT pane given to the NEW pane.
# Strategy: create monitor column first (if enabled), then lay out agent grid.

$wtNewWindow = "-w new"

# First agent fills the initial pane
$wt = "$wtNewWindow --maximized $(NextAgentPane)"

# Add monitor column on right (20% width)
if (-not $NoMonitor) {
    $monitorScript = "$PSScriptRoot\Watch-Sessions.ps1"
    $monArgs = "--tabColor `"#475569`" --title `"Monitor`" -d `"$wd`""
    if (Test-Path $monitorScript) {
        $monArgs += " pwsh -NoExit -File `"$monitorScript`" -StateFile `"$stateFile`""
    }
    $wt += " ; split-pane -V -s 0.2 $monArgs"
    $wt += " ; move-focus left"
}

# Layout based on agent count (agent 0 already placed)
switch ($Panes) {
    1 {
        # Single agent — nothing more to do
    }
    2 {
        # Side by side: [Ag0 | Ag1]
        $wt += " ; split-pane -V -s 0.5 $(NextAgentPane)"
    }
    3 {
        # 3 equal columns: [Ag0 | Ag1 | Ag2]
        # split-V 0.67: Ag0 keeps 33%, new pane gets 67%
        # split-V 0.5 on that 67%: Ag1 33%, Ag2 33%
        $wt += " ; split-pane -V -s 0.67 $(NextAgentPane)"
        $wt += " ; split-pane -V -s 0.5 $(NextAgentPane)"
    }
    4 {
        # 2×2 grid: [Ag0 | Ag1] / [Ag2 | Ag3]
        $wt += " ; split-pane -V -s 0.5 $(NextAgentPane)"
        $wt += " ; move-focus left"
        $wt += " ; split-pane -H -s 0.5 $(NextAgentPane)"
        $wt += " ; move-focus right"
        $wt += " ; split-pane -H -s 0.5 $(NextAgentPane)"
    }
    5 {
        # 3 top + 2 bottom: [Ag0 | Ag1 | Ag2] / [Ag3 | Ag4 | ---]
        # Build 3 columns, then split the left 2 horizontally
        $wt += " ; split-pane -V -s 0.67 $(NextAgentPane)"   # Ag1 (focus on Ag1)
        $wt += " ; split-pane -V -s 0.5 $(NextAgentPane)"    # Ag2 (focus on Ag2)
        $wt += " ; move-focus left"                           # → Ag1
        $wt += " ; move-focus left"                           # → Ag0
        $wt += " ; split-pane -H -s 0.5 $(NextAgentPane)"    # Ag3 below Ag0
        $wt += " ; move-focus right"                          # → Ag1
        $wt += " ; split-pane -H -s 0.5 $(NextAgentPane)"    # Ag4 below Ag1
    }
    6 {
        # 3×2 grid: [Ag0 | Ag1 | Ag2] / [Ag3 | Ag4 | Ag5]
        $wt += " ; split-pane -V -s 0.67 $(NextAgentPane)"   # Ag1
        $wt += " ; split-pane -V -s 0.5 $(NextAgentPane)"    # Ag2
        $wt += " ; move-focus left"                           # → Ag1
        $wt += " ; move-focus left"                           # → Ag0
        $wt += " ; split-pane -H -s 0.5 $(NextAgentPane)"    # Ag3
        $wt += " ; move-focus right"                          # → Ag1
        $wt += " ; split-pane -H -s 0.5 $(NextAgentPane)"    # Ag4
        $wt += " ; move-focus right"                          # → Ag2
        $wt += " ; split-pane -H -s 0.5 $(NextAgentPane)"    # Ag5
    }
}

$teamList = ($paneConfigs | ForEach-Object {
    if ($_.Alias -ne $_.Role) { "$($_.Title) ($($_.Alias))" } else { $_.Title }
}) -join ', '
$label = if ($NoMonitor) { "$Panes agents" } else { "$Panes agents + monitor" }
Write-Host "[CICADA] $label" -ForegroundColor Cyan
Write-Host "  Team: $teamList" -ForegroundColor DarkGray
if ($mcpEnabled) {
    Write-Host "  MCP: enabled (per-agent configs in $cicadaDir)" -ForegroundColor DarkGray
}
Write-Verbose "wt $wt"

# Launch WT in a dedicated window
Start-Process wt -ArgumentList $wt

# Mark state as running (no PID — WT launcher exits immediately, real process is WindowsTerminal.exe)
$state.status = 'running'
$state | ConvertTo-Json -Depth 4 | Set-Content $stateFile -Encoding UTF8

Write-Host ""
Write-Host "  Run 'cicada --resume' to relaunch this session after exit." -ForegroundColor DarkGray
