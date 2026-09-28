# Changelog

All notable changes to this project are documented here.

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
