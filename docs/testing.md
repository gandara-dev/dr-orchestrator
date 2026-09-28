# Testing guide

DR Orchestrator uses two test layers: infrastructure-free unit tests and a
VMware provider integration test against `vcsim`.

## Unit tests

Requirements:

- PowerShell 7.2 or newer;
- Pester `5.7.1`;
- `powershell-yaml` `0.4.12`.

```powershell
Install-Module Pester -RequiredVersion 5.7.1 -Scope CurrentUser -Force -SkipPublisherCheck
Install-Module powershell-yaml -RequiredVersion 0.4.12 -Scope CurrentUser
Invoke-Pester ./tests/DrOrchestrator.Tests.ps1 -Output Detailed
```

The unit suite covers parsing, stable dependency order, unknown dependencies,
cycles, provider/action validation, required parameters, successful simulation,
failure propagation, report creation, and HTML encoding.

## Static analysis

```powershell
Install-Module PSScriptAnalyzer -RequiredVersion 1.24.0 -Scope CurrentUser
$findings = @(Invoke-ScriptAnalyzer -Path . -Recurse -Severity Warning,Error)
$findings | Format-Table -AutoSize
if ($findings.Count -gt 0) { throw 'PSScriptAnalyzer reported findings.' }
```

## VMware integration with vcsim

The integration suite starts one powered-off VM through the real PowerCLI
provider. VMware `vcsim` supplies a disposable vCenter-compatible API and
synthetic `user` / `pass` credentials.

```powershell
docker run --rm --detach `
    --name dr-orchestrator-vcsim `
    --publish 8989:8989 `
    vmware/vcsim@sha256:a58d77fdb0b52dd7c8ded660890542c3a82518ae3911fe65920428b041a99db2 `
    -l 0.0.0.0:8989 -autostart=false

Install-Module VCF.PowerCLI -RequiredVersion 9.1.1.25718932 -Scope CurrentUser -Force -AllowClobber
$env:DR_VCENTER_SERVER = 'localhost'
Invoke-Pester ./tests/DrOrchestrator.Vmware.Tests.ps1 -Output Detailed

docker stop dr-orchestrator-vcsim
```

The test creates no production connection and never prompts for credentials.
Use a disposable simulator because it intentionally changes a simulated VM from
`PoweredOff` to `PoweredOn`.

## Runbook Viewer tests

The viewer's JavaScript engine must behave exactly like the PowerShell module.
The module is the reference: `tests/Update-ViewerFixtures.ps1` runs the inputs in
`tests/fixtures/viewer-inputs.json` through it and writes
`tests/fixtures/viewer-cases.json` (simulated statuses and messages, recovery
plans, and validation errors). The Node suite asserts the browser engine against
that file with Node.js 20 or newer and no npm dependencies:

```powershell
node --test tests/web/*.test.mjs
```

Pester fails when `viewer-cases.json` or the JSON runbooks in `site/runbooks/`
are out of date. After changing the engine, a sample runbook, or the inputs, run:

```powershell
./scripts/Export-DrRunbookJson.ps1 -All
./tests/Update-ViewerFixtures.ps1
```

then review the diff before committing.

## Continuous integration

`.github/workflows/ci.yml` performs:

1. unit tests on current GitHub-hosted Windows and Ubuntu runners;
2. PSScriptAnalyzer with warning and error severities;
3. VCF PowerCLI integration against a digest-pinned `vcsim` image;
4. the Runbook Viewer's Node suite.

`.github/workflows/pages.yml` tests the viewer again and publishes `site/` to
GitHub Pages when it changes on `main`.

The workflow has read-only repository permissions. It uses no repository secret
and cannot contact a private vCenter unless the workflow is deliberately
changed.

## Rebuild the demo

The GIF is derived from a real simulation result, not hand-authored output.

```powershell
pwsh ./demo/New-DemoCast.ps1
docker run --rm --volume "${PWD}:/work" `
    ghcr.io/asciinema/agg@sha256:84e04c21013e4fb91cbdb3eade5977c1e66685c18f0d234da78d3350bb3404b2 `
    /work/demo/demo.cast /work/docs/demo.gif --font-size 18
```

`demo/demo.cast` is generated and ignored. `docs/demo.gif` is the published
artifact.
