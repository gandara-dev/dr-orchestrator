<#
.SYNOPSIS
Converts a validated YAML runbook to the JSON format used by the Runbook Viewer.

.DESCRIPTION
Imports the runbook with the same validation as Invoke-DrRunbook and writes a
stable JSON representation: fields keep their runbook names and parameter keys
are sorted, so regenerating an unchanged runbook produces identical output.
Load the result in the Runbook Viewer with "Open runbook JSON".

.EXAMPLE
./scripts/Export-DrRunbookJson.ps1 -Path ./runbooks/site-recovery.yml -OutputPath ./site-recovery.json

.EXAMPLE
./scripts/Export-DrRunbookJson.ps1 -All
Regenerates site/runbooks/*.json from every runbook in runbooks/.
#>
[CmdletBinding(DefaultParameterSetName = 'Single')]
param(
    [Parameter(Mandatory, ParameterSetName = 'Single')][string]$Path,
    [Parameter(Mandatory, ParameterSetName = 'Single')][string]$OutputPath,
    [Parameter(Mandatory, ParameterSetName = 'All')][switch]$All
)

$ErrorActionPreference = 'Stop'
$repositoryRoot = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path (Join-Path (Join-Path $repositoryRoot 'src') 'DrOrchestrator') 'DrOrchestrator.psd1') -Force

function ConvertTo-SortedValue {
    param($Value)
    if ($Value -is [System.Collections.IDictionary]) {
        $sorted = [ordered]@{}
        foreach ($key in @($Value.Keys | Sort-Object)) {
            $sorted[[string]$key] = ConvertTo-SortedValue $Value[$key]
        }
        return $sorted
    }
    if ($Value -is [System.Management.Automation.PSCustomObject]) {
        $sorted = [ordered]@{}
        foreach ($name in @($Value.PSObject.Properties.Name | Sort-Object)) {
            $sorted[$name] = ConvertTo-SortedValue $Value.$name
        }
        return $sorted
    }
    if ($Value -is [System.Collections.IEnumerable] -and $Value -isnot [string]) {
        return , @($Value | ForEach-Object { ConvertTo-SortedValue $_ })
    }
    return $Value
}

function Export-RunbookJson {
    param([string]$Source, [string]$Destination)

    $runbook = Import-DrRunbook -Path $Source
    $null = Get-DrExecutionOrder -Runbook $runbook
    $steps = foreach ($step in $runbook.Steps) {
        $entry = [ordered]@{
            id = $step.Id
            name = $step.Name
            provider = $step.Provider
            action = $step.Action
        }
        if (@($step.DependsOn).Count -gt 0) {
            $entry.dependsOn = @($step.DependsOn)
        }
        if ($null -ne $step.ExpectedDurationSeconds) {
            $entry.expectedDurationSeconds = $step.ExpectedDurationSeconds
        }
        $entry.parameters = ConvertTo-SortedValue $step.Parameters
        $entry
    }
    $document = [ordered]@{
        name = $runbook.Name
        version = $runbook.Version
        description = $runbook.Description
        steps = @($steps)
    }
    $json = ($document | ConvertTo-Json -Depth 10) -replace "`r`n", "`n"
    $destinationPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Destination)
    [System.IO.File]::WriteAllText($destinationPath, $json + "`n", [System.Text.UTF8Encoding]::new($false))
    return $destinationPath
}

if ($All) {
    $outputDirectory = Join-Path (Join-Path $repositoryRoot 'site') 'runbooks'
    New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null
    foreach ($file in Get-ChildItem -Path (Join-Path $repositoryRoot 'runbooks') -Filter '*.yml' | Sort-Object Name) {
        Export-RunbookJson -Source $file.FullName -Destination (Join-Path $outputDirectory ($file.BaseName + '.json'))
    }
}
else {
    Export-RunbookJson -Source $Path -Destination $OutputPath
}
