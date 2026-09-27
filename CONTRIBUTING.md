# Contributing

Contributions should preserve the project's evidence-first and fail-safe
behavior.

## Development setup

```powershell
Install-Module Pester -RequiredVersion 5.7.1 -Scope CurrentUser -Force -SkipPublisherCheck
Install-Module powershell-yaml -RequiredVersion 0.4.12 -Scope CurrentUser
Install-Module PSScriptAnalyzer -RequiredVersion 1.24.0 -Scope CurrentUser
Import-Module ./src/DrOrchestrator/DrOrchestrator.psd1 -Force
```

## Pull-request checklist

- Keep code, documentation, tests, examples, and commit messages in English.
- Use only synthetic hostnames and data in fixtures and documentation.
- Add tests for every behavior change and failure path.
- Update the JSON Schema and runbook reference when the YAML contract changes.
- Preserve non-interactive behavior; provider code must not prompt for secrets.
- Run unit tests and PSScriptAnalyzer locally.
- Run the vcsim integration test for VMware provider changes.
- Update `CHANGELOG.md` under an unreleased or release section.

## Design constraints

- Dependencies must be validated before provider calls.
- A failed branch must not prevent unrelated branches from completing.
- Provider exceptions must remain visible in the execution result.
- Reports must encode runbook-controlled HTML.
- New state-changing actions require explicit documentation of idempotency and
  rollback boundaries.

Please keep pull requests focused. Large features should begin with a design
discussion describing the runbook contract, failure semantics, and tests.
