# Install-Cicada.ps1 — Install Cicada from a local clone or extracted release archive

[CmdletBinding()]
param(
    [string]$SourcePath = $PSScriptRoot
)

$ErrorActionPreference = 'Stop'

# Warn if running in Windows PowerShell 5.1 instead of pwsh 7+
if ($PSVersionTable.PSVersion.Major -lt 7) {
    Write-Host ""
    Write-Host "  [WARN] You are running Windows PowerShell $($PSVersionTable.PSVersion)." -ForegroundColor Yellow
    Write-Host "         Cicada requires PowerShell 7+ (pwsh)." -ForegroundColor Yellow
    Write-Host "         Install: winget install Microsoft.PowerShell" -ForegroundColor DarkGray
    Write-Host "         Then re-run: pwsh -File .\Install-Cicada.ps1" -ForegroundColor DarkGray
    Write-Host ""
    return
}

# Re-launch with -NoProfile if profile is loaded (avoids Import-Module errors
# when re-installing, since the profile tries to load Cicada before it's copied)
if (-not $env:CICADA_INSTALLING) {
    $env:CICADA_INSTALLING = '1'
    & pwsh -NoProfile -File $MyInvocation.MyCommand.Path -SourcePath $SourcePath
    $env:CICADA_INSTALLING = $null
    return
}

# Spinner helper — runs a script block while showing a CLI loading animation
function Invoke-WithSpinner {
    param(
        [scriptblock]$ScriptBlock,
        [string]$Label
    )
    $frames = @('|', '/', '-', '\')
    $i = 0
    $job = Start-Job -ScriptBlock $ScriptBlock
    while ($job.State -eq 'Running') {
        $frame = $frames[$i % $frames.Count]
        Write-Host "`r        $frame $Label" -NoNewline -ForegroundColor DarkGray
        Start-Sleep -Milliseconds 200
        $i++
    }
    Write-Host "`r        " -NoNewline  # clear spinner line
    Write-Host "                                                  " -NoNewline  # overwrite residual
    Write-Host "`r" -NoNewline
    $result = Receive-Job $job
    $exitCode = if ($job.State -eq 'Failed') { 1 } else { 0 }
    Remove-Job $job
    return @{ Output = $result; ExitCode = $exitCode }
}

$SourcePath = (Resolve-Path $SourcePath).Path
$requiredPaths = @(
    'Cicada.psd1',
    'Cicada.psm1',
    'Invoke-Cicada.ps1',
    'Start-Agent.ps1',
    'Watch-Sessions.ps1',
    'roles.json',
    'pyproject.toml',
    'cicada_mcp'
)
foreach ($relativePath in $requiredPaths) {
    if (-not (Test-Path (Join-Path $SourcePath $relativePath))) {
        throw "Install source is incomplete: missing '$relativePath' under $SourcePath"
    }
}

# Resolve the user module directory from PSModulePath (handles folder redirection)
$userModuleRoot = ($env:PSModulePath -split [IO.Path]::PathSeparator |
    Where-Object { $_ -like "$HOME*" } |
    Select-Object -First 1)
if (-not $userModuleRoot) {
    $userModuleRoot = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'PowerShell\Modules'
}
$modulePath = Join-Path $userModuleRoot 'Cicada'
if (Test-Path $modulePath) {
    Write-Host "  Removing previous install..." -ForegroundColor DarkGray
    Remove-Item $modulePath -Recurse -Force
}

$g = 'Green'; $c = 'Cyan'; $dg = 'DarkGreen'; $dc = 'DarkCyan'
Write-Host ""
Write-Host "              " -NoNewline; Write-Host "▄" -NoNewline -ForegroundColor $dg; Write-Host "█" -NoNewline -ForegroundColor $g; Write-Host "▄" -ForegroundColor $dg
Write-Host "           " -NoNewline; Write-Host "▐" -NoNewline -ForegroundColor $dg; Write-Host "█" -NoNewline -ForegroundColor $dg; Write-Host "████" -NoNewline -ForegroundColor $g; Write-Host "█" -NoNewline -ForegroundColor $dg; Write-Host "▌" -ForegroundColor $dg
Write-Host "    ░▒▓▒░ " -NoNewline -ForegroundColor $c; Write-Host "█" -NoNewline -ForegroundColor $dg; Write-Host "████████" -NoNewline -ForegroundColor $g; Write-Host "█" -NoNewline -ForegroundColor $dg; Write-Host " ░▒▓▒░" -ForegroundColor $c
Write-Host "  ░▒▓▓▒░  " -NoNewline -ForegroundColor $c; Write-Host "▐" -NoNewline -ForegroundColor $dg; Write-Host "█" -NoNewline -ForegroundColor $dg; Write-Host "██████" -NoNewline -ForegroundColor $g; Write-Host "█" -NoNewline -ForegroundColor $dg; Write-Host "▌" -NoNewline -ForegroundColor $dg; Write-Host "  ░▒▓▓▒░" -ForegroundColor $c
Write-Host "   ░▒▓▒░   " -NoNewline -ForegroundColor $dc; Write-Host "█" -NoNewline -ForegroundColor $dg; Write-Host "██████" -NoNewline -ForegroundColor $g; Write-Host "█" -NoNewline -ForegroundColor $dg; Write-Host "   ░▒▓▒░" -ForegroundColor $dc
Write-Host "      ░▒▓   " -NoNewline -ForegroundColor $dc; Write-Host "█" -NoNewline -ForegroundColor $dg; Write-Host "████" -NoNewline -ForegroundColor $g; Write-Host "█" -NoNewline -ForegroundColor $dg; Write-Host "   ▓▒░" -ForegroundColor $dc
Write-Host "             " -NoNewline; Write-Host "█" -NoNewline -ForegroundColor $dg; Write-Host "██" -NoNewline -ForegroundColor $g; Write-Host "█" -ForegroundColor $dg
Write-Host "             " -NoNewline; Write-Host "▐" -NoNewline -ForegroundColor $dg; Write-Host "██" -NoNewline -ForegroundColor $g; Write-Host "▌" -ForegroundColor $dg
Write-Host "              " -NoNewline; Write-Host "▐▌" -ForegroundColor $dg
Write-Host "               " -NoNewline; Write-Host "▀" -ForegroundColor $dg
Write-Host "         Installing..." -ForegroundColor Cyan
Write-Host ""

# Copy PowerShell module files
Write-Host "  Copying PowerShell module..." -ForegroundColor White
New-Item $modulePath -ItemType Directory -Force | Out-Null
$psFiles = @('Cicada.psd1', 'Cicada.psm1', 'Invoke-Cicada.ps1', 'Start-Agent.ps1', 'Watch-Sessions.ps1', 'roles.json')
foreach ($f in $psFiles) {
    $src = Join-Path $SourcePath $f
    if (Test-Path $src) {
        Copy-Item $src "$modulePath\$f"
    }
}
Write-Host "        Copied to $modulePath" -ForegroundColor DarkGray

# Copy Python MCP package
Write-Host "  Copying Python MCP package..." -ForegroundColor White
$mcpSrc = Join-Path $SourcePath "cicada_mcp"
if (Test-Path $mcpSrc) {
    Copy-Item $mcpSrc "$modulePath\cicada_mcp" -Recurse
}
$pyprojectSrc = Join-Path $SourcePath "pyproject.toml"
if (Test-Path $pyprojectSrc) {
    Copy-Item $pyprojectSrc "$modulePath\pyproject.toml"
}
Write-Host "        Done" -ForegroundColor DarkGray

# Python MCP setup
Write-Host "  Setting up Python MCP server..." -ForegroundColor White

# Resolve python command (try python, then python3)
$pythonExe = $null
$pythonCmd = Get-Command python -ErrorAction SilentlyContinue
if ($pythonCmd) {
    # Detect Microsoft Store Python shim (returns exit code 9009 or opens Store)
    $testVer = & python --version 2>&1
    if ($LASTEXITCODE -eq 0 -and $testVer -match 'Python \d') {
        $pythonExe = 'python'
    }
}
if (-not $pythonExe) {
    $python3Cmd = Get-Command python3 -ErrorAction SilentlyContinue
    if ($python3Cmd) {
        $testVer = & python3 --version 2>&1
        if ($LASTEXITCODE -eq 0 -and $testVer -match 'Python \d') {
            $pythonExe = 'python3'
        }
    }
}

if ($pythonExe) {
    $pyVer = (& $pythonExe --version 2>&1) -replace 'Python\s*', ''
    Write-Host "        Found Python $pyVer" -ForegroundColor DarkGray

    # Check minimum version (3.10+)
    if ($pyVer -match '^(\d+)\.(\d+)') {
        $pyMajor = [int]$Matches[1]; $pyMinor = [int]$Matches[2]
        if ($pyMajor -lt 3 -or ($pyMajor -eq 3 -and $pyMinor -lt 10)) {
            Write-Host "        [WARN] Python $pyVer is too old — requires 3.10+ for MCP" -ForegroundColor Yellow
            Write-Host "        MCP features disabled. Upgrade Python and re-run installer." -ForegroundColor DarkGray
            $pythonExe = $null
        }
    }
}

if ($pythonExe) {
    $cicadaDir = "$HOME\.cicada"
    if (-not (Test-Path $cicadaDir)) { New-Item $cicadaDir -ItemType Directory -Force | Out-Null }

    # Check if pip is available — bootstrap if missing
    $pipCheck = & $pythonExe -m pip --version 2>&1
    if ($LASTEXITCODE -ne 0) {
        $pyExe = (Get-Command $pythonExe).Source
        $r = Invoke-WithSpinner -Label "Bootstrapping pip..." -ScriptBlock ([scriptblock]::Create("& '$pyExe' -m ensurepip --upgrade 2>&1"))
        $pipCheck = & $pythonExe -m pip --version 2>&1
    }

    if ($LASTEXITCODE -eq 0) {
        $pyExe = (Get-Command $pythonExe).Source
        $modDir = $modulePath
        $installed = $false
        try {
            $r = Invoke-WithSpinner -Label "Installing cicada-mcp..." -ScriptBlock ([scriptblock]::Create("& '$pyExe' -m pip install --quiet '$modDir' 2>&1; `$LASTEXITCODE"))
            # Verify it actually installed by trying to import it
            & $pythonExe -c "import cicada_mcp" 2>&1 | Out-Null
            if ($LASTEXITCODE -eq 0) {
                $installed = $true
            } else {
                # Retry with --user for externally-managed environments (Python 3.12+)
                $r2 = Invoke-WithSpinner -Label "Retrying with --user flag..." -ScriptBlock ([scriptblock]::Create("& '$pyExe' -m pip install --quiet --user '$modDir' 2>&1; `$LASTEXITCODE"))
                & $pythonExe -c "import cicada_mcp" 2>&1 | Out-Null
                if ($LASTEXITCODE -eq 0) { $installed = $true }
            }
        } catch {
            Write-Host "        [WARN] Python setup error: $_" -ForegroundColor Yellow
        }

        if ($installed) {
            Write-Host "        [OK] cicada-mcp installed" -ForegroundColor Green
        } else {
            Write-Host "        [WARN] cicada-mcp install failed — MCP features disabled" -ForegroundColor Yellow
            Write-Host "        Try manually: $pythonExe -m pip install `"$modulePath`"" -ForegroundColor DarkGray
        }
    } else {
        Write-Host "        [WARN] pip unavailable — MCP features disabled" -ForegroundColor Yellow
        Write-Host "        Fix: install pip, then re-run this installer" -ForegroundColor DarkGray
    }
} else {
    Write-Host "        [--] Python not found — MCP tools disabled (prompt-only mode)" -ForegroundColor Yellow
    Write-Host "        Install Python 3.10+ and re-run to enable MCP features." -ForegroundColor DarkGray
}

# Verify PS module loads (inside this process only)
Import-Module Cicada -Force
Write-Host ""
Write-Host "  Installed successfully." -ForegroundColor Green
Write-Host ""

# Offer to add Import-Module to $PROFILE for auto-load
$alreadyInProfile = $false
if (Test-Path $PROFILE) {
    $profileContent = Get-Content $PROFILE -Raw -ErrorAction SilentlyContinue
    if ($profileContent -and $profileContent -match 'Import-Module\s+Cicada') {
        $alreadyInProfile = $true
    }
}

if ($alreadyInProfile) {
    # Upgrade old profile line to include -ErrorAction SilentlyContinue
    if ($profileContent -match 'Import-Module\s+Cicada\s*$' -and $profileContent -notmatch 'ErrorAction') {
        $upgraded = $profileContent -replace 'Import-Module\s+Cicada', 'Import-Module Cicada -ErrorAction SilentlyContinue'
        Set-Content -Path $PROFILE -Value $upgraded.TrimEnd() -Encoding UTF8
    }
    Write-Host "  Import-Module Cicada already in `$PROFILE — will load automatically." -ForegroundColor DarkGray
} else {
    Write-Host "  Load cicada automatically in every PowerShell session?" -ForegroundColor White
    Write-Host "  This adds 'Import-Module Cicada' to your `$PROFILE." -ForegroundColor DarkGray
    Write-Host ""
    $answer = Read-Host "  Add to profile? [Y/n]"
    if ($answer -match '^[Yy]?$') {
        if (-not (Test-Path $PROFILE)) {
            New-Item $PROFILE -ItemType File -Force | Out-Null
        }
        Add-Content -Path $PROFILE -Value "Import-Module Cicada -ErrorAction SilentlyContinue"
        Write-Host "  Added to $PROFILE" -ForegroundColor Green
        Write-Host "  cicada will be available in every new pwsh session." -ForegroundColor DarkGray
    } else {
        Write-Host "  Skipped. To load manually, run:" -ForegroundColor DarkGray
        Write-Host "    Import-Module Cicada" -ForegroundColor Cyan
    }
}

Write-Host ""
Write-Host "  Next steps:" -ForegroundColor White
Write-Host ""
Write-Host "    Import-Module Cicada        # load in your current session" -ForegroundColor Cyan
Write-Host "    cicada --doctor             # verify all dependencies" -ForegroundColor DarkGray
Write-Host "    cicada                      # launch a team" -ForegroundColor DarkGray
Write-Host ""

# Offer to install cicada.cmd shim for cross-terminal access (cmd, Git Bash, etc.)
$shimDir = "$HOME\.cicada\bin"
$shimPath = "$shimDir\cicada.cmd"
$shimExists = Test-Path $shimPath
$onPath = $false
$userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
if ($userPath -and $userPath -split ';' -contains $shimDir) { $onPath = $true }

if ($shimExists -and $onPath) {
    Write-Host "  cicada.cmd shim already installed — available from any terminal." -ForegroundColor DarkGray
} else {
    Write-Host "  Make cicada available from any terminal (cmd, Git Bash, etc.)?" -ForegroundColor White
    Write-Host "  This creates a small wrapper at $shimDir" -ForegroundColor DarkGray
    Write-Host "  and adds it to your user PATH." -ForegroundColor DarkGray
    Write-Host ""
    $answer = Read-Host "  Add to PATH? [Y/n]"
    if ($answer -match '^[Yy]?$') {
        if (-not (Test-Path $shimDir)) { New-Item $shimDir -ItemType Directory -Force | Out-Null }
        @"
@echo off
pwsh -NoLogo -NoProfile -Command "Import-Module Cicada; Invoke-Cicada %*"
"@ | Set-Content $shimPath -Encoding ASCII
        Write-Host "  Created $shimPath" -ForegroundColor Green

        if (-not $onPath) {
            $newPath = if ($userPath) { "$userPath;$shimDir" } else { $shimDir }
            [Environment]::SetEnvironmentVariable('Path', $newPath, 'User')
            Write-Host "  Added to user PATH." -ForegroundColor Green
            Write-Host "  Restart your terminal for PATH changes to take effect." -ForegroundColor Yellow
        }
    } else {
        Write-Host "  Skipped. cicada will only be available inside pwsh sessions." -ForegroundColor DarkGray
    }
}
Write-Host ""
