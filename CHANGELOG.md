# Changelog

All notable changes to this project are documented here.

## [Unreleased]

### Added

- GitHub Codespaces configuration: PowerShell 7 with the module and its test
  dependencies, the Runbook Viewer on a forwarded port, and a script that runs
  the VMware provider integration test against vcsim.

## [0.2.1] - 2026-09-29

### Changed

- Runbook Viewer redesigned as a printable procedure: numbered steps with
  targets and dependencies, a planned-versus-drill schedule, and a timestamped
  drill log. The page prints as a runbook document.
- License changed from MIT to PolyForm Shield 1.0.0. Releases up to v0.2.0
  remain available under the MIT license.

## [0.2.0] - 2026-09-28

### Added

- Runbook Viewer (`site/`): dependency graph by level, failure selection,
  animated simulation, planned-versus-simulated timeline, and Markdown report,
  published with GitHub Pages and runnable with `scripts/Start-RunbookViewer.ps1`.
- `Get-DrRecoveryPlan`, which reports dependency levels, the critical path, the
  sequential estimate, and the critical-path lower bound.
- Optional `expectedDurationSeconds` step field, validated from 1 to 604800.
- `Invoke-DrRunbook -Runbook` accepts an imported runbook from the pipeline.
- A branched synthetic Citrix site recovery runbook with independent licensing,
  profile storage, and gateway branches.
- `scripts/Export-DrRunbookJson.ps1` and fixtures generated from the PowerShell
  engine that the viewer's JavaScript engine must reproduce exactly.

## [0.1.2] - 2026-09-28

### Added

- Release-verification guide separating the public simulation and PowerCLI
  `vcsim` gate from the environment-specific production recovery exercise.

## [0.1.1] - 2026-09-27

### Fixed

- Replaced live Mermaid blocks with pre-rendered SVG diagrams so GitHub renders
  the architecture documentation reliably.

### Added

- Versioned Mermaid diagram sources and pinned Mermaid CLI validation in CI.

## [0.1.0] - 2026-09-27

### Added

- YAML runbook loading and dependency validation.
- Stable dependency ordering and simulated, VMware, and Windows step providers.
- Markdown and HTML execution reports with measured elapsed time.
- Reproducible animated terminal demo built from real simulation results.
- Pester tests and GitHub Actions workflows for cross-platform and vcsim checks.
- Non-interactive VCF PowerCLI integration test that performs a real simulated `Start-VM` operation.
- Semantic validation for provider/action combinations and required parameters.
- JSON Schema action contracts and complete architecture, runbook, operations,
  testing, security, and contribution documentation.
- PSScriptAnalyzer validation in continuous integration.
