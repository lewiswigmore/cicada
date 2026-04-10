# Cicada module loader
# Exports Invoke-Cicada and the 'cicada' alias

function Show-CicadaLogo {
    $g = 'Green'; $c = 'Cyan'; $dg = 'DarkGreen'; $dc = 'DarkCyan'
    Write-Host ""
    # head
    Write-Host "              " -NoNewline; Write-Host "▄" -NoNewline -ForegroundColor $dg; Write-Host "█" -NoNewline -ForegroundColor $g; Write-Host "▄" -ForegroundColor $dg
    # prothorax
    Write-Host "           " -NoNewline; Write-Host "▐" -NoNewline -ForegroundColor $dg; Write-Host "█" -NoNewline -ForegroundColor $dg; Write-Host "████" -NoNewline -ForegroundColor $g; Write-Host "█" -NoNewline -ForegroundColor $dg; Write-Host "▌" -ForegroundColor $dg
    # thorax + wings
    Write-Host "    ░▒▓▒░ " -NoNewline -ForegroundColor $c; Write-Host "█" -NoNewline -ForegroundColor $dg; Write-Host "████████" -NoNewline -ForegroundColor $g; Write-Host "█" -NoNewline -ForegroundColor $dg; Write-Host " ░▒▓▒░" -ForegroundColor $c
    # peak wings
    Write-Host "  ░▒▓▓▒░  " -NoNewline -ForegroundColor $c; Write-Host "▐" -NoNewline -ForegroundColor $dg; Write-Host "█" -NoNewline -ForegroundColor $dg; Write-Host "██████" -NoNewline -ForegroundColor $g; Write-Host "█" -NoNewline -ForegroundColor $dg; Write-Host "▌" -NoNewline -ForegroundColor $dg; Write-Host "  ░▒▓▓▒░" -ForegroundColor $c
    # wings taper
    Write-Host "   ░▒▓▒░   " -NoNewline -ForegroundColor $dc; Write-Host "█" -NoNewline -ForegroundColor $dg; Write-Host "██████" -NoNewline -ForegroundColor $g; Write-Host "█" -NoNewline -ForegroundColor $dg; Write-Host "   ░▒▓▒░" -ForegroundColor $dc
    # wings fade
    Write-Host "      ░▒▓   " -NoNewline -ForegroundColor $dc; Write-Host "█" -NoNewline -ForegroundColor $dg; Write-Host "████" -NoNewline -ForegroundColor $g; Write-Host "█" -NoNewline -ForegroundColor $dg; Write-Host "   ▓▒░" -ForegroundColor $dc
    # abdomen
    Write-Host "             " -NoNewline; Write-Host "█" -NoNewline -ForegroundColor $dg; Write-Host "██" -NoNewline -ForegroundColor $g; Write-Host "█" -ForegroundColor $dg
    # tail
    Write-Host "             " -NoNewline; Write-Host "▐" -NoNewline -ForegroundColor $dg; Write-Host "██" -NoNewline -ForegroundColor $g; Write-Host "▌" -ForegroundColor $dg
    # tip
    Write-Host "              " -NoNewline; Write-Host "▐▌" -ForegroundColor $dg
    # end
    Write-Host "               " -NoNewline; Write-Host "▀" -ForegroundColor $dg
    Write-Host ""
}

function Show-CicadaHelp {
    $v = (Import-PowerShellDataFile "$PSScriptRoot\Cicada.psd1").ModuleVersion
    Show-CicadaLogo
    Write-Host "  Multi-agent terminal orchestrator" -ForegroundColor DarkGray
    Write-Host "  Version $v" -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "  Usage: cicada [options]" -ForegroundColor White
    Write-Host ""
    Write-Host "  Options:" -ForegroundColor White
    Write-Host "    -h, --help              Show this help message"
    Write-Host "    --doctor                Run health checks on dependencies"
    Write-Host "    --update                Update a git install or show safe reinstall guidance"
    Write-Host "    --resume, --continue    Relaunch the last Cicada session in place"
    Write-Host "    --clear                 Delete Cicada session data and reset state"
    Write-Host "    --no-monitor            Launch without the sidebar monitor"
    Write-Host "    --no-mcp                Disable Cicada MCP and block other Copilot MCP servers"
    Write-Host "    --yolo                  Auto-approve all tools, paths, and URLs"
    Write-Host "    --autopilot             Enable Copilot autopilot mode (implies --yolo)"
    Write-Host "    --prompt <text>         Shared context for all agents on launch"
    Write-Host "                            e.g. --prompt `"We are working on the API`""
    Write-Host "    --team <roles>          Custom team composition (comma-separated)"
    Write-Host "                            e.g. --team `"coder,reviewer`""
    Write-Host "                            Supports 1-6 agents with auto layout"
    Write-Host "    -d, --directory <path>  Override working directory"
    Write-Host ""
    Write-Host "  Examples:" -ForegroundColor White
    Write-Host "    cicada                          # default 4-agent team + monitor"
    Write-Host "    cicada --yolo                    # auto-approve all tools, paths, and URLs"
    Write-Host "    cicada --autopilot               # autopilot mode (implies --yolo)"
    Write-Host "    cicada --continue                # reopen the last saved team session"
    Write-Host "    cicada --prompt `"Fix the auth bug`" # give all agents shared context"
    Write-Host "    cicada --team `"coder,tester`"     # 2-agent team"
    Write-Host "    cicada --no-mcp                  # launch without any MCP servers"
    Write-Host "    cicada --doctor                  # check dependencies"
    Write-Host ""
}

function Show-CicadaDoctor {
    $v = (Import-PowerShellDataFile "$PSScriptRoot\Cicada.psd1").ModuleVersion
    Write-Host ""
    Write-Host "  Cicada Doctor v$v" -ForegroundColor Cyan
    Write-Host "  Checking dependencies..." -ForegroundColor DarkGray
    Write-Host ""

    $allGood = $true
    $warnings = 0

    # Check pwsh
    $pwshCmd = Get-Command pwsh -ErrorAction SilentlyContinue
    if ($pwshCmd) {
        $pwshVer = (pwsh --version 2>$null) -replace 'PowerShell\s*', ''
        Write-Host "  [OK] pwsh $pwshVer" -ForegroundColor Green
    } else {
        Write-Host "  [!!] pwsh not found" -ForegroundColor Red
        $allGood = $false
    }

    # Check git (needed for --update)
    $gitCmd = Get-Command git -ErrorAction SilentlyContinue
    if ($gitCmd) {
        $gitVer = (git --version 2>$null) -replace 'git version\s*', ''
        Write-Host "  [OK] git $gitVer" -ForegroundColor Green
    } else {
        Write-Host "  [--] git not found — --update will not work" -ForegroundColor Yellow
        $warnings++
    }

    # Check Windows Terminal
    $wtCmd = Get-Command wt -ErrorAction SilentlyContinue
    if ($wtCmd) {
        Write-Host "  [OK] wt.exe" -ForegroundColor Green
    } else {
        Write-Host "  [!!] wt.exe not found — install: winget install Microsoft.WindowsTerminal" -ForegroundColor Red
        $allGood = $false
    }

    # Check Copilot CLI
    $copilotCmd = Get-Command copilot -ErrorAction SilentlyContinue
    if ($copilotCmd) {
        $copilotVer = ((copilot --version 2>$null) | Select-Object -First 1) -replace 'GitHub Copilot CLI\s*', '' -replace '[\.\s]+$', ''
        if ($copilotVer) {
            Write-Host "  [OK] copilot $copilotVer" -ForegroundColor Green
        } else {
            Write-Host "  [OK] copilot" -ForegroundColor Green
        }
    } else {
        Write-Host "  [!!] copilot not found — install: winget install GitHub.CopilotCLI" -ForegroundColor Red
        $allGood = $false
    }

    # Check Python
    $pythonCmd = Get-Command python -ErrorAction SilentlyContinue
    if ($pythonCmd) {
        $pyVer = (python --version 2>&1) -replace 'Python\s*', ''
        $pyMajor = 0; $pyMinor = 0
        if ($pyVer -match '^(\d+)\.(\d+)') { $pyMajor = [int]$Matches[1]; $pyMinor = [int]$Matches[2] }
        if ($pyMajor -ge 3 -and $pyMinor -ge 10) {
            Write-Host "  [OK] python $pyVer" -ForegroundColor Green
        } else {
            Write-Host "  [!!] python $pyVer — requires 3.10+ for MCP" -ForegroundColor Red
            $allGood = $false
        }
    } else {
        Write-Host "  [--] python not found — MCP coordination will be disabled" -ForegroundColor Yellow
        $warnings++
    }

    # Check mcp package
    if ($pythonCmd) {
        $mcpCheck = python -c "import cicada_mcp; print(cicada_mcp.__version__)" 2>&1
        if ($LASTEXITCODE -eq 0) {
            Write-Host "  [OK] cicada-mcp $mcpCheck" -ForegroundColor Green
        } else {
            Write-Host "  [--] cicada-mcp not installed — run: pip install -e ." -ForegroundColor Yellow
            $warnings++
        }
    }

    # Check MCP server can start (catches import errors, SDK conflicts)
    if ($pythonCmd -and $LASTEXITCODE -eq 0) {
        $serverCheck = python -c "from cicada_mcp.server import mcp" 2>&1
        if ($LASTEXITCODE -eq 0) {
            Write-Host "  [OK] MCP server importable" -ForegroundColor Green
        } else {
            Write-Host "  [!!] MCP server import failed — possible SDK conflict" -ForegroundColor Red
            Write-Host "       $serverCheck" -ForegroundColor DarkGray
            $allGood = $false
        }
    }

    # Check roles.json
    $rolesFile = "$PSScriptRoot\roles.json"
    if (Test-Path $rolesFile) {
        $roleCount = @((Get-Content $rolesFile -Raw | ConvertFrom-Json).PSObject.Properties).Count
        Write-Host "  [OK] roles.json ($roleCount roles)" -ForegroundColor Green
    } else {
        Write-Host "  [!!] roles.json missing from $PSScriptRoot" -ForegroundColor Red
        $allGood = $false
    }

    # Check cicada.db path
    $cicadaDir = "$HOME\.cicada"
    $cicadaDb = "$cicadaDir\cicada.db"
    if (Test-Path $cicadaDb) {
        $dbSize = [math]::Round((Get-Item $cicadaDb).Length / 1KB, 1)
        Write-Host "  [OK] cicada.db (${dbSize}KB)" -ForegroundColor Green
    } elseif (Test-Path $cicadaDir) {
        Write-Host "  [--] cicada.db not yet created (will be created on first MCP launch)" -ForegroundColor DarkGray
    } else {
        Write-Host "  [--] ~/.cicada/ directory not yet created" -ForegroundColor DarkGray
    }

    # Version check — compare local vs remote
    if ($gitCmd) {
        try {
            $remote = git -C $PSScriptRoot ls-remote --tags origin 2>$null |
                ForEach-Object { if ($_ -match 'refs/tags/v(.+)$') { $Matches[1] } } |
                Sort-Object { [version]$_ } -ErrorAction SilentlyContinue |
                Select-Object -Last 1
            if ($remote -and $remote -ne $v) {
                Write-Host "  [--] update available: v$remote (current: v$v) — run: cicada --update" -ForegroundColor Yellow
                $warnings++
            }
        } catch {
            # Silently skip version check on failure
        }
    }

    # Session stats
    $sessionDir = "$HOME\.copilot\session-state"
    $stateFile = "$HOME\.copilot\cicada-state.json"
    if (Test-Path $stateFile) {
        try {
            $state = Get-Content $stateFile -Raw | ConvertFrom-Json
            $paneCount = @($state.panes).Count
            Write-Host "  [--] last launch: $paneCount agents" -ForegroundColor DarkGray
        } catch {}
    }

    Write-Host ""
    if ($allGood -and $warnings -eq 0) {
        Write-Host "  All checks passed." -ForegroundColor Green
    } elseif ($allGood) {
        Write-Host "  Passed with $warnings warning(s) — see above." -ForegroundColor Yellow
    } else {
        Write-Host "  Some checks failed — see above." -ForegroundColor Red
    }
    Write-Host ""
}

function Update-Cicada {
    Write-Host ""
    Write-Host "  Cicada Update" -ForegroundColor Cyan
    Write-Host ""

    $moduleBase = $PSScriptRoot

    # Detect install method: git repo vs copied module
    $isGitRepo = Test-Path "$moduleBase\.git"

    if ($isGitRepo) {
        # Git clone install — pull latest
        Write-Host "  Pulling latest from origin..." -ForegroundColor DarkGray
        $pullOutput = git -C $moduleBase pull --ff-only 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-Host "  [!!] git pull failed:" -ForegroundColor Red
            Write-Host "  $pullOutput" -ForegroundColor Red
            return
        }
        Write-Host "  $pullOutput" -ForegroundColor DarkGray

        # Reinstall Python package if available
        $pythonCmd = Get-Command python -ErrorAction SilentlyContinue
        if ($pythonCmd) {
            Write-Host "  Updating Python MCP package..." -ForegroundColor DarkGray
            & python -m pip install --quiet -e "$moduleBase" 2>&1 | Out-Null
            if ($LASTEXITCODE -eq 0) {
                Write-Host "  [OK] cicada-mcp updated" -ForegroundColor Green
            } else {
                Write-Host "  [--] cicada-mcp pip install failed" -ForegroundColor Yellow
            }
        }
    } else {
        Write-Host "  Safe auto-update is only available for git-based installs." -ForegroundColor Yellow
        Write-Host "  This install does not have a git checkout, so Cicada will not download and execute remote code automatically." -ForegroundColor DarkGray
        Write-Host ""
        Write-Host "  Reinstall safely from a local clone or immutable release archive:" -ForegroundColor DarkGray
        Write-Host "    1. Download or clone the desired Cicada version locally" -ForegroundColor DarkGray
        Write-Host "    2. Run: pwsh -File .\\Install-Cicada.ps1" -ForegroundColor DarkGray
        Write-Host ""
        return
    }

    # Reload module
    Import-Module "$moduleBase\Cicada.psd1" -Force -Global
    $v = (Import-PowerShellDataFile "$moduleBase\Cicada.psd1").ModuleVersion
    Write-Host ""
    Write-Host "  Updated to v$v" -ForegroundColor Green
    Write-Host ""
}

function Invoke-Cicada {
    $params = @{}
    $showHelp = $false
    $i = 0

    while ($i -lt $args.Count) {
        $lower = "$($args[$i])".ToLower()

        if ($lower -in '--help', '-h') {
            $showHelp = $true
        }
        elseif ($lower -eq '--doctor') {
            Show-CicadaDoctor
            return
        }
        elseif ($lower -eq '--update') {
            Update-Cicada
            return
        }
        elseif ($lower -in '--resume', '--continue') {
            $params['Resume'] = $true
        }
        elseif ($lower -eq '--clear') {
            $params['Clear'] = $true
        }
        elseif ($lower -eq '--no-monitor') {
            $params['NoMonitor'] = $true
        }
        elseif ($lower -eq '--no-mcp') {
            $params['NoMcp'] = $true
        }
        elseif ($lower -eq '--yolo') {
            $params['Yolo'] = $true
        }
        elseif ($lower -eq '--autopilot') {
            $params['Autopilot'] = $true
            $params['Yolo'] = $true
        }
        elseif ($lower -eq '--prompt') {
            $i++
            if ($i -lt $args.Count) {
                $params['Prompt'] = "$($args[$i])"
            } else {
                Write-Host "  --prompt requires a text argument." -ForegroundColor Red
                return
            }
        }
        elseif ($lower -eq '--team') {
            $i++
            if ($i -lt $args.Count) {
                $params['Team'] = "$($args[$i])"
            } else {
                Write-Host "  --team requires a roles argument (e.g. `"coder,reviewer`")." -ForegroundColor Red
                return
            }
        }
        elseif ($lower -in '-d', '--directory') {
            $i++
            if ($i -lt $args.Count) {
                $params['WorkingDirectory'] = "$($args[$i])"
            } else {
                Write-Host "  --directory requires a path argument." -ForegroundColor Red
                return
            }
        }
        else {
            Write-Host "  Unknown option: $($args[$i])" -ForegroundColor Red
            Write-Host "  Run 'cicada --help' for usage." -ForegroundColor DarkGray
            return
        }

        $i++
    }

    if ($showHelp) {
        Show-CicadaHelp
        return
    }

    & "$PSScriptRoot\Invoke-Cicada.ps1" @params
}

Set-Alias -Name cicada -Value Invoke-Cicada -Scope Global
