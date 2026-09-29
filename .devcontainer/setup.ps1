# Installs the modules the project and its tests need, at the versions CI uses.
$ErrorActionPreference = 'Stop'
Set-PSRepository -Name PSGallery -InstallationPolicy Trusted
Install-Module Pester -RequiredVersion 5.7.1 -Scope CurrentUser -Force -SkipPublisherCheck
Install-Module powershell-yaml -RequiredVersion 0.4.12 -Scope CurrentUser -Force
Write-Information 'DR Orchestrator is ready. See .devcontainer/README.md.' -InformationAction Continue
