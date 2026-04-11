# Watch-Sessions.ps1 — Live conversation monitor for Cicada
# Sidebar panel: team status, per-agent conversation context, activity feed
[CmdletBinding()]
param(
    [string]$StateFile = "$HOME\.copilot\cicada-state.json",
    [int]$Interval = 5
)

$sessionDir = "$HOME\.copilot\session-state"

# ── Python helper: batch-queries session-store.db in one process call ──
$queryScript = @'
import sqlite3, sys, json, os
db_path = os.path.expanduser("~/.copilot/session-store.db")
if not os.path.exists(db_path):
    print(json.dumps([]))
    sys.exit(0)
try:
    spec = json.loads(sys.argv[1])
except (IndexError, json.JSONDecodeError):
    print(json.dumps([]))
    sys.exit(0)
conn = sqlite3.connect(db_path, timeout=3)
conn.row_factory = sqlite3.Row
results = []
for item in spec:
    q = item.get("query", "")
    ids = item.get("ids", [])
    try:
        if ids:
            ph = ",".join(["?"] * len(ids))
            q = q.replace("?IDS?", ph)
            rows = conn.execute(q, ids).fetchall()
        else:
            rows = conn.execute(q).fetchall()
        results.append([dict(r) for r in rows])
    except Exception:
        results.append([])
conn.close()
print(json.dumps(results))
'@
$queryScriptPath = "$env:TEMP\cicada_query.py"
Set-Content $queryScriptPath $queryScript -Encoding UTF8

# ── Python helper: query cicada.db for board state ──
$boardQueryScript = @'
import sqlite3, sys, json, os

db_path = sys.argv[1] if len(sys.argv) > 1 else os.path.expanduser("~/.cicada/cicada.db")
if not os.path.exists(db_path):
    print(json.dumps({"messages": [], "tasks": [], "unread": {}, "activity": []}))
    sys.exit(0)

team_id = sys.argv[2] if len(sys.argv) > 2 else ""

try:
    conn = sqlite3.connect(db_path, timeout=3)
    conn.row_factory = sqlite3.Row

    # Unread counts per agent
    unread = {}
    if team_id:
        rows = conn.execute(
            "SELECT to_alias, COUNT(*) as cnt FROM messages WHERE team_id = ? AND read = 0 AND to_alias IS NOT NULL GROUP BY to_alias",
            (team_id,)
        ).fetchall()
        for r in rows:
            unread[r["to_alias"]] = r["cnt"]
        # Also count broadcasts
        bc = conn.execute(
            "SELECT COUNT(*) as cnt FROM messages WHERE team_id = ? AND read = 0 AND to_alias IS NULL",
            (team_id,)
        ).fetchone()
        if bc and bc["cnt"] > 0:
            unread["_broadcast"] = bc["cnt"]

    # Recent messages (last 5)
    messages = []
    if team_id:
        rows = conn.execute(
            "SELECT from_alias, to_alias, kind, payload, created_at FROM messages WHERE team_id = ? ORDER BY created_at DESC LIMIT 5",
            (team_id,)
        ).fetchall()
        messages = [dict(r) for r in rows]

    # Task summary (recent 10 for display)
    tasks = []
    task_counts = {}
    if team_id:
        rows = conn.execute(
            "SELECT id, title, status, claimed_by, created_by FROM tasks WHERE team_id = ? ORDER BY created_at DESC LIMIT 10",
            (team_id,)
        ).fetchall()
        tasks = [dict(r) for r in rows]
        # Aggregate counts across ALL tasks (not limited)
        count_rows = conn.execute(
            "SELECT status, COUNT(*) as cnt FROM tasks WHERE team_id = ? GROUP BY status",
            (team_id,)
        ).fetchall()
        task_counts = {r['status']: r['cnt'] for r in count_rows}

    # Recent activity from task_events (last 5)
    activity = []
    if team_id:
        try:
            rows = conn.execute(
                "SELECT e.agent, e.event, e.detail, e.created_at, t.title "
                "FROM task_events e JOIN tasks t ON t.id = e.task_id "
                "WHERE e.team_id = ? ORDER BY e.created_at DESC LIMIT 5",
                (team_id,)
            ).fetchall()
            activity = [dict(r) for r in rows]
        except Exception:
            pass

    # Per-agent activity summary (event count + last event time + last message snippet)
    agent_status = {}
    if team_id:
        try:
            rows = conn.execute(
                "SELECT agent, COUNT(*) as events, MAX(created_at) as last_event "
                "FROM task_events WHERE team_id = ? GROUP BY agent",
                (team_id,)
            ).fetchall()
            for r in rows:
                agent_status[r["agent"]] = {"events": r["events"], "last_event": r["last_event"], "last_msg": ""}
        except Exception:
            pass
        try:
            rows = conn.execute(
                "SELECT from_alias, payload, created_at FROM messages "
                "WHERE team_id = ? AND id IN (SELECT MAX(id) FROM messages WHERE team_id = ? GROUP BY from_alias)",
                (team_id, team_id)
            ).fetchall()
            for r in rows:
                alias = r["from_alias"]
                if alias not in agent_status:
                    agent_status[alias] = {"events": 0, "last_event": r["created_at"], "last_msg": ""}
                snippet = (r["payload"] or "")[:120].replace("\n", " ")
                agent_status[alias]["last_msg"] = snippet
                if not agent_status[alias]["last_event"] or r["created_at"] > agent_status[alias]["last_event"]:
                    agent_status[alias]["last_event"] = r["created_at"]
        except Exception:
            pass

    conn.close()
    print(json.dumps({"messages": messages, "tasks": tasks, "task_counts": task_counts, "unread": unread, "activity": activity, "agent_status": agent_status}))
except Exception as e:
    print(json.dumps({"messages": [], "tasks": [], "task_counts": {}, "unread": {}, "activity": [], "error": str(e)}))
'@
$boardQueryScriptPath = "$env:TEMP\cicada_board_query.py"
Set-Content $boardQueryScriptPath $boardQueryScript -Encoding UTF8

function Invoke-BatchQuery {
    param([array]$Queries)
    $venvPy = "$HOME\.cicada\venv\Scripts\python.exe"
    $py = if (Test-Path $venvPy) { $venvPy }
         elseif (Get-Command python3 -ErrorAction SilentlyContinue) { 'python3' }
         elseif (Get-Command python -ErrorAction SilentlyContinue) { 'python' }
         else { $null }
    if (-not $py) { return @() }
    try {
        $spec = $Queries | ConvertTo-Json -Depth 3 -Compress
        $raw = & $py $queryScriptPath $spec 2>$null
        if ($raw) { return ($raw | ConvertFrom-Json) }
    } catch {}
    return @()
}

function Invoke-BoardQuery {
    param([string]$DbPath, [string]$TeamId)
    $venvPy = "$HOME\.cicada\venv\Scripts\python.exe"
    $py = if (Test-Path $venvPy) { $venvPy }
         elseif (Get-Command python3 -ErrorAction SilentlyContinue) { 'python3' }
         elseif (Get-Command python -ErrorAction SilentlyContinue) { 'python' }
         else { $null }
    if (-not $py) { return @{ messages = @(); tasks = @(); unread = @{} } }
    try {
        $raw = & $py $boardQueryScriptPath $DbPath $TeamId 2>$null
        if ($raw) { return ($raw | ConvertFrom-Json) }
    } catch {}
    return @{ messages = @(); tasks = @(); unread = @{} }
}

# ── ANSI helpers ──
function Get-AnsiColor([string]$hex) {
    $r = [Convert]::ToInt32($hex.Substring(1, 2), 16)
    $g = [Convert]::ToInt32($hex.Substring(3, 2), 16)
    $b = [Convert]::ToInt32($hex.Substring(5, 2), 16)
    return "`e[38;2;${r};${g};${b}m"
}
$rst = "`e[0m"
$dim = "`e[90m"
$bold = "`e[1m"

function Get-PanelWidth {
    try { return [math]::Max(28, $Host.UI.RawUI.WindowSize.Width) }
    catch { return 34 }
}

function Truncate([string]$text, [int]$max) {
    if (-not $text -or $max -le 0) { return "" }
    # Strip ANSI escape sequences and collapse whitespace
    $clean = ($text -replace "`e\[[0-9;]*m", '' -replace '[\x00-\x1F]', ' ' -replace '\s+', ' ').Trim()
    if ($clean.Length -le $max) { return $clean }
    return $clean.Substring(0, $max - 1) + [char]0x2026
}

function Get-FirstMeaningfulLine([string]$text) {
    if (-not $text) { return "" }
    # Skip blank lines, fenced code markers, and pure-whitespace lines
    foreach ($line in ($text -split "`n")) {
        $trimmed = $line.Trim()
        if ($trimmed.Length -gt 0 -and $trimmed -notmatch '^```' -and $trimmed -notmatch '^---+$' -and $trimmed -notmatch '^\*\*\*+$') {
            return $trimmed
        }
    }
    return ""
}

function Format-Ago([string]$isoTimestamp) {
    if (-not $isoTimestamp) { return "?" }
    try {
        $dt = [DateTime]::Parse($isoTimestamp)
        $mins = [math]::Round(((Get-Date).ToUniversalTime() - $dt).TotalMinutes)
        if ($mins -lt 1) { return "now" }
        if ($mins -lt 60) { return "${mins}m" }
        return "$([math]::Floor($mins / 60))h"
    } catch { return "?" }
}

# ── Helper: safely extract DateTime from state (avoids culture-dependent re-parsing) ──
function Get-LaunchDateTime($value) {
    if ($value -is [datetime]) { return $value }
    return Get-Date $value
}

function Sync-AgentSessionBinding {
    param(
        [string]$DbPath,
        [string]$TeamId,
        [string]$Alias,
        [string]$SessionId
    )
    if (-not $DbPath -or -not $TeamId -or -not $Alias -or -not $SessionId) { return }
    $venvPy = "$HOME\.cicada\venv\Scripts\python.exe"
    try {
        & $venvPy -m cicada_mcp bind-session --team-id $TeamId --alias $Alias --session-id $SessionId --db $DbPath 2>$null | Out-Null
    } catch {}
}

# ── Session ID discovery: bind unbound panes to newly created sessions ──
function Resolve-SessionIds {
    param($State)
    if (-not $State -or -not $State.panes -or -not $State.launchedAt) { return $false }
    if (-not (Test-Path $sessionDir)) { return $false }

    $unbound = @($State.panes | Where-Object { $_.role -and -not $_.sessionId })
    if ($unbound.Count -eq 0) { return $false }

    $launchDt = Get-LaunchDateTime $State.launchedAt
    $launchTime = $launchDt.AddSeconds(-10)
    $boundIds = @($State.panes | Where-Object { $_.sessionId } | ForEach-Object { $_.sessionId })

    $candidates = @(Get-ChildItem $sessionDir -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.CreationTime -ge $launchTime -and $_.Name -notin $boundIds } |
        Sort-Object CreationTime)

    if ($candidates.Count -eq 0) { return $false }

    $changed = $false
    for ($i = 0; $i -lt [math]::Min($unbound.Count, @($candidates).Count); $i++) {
        $unbound[$i] | Add-Member -NotePropertyName 'sessionId' -NotePropertyValue $candidates[$i].Name -Force
        Sync-AgentSessionBinding -DbPath $State.cicadaDb -TeamId $State.sessionGuid -Alias $unbound[$i].alias -SessionId $candidates[$i].Name
        $changed = $true
    }

    if ($changed) {
        # Write with file locking to avoid conflicts with Start-Agent
        for ($attempt = 0; $attempt -lt 3; $attempt++) {
            try {
                $fs = [System.IO.File]::Open($StateFile, 'Open', 'ReadWrite', 'None')
                try {
                    $fs.SetLength(0)
                    $writer = [System.IO.StreamWriter]::new($fs, [System.Text.Encoding]::UTF8)
                    $writer.Write(($State | ConvertTo-Json -Depth 3))
                    $writer.Flush()
                    $writer.Dispose()
                } finally { $fs.Dispose() }
                break
            } catch [System.IO.IOException] {
                Start-Sleep -Milliseconds (100 * ($attempt + 1))
            } catch { break }
        }
    }
    return $changed
}

# ── Main render ──
function Show-Monitor {
    Clear-Host
    $w = Get-PanelWidth
    $lineChar = [string]::new([char]0x2500, [math]::Min($w - 2, 40))
    $contextWidth = $w - 6
    $time = Get-Date -Format "HH:mm:ss"

    # Load state
    $state = $null
    if (Test-Path $StateFile) {
        try { $state = Get-Content $StateFile -Raw | ConvertFrom-Json } catch {}
    }

    # Try to discover session IDs for unbound panes
    if ($state) { [void](Resolve-SessionIds $state) }

    # ── Header ──
    Write-Host " ${bold}`u{25A0} CICADA${rst}  ${dim}$time${rst}"

    # Uptime + agent count
    $upStr = "?"
    if ($state -and $state.launchedAt) {
        try {
            $upMin = [math]::Floor(((Get-Date) - (Get-LaunchDateTime $state.launchedAt)).TotalMinutes)
            $upStr = if ($upMin -lt 1) { "<1m" } elseif ($upMin -lt 60) { "${upMin}m" } else { "$([math]::Floor($upMin/60))h$($upMin % 60)m" }
        } catch {}
    }
    # Agent count: use pane count from state, not system-wide process count
    $agentCount = if ($state -and $state.panes) { @($state.panes).Count } else { 0 }
    Write-Host " ${dim}$agentCount agents `u{2502} up $upStr${rst}"
    Write-Host " $dim$lineChar$rst"

    if (-not $state -or -not $state.panes) {
        Write-Host ""; Write-Host " ${dim}Waiting for cicada launch...$rst"
        Write-Host " $dim$lineChar$rst"
        Write-Host " ${dim}`u{21BB} ${Interval}s `u{2502} Ctrl+C exit$rst"
        return
    }

    # ── Batch DB query: per-agent stats + latest turn from Copilot session-store ──
    $sessionIds = @($state.panes | Where-Object { $_.sessionId } | ForEach-Object { $_.sessionId })
    $agentData = @{}

    if ($sessionIds.Count -gt 0) {
        $results = Invoke-BatchQuery -Queries @(
            # Q0: CTE — stats + latest turn per agent in a single query
            @{
                query = "WITH latest AS (SELECT session_id, MAX(turn_index) AS max_turn, COUNT(*) AS turns, MAX(timestamp) AS last_active FROM turns WHERE session_id IN (?IDS?) GROUP BY session_id) SELECT l.session_id, l.turns, l.last_active, t.user_message, t.assistant_response FROM latest l LEFT JOIN turns t ON t.session_id = l.session_id AND t.turn_index = l.max_turn"
                ids = $sessionIds
            }
        )
        if ($results.Count -ge 1 -and $results[0]) {
            foreach ($r in $results[0]) { $agentData[$r.session_id] = $r }
        }
    }

    # Fetch cicada board data early so we can use agent_status in the Team section
    $cicadaDb = "$HOME\.cicada\cicada.db"
    $teamId = $state.sessionGuid
    $boardData = $null
    if ((Test-Path $cicadaDb) -and $teamId) {
        $boardData = Invoke-BoardQuery -DbPath $cicadaDb -TeamId $teamId
    }

    # Total turns
    $totalTurns = 0
    foreach ($d in $agentData.Values) { $totalTurns += $d.turns }
    if ($totalTurns -gt 0) { Write-Host " ${dim}$totalTurns turns across team${rst}" }
    Write-Host ""

    # ── Team: per-agent status + conversation context ──
    Write-Host " ${bold}Team${rst}" -ForegroundColor Yellow

    foreach ($p in $state.panes) {
        $color = Get-AnsiColor $p.color

        # Determine status: prefer cicada DB agent_status, fall back to session-store
        $turns = 0; $age = ""; $status = "launching"; $contextLine = ""
        $cicadaStatus = $null
        if ($boardData -and $boardData.agent_status -and $boardData.agent_status.PSObject.Properties[$p.alias]) {
            $cicadaStatus = $boardData.agent_status.($p.alias)
        }

        if ($p.sessionId -and $agentData.ContainsKey($p.sessionId)) {
            $d = $agentData[$p.sessionId]
            $turns = $d.turns
            $age = Format-Ago $d.last_active
            $status = if ($turns -eq 0) { "waiting" }
                      elseif ($age -eq "now" -or $age -eq "1m") { "active" }
                      else { "idle" }
            # Context from session-store
            if ($d.assistant_response) {
                $contextLine = Truncate (Get-FirstMeaningfulLine $d.assistant_response) $contextWidth
            } elseif ($d.user_message) {
                $contextLine = Truncate $d.user_message $contextWidth
            }
        } elseif ($p.sessionId) {
            $status = "waiting"
        }

        # Override with cicada DB info if session-store has no data
        if ($cicadaStatus -and ($status -eq "launching" -or $status -eq "waiting" -or ($turns -eq 0 -and $cicadaStatus.events -gt 0))) {
            $cicadaAge = Format-Ago $cicadaStatus.last_event
            $status = if ($cicadaAge -eq "now" -or $cicadaAge -eq "1m") { "active" } else { "idle" }
            $turns = $cicadaStatus.events
            $age = $cicadaAge
            if (-not $contextLine -and $cicadaStatus.last_msg) {
                $contextLine = Truncate $cicadaStatus.last_msg $contextWidth
            }
        }

        $dot = switch ($status) {
            "active"    { "`e[32m" + [char]0x25CF + $rst }   # green filled
            "waiting"   { "`e[33m" + [char]0x25CF + $rst }   # yellow filled
            "launching" { "`e[33m" + [char]0x25CB + $rst }   # yellow hollow
            "idle"      { $dim + [char]0x25CF + $rst }       # gray filled
            default     { $dim + [char]0x25CB + $rst }       # gray hollow
        }

        $statsStr = if ($turns -gt 0) { " ${dim}${turns}t $age${rst}" }
                    elseif ($status -eq "launching") { " ${dim}starting${rst}" }
                    elseif ($status -eq "waiting") { " ${dim}ready${rst}" }
                    else { "" }

        Write-Host " ${dot} ${color}$($p.title)${rst}${statsStr}"

        if ($contextLine) {
            Write-Host "   ${dim}$contextLine${rst}"
        } elseif ($status -eq "waiting") {
            Write-Host "   ${dim}awaiting first prompt${rst}"
        } elseif ($status -eq "launching") {
            Write-Host "   ${dim}copilot loading...${rst}"
        }
    }

    # ── Board: messages + tasks from cicada.db ──
    if ($boardData -and ($boardData.messages.Count -gt 0 -or $boardData.tasks.Count -gt 0)) {
        Write-Host ""
        Write-Host " ${bold}Board${rst}" -ForegroundColor Yellow

        # Unread summary
        $totalUnread = 0
        if ($boardData.unread) {
            foreach ($key in $boardData.unread.PSObject.Properties.Name) {
                $totalUnread += $boardData.unread.$key
            }
        }
        # Use aggregate counts (accurate across all tasks, not just the LIMIT 10 display list)
        $tc = $boardData.task_counts
        $taskOpen = if ($tc -and $tc.open) { $tc.open } else { 0 }
        $taskInProgress = if ($tc -and $tc.'in-progress') { $tc.'in-progress' } else { 0 }
        $taskDone = if ($tc -and $tc.done) { $tc.done } else { 0 }
        $taskRework = if ($tc -and $tc.'needs-rework') { $tc.'needs-rework' } else { 0 }

        if ($totalUnread -gt 0) {
            # Show per-agent unread
            $unreadParts = @()
            foreach ($key in $boardData.unread.PSObject.Properties.Name) {
                if ($key -ne '_broadcast') {
                    $unreadParts += "$($boardData.unread.$key) for $key"
                }
            }
            $unreadStr = if ($unreadParts.Count -gt 0) { " ($($unreadParts -join ', '))" } else { "" }
            Write-Host " Unread: $totalUnread$unreadStr" -ForegroundColor White
        }

        $taskTotal = $taskOpen + $taskInProgress + $taskDone + $taskRework
        if ($taskTotal -gt 0) {
            $taskParts = @()
            if ($taskOpen -gt 0) { $taskParts += "$taskOpen open" }
            if ($taskInProgress -gt 0) { $taskParts += "$taskInProgress in-progress" }
            if ($taskRework -gt 0) { $taskParts += "$taskRework needs-rework" }
            if ($taskDone -gt 0) { $taskParts += "$taskDone done" }
            Write-Host " Tasks: $taskTotal ($($taskParts -join ', '))" -ForegroundColor White
        }

        # Recent messages (max 3)
        if ($boardData.messages.Count -gt 0) {
            Write-Host ""
            $msgShown = 0
            foreach ($msg in $boardData.messages) {
                if ($msgShown -ge 3) { break }
                $fromAlias = $msg.from_alias
                $toAlias = if ($msg.to_alias) { $msg.to_alias } else { "team" }
                $arrow = [char]0x2192  # →
                $msgTime = ""
                if ($msg.created_at) {
                    try { $msgTime = ([DateTime]::Parse($msg.created_at)).ToLocalTime().ToString("HH:mm") } catch {}
                }
                $preview = Truncate $msg.payload ($w - 10)
                Write-Host " ${dim}$msgTime${rst} $fromAlias $arrow $toAlias"
                if ($preview) { Write-Host "   ${dim}$preview${rst}" }
                $msgShown++
            }
        }
    }

    # ── Idle alerts: warn when agents are idle with pending work ──
    if ($boardData) {
        $idleAlerts = @()
        foreach ($p in $state.panes) {
            # Determine if this agent is idle
            $agentStatus = "launching"
            $cicadaStatus = $null
            if ($boardData.agent_status -and $boardData.agent_status.PSObject.Properties[$p.alias]) {
                $cicadaStatus = $boardData.agent_status.($p.alias)
            }
            if ($p.sessionId -and $agentData.ContainsKey($p.sessionId)) {
                $d = $agentData[$p.sessionId]
                $agentAge = Format-Ago $d.last_active
                $agentStatus = if ($d.turns -eq 0) { "waiting" }
                              elseif ($agentAge -eq "now" -or $agentAge -eq "1m") { "active" }
                              else { "idle" }
            } elseif ($p.sessionId) {
                $agentStatus = "waiting"
            }
            # Fallback to cicada DB when session-store has no data
            if ($cicadaStatus -and ($agentStatus -eq "launching" -or $agentStatus -eq "waiting" -or ($agentStatus -eq "idle" -and $cicadaStatus.events -gt 0))) {
                $cicadaAge = Format-Ago $cicadaStatus.last_event
                $agentStatus = if ($cicadaAge -eq "now" -or $cicadaAge -eq "1m") { "active" } else { "idle" }
            }

            if ($agentStatus -ne "idle") { continue }

            # Check if this agent has pending work
            $agentUnread = 0
            if ($boardData.unread -and $boardData.unread.PSObject.Properties[$p.alias]) {
                $agentUnread = $boardData.unread.($p.alias)
            }
            $pendingParts = @()
            if ($agentUnread -gt 0) { $pendingParts += "$agentUnread unread" }
            if ($taskOpen -gt 0) { $pendingParts += "$taskOpen open task$(if ($taskOpen -ne 1) {'s'})" }
            if ($taskRework -gt 0) { $pendingParts += "$taskRework needs-rework" }
            if ($pendingParts.Count -gt 0) {
                $idleAlerts += " [!] $($p.alias) idle with $($pendingParts -join ', ')"
            }
        }
        if ($idleAlerts.Count -gt 0) {
            Write-Host ""
            foreach ($alert in $idleAlerts) {
                Write-Host $alert -ForegroundColor Yellow
            }
        }
    }

    Write-Host ""

    # ── Activity feed: recent task events from cicada DB ──
    if ($boardData -and $boardData.activity -and @($boardData.activity).Count -gt 0) {
        Write-Host " ${bold}Recent${rst}" -ForegroundColor Yellow

        # Map alias → color
        $aliasColor = @{}
        foreach ($p in $state.panes) {
            $aliasColor[$p.alias] = Get-AnsiColor $p.color
        }

        $shown = 0
        foreach ($evt in $boardData.activity) {
            if ($shown -ge 3) { break }
            $agentAlias = $evt.agent
            $roleColor = if ($aliasColor.ContainsKey($agentAlias)) { $aliasColor[$agentAlias] } else { $dim }
            $evtTime = ""
            if ($evt.created_at) {
                try { $evtTime = ([DateTime]::Parse($evt.created_at)).ToLocalTime().ToString("HH:mm") } catch {}
            }
            $evtTitle = Truncate $evt.title ($w - 16)
            $evtDetail = if ($evt.detail) { " [$($evt.detail)]" } else { "" }
            Write-Host " ${dim}$evtTime${rst} ${roleColor}$agentAlias${rst} $($evt.event)${dim}$evtDetail${rst}"
            if ($evtTitle) { Write-Host "   ${dim}$evtTitle${rst}" }
            $shown++
        }
    }

    Write-Host ""

    # ── Other sessions (compact) ──
    if (Test-Path $sessionDir) {
        $gridIds = @($state.panes | Where-Object { $_.sessionId } | ForEach-Object { $_.sessionId })
        $allOthers = @(Get-ChildItem $sessionDir -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -notin $gridIds })
        if ($allOthers.Count -gt 0) {
            $recent = $allOthers | Sort-Object LastWriteTime -Descending | Select-Object -First 3
            Write-Host " ${dim}$($allOthers.Count) other sessions${rst}"
            foreach ($s in $recent) {
                $id = $s.Name.Substring(0, 8)
                $mins = [math]::Round(((Get-Date) - $s.LastWriteTime).TotalMinutes)
                $age = if ($mins -lt 1) { "now" } elseif ($mins -lt 60) { "${mins}m" } else { "$([math]::Floor($mins/60))h" }
                Write-Host " ${dim}`u{25CB} $id $age${rst}"
            }
        }
    }

    Write-Host ""
    Write-Host " $dim$lineChar$rst"
    Write-Host " ${dim}`u{21BB} ${Interval}s `u{2502} Ctrl+C exit$rst"
}

while ($true) {
    Show-Monitor
    Start-Sleep -Seconds $Interval
}
