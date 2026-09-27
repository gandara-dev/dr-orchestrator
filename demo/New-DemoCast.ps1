[CmdletBinding()]
param(
    [string]$OutputPath = (Join-Path $PSScriptRoot 'demo.cast')
)

$ErrorActionPreference = 'Stop'
$modulePath = Join-Path $PSScriptRoot '../src/DrOrchestrator/DrOrchestrator.psd1'
$runbookPath = Join-Path $PSScriptRoot '../runbooks/site-recovery.yml'
Import-Module $modulePath -Force

$success = Invoke-DrRunbook -Path $runbookPath -Simulation
$failure = Invoke-DrRunbook -Path $runbookPath -Simulation -InjectFailureStepId start-sql

$reportDirectory = Join-Path ([System.IO.Path]::GetTempPath()) "dr-orchestrator-demo-$PID"
try {
    $reports = Export-DrReport -Execution $failure -OutputDirectory $reportDirectory

    $esc = [char]27
    $green = "$esc[32m"
    $red = "$esc[31m"
    $yellow = "$esc[33m"
    $cyan = "$esc[36m"
    $dim = "$esc[2m"
    $reset = "$esc[0m"
    $events = [System.Collections.Generic.List[string]]::new()
    $time = 0.0

    function Add-DemoFrame {
        param(
            [double]$Delay,
            [string]$Text
        )

        $script:time += $Delay
        $events.Add((@($script:time, 'o', $Text) | ConvertTo-Json -Compress))
    }

    $header = [ordered]@{
        version = 2
        width = 112
        height = 31
        timestamp = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
        env = [ordered]@{ SHELL = 'pwsh'; TERM = 'xterm-256color' }
        title = 'DR Orchestrator demo'
    } | ConvertTo-Json -Compress

    Add-DemoFrame 0.0 "${cyan}DR ORCHESTRATOR${reset}  ${dim}dependency-aware disaster recovery${reset}`r`n`r`n"
    Add-DemoFrame 0.6 "${yellow}PS>${reset} `$result = Invoke-DrRunbook ./runbooks/site-recovery.yml -Simulation`r`n"
    Add-DemoFrame 0.7 "Runbook: $($success.RunbookName)`r`nStatus:  ${green}$($success.Status)${reset}    Steps: $($success.Steps.Count)    Measured: $($success.ElapsedMilliseconds) ms`r`n`r`n"
    Add-DemoFrame 0.2 "STEP                         PROVIDER   STATUS       DURATION`r`n"
    Add-DemoFrame 0.1 "---------------------------  ---------  -----------  ----------`r`n"
    foreach ($step in $success.Steps) {
        $line = '{0,-27}  {1,-9}  {2}{3,-11}{4}  {5,7:N2} ms' -f $step.Id, $step.Provider, $green, $step.Status, $reset, $step.DurationMilliseconds
        Add-DemoFrame 0.16 "$line`r`n"
    }

    Add-DemoFrame 0.7 "`r`n${yellow}PS>${reset} Invoke-DrRunbook ... -Simulation -InjectFailureStepId start-sql`r`n"
    foreach ($step in $failure.Steps | Where-Object Status -ne 'Succeeded') {
        $color = if ($step.Status -eq 'Failed') { $red } else { $yellow }
        $line = '{0,-27}  {1}{2,-11}{3}  {4}' -f $step.Id, $color, $step.Status, $reset, $step.Message
        Add-DemoFrame 0.22 "$line`r`n"
    }

    Add-DemoFrame 0.7 "`r`n${yellow}PS>${reset} Export-DrReport `$failure ./artifacts`r`n"
    Add-DemoFrame 0.5 "${green}Created${reset} report.md and report.html with the measured recovery timeline.`r`n"
    Add-DemoFrame 1.8 "`r`n${cyan}Recovery logic validated without production infrastructure.${reset}`r`n"

    $outputDirectory = Split-Path -Parent $OutputPath
    if ($outputDirectory) {
        New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null
    }
    @($header) + $events | Set-Content -LiteralPath $OutputPath -Encoding utf8NoBOM
    Write-Output "Created asciinema recording: $OutputPath"
    Write-Verbose "Temporary reports: $($reports.MarkdownPath), $($reports.HtmlPath)"
}
finally {
    if (Test-Path -LiteralPath $reportDirectory) {
        Remove-Item -LiteralPath $reportDirectory -Recurse -Force
    }
}
