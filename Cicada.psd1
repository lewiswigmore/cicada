@{
    RootModule        = 'Cicada.psm1'
    ModuleVersion     = '0.1.2'
    GUID              = 'a3c7e8f1-4b2d-4e9a-b6d8-1f3c5a7e9b2d'
    Author            = 'Lewis Wigmore'
    CompanyName       = 'Community'
    Copyright         = '(c) Lewis Wigmore. MIT License.'
    Description       = 'Multi-agent terminal orchestrator for Windows Terminal + GitHub Copilot CLI. Launch coordinated teams of AI agents with MCP-powered coordination, shared task boards, and live monitoring.'
    PowerShellVersion = '7.0'
    FunctionsToExport = @('Invoke-Cicada')
    AliasesToExport   = @('cicada')
    FileList          = @(
        'Cicada.psm1'
        'Cicada.psd1'
        'Invoke-Cicada.ps1'
        'Start-Agent.ps1'
        'Watch-Sessions.ps1'
        'roles.json'
    )
    PrivateData = @{
        PSData = @{
            Tags         = @('copilot', 'terminal', 'agents', 'windows-terminal', 'multi-agent', 'orchestrator', 'mcp')
            LicenseUri   = 'https://github.com/lewiswigmore/cicada/blob/master/LICENSE'
            ProjectUri   = 'https://github.com/lewiswigmore/cicada'
            ReleaseNotes = 'v0.1.1: Dedicated MCP venv, improved tool descriptions, PM role, autopilot re-prompt loop, and prompt cleanup.'
        }
    }
}
