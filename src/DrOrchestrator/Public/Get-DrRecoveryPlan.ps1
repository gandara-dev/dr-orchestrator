function Get-DrRecoveryPlan {
    <#
    .SYNOPSIS
    Calculates dependency levels, the critical path, and planned recovery time.

    .DESCRIPTION
    Uses the optional expectedDurationSeconds of each step to produce two
    planning figures:

    - SequentialEstimateSeconds: the sum of all step durations. This is how the
      engine runs today, because it executes one step at a time.
    - CriticalPathSeconds: the longest dependency chain. It is the lower bound
      if independent branches ran in parallel.

    Both are planning values derived from the runbook, not measurements. Steps
    without a duration count as zero and are listed in MissingDurations.

    .PARAMETER Runbook
    A normalized runbook returned by Import-DrRunbook.

    .OUTPUTS
    PSCustomObject. Per-step levels and schedule, the critical path, and totals.

    .EXAMPLE
    Import-DrRunbook ./runbooks/citrix-site-recovery.yml | Get-DrRecoveryPlan
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, ValueFromPipeline)]
        [psobject]$Runbook
    )

    process {
        $ordered = @(Get-DrExecutionOrder -Runbook $Runbook)
        $byId = @{}
        $level = @{}
        $start = @{}
        $finish = @{}
        $predecessor = @{}
        $missing = [System.Collections.Generic.List[string]]::new()
        $sequential = 0

        foreach ($step in $ordered) {
            $key = $step.Id.ToLowerInvariant()
            $byId[$key] = $step
            $duration = 0
            if ($null -ne $step.ExpectedDurationSeconds) {
                $duration = [int]$step.ExpectedDurationSeconds
            }
            else {
                $missing.Add($step.Id)
            }
            $sequential += $duration

            $stepLevel = 0
            $stepStart = 0
            $stepPredecessor = $null
            foreach ($dependency in @($step.DependsOn)) {
                $dependencyKey = ([string]$dependency).ToLowerInvariant()
                $stepLevel = [Math]::Max($stepLevel, $level[$dependencyKey] + 1)
                if ($null -eq $stepPredecessor -or $finish[$dependencyKey] -gt $stepStart) {
                    $stepStart = $finish[$dependencyKey]
                    $stepPredecessor = $dependencyKey
                }
            }
            $level[$key] = $stepLevel
            $start[$key] = $stepStart
            $finish[$key] = $stepStart + $duration
            $predecessor[$key] = $stepPredecessor
        }

        $endKey = $null
        foreach ($step in $ordered) {
            $key = $step.Id.ToLowerInvariant()
            if ($null -eq $endKey -or $finish[$key] -gt $finish[$endKey]) {
                $endKey = $key
            }
        }

        $critical = [System.Collections.Generic.List[string]]::new()
        $cursor = $endKey
        while ($null -ne $cursor) {
            $critical.Insert(0, $byId[$cursor].Id)
            $cursor = $predecessor[$cursor]
        }
        $criticalSet = [System.Collections.Generic.HashSet[string]]::new(
            [string[]]$critical.ToArray(),
            [System.StringComparer]::OrdinalIgnoreCase
        )

        $steps = foreach ($step in $ordered) {
            $key = $step.Id.ToLowerInvariant()
            [pscustomobject]@{
                Id = $step.Id
                Name = $step.Name
                Level = $level[$key]
                DependsOn = $step.DependsOn
                ExpectedDurationSeconds = $step.ExpectedDurationSeconds
                EarliestStartSeconds = $start[$key]
                EarliestFinishSeconds = $finish[$key]
                OnCriticalPath = $criticalSet.Contains($step.Id)
            }
        }

        [pscustomobject]@{
            RunbookName = $Runbook.Name
            Steps = @($steps)
            SequentialEstimateSeconds = $sequential
            CriticalPathSeconds = $finish[$endKey]
            CriticalPath = $critical.ToArray()
            MissingDurations = $missing.ToArray()
        }
    }
}
