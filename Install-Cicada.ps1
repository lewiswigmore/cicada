# Install-Cicada.ps1 — Install Cicada from a local clone or extracted release archive

[CmdletBinding()]
param(
    [string]$SourcePath = $PSScriptRoot
)

$ErrorActionPreference = 'Stop'

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

$modulePath = "$HOME\Documents\PowerShell\Modules\Cicada"
if (Test-Path $modulePath) {
    Write-Host "Updating existing Cicada install..." -ForegroundColor Yellow
    Remove-Item $modulePath -Recurse -Force
}

Write-Host "[CICADA] Installing..." -ForegroundColor Cyan

# Copy PowerShell module files
New-Item $modulePath -ItemType Directory -Force | Out-Null
$psFiles = @('Cicada.psd1', 'Cicada.psm1', 'Invoke-Cicada.ps1', 'Start-Agent.ps1', 'Watch-Sessions.ps1', 'roles.json')
foreach ($f in $psFiles) {
    $src = Join-Path $SourcePath $f
    if (Test-Path $src) {
        Copy-Item $src "$modulePath\$f"
    }
}

# Copy Python MCP package
$mcpSrc = Join-Path $SourcePath "cicada_mcp"
if (Test-Path $mcpSrc) {
    Copy-Item $mcpSrc "$modulePath\cicada_mcp" -Recurse
}
$pyprojectSrc = Join-Path $SourcePath "pyproject.toml"
if (Test-Path $pyprojectSrc) {
    Copy-Item $pyprojectSrc "$modulePath\pyproject.toml"
}

# Python MCP setup
$pythonCmd = Get-Command python -ErrorAction SilentlyContinue
if ($pythonCmd) {
    Write-Host "  Setting up Python MCP server..." -ForegroundColor DarkGray
    $cicadaDir = "$HOME\.cicada"
    if (-not (Test-Path $cicadaDir)) { New-Item $cicadaDir -ItemType Directory -Force | Out-Null }

    try {
        # Install cicada-mcp from the copied package
        & python -m pip install --quiet "$modulePath" 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) {
            Write-Host "  [OK] cicada-mcp installed" -ForegroundColor Green
        } else {
            Write-Host "  [WARN] cicada-mcp install failed — MCP features disabled" -ForegroundColor Yellow
            Write-Host "  Run 'cicada --doctor' to diagnose." -ForegroundColor DarkGray
        }
    } catch {
        Write-Host "  [WARN] Python setup error: $_" -ForegroundColor Yellow
    }
} else {
    Write-Host "  [INFO] Python not found — MCP tools disabled (prompt-only mode)" -ForegroundColor Yellow
    Write-Host "  Install Python 3.10+ and run 'cicada --doctor' to enable MCP features." -ForegroundColor DarkGray
}

# Verify PS module
Import-Module Cicada -Force
Write-Host ""
Write-Host "[CICADA] Installed successfully." -ForegroundColor Green
Write-Host "  Run 'cicada' to launch a team, or 'cicada --help' for options." -ForegroundColor DarkGray
Write-Host ""
