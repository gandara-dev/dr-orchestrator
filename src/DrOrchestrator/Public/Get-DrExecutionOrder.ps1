function Get-DrExecutionOrder {
    <#
    .SYNOPSIS
    Returns runbook steps in stable dependency order.

    .DESCRIPTION
    Performs a stable topological sort. Dependencies precede their consumers,
    unrelated steps retain declaration order, and dependency cycles are rejected.

    .PARAMETER Runbook
    A normalized runbook returned by Import-DrRunbook.

    .OUTPUTS
    PSCustomObject[]. Ordered step definitions.

    .EXAMPLE
    Import-DrRunbook ./runbooks/site-recovery.yml | Get-DrExecutionOrder
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, ValueFromPipeline)]
        [psobject]$Runbook
    )

    process {
        $remaining = [System.Collections.Generic.List[object]]::new()
        foreach ($step in @($Runbook.Steps)) {
            $remaining.Add($step)
        }

        $completed = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        $ordered = [System.Collections.Generic.List[object]]::new()

        while ($remaining.Count -gt 0) {
            $nextStep = $null
            foreach ($step in $remaining) {
                $dependenciesMet = $true
                foreach ($dependency in @($step.DependsOn)) {
                    if (-not $completed.Contains([string]$dependency)) {
                        $dependenciesMet = $false
                        break
                    }
                }
                if ($dependenciesMet) {
                    $nextStep = $step
                    break
                }
            }

            if ($null -eq $nextStep) {
                $blockedIds = @($remaining | ForEach-Object { $_.Id }) -join ', '
                throw "Dependency cycle detected among steps: $blockedIds."
            }

            $ordered.Add($nextStep)
            [void]$completed.Add([string]$nextStep.Id)
            [void]$remaining.Remove($nextStep)
        }

        return $ordered.ToArray()
    }
}
