function Get-DrPropertyValue {
    param(
        [Parameter(Mandatory)]
        [object]$InputObject,

        [Parameter(Mandatory)]
        [string]$Name
    )

    if ($InputObject -is [System.Collections.IDictionary]) {
        return $InputObject[$Name]
    }

    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -ne $property) {
        return $property.Value
    }

    return $null
}

function Test-DrPropertyPresence {
    param(
        [Parameter(Mandatory)]
        [object]$InputObject,

        [Parameter(Mandatory)]
        [string]$Name
    )

    if ($InputObject -is [System.Collections.IDictionary]) {
        return $InputObject.Contains($Name)
    }

    return $null -ne $InputObject.PSObject.Properties[$Name]
}

function Confirm-DrStepParameter {
    param(
        [Parameter(Mandatory)]
        [string]$StepId,

        [Parameter(Mandatory)]
        [string]$Provider,

        [Parameter(Mandatory)]
        [string]$Action,

        [Parameter(Mandatory)]
        [object]$Parameters
    )

    $supportedActions = @{
        VMware = @('StartVM', 'WaitForTools', 'TestVM')
        Windows = @('StartService', 'TestTcpPort', 'TestHttp')
    }
    if ($Action -notin $supportedActions[$Provider]) {
        throw "Step '$StepId' has unsupported action '$Action' for provider '$Provider'."
    }

    switch ($Action) {
        { $_ -in @('StartVM', 'WaitForTools', 'TestVM') } {
            $vmNames = @(
                Get-DrPropertyValue -InputObject $Parameters -Name 'vmNames' |
                    ForEach-Object { [string]$_ } |
                    Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
            )
            if ($vmNames.Count -eq 0) {
                throw "Step '$StepId' action '$Action' requires parameters.vmNames."
            }
        }
        'StartService' {
            foreach ($name in 'computerName', 'serviceName') {
                $value = [string](Get-DrPropertyValue -InputObject $Parameters -Name $name)
                if ([string]::IsNullOrWhiteSpace($value)) {
                    throw "Step '$StepId' action '$Action' requires parameters.$name."
                }
            }
        }
        'TestTcpPort' {
            $computerName = [string](Get-DrPropertyValue -InputObject $Parameters -Name 'computerName')
            $port = [int](Get-DrPropertyValue -InputObject $Parameters -Name 'port')
            if ([string]::IsNullOrWhiteSpace($computerName)) {
                throw "Step '$StepId' action '$Action' requires parameters.computerName."
            }
            if ($port -lt 1 -or $port -gt 65535) {
                throw "Step '$StepId' action '$Action' requires parameters.port between 1 and 65535."
            }
        }
        'TestHttp' {
            $uriText = [string](Get-DrPropertyValue -InputObject $Parameters -Name 'uri')
            $uri = $null
            if (-not [uri]::TryCreate($uriText, [UriKind]::Absolute, [ref]$uri) -or
                $uri.Scheme -notin @('http', 'https')) {
                throw "Step '$StepId' action '$Action' requires an absolute HTTP(S) parameters.uri."
            }
        }
    }

    if (Test-DrPropertyPresence -InputObject $Parameters -Name 'timeoutSeconds') {
        $timeoutSeconds = [int](Get-DrPropertyValue -InputObject $Parameters -Name 'timeoutSeconds')
        if ($timeoutSeconds -lt 1) {
            throw "Step '$StepId' parameters.timeoutSeconds must be greater than zero."
        }
    }
}

function ConvertTo-DrRunbookDefinition {
    param(
        [Parameter(Mandatory)]
        [object]$Runbook
    )

    foreach ($requiredProperty in 'name', 'version', 'steps') {
        if (-not (Test-DrPropertyPresence -InputObject $Runbook -Name $requiredProperty)) {
            throw "Runbook is missing required property '$requiredProperty'."
        }
    }

    if ([string]::IsNullOrWhiteSpace([string]$Runbook.name)) {
        throw 'Runbook name must not be empty.'
    }

    if ([int]$Runbook.version -ne 1) {
        throw "Unsupported runbook version '$($Runbook.version)'; expected version 1."
    }

    $sourceSteps = @($Runbook.steps)
    if ($sourceSteps.Count -eq 0) {
        throw 'Runbook must define at least one step.'
    }

    $ids = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $steps = [System.Collections.Generic.List[object]]::new()

    foreach ($sourceStep in $sourceSteps) {
        foreach ($requiredProperty in 'id', 'name', 'provider', 'action') {
            if (-not (Test-DrPropertyPresence -InputObject $sourceStep -Name $requiredProperty)) {
                throw "A runbook step is missing required property '$requiredProperty'."
            }
        }

        $id = [string]$sourceStep.id
        if ([string]::IsNullOrWhiteSpace($id)) {
            throw 'Step id must not be empty.'
        }
        if (-not $ids.Add($id)) {
            throw "Duplicate step id '$id'."
        }
        if ([string]::IsNullOrWhiteSpace([string]$sourceStep.name)) {
            throw "Step '$id' name must not be empty."
        }
        $provider = [string]$sourceStep.provider
        $action = [string]$sourceStep.action
        if ($provider -notin @('VMware', 'Windows')) {
            throw "Step '$id' has unsupported provider '$($sourceStep.provider)'."
        }
        if ([string]::IsNullOrWhiteSpace($action)) {
            throw "Step '$id' action must not be empty."
        }

        $dependencies = @()
        if (Test-DrPropertyPresence -InputObject $sourceStep -Name 'dependsOn') {
            $dependencies = @(Get-DrPropertyValue -InputObject $sourceStep -Name 'dependsOn' | ForEach-Object { [string]$_ })
        }

        $parameters = Get-DrPropertyValue -InputObject $sourceStep -Name 'parameters'
        if ($null -eq $parameters) {
            $parameters = @{}
        }
        if ($parameters -isnot [System.Collections.IDictionary] -and $parameters -isnot [pscustomobject]) {
            throw "Step '$id' parameters must be a mapping/object."
        }
        Confirm-DrStepParameter `
            -StepId $id `
            -Provider $provider `
            -Action $action `
            -Parameters $parameters

        $steps.Add([pscustomobject]@{
            Id = $id
            Name = [string]$sourceStep.name
            Provider = $provider
            Action = $action
            DependsOn = [string[]]$dependencies
            Parameters = $parameters
        })
    }

    $idSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($step in $steps) {
        [void]$idSet.Add($step.Id)
    }

    foreach ($step in $steps) {
        foreach ($dependency in $step.DependsOn) {
            if (-not $idSet.Contains($dependency)) {
                throw "Step '$($step.Id)' depends on unknown step '$dependency'."
            }
            if ($dependency -eq $step.Id) {
                throw "Step '$($step.Id)' cannot depend on itself."
            }
        }
    }

    return [pscustomobject]@{
        Name = [string]$Runbook.name
        Version = [int]$Runbook.version
        Description = [string](Get-DrPropertyValue -InputObject $Runbook -Name 'description')
        Steps = $steps.ToArray()
    }
}

function Import-DrRunbook {
    <#
    .SYNOPSIS
    Imports and validates a DR Orchestrator YAML runbook.

    .DESCRIPTION
    Parses schema version 1 YAML, normalizes its fields, and validates providers,
    actions, parameters, step IDs, and dependency references. Dependency-cycle
    detection occurs when the result is passed to Get-DrExecutionOrder or
    Invoke-DrRunbook.

    .PARAMETER Path
    Path to the YAML runbook.

    .OUTPUTS
    PSCustomObject. A normalized runbook definition.

    .EXAMPLE
    $runbook = Import-DrRunbook -Path ./runbooks/site-recovery.yml
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string]$Path
    )

    $resolvedPath = Resolve-Path -LiteralPath $Path -ErrorAction Stop
    $yaml = Get-Content -LiteralPath $resolvedPath -Raw
    try {
        $parsed = ConvertFrom-Yaml -Yaml $yaml -ErrorAction Stop
    }
    catch {
        throw "Could not parse runbook YAML '$Path': $($_.Exception.Message)"
    }

    return ConvertTo-DrRunbookDefinition -Runbook $parsed
}
