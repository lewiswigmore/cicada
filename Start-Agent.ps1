# Start-Agent.ps1 — Wrapper to launch copilot with role + team awareness + MCP
# Called by Invoke-Cicada.ps1 per pane to avoid wt quoting issues
[CmdletBinding()]
param(
    [string]$ConfigFile,
    [string]$Role,
    [string]$Alias,
    [string]$RolesFile,
    [string]$StateFile = "$HOME\.copilot\cicada-state.json",
    [string]$McpConfigPath,
    [string]$CicadaDb,
    [string]$TeamId,
    [string]$ResumeSessionId,
    [switch]$Yolo,
    [switch]$Autopilot,
    [string]$Prompt,
    [switch]$PromptIsFile,
    [int]$MaxCycles = 0
)

# If launched via config file, read params from JSON and override
if ($ConfigFile -and (Test-Path $ConfigFile)) {
    $cfg = Get-Content $ConfigFile -Raw -Encoding UTF8 | ConvertFrom-Json
    Remove-Item $ConfigFile -Force -ErrorAction SilentlyContinue
    $Role            = $cfg.Role
    $Alias           = $cfg.Alias
    $RolesFile       = $cfg.RolesFile
    $StateFile       = $cfg.StateFile
    $McpConfigPath   = $cfg.McpConfigPath
    $CicadaDb        = $cfg.CicadaDb
    $TeamId          = $cfg.TeamId
    $ResumeSessionId = $cfg.ResumeSessionId
    $Yolo            = [bool]$cfg.Yolo
    $Autopilot       = [bool]$cfg.Autopilot
    $Prompt          = $cfg.Prompt
    $PromptIsFile    = [bool]$cfg.PromptIsFile
    $MaxCycles       = [int]($cfg.MaxCycles ?? 0)
}

if (-not $Role -or $Role -notmatch '^[a-z][a-z0-9\-]{0,30}$') {
    Write-Host "Missing or invalid -Role. Use -ConfigFile or provide -Role directly." -ForegroundColor Red
    return
}

if (-not $RolesFile) { $RolesFile = "$PSScriptRoot\roles.json" }
if (-not $Alias) { $Alias = $Role }

# If prompt was passed as a file path, read and clean up
if ($PromptIsFile -and $Prompt -and (Test-Path $Prompt)) {
    $promptFile = $Prompt
    $Prompt = Get-Content $promptFile -Raw -Encoding UTF8
    Remove-Item $promptFile -Force -ErrorAction SilentlyContinue
}

if (-not (Test-Path $RolesFile)) {
    Write-Host "roles.json not found: $RolesFile" -ForegroundColor Red
    return
}

$roles = Get-Content $RolesFile -Raw | ConvertFrom-Json
$config = $roles.$Role

if (-not $config) {
    Write-Host "Unknown role: $Role" -ForegroundColor Red
    return
}

# File-locked state update: read-modify-write with exclusive lock + retry
function Update-StateFile {
    param([string]$Path, [scriptblock]$Mutator)
    $maxRetries = 5
    for ($attempt = 0; $attempt -lt $maxRetries; $attempt++) {
        try {
            $fs = [System.IO.File]::Open($Path, 'Open', 'ReadWrite', 'None')
            try {
                $reader = [System.IO.StreamReader]::new($fs)
                $json = $reader.ReadToEnd()
                $reader.Dispose()
                $obj = $json | ConvertFrom-Json
                $changed = & $Mutator $obj
                if ($changed) {
                    $fs.SetLength(0)
                    $writer = [System.IO.StreamWriter]::new($fs, [System.Text.Encoding]::UTF8)
                    $writer.Write(($obj | ConvertTo-Json -Depth 4))
                    $writer.Flush()
                    $writer.Dispose()
                }
            } finally { $fs.Dispose() }
            return
        } catch [System.IO.IOException] {
            Start-Sleep -Milliseconds (100 * ($attempt + 1))
        } catch {
            Write-Verbose "State update error: $_"
            return
        }
    }
    Write-Verbose "State update failed after $maxRetries retries"
}

function Update-AgentSessionBinding {
    param([string]$SessionId)
    if (-not $SessionId -or -not $TeamId -or -not $Alias -or -not $CicadaDb) { return }
    $venvPy = "$HOME\.cicada\venv\Scripts\python.exe"
    if (-not (Test-Path $venvPy)) { return }
    try {
        & $venvPy -m cicada_mcp bind-session --team-id $TeamId --alias $Alias --session-id $SessionId --db $CicadaDb 2>$null | Out-Null
    } catch {
        Write-Verbose "Could not bind session ID for ${Alias}: $_"
    }
}

function Get-CopilotMcpIsolationArgs {
    $isolationArgs = @('--disable-builtin-mcps')
    $configPath = Join-Path $HOME '.copilot\mcp-config.json'
    if (-not (Test-Path $configPath)) {
        return $isolationArgs
    }
    try {
        $config = Get-Content $configPath -Raw | ConvertFrom-Json
        $serverNames = @()
        if ($config.mcpServers) {
            $serverNames = @($config.mcpServers.PSObject.Properties.Name | Where-Object { $_ -and $_ -ne 'cicada' })
        }
        foreach ($serverName in $serverNames) {
            $isolationArgs += '--disable-mcp-server', [string]$serverName
        }
    } catch {
        Write-Verbose "Could not parse global Copilot MCP config: $_"
    }
    return $isolationArgs
}

# Build team context from state file
$teammates = @()
if (Test-Path $StateFile) {
    try {
        $state = Get-Content $StateFile -Raw | ConvertFrom-Json
        $teammates = @($state.panes | Where-Object { $_.alias -and $_.alias -ne $Alias } |
            ForEach-Object {
                if ($_.alias -ne $_.role) { "$($_.title) ($($_.alias))" } else { $_.title }
            })
    } catch {
        Write-Verbose "Could not read state for team context: $_"
    }
}

# Assemble prompt: role identity first, then user context, then teammates + coordination
$parts = @()
$parts += $config.prompt
if ($Prompt) {
    $parts += "Team objective: $Prompt"
}
if ($teammates) {
    $parts += "Your teammates: $($teammates -join ', ')."
}
if ($McpConfigPath -and (Test-Path $McpConfigPath)) {
    $parts += "You have team coordination tools available. Check the board and your messages before starting work, claim tasks before working on them, and check again before declaring everything done."
}
$fullPrompt = $parts -join ' '

# Display startup banner
Write-Host "`n  $($config.title)" -ForegroundColor Cyan
if ($Alias -ne $Role) {
    Write-Host "  Alias: $Alias" -ForegroundColor DarkGray
}
Write-Host "  $($config.prompt)" -ForegroundColor DarkGray
if ($teammates) {
    Write-Host "  Team: $($teammates -join ', ')" -ForegroundColor DarkGray
}
$effectiveYolo = $Yolo -or $Autopilot

if ($McpConfigPath) {
    $modeSuffix = if ($Autopilot) {
        ' (yolo, autopilot)'
    } elseif ($effectiveYolo) {
        ' (yolo)'
    } else {
        ''
    }
    Write-Host "  MCP: enabled$modeSuffix" -ForegroundColor DarkGray
}
Write-Host ""

# Non-PM agents wait so PM can populate the board first, staggered by role
if ($Role -ne 'pm' -and $Prompt -and -not $ResumeSessionId) {
    # Role-based stagger: engineer waits for PM, reviewer/tester wait for code
    $waitSec = switch ($Role) {
        'engineer'   { 15 + (Get-Random -Minimum 0 -Maximum 4) }
        'reviewer'   { 30 + (Get-Random -Minimum 0 -Maximum 6) }
        'tester'     { 35 + (Get-Random -Minimum 0 -Maximum 6) }
        default      { 20 + (Get-Random -Minimum 0 -Maximum 4) }
    }
    $waitReason = switch ($Role) {
        'engineer'   { 'Waiting for PM to set up the board' }
        'reviewer'   { 'Waiting for code to review' }
        'tester'     { 'Waiting for implementation' }
        default      { 'Waiting for team setup' }
    }

    # Random color palette per window
    $palettes = @(
        @{ body = 'Green';       edge = 'DarkGreen';  wing = 'Cyan';     wingDim = 'DarkCyan'    },
        @{ body = 'Magenta';     edge = 'DarkMagenta'; wing = 'White';   wingDim = 'DarkGray'    },
        @{ body = 'Blue';        edge = 'DarkBlue';   wing = 'Cyan';     wingDim = 'DarkCyan'    },
        @{ body = 'Yellow';      edge = 'DarkYellow';  wing = 'White';   wingDim = 'Gray'        },
        @{ body = 'Cyan';        edge = 'DarkCyan';   wing = 'White';    wingDim = 'DarkGray'    },
        @{ body = 'Red';         edge = 'DarkRed';    wing = 'Yellow';   wingDim = 'DarkYellow'  }
    )
    $pal = $palettes[(Get-Random -Minimum 0 -Maximum $palettes.Count)]
    $g = $pal.body; $dg = $pal.edge; $c = $pal.wing; $dc = $pal.wingDim

    # Random wing styles
    $wingStyles = @(
        @{ L1 = "`u{2591}`u{2592}`u{2593}`u{2592}`u{2591}"; L2 = "`u{2591}`u{2592}`u{2593}`u{2593}`u{2592}`u{2591}"; L3 = "`u{2591}`u{2592}`u{2593}`u{2592}`u{2591}"; L4 = "`u{2591}`u{2592}`u{2593}" },
        @{ L1 = "`u{2550}`u{2550}`u{2566}`u{2550}`u{2550}"; L2 = "`u{2550}`u{2550}`u{2566}`u{2566}`u{2550}`u{2550}"; L3 = "`u{2550}`u{2550}`u{2566}`u{2550}`u{2550}"; L4 = "`u{2550}`u{2550}`u{2566}" },
        @{ L1 = "~`u{2248}`u{2261}`u{2248}~";              L2 = "~`u{2248}`u{2261}`u{2261}`u{2248}~";              L3 = "~`u{2248}`u{2261}`u{2248}~";              L4 = "~`u{2248}`u{2261}" },
        @{ L1 = "`u{00B7}`u{2022}`u{25CF}`u{2022}`u{00B7}"; L2 = "`u{00B7}`u{2022}`u{25CF}`u{25CF}`u{2022}`u{00B7}"; L3 = "`u{00B7}`u{2022}`u{25CF}`u{2022}`u{00B7}"; L4 = "`u{00B7}`u{2022}`u{25CF}" }
    )
    $ws = $wingStyles[(Get-Random -Minimum 0 -Maximum $wingStyles.Count)]

    # Random leg variation
    $legStyles = @(
        @{ A = "`u{2590}`u{258C}"; B = "`u{2580}" },
        @{ A = "`u{2502}`u{2502}"; B = "`u{2514}`u{2518}" },
        @{ A = "||";               B = "`u{2227}" }
    )
    $leg = $legStyles[(Get-Random -Minimum 0 -Maximum $legStyles.Count)]

    Write-Host ""
    Write-Host "              " -NoNewline; Write-Host "`u{2584}" -NoNewline -ForegroundColor $dg; Write-Host "`u{2588}" -NoNewline -ForegroundColor $g; Write-Host "`u{2584}" -ForegroundColor $dg
    Write-Host "           " -NoNewline; Write-Host "`u{2590}" -NoNewline -ForegroundColor $dg; Write-Host "`u{2588}" -NoNewline -ForegroundColor $dg; Write-Host "`u{2588}`u{2588}`u{2588}`u{2588}" -NoNewline -ForegroundColor $g; Write-Host "`u{2588}" -NoNewline -ForegroundColor $dg; Write-Host "`u{258C}" -ForegroundColor $dg
    Write-Host "    $($ws.L1) " -NoNewline -ForegroundColor $c; Write-Host "`u{2588}" -NoNewline -ForegroundColor $dg; Write-Host "`u{2588}`u{2588}`u{2588}`u{2588}`u{2588}`u{2588}`u{2588}`u{2588}" -NoNewline -ForegroundColor $g; Write-Host "`u{2588}" -NoNewline -ForegroundColor $dg; Write-Host " $($ws.L1)" -ForegroundColor $c
    Write-Host "  $($ws.L2)  " -NoNewline -ForegroundColor $c; Write-Host "`u{2590}" -NoNewline -ForegroundColor $dg; Write-Host "`u{2588}" -NoNewline -ForegroundColor $dg; Write-Host "`u{2588}`u{2588}`u{2588}`u{2588}`u{2588}`u{2588}" -NoNewline -ForegroundColor $g; Write-Host "`u{2588}" -NoNewline -ForegroundColor $dg; Write-Host "`u{258C}" -NoNewline -ForegroundColor $dg; Write-Host "  $($ws.L2)" -ForegroundColor $c
    Write-Host "   $($ws.L3)   " -NoNewline -ForegroundColor $dc; Write-Host "`u{2588}" -NoNewline -ForegroundColor $dg; Write-Host "`u{2588}`u{2588}`u{2588}`u{2588}`u{2588}`u{2588}" -NoNewline -ForegroundColor $g; Write-Host "`u{2588}" -NoNewline -ForegroundColor $dg; Write-Host "   $($ws.L3)" -ForegroundColor $dc
    Write-Host "      $($ws.L4)   " -NoNewline -ForegroundColor $dc; Write-Host "`u{2588}" -NoNewline -ForegroundColor $dg; Write-Host "`u{2588}`u{2588}`u{2588}`u{2588}" -NoNewline -ForegroundColor $g; Write-Host "`u{2588}" -NoNewline -ForegroundColor $dg; $r4 = ($ws.L4.ToCharArray() | ForEach-Object { $_ }); [array]::Reverse($r4); Write-Host "   $(-join $r4)" -ForegroundColor $dc
    Write-Host "             " -NoNewline; Write-Host "`u{2588}" -NoNewline -ForegroundColor $dg; Write-Host "`u{2588}`u{2588}" -NoNewline -ForegroundColor $g; Write-Host "`u{2588}" -ForegroundColor $dg
    Write-Host "             " -NoNewline; Write-Host "`u{2590}" -NoNewline -ForegroundColor $dg; Write-Host "`u{2588}`u{2588}" -NoNewline -ForegroundColor $g; Write-Host "`u{258C}" -ForegroundColor $dg
    Write-Host "              " -NoNewline; Write-Host $leg.A -ForegroundColor $dg
    Write-Host "               " -NoNewline; Write-Host $leg.B -ForegroundColor $dg
    Write-Host ""
    Write-Host "       $waitReason..." -ForegroundColor DarkGray
    Write-Host ""

    # Random bar style
    $barWidth = 36
    $barFillChar = @("`u{2588}", "`u{2593}", "`u{25A0}", "`u{2586}")[(Get-Random -Minimum 0 -Maximum 4)]
    $barEmptyChar = @("`u{2500}", "`u{2508}", "`u{00B7}", "`u{2504}")[(Get-Random -Minimum 0 -Maximum 4)]
    $barColors = @(
        @{ full = 'Green';   mid = 'Cyan';     tip = 'DarkCyan'   },
        @{ full = 'Magenta'; mid = 'White';     tip = 'DarkGray'   },
        @{ full = 'Blue';    mid = 'Cyan';      tip = 'DarkCyan'   },
        @{ full = 'Yellow';  mid = 'White';     tip = 'Gray'       },
        @{ full = 'Cyan';    mid = 'White';     tip = 'DarkGray'   }
    )
    $bc = $barColors[(Get-Random -Minimum 0 -Maximum $barColors.Count)]
    for ($i = 1; $i -le $waitSec; $i++) {
        $filled = [math]::Floor(($i / $waitSec) * $barWidth)
        $empty = $barWidth - $filled
        $pct = [math]::Floor(($i / $waitSec) * 100)
        Write-Host "`r  " -NoNewline
        for ($j = 0; $j -lt $filled; $j++) {
            $fromEnd = $filled - 1 - $j
            if ($fromEnd -ge 3) {
                Write-Host $barFillChar -NoNewline -ForegroundColor $bc.full
            } elseif ($fromEnd -eq 2) {
                Write-Host $barFillChar -NoNewline -ForegroundColor $bc.mid
            } elseif ($fromEnd -eq 1) {
                Write-Host $barFillChar -NoNewline -ForegroundColor $bc.tip
            } else {
                Write-Host $barFillChar -NoNewline -ForegroundColor $bc.tip
            }
        }
        Write-Host ($barEmptyChar * $empty) -NoNewline -ForegroundColor DarkGray
        Write-Host " $pct%" -NoNewline -ForegroundColor DarkGray
        Start-Sleep -Seconds 1
    }
    Write-Host ""
    Write-Host ""
}

# Snapshot session IDs before launch for diff-based detection
$sessionDir = "$HOME\.copilot\session-state"
$before = @()
if (-not $ResumeSessionId -and (Test-Path $sessionDir)) {
    $before = @(Get-ChildItem $sessionDir -Directory | ForEach-Object { $_.Name })
}

# Background watcher: bind session ID to state as soon as copilot creates it
$watcher = $null
$registration = $null
try {
    if (-not $ResumeSessionId -and (Test-Path $sessionDir)) {
        $watcher = [System.IO.FileSystemWatcher]::new($sessionDir)
        $watcher.NotifyFilter = [System.IO.NotifyFilters]::DirectoryName
        $watcher.IncludeSubdirectories = $false
        $watchContext = @{
            Before = $before; StateFile = $StateFile; Role = $Role; Alias = $Alias; TeamId = $TeamId; CicadaDb = $CicadaDb; Bound = $false
        }
        $registration = Register-ObjectEvent $watcher 'Created' -MessageData $watchContext -Action {
            $ctx = $Event.MessageData
            if ($ctx.Bound) { return }
            $newId = $Event.SourceEventArgs.Name
            if ($newId -notin $ctx.Before) {
                $maxRetries = 5
                for ($attempt = 0; $attempt -lt $maxRetries; $attempt++) {
                    try {
                        $fs = [System.IO.File]::Open($ctx.StateFile, 'Open', 'ReadWrite', 'None')
                        try {
                            $reader = [System.IO.StreamReader]::new($fs)
                            $obj = $reader.ReadToEnd() | ConvertFrom-Json
                            $reader.Dispose()
                            $p = $obj.panes | Where-Object { $_.alias -eq $ctx.Alias } | Select-Object -First 1
                            if ($p) {
                                $p | Add-Member -NotePropertyName 'sessionId' -NotePropertyValue $newId -Force
                                $fs.SetLength(0)
                                $writer = [System.IO.StreamWriter]::new($fs, [System.Text.Encoding]::UTF8)
                                $writer.Write(($obj | ConvertTo-Json -Depth 4))
                                $writer.Flush()
                                $writer.Dispose()
                                if ($ctx.TeamId -and $ctx.CicadaDb) {
                                    try {
                                        $vPy = Join-Path $HOME '.cicada\venv\Scripts\python.exe'
                                        & $vPy -m cicada_mcp bind-session --team-id $ctx.TeamId --alias $ctx.Alias --session-id $newId --db $ctx.CicadaDb 2>$null | Out-Null
                                    } catch {}
                                }
                                $ctx.Bound = $true
                            }
                        } finally { $fs.Dispose() }
                        break
                    } catch [System.IO.IOException] {
                        Start-Sleep -Milliseconds (100 * ($attempt + 1))
                    } catch { break }
                }
            }
        }
        $watcher.EnableRaisingEvents = $true
    }
} catch {
    Write-Verbose "FileSystemWatcher setup failed: $_"
}

# Set MCP environment variables before launch (inherited by the MCP server process)
if ($McpConfigPath -and (Test-Path $McpConfigPath)) {
    $env:CICADA_ALIAS = $Alias
    $env:CICADA_TEAM_ID = $TeamId
    $env:CICADA_DB = $CicadaDb
}

# Resolve effective max cycles: 0 = smart default (5 normally, unlimited in autopilot)
$mcpActive = $McpConfigPath -and (Test-Path $McpConfigPath)
$effectiveMaxCycles = if ($MaxCycles -gt 0) {
    $MaxCycles
} elseif ($Autopilot -and $mcpActive) {
    [int]::MaxValue
} elseif ($mcpActive) {
    5
} else {
    1
}
$cooldownSeconds = 3

function Get-PendingSummary {
    if (-not $CicadaDb -or -not $TeamId -or -not $Alias) { return $null }
    $venvPy = "$HOME\.cicada\venv\Scripts\python.exe"
    if (-not (Test-Path $venvPy)) { return $null }
    try {
        $raw = & $venvPy -m cicada_mcp check-pending --team-id $TeamId --alias $Alias --db $CicadaDb 2>$null
        if ($raw) { return ($raw | ConvertFrom-Json) }
    } catch {}
    return $null
}

function Get-BoundSessionId {
    if (-not (Test-Path $StateFile)) { return $null }
    try {
        $s = Get-Content $StateFile -Raw | ConvertFrom-Json
        $pane = $s.panes | Where-Object { $_.alias -eq $Alias } | Select-Object -First 1
        if ($pane -and $pane.sessionId) { return [string]$pane.sessionId }
    } catch {}
    return $null
}

# Launch copilot with team-aware prompt (with re-prompt loop for pending work)
$cycle = 0
$isFirstCycle = $true
do {
    $copilotArgs = @(Get-CopilotMcpIsolationArgs)
    if ($McpConfigPath -and (Test-Path $McpConfigPath)) {
        $copilotArgs += '--additional-mcp-config', "@$McpConfigPath"
        if (-not $effectiveYolo) {
            # Auto-approve Cicada coordination tools so agents don't need manual approval
            $copilotArgs += "--allow-tool=cicada"
        }
    }
    if ($effectiveYolo) {
        $copilotArgs += '--yolo'
    }
    if ($Autopilot) {
        $copilotArgs += '--autopilot'
    }

    if ($isFirstCycle) {
        if ($ResumeSessionId) {
            Update-AgentSessionBinding -SessionId $ResumeSessionId
            $copilotArgs += "--resume=$ResumeSessionId"
        } else {
            $copilotArgs += '-i', $fullPrompt
        }
    } else {
        # Re-prompt cycle: resume existing session with nudge
        $boundSid = Get-BoundSessionId
        if ($boundSid) {
            $copilotArgs += "--resume=$boundSid"
        }
        $copilotArgs += '-i', $script:nudgePrompt
    }

    copilot @copilotArgs
    $isFirstCycle = $false

    # ── Post-exit: session binding (first cycle only for watcher) ──
    if ($cycle -eq 0) {
        # Cleanup watcher
        if ($registration) { Unregister-Event -SubscriptionId $registration.Id -ErrorAction SilentlyContinue }
        if ($watcher) { $watcher.Dispose() }

        # Fallback: if watcher missed it, do post-exit diff detection with file locking
        if (-not $ResumeSessionId -and (Test-Path $sessionDir) -and (Test-Path $StateFile)) {
            $after = @(Get-ChildItem $sessionDir -Directory | ForEach-Object { $_.Name })
            $newSessions = $after | Where-Object { $_ -notin $before }
            if ($newSessions) {
                $sessionId = ($newSessions | Sort-Object | Select-Object -Last 1)
                Update-StateFile -Path $StateFile -Mutator {
                    param($s)
                    $pane = $s.panes | Where-Object { $_.alias -eq $Alias } | Select-Object -First 1
                    if ($pane -and -not $pane.sessionId) {
                        $pane | Add-Member -NotePropertyName 'sessionId' -NotePropertyValue $sessionId -Force
                        return $true
                    }
                    return $false
                }
                Update-AgentSessionBinding -SessionId $sessionId
            }
        }
    }

    # ── Check for pending work before re-prompting ──
    $cycle++
    if ($cycle -ge $effectiveMaxCycles) { break }
    if (-not $mcpActive) { break }

    $pending = Get-PendingSummary
    if (-not $pending) { break }

    $totalPending = $pending.unread + $pending.open_tasks + $pending.in_progress_tasks + ($pending.rework_tasks ?? 0)
    if ($totalPending -eq 0) {
        Write-Host "  [$Alias] No pending work on the board. Cycle complete." -ForegroundColor DarkGray
        break
    }

    # Build nudge prompt for next cycle
    $nudgeParts = @()
    if ($pending.unread -gt 0) { $nudgeParts += "$($pending.unread) unread message$(if ($pending.unread -ne 1) {'s'})" }
    if ($pending.open_tasks -gt 0) { $nudgeParts += "$($pending.open_tasks) open task$(if ($pending.open_tasks -ne 1) {'s'})" }
    if ($pending.in_progress_tasks -gt 0) { $nudgeParts += "$($pending.in_progress_tasks) task$(if ($pending.in_progress_tasks -ne 1) {'s'}) in progress" }
    if (($pending.rework_tasks ?? 0) -gt 0) { $nudgeParts += "$($pending.rework_tasks) task$(if ($pending.rework_tasks -ne 1) {'s'}) needs rework" }
    $script:nudgePrompt = "You have $($nudgeParts -join ' and ') on the board. Check your messages and the task board to continue working."

    Write-Host "  [$Alias] Pending work detected ($($nudgeParts -join ', ')). Re-prompting in ${cooldownSeconds}s... (cycle $cycle)" -ForegroundColor Yellow
    Start-Sleep -Seconds $cooldownSeconds

} while ($cycle -lt $effectiveMaxCycles)

if ($cycle -ge $effectiveMaxCycles -and $effectiveMaxCycles -ne [int]::MaxValue) {
    Write-Host "  [$Alias] Max re-prompt cycles ($effectiveMaxCycles) reached. Waiting for manual input." -ForegroundColor DarkGray
}
