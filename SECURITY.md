# Security policy

## Supported versions

Security fixes are applied to the latest release on `main`. This project is in
its initial `0.x` phase; operators should review release notes before upgrading.

## Report a vulnerability

Do not open a public issue containing exploit details, credentials, private
hostnames, or recovery evidence. Use private vulnerability reporting from the
repository's Security tab when it is available. Otherwise, open a minimal issue
requesting a private contact channel without including sensitive details.
Include the affected version, impact, reproduction steps using synthetic data,
and any suggested mitigation in the private report.

## Security model

- Runbooks are executable configuration and must be code-reviewed.
- Credentials are established in PowerCLI or PowerShell remoting sessions; they
  must never be stored in YAML, source control, or reports.
- VMware operations require an existing authenticated session and never invoke
  an interactive connection command internally.
- TCP and HTTP checks make outbound connections from the orchestrator host.
- `StartService` executes a fixed script block on the declared remote host.
- HTML report fields are encoded, but reports can still contain sensitive
  infrastructure names and upstream error messages.
- Simulation is not a security boundary and does not validate authorization,
  certificates, or real endpoint identity.

Use a least-privileged operator identity, protect the orchestrator host, inspect
runbook changes, and retain generated reports according to incident-data policy.
