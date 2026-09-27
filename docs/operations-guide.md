# Operations guide

This guide describes a controlled path from a reviewed runbook to a live
recovery execution. Adapt it to your organization's change, evidence, and
incident-management processes.

## 1. Prepare the orchestrator host

- Use PowerShell 7.2 or newer on a managed workstation or automation runner.
- Install `powershell-yaml` and, for VMware actions, `VCF.PowerCLI`.
- Restrict repository write access and verify the exact commit to execute.
- Ensure the report destination has appropriate access and retention controls.
- Confirm DNS, routing, proxy, certificate trust, and firewall behavior from the
  orchestrator host, because health checks originate there.

```powershell
Install-Module powershell-yaml -RequiredVersion 0.4.12 -Scope CurrentUser
Install-Module VCF.PowerCLI -Scope CurrentUser
Import-Module ./src/DrOrchestrator/DrOrchestrator.psd1
```

## 2. Review the runbook

Verify each of these items in a pull request or formal change record:

- the VM names and optional vCenter session selector;
- the dependency graph and intended independent branches;
- the network perspective of every TCP and HTTP check;
- service names and PowerShell remoting authorization;
- timeout values under degraded recovery conditions;
- ownership and rollback procedure for every state-changing step.

Keep credentials and tokens out of YAML. The sample names under
`example.test` are deliberately non-routable placeholders.

## 3. Simulate the exact revision

```powershell
$simulation = Invoke-DrRunbook ./runbooks/site-recovery.yml -Simulation
$simulation.Steps | Format-Table Id, Provider, Action, Status, Message

if ($simulation.Status -ne 'Succeeded') {
    throw 'Runbook simulation failed.'
}
```

Simulation performs parsing, semantic validation, cycle detection, ordering,
state transitions, and reporting. It does not verify infrastructure identifiers
or connectivity.

Exercise failure behavior for critical branches:

```powershell
Invoke-DrRunbook ./runbooks/site-recovery.yml `
    -Simulation `
    -InjectFailureStepId start-sql
```

Confirm that every blocked and continuing step matches the recovery design.

## 4. Authenticate without storing secrets

### VMware

```powershell
$credential = Get-Credential
Connect-VIServer -Server vcenter.example.test -Credential $credential
```

The provider reuses a connected PowerCLI session. If a runbook specifies
`parameters.server`, it must match the connected server name or service URI
host. No session means an explicit failure, not an interactive prompt.

### Windows remoting

`StartService` uses the current remoting context. Configure WinRM, constrained
endpoints, Just Enough Administration, or runner identity according to local
policy. Test authorization independently before a recovery window.

## 5. Execute and persist evidence

```powershell
$execution = Invoke-DrRunbook ./runbooks/site-recovery.yml
$report = Export-DrReport -Execution $execution -OutputDirectory ./artifacts

$execution.Steps | Format-Table Id, Status, DurationMilliseconds, Message
$report | Format-List

if ($execution.Status -ne 'Succeeded') {
    exit 1
}
```

The module returns an execution object when a provider step fails; it does not
terminate the shell solely because the overall run is failed. Automation must
inspect `Status` as shown above.

## 6. Interpret failures

- `Failed` means the provider returned failure or threw an exception.
- `Blocked` means at least one prerequisite did not succeed; the provider was
  not called.
- `Succeeded` confirms only the action's narrow contract. For example,
  `StartVM` confirms a power-on request, not application availability.

Provider messages can contain operational names and upstream error text. Treat
reports as potentially sensitive incident evidence.

## 7. Rollback and rerun boundaries

Version `0.1.0` has no automatic rollback, retry, checkpoint resume, or
idempotency ledger. Some actions are naturally repeatable (`StartVM` skips an
already powered-on VM; `StartService` skips a running service), but a complete
rerun must still be an operator decision.

Before rerunning:

1. identify the failed action and its external effects;
2. follow the system owner's rollback or correction procedure;
3. decide whether already successful steps may be repeated safely;
4. retain the first report and use a new output location for the rerun;
5. record the runbook commit and operator decision in the incident timeline.

## Production readiness checklist

- [ ] Runbook and dependency graph reviewed by service owners
- [ ] Same commit simulated with critical failure injection
- [ ] Non-production recovery exercise completed
- [ ] PowerCLI session targets the intended vCenter
- [ ] WinRM identity and least privilege verified
- [ ] Health checks tested from the orchestrator network
- [ ] Report storage and retention approved
- [ ] Rollback owner and communications channel identified
- [ ] Automation fails when `execution.Status` is not `Succeeded`
