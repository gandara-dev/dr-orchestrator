#!/usr/bin/env bash
# Runs the VMware provider against vcsim, the vCenter simulator: the runbook
# step starts a powered-off VM through PowerCLI and checks it is powered on.
set -euo pipefail

pwsh -NoProfile -Command '
  if (-not (Get-Module -ListAvailable VCF.PowerCLI)) {
    Write-Host "Installing VCF.PowerCLI (one time, about two minutes)..."
    Install-Module VCF.PowerCLI -RequiredVersion 9.1.1.25718932 -Scope CurrentUser -Force -AllowClobber
  }'

docker rm --force vcsim >/dev/null 2>&1 || true
docker run --rm --detach --name vcsim --publish 8989:8989 \
  vmware/vcsim@sha256:a58d77fdb0b52dd7c8ded660890542c3a82518ae3911fe65920428b041a99db2 \
  -l 0.0.0.0:8989 -autostart=false >/dev/null
trap 'docker stop vcsim >/dev/null' EXIT

for _ in $(seq 1 30); do
  (echo > /dev/tcp/127.0.0.1/8989) >/dev/null 2>&1 && break
  sleep 2
done

DR_VCENTER_SERVER=localhost pwsh -NoProfile -Command \
  'Invoke-Pester -Path ./tests/DrOrchestrator.Vmware.Tests.ps1 -Output Detailed'
