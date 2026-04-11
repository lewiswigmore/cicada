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
    e.g. "engineer,reviewer" or "engineer,engineer,tester"
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
.PARAMETER Icebreaker
    Add a random team warm-up prompt to kick off collaboration.
.EXAMPLE
    cicada                              # default 4-agent team + monitor
    cicada --yolo                       # auto-approve all tools, paths, and URLs
    cicada --autopilot                  # autopilot mode (implies --yolo)
    cicada --icebreaker                 # add a fun random warm-up prompt
    cicada --continue                   # alias for --resume
    cicada --team "engineer,reviewer"      # 2-agent team
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
    [string]$Prompt,
    [switch]$Icebreaker,
    [int]$MaxCycles = 0
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
        Write-Host "  Cleared $removed session(s) and reset state." -ForegroundColor Cyan
    } else {
        Write-Host "  No state file found — nothing to clear." -ForegroundColor DarkGray
    }

    # Delete cicada.db — it gets recreated on next launch
    $cicadaDb = "$HOME\.cicada\cicada.db"
    if (Test-Path $cicadaDb) {
        Remove-Item $cicadaDb -Force -ErrorAction SilentlyContinue
        Write-Host "  Cleared cicada.db" -ForegroundColor DarkGray
    }

    # Clean up MCP config files
    Get-ChildItem "$HOME\.cicada\mcp-config-*.json" -ErrorAction SilentlyContinue | Remove-Item -Force

    return
}

# --- Validation ---

# Resolve Windows Terminal executable
$wtExe = $null
$wtCmd = Get-Command wt -ErrorAction SilentlyContinue
if ($wtCmd) {
    $wtExe = 'wt'
} elseif (Test-Path "$env:LOCALAPPDATA\Microsoft\WindowsApps\wt.exe") {
    $wtExe = "$env:LOCALAPPDATA\Microsoft\WindowsApps\wt.exe"
}
if (-not $wtExe) {
    Write-Error "Windows Terminal (wt.exe) not found. Download from: https://aka.ms/terminal"
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
    if ($saved.maxCycles -and $MaxCycles -eq 0) { $MaxCycles = [int]$saved.maxCycles }
    if ($saved.team) { $Team = $saved.team }
    if ($saved.prompt) { $Prompt = [string]$saved.prompt }
    if ($saved.icebreaker -eq $true) { $Icebreaker = [switch]::new($true) }
    $WorkingDirectory = if ($saved.workDir) { $saved.workDir } else { (Get-Location).Path }
    Write-Host "  Relaunching session" -ForegroundColor Yellow
}

$wd = if ($WorkingDirectory) { $WorkingDirectory } else { (Get-Location).Path }
if (-not (Test-Path $wd -PathType Container)) {
    Write-Error "Working directory not found: $wd"
    return
}
$wd = (Resolve-Path $wd).Path

function Get-RandomIcebreakerPrompt {
    $prompts = @(
        "Icebreaker mode: before implementation, each teammate should share one bold idea and one risk in a single sentence.",
        "Icebreaker mode: agree on a codename for this task and one measurable success signal before writing code.",
        "Icebreaker mode: each teammate should propose one tiny win we can ship quickly, then pick the best one together.",
        "Icebreaker mode: start with a 60-second plan where each teammate states one priority and one thing to avoid.",
        "Icebreaker mode: before coding, each teammate should post one assumption they are making so the team can challenge it."
    )
    return Get-Random -InputObject $prompts
}

$icebreakerPrompt = $null
if ($saved -and $saved.icebreakerPrompt) {
    $icebreakerPrompt = [string]$saved.icebreakerPrompt
} elseif ($Icebreaker) {
    $icebreakerPrompt = Get-RandomIcebreakerPrompt
}

if ($icebreakerPrompt -and (-not $Prompt -or -not ([string]$Prompt).Contains($icebreakerPrompt))) {
    if ($Prompt) {
        $Prompt = "$Prompt $icebreakerPrompt"
    } else {
        $Prompt = $icebreakerPrompt
    }
}

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
    $teamRoles = @('pm', 'engineer', 'reviewer', 'tester')
}

if ($teamRoles.Count -eq 0) {
    Write-Error "No roles specified. Use --team with comma-separated role names."
    return
}
if ($teamRoles.Count -gt 6) {
    Write-Error "Cicada supports 1-6 agents. Got $($teamRoles.Count). Use --team to select fewer."
    return
}

# Generate aliases (auto-suffix duplicates like engineer-1, engineer-2)
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
    # Use the dedicated venv python for MCP
    $venvPython = "$HOME\.cicada\venv\Scripts\python.exe"
    $pythonCmd = $null
    if (Test-Path $venvPython) {
        $pythonCmd = Get-Command $venvPython -ErrorAction SilentlyContinue
    }
    if (-not $pythonCmd) {
        Write-Host "  MCP venv not found — run Install-Cicada.ps1 to set up" -ForegroundColor Yellow
    }
    if ($pythonCmd) {
        $agentsList = ($paneConfigs | ForEach-Object { $_.Alias }) -join ','

        # Ensure ~/.cicada/ exists
        $cicadaDir = "$HOME\.cicada"
        if (-not (Test-Path $cicadaDir)) { New-Item $cicadaDir -ItemType Directory -Force | Out-Null }

        # Initialize team in cicada.db via Python MCP package
        $initResult = & $pythonCmd.Source -m cicada_mcp init --team-id $sessionGuid --work-dir $wd --agents $agentsList --db $cicadaDb 2>&1
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
        Write-Host "  Python not found — launching without MCP tools" -ForegroundColor DarkGray
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
    maxCycles   = $MaxCycles
    prompt      = $Prompt
    icebreaker  = [bool]$Icebreaker
    icebreakerPrompt = $icebreakerPrompt
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

    # Build agent config and write to a temp JSON file to avoid WT command-line length limits
    $agentCfg = @{
        Role     = $cfg.Role
        Alias    = $cfg.Alias
        StateFile = $stateFile
    }
    if ($mcpEnabled) {
        $agentMcpPath = "$cicadaDir\mcp-config-$sessionGuid-$($cfg.Alias).json"
        $agentCfg.McpConfigPath = $agentMcpPath
        $agentCfg.CicadaDb = $cicadaDb
        $agentCfg.TeamId = $sessionGuid
    }
    if ($cfg.SessionId) {
        $agentCfg.ResumeSessionId = $cfg.SessionId
    }
    if ($Yolo) {
        $agentCfg.Yolo = $true
    }
    if ($Autopilot) {
        $agentCfg.Autopilot = $true
    }
    if ($MaxCycles -gt 0) {
        $agentCfg.MaxCycles = $MaxCycles
    }
    if ($Prompt) {
        # Write prompt to a temp file to avoid WT/pwsh quoting issues
        $promptFile = "$cicadaDir\prompt-$sessionGuid-$($cfg.Alias).txt"
        $Prompt | Set-Content $promptFile -Encoding UTF8 -NoNewline
        $agentCfg.Prompt = $promptFile
        $agentCfg.PromptIsFile = $true
    }

    $configFile = "$cicadaDir\agent-$sessionGuid-$($cfg.Alias).json"
    $agentCfg | ConvertTo-Json -Depth 2 | Set-Content $configFile -Encoding UTF8 -NoNewline

    return "--tabColor `"$($cfg.Color)`" --title `"$($cfg.Title)`" -d `"$wd`" pwsh -NoExit -File `"$agentScript`" -ConfigFile `"$configFile`""
}

# --- Build wt argument string ---
# Adaptive layout for 1-6 agents with optional monitor column on the right.
# Uses focus-pane -t <id> to target specific panes before splitting.
# Pane IDs: 0=Ag0, 1=Monitor(if enabled), then agents sequentially.
# After each split-pane, the NEW pane receives focus.

$wtNewWindow = "-w new"

# First agent fills the initial pane (pane 0)
$wt = "$wtNewWindow --maximized $(NextAgentPane)"

# Monitor offset — shifts agent pane IDs by 1 when monitor is present
$monOfs = 0

# Add monitor column on right (20% width) — splits off initial pane
if (-not $NoMonitor) {
    $monitorScript = "$PSScriptRoot\Watch-Sessions.ps1"
    $monArgs = "--tabColor `"#475569`" --title `"Monitor`" -d `"$wd`""
    if (Test-Path $monitorScript) {
        $monArgs += " pwsh -NoExit -File `"$monitorScript`" -StateFile `"$stateFile`""
    }
    # Monitor = pane 1
    $wt += " ; split-pane -V -s 0.2 $monArgs"
    $monOfs = 1
    # Return focus to Ag0 (pane 0)
    $wt += " ; focus-pane -t 0"
}

# Layout remaining agents
# Pane IDs: Ag0=0, Ag(N)=(N + $monOfs) for N>=1
switch ($Panes) {
    1 {
        # Single agent — nothing more to do
    }
    2 {
        # Side by side: [Ag0 | Ag1]
        $wt += " ; split-pane -V -s 0.5 $(NextAgentPane)"
    }
    3 {
        # 3 columns: [Ag0 | Ag1 | Ag2]
        $wt += " ; split-pane -V -s 0.67 $(NextAgentPane)"
        $wt += " ; split-pane -V -s 0.5 $(NextAgentPane)"
    }
    4 {
        # 2x2 grid: [Ag0 | Ag1] / [Ag2 | Ag3]
        $ag1 = 1 + $monOfs
        $wt += " ; split-pane -V -s 0.5 $(NextAgentPane)"   # Ag1, focus: Ag1
        $wt += " ; focus-pane -t 0"                           # → Ag0
        $wt += " ; split-pane -H -s 0.5 $(NextAgentPane)"   # Ag2 below Ag0, focus: Ag2
        $wt += " ; focus-pane -t $ag1"                        # → Ag1
        $wt += " ; split-pane -H -s 0.5 $(NextAgentPane)"   # Ag3 below Ag1
    }
    5 {
        # 3 top + 2 bottom: [Ag0 | Ag1 | Ag2] / [Ag3 | Ag4]
        $ag1 = 1 + $monOfs
        $wt += " ; split-pane -V -s 0.67 $(NextAgentPane)"  # Ag1, focus: Ag1
        $wt += " ; split-pane -V -s 0.5 $(NextAgentPane)"   # Ag2, focus: Ag2
        $wt += " ; focus-pane -t 0"                           # → Ag0
        $wt += " ; split-pane -H -s 0.5 $(NextAgentPane)"   # Ag3 below Ag0, focus: Ag3
        $wt += " ; focus-pane -t $ag1"                        # → Ag1
        $wt += " ; split-pane -H -s 0.5 $(NextAgentPane)"   # Ag4 below Ag1
    }
    6 {
        # 3x2 grid: [Ag0 | Ag1 | Ag2] / [Ag3 | Ag4 | Ag5]
        $ag1 = 1 + $monOfs
        $ag2 = 2 + $monOfs
        $wt += " ; split-pane -V -s 0.67 $(NextAgentPane)"  # Ag1, focus: Ag1
        $wt += " ; split-pane -V -s 0.5 $(NextAgentPane)"   # Ag2, focus: Ag2
        $wt += " ; focus-pane -t 0"                           # → Ag0
        $wt += " ; split-pane -H -s 0.5 $(NextAgentPane)"   # Ag3 below Ag0, focus: Ag3
        $wt += " ; focus-pane -t $ag1"                        # → Ag1
        $wt += " ; split-pane -H -s 0.5 $(NextAgentPane)"   # Ag4 below Ag1, focus: Ag4
        $wt += " ; focus-pane -t $ag2"                        # → Ag2
        $wt += " ; split-pane -H -s 0.5 $(NextAgentPane)"   # Ag5 below Ag2
    }
}

$teamList = ($paneConfigs | ForEach-Object {
    if ($_.Alias -ne $_.Role) { "$($_.Title) ($($_.Alias))" } else { $_.Title }
}) -join ', '
$label = if ($NoMonitor) { "$Panes agents" } else { "$Panes agents + monitor" }
Write-Host "  $label" -ForegroundColor Cyan
Write-Host "  Team: $teamList" -ForegroundColor DarkGray
if ($icebreakerPrompt) {
    Write-Host "  Icebreaker: $icebreakerPrompt" -ForegroundColor DarkGray
}
if ($mcpEnabled) {
    Write-Host "  MCP: enabled (per-agent configs in $cicadaDir)" -ForegroundColor DarkGray
}
Write-Verbose "wt $wt"

# Launch WT in a dedicated window
Start-Process $wtExe -ArgumentList $wt

# Mark state as running (no PID — WT launcher exits immediately, real process is WindowsTerminal.exe)
$state.status = 'running'
$state | ConvertTo-Json -Depth 4 | Set-Content $stateFile -Encoding UTF8

Write-Host ""
Write-Host "  Run 'cicada --resume' to relaunch this session after exit." -ForegroundColor DarkGray
