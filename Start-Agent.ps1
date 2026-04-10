# Start-Agent.ps1 — Wrapper to launch copilot with role + team awareness + MCP
# Called by Invoke-Cicada.ps1 per pane to avoid wt quoting issues
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidatePattern('^[a-z][a-z0-9\-]{0,30}$')]
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
    [string]$Prompt
)

if (-not $RolesFile) { $RolesFile = "$PSScriptRoot\roles.json" }
if (-not $Alias) { $Alias = $Role }

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
    $pythonCmd = Get-Command python -ErrorAction SilentlyContinue
    if (-not $pythonCmd) { return }
    try {
        & python -m cicada_mcp bind-session --team-id $TeamId --alias $Alias --session-id $SessionId --db $CicadaDb 2>$null | Out-Null
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

# Assemble prompt: user context (if any) + role + teammates + coordination hint
$parts = @()
if ($Prompt) {
    $parts += $Prompt
}
$parts += $config.prompt
if ($teammates) {
    $parts += "Your teammates: $($teammates -join ', ')."
}
if ($McpConfigPath -and (Test-Path $McpConfigPath)) {
    $parts += "You have Cicada coordination tools for messaging teammates and managing a shared task board. Do not use them until you have been given a task."
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
                                        & python -m cicada_mcp bind-session --team-id $ctx.TeamId --alias $ctx.Alias --session-id $newId --db $ctx.CicadaDb 2>$null | Out-Null
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

# Launch copilot with team-aware prompt
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
if ($ResumeSessionId) {
    Update-AgentSessionBinding -SessionId $ResumeSessionId
    $copilotArgs += "--resume=$ResumeSessionId"
} else {
    $copilotArgs += '-i', $fullPrompt
}
copilot @copilotArgs

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
