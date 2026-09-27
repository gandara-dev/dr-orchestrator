function ConvertTo-DrReportMarkdown {
    param(
        [Parameter(Mandatory)]
        [psobject]$Execution
    )

    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add("# Disaster Recovery Report: $($Execution.RunbookName)")
    $lines.Add('')
    $lines.Add("- **Status:** $($Execution.Status)")
    $lines.Add("- **Mode:** $(if ($Execution.Simulation) { 'Simulation' } else { 'Execution' })")
    $lines.Add("- **Started (UTC):** $($Execution.StartedAt.ToString('yyyy-MM-dd HH:mm:ss.fff'))")
    $lines.Add("- **Completed (UTC):** $($Execution.CompletedAt.ToString('yyyy-MM-dd HH:mm:ss.fff'))")
    $lines.Add("- **Measured elapsed time:** $($Execution.ElapsedMilliseconds) ms")
    $lines.Add('')
    $lines.Add('| Step | Name | Provider | Status | Duration (ms) | Details |')
    $lines.Add('| --- | --- | --- | --- | ---: | --- |')

    foreach ($step in $Execution.Steps) {
        $name = ([string]$step.Name).Replace('|', '\|').Replace("`r", ' ').Replace("`n", ' ')
        $message = ([string]$step.Message).Replace('|', '\|').Replace("`r", ' ').Replace("`n", ' ')
        $lines.Add("| $($step.Id) | $name | $($step.Provider) | $($step.Status) | $($step.DurationMilliseconds) | $message |")
    }

    return $lines -join "`n"
}

function Export-DrReport {
    <#
    .SYNOPSIS
    Exports a DR execution timeline as Markdown and HTML.

    .DESCRIPTION
    Writes report.md and report.html to the requested directory. HTML fields
    controlled by the runbook or provider output are encoded before rendering.

    .PARAMETER Execution
    An execution result returned by Invoke-DrRunbook.

    .PARAMETER OutputDirectory
    Destination directory. It is created when it does not exist.

    .OUTPUTS
    PSCustomObject. Paths to the generated Markdown and HTML files.

    .EXAMPLE
    $execution = Invoke-DrRunbook ./runbooks/site-recovery.yml -Simulation
    Export-DrReport -Execution $execution -OutputDirectory ./artifacts
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, ValueFromPipeline)]
        [psobject]$Execution,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$OutputDirectory
    )

    process {
        $directory = New-Item -ItemType Directory -Path $OutputDirectory -Force
        $markdownPath = Join-Path $directory.FullName 'report.md'
        $htmlPath = Join-Path $directory.FullName 'report.html'
        $markdown = ConvertTo-DrReportMarkdown -Execution $Execution
        Set-Content -LiteralPath $markdownPath -Value $markdown -Encoding utf8NoBOM

        $encoder = [System.Net.WebUtility]
        $title = $encoder::HtmlEncode([string]$Execution.RunbookName)
        $rows = foreach ($step in $Execution.Steps) {
            $cells = @($step.Id, $step.Name, $step.Provider, $step.Status, "$($step.DurationMilliseconds) ms", $step.Message) |
                ForEach-Object { "<td>$($encoder::HtmlEncode([string]$_))</td>" }
            "<tr class=`"$($encoder::HtmlEncode([string]$step.Status))`">$($cells -join '')</tr>"
        }
        $mode = if ($Execution.Simulation) { 'Simulation' } else { 'Execution' }
        $html = @"
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>DR report: $title</title>
  <style>
    body { font: 15px/1.5 Segoe UI, sans-serif; margin: 2rem auto; max-width: 1100px; padding: 0 1rem; color: #202b36; }
    h1 { margin-bottom: .25rem; }
    .summary { display: flex; flex-wrap: wrap; gap: 1rem 2rem; border-bottom: 1px solid #ccd4dc; padding: 1rem 0; }
    table { border-collapse: collapse; width: 100%; margin-top: 1.5rem; }
    th, td { border-bottom: 1px solid #d8dee5; padding: .65rem; text-align: left; vertical-align: top; }
    th { background: #f2f5f7; }
    tr.Failed { background: #fff0ed; }
    tr.Blocked { background: #fff8e6; }
    tr.Succeeded { background: #eff8f2; }
  </style>
</head>
<body>
  <h1>Disaster Recovery Report: $title</h1>
  <div class="summary">
    <span><strong>Status:</strong> $($encoder::HtmlEncode([string]$Execution.Status))</span>
    <span><strong>Mode:</strong> $mode</span>
    <span><strong>Started (UTC):</strong> $($Execution.StartedAt.ToString('yyyy-MM-dd HH:mm:ss.fff'))</span>
    <span><strong>Measured elapsed time:</strong> $($Execution.ElapsedMilliseconds) ms</span>
  </div>
  <table>
    <thead><tr><th>Step</th><th>Name</th><th>Provider</th><th>Status</th><th>Duration</th><th>Details</th></tr></thead>
    <tbody>
      $($rows -join "`n      ")
    </tbody>
  </table>
</body>
</html>
"@
        Set-Content -LiteralPath $htmlPath -Value $html -Encoding utf8NoBOM

        return [pscustomobject]@{
            MarkdownPath = $markdownPath
            HtmlPath = $htmlPath
        }
    }
}
