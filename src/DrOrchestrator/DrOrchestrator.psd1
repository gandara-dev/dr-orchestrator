@{
    RootModule = 'DrOrchestrator.psm1'
    ModuleVersion = '0.2.0'
    GUID = 'e3d9ef25-283f-45ba-95a1-e3bd5519b1da'
    Author = 'Mateus Gandara'
    CompanyName = 'Community'
    Copyright = '(c) 2026 Mateus Gandara. All rights reserved.'
    Description = 'Dependency-aware disaster recovery runbook execution and reporting.'
    PowerShellVersion = '7.2'
    CompatiblePSEditions = @('Core')
    RequiredModules = @(
        @{
            ModuleName = 'powershell-yaml'
            ModuleVersion = '0.4.12'
        }
    )
    FunctionsToExport = @(
        'Import-DrRunbook',
        'Get-DrExecutionOrder',
        'Get-DrRecoveryPlan',
        'Invoke-DrRunbook',
        'Export-DrReport'
    )
    CmdletsToExport = @()
    VariablesToExport = @()
    AliasesToExport = @()
    PrivateData = @{
        PSData = @{
            Tags = @('DisasterRecovery', 'VMware', 'Citrix', 'Runbook', 'Orchestration')
            LicenseUri = 'https://github.com/gandara-dev/dr-orchestrator/blob/main/LICENSE'
            ProjectUri = 'https://github.com/gandara-dev/dr-orchestrator'
            ReleaseNotes = 'Initial dependency-aware runbook engine with simulation, VMware, Windows, and reports.'
        }
    }
}
