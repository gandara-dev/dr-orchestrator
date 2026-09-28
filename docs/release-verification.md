# Release Verification

This project uses layered verification so that orchestration behavior is tested
without claiming that a simulator can validate an organization's recovery plan.

## Public release gate

Every change must pass:

- a fresh-clone simulation of the sample runbook;
- all Pester unit tests on Windows and Linux;
- report generation and HTML encoding checks;
- PSScriptAnalyzer with warning and error severity enabled;
- JSON Schema parsing and Mermaid rendering;
- a real PowerCLI `Start-VM` operation against a disposable `vcsim` instance
  whose virtual machines start powered off.

Run the infrastructure-free checks locally:

```powershell
Install-Module Pester -RequiredVersion 5.7.1 -Scope CurrentUser -Force -SkipPublisherCheck
Install-Module powershell-yaml -RequiredVersion 0.4.12 -Scope CurrentUser -Force
Invoke-Pester ./tests/DrOrchestrator.Tests.ps1 -CI -Output Detailed

$execution = Invoke-DrRunbook ./runbooks/site-recovery.yml -Simulation
if ($execution.Status -ne 'Succeeded') { throw 'Simulation failed.' }
```

The exact disposable VMware integration procedure is documented in
[Testing](testing.md).

## Environment acceptance gate

Before a production recovery window, the operator must validate what public CI
cannot own:

1. Run the exact tagged revision in a non-production vCenter.
2. Confirm every VM and service identifier against current inventory.
3. Test WinRM authorization with the same identity used by the orchestrator.
4. Execute TCP and HTTP health checks from the actual orchestrator network.
5. Exercise an injected failure and confirm the intended blocked branches.
6. Export reports to the approved evidence location.
7. Complete a controlled recovery exercise and record actual RTO observations.

A passing public build proves parser, dependency, state-machine, reporting, and
simulated VMware-provider behavior. It does not certify customer infrastructure,
permissions, application health, recovery data, or production RTO.
