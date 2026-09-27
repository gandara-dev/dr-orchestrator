function Invoke-DrRunbook {
    <#
    .SYNOPSIS
    Executes or simulates a dependency-aware disaster recovery runbook.

    .DESCRIPTION
    Validates and orders the runbook, invokes each eligible provider action,
    blocks steps whose prerequisites did not succeed, and returns a measured
    execution timeline. Provider failures are recorded in the result so unrelated
    branches can continue.

    .PARAMETER Path
    Path to a schema version 1 YAML runbook.

    .PARAMETER Simulation
    Replaces provider calls with successful synthetic results after validation.

    .PARAMETER InjectFailureStepId
    One or more step IDs that should fail in simulation mode.

    .OUTPUTS
    PSCustomObject. The overall result and ordered per-step timeline.

    .EXAMPLE
    Invoke-DrRunbook ./runbooks/site-recovery.yml -Simulation

    .EXAMPLE
    Invoke-DrRunbook ./runbooks/site-recovery.yml -Simulation -InjectFailureStepId start-sql
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string]$Path,

        [switch]$Simulation,

        [string[]]$InjectFailureStepId = @()
    )

    $runbook = Import-DrRunbook -Path $Path
    $executionOrder = @(Get-DrExecutionOrder -Runbook $runbook)
    $failureIds = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($failureId in $InjectFailureStepId) {
        [void]$failureIds.Add($failureId)
    }

    $stepStates = @{}
    $results = [System.Collections.Generic.List[object]]::new()
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

    foreach ($step in $executionOrder) {
        $blockedBy = @(
            foreach ($dependency in $step.DependsOn) {
                if ($stepStates[$dependency] -ne 'Succeeded') {
                    $dependency
                }
            }
        )

        if ($blockedBy.Count -gt 0) {
            $now = [DateTimeOffset]::UtcNow
            $stepStates[$step.Id] = 'Blocked'
            $results.Add([pscustomobject]@{
                Id = $step.Id
                Name = $step.Name
                Provider = $step.Provider
                Action = $step.Action
                Status = 'Blocked'
                Message = "Skipped because prerequisite step(s) did not succeed: $($blockedBy -join ', ')."
                StartedAt = $now
                CompletedAt = $now
                DurationMilliseconds = 0
            })
            continue
        }

        $startedAt = [DateTimeOffset]::UtcNow
        $stepTimer = [System.Diagnostics.Stopwatch]::StartNew()
        try {
            $providerResult = Invoke-DrProviderStep -Step $step -Simulation:$Simulation.IsPresent -InjectedFailures $failureIds
            $status = if ($providerResult.Success) { 'Succeeded' } else { 'Failed' }
            $message = [string]$providerResult.Message
        }
        catch {
            $status = 'Failed'
            $message = $_.Exception.Message
        }
        finally {
            $stepTimer.Stop()
        }

        $completedAt = [DateTimeOffset]::UtcNow
        $stepStates[$step.Id] = $status
        $results.Add([pscustomobject]@{
            Id = $step.Id
            Name = $step.Name
            Provider = $step.Provider
            Action = $step.Action
            Status = $status
            Message = $message
            StartedAt = $startedAt
            CompletedAt = $completedAt
            DurationMilliseconds = [math]::Round($stepTimer.Elapsed.TotalMilliseconds, 2)
        })
    }

    $stopwatch.Stop()
    $overallStatus = if (@($results | Where-Object Status -eq 'Failed').Count -gt 0) { 'Failed' } else { 'Succeeded' }

    return [pscustomobject]@{
        RunbookName = $runbook.Name
        Status = $overallStatus
        Simulation = $Simulation.IsPresent
        StartedAt = [DateTimeOffset]($results[0].StartedAt)
        CompletedAt = [DateTimeOffset]::UtcNow
        ElapsedMilliseconds = [math]::Round($stopwatch.Elapsed.TotalMilliseconds, 2)
        Steps = $results.ToArray()
    }
}
