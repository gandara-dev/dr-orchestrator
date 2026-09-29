# DR Orchestrator in Codespaces

This codespace has PowerShell 7, the DR Orchestrator module, and Docker. The
Runbook Viewer runs on port 8766 and opens by itself (see the **Ports** tab).
Everything is synthetic: no vCenter or Windows server is contacted, except the
vCenter simulator you start below.

Open a terminal and run PowerShell with `pwsh`.

## Run a recovery

```powershell
Import-Module ./src/DrOrchestrator/DrOrchestrator.psd1
$run = Invoke-DrRunbook ./runbooks/citrix-site-recovery.yml -Simulation
$run.Steps | Format-Table Id, Name, Status, DurationMilliseconds
```

## Make a step fail and watch the dependents stop

```powershell
$run = Invoke-DrRunbook ./runbooks/citrix-site-recovery.yml -Simulation -InjectFailureStep start-sql
$run.Steps | Format-Table Id, Status, Message
```

## Plan and report

```powershell
Import-DrRunbook ./runbooks/citrix-site-recovery.yml | Get-DrRecoveryPlan | Format-List
Export-DrReport -Execution $run -OutputDirectory ./artifacts
```

Open the Markdown and HTML reports in `artifacts/` from the Explorer.

## Real VMware calls against the vCenter simulator

```bash
bash .devcontainer/vmware-demo.sh
```

It installs VCF.PowerCLI the first time, starts `vmware/vcsim`, and runs the
integration test: a runbook step powers on a VM through PowerCLI and the test
checks the power state. The simulator stops when the script ends.

## Tests

```powershell
Invoke-Pester ./tests/DrOrchestrator.Tests.ps1
```

Stop the codespace when you are done so it does not use your Codespaces quota.
