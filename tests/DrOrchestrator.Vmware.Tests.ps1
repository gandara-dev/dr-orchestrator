BeforeAll {
    Import-Module VMware.VimAutomation.Core -ErrorAction Stop -WarningAction SilentlyContinue
    $modulePath = Join-Path $PSScriptRoot '../src/DrOrchestrator/DrOrchestrator.psd1'
    Import-Module $modulePath -Force

    if ([string]::IsNullOrWhiteSpace($env:DR_VCENTER_SERVER)) {
        throw 'DR_VCENTER_SERVER must identify the vcsim host.'
    }

    Set-PowerCLIConfiguration `
        -Scope Session `
        -InvalidCertificateAction Ignore `
        -DefaultVIServerMode Single `
        -WebOperationTimeoutSeconds 30 `
        -Confirm:$false | Out-Null
}

Describe 'vcsim integration' {
    It 'starts a powered-off virtual machine through the VMware provider' {
        $securePassword = [System.Security.SecureString]::new()
        foreach ($character in [char[]](112, 97, 115, 115)) {
            $securePassword.AppendChar($character)
        }
        $securePassword.MakeReadOnly()
        $credential = [pscredential]::new('user', $securePassword)
        $port = if ($env:DR_VCENTER_PORT) { [int]$env:DR_VCENTER_PORT } else { 8989 }
        $server = $null

        try {
            $server = Connect-VIServer `
                -Server $env:DR_VCENTER_SERVER `
                -Port $port `
                -Protocol https `
                -Credential $credential `
                -Force `
                -ErrorAction Stop `
                -WarningAction SilentlyContinue

            $vm = Get-VM -Server $server -ErrorAction Stop |
                Where-Object PowerState -eq 'PoweredOff' |
                Select-Object -First 1
            $vm | Should -Not -BeNullOrEmpty

            $runbookPath = Join-Path $TestDrive 'vcsim-provider.yml'
            $runbookDefinition = [ordered]@{
                name = 'vcsim provider smoke test'
                version = 1
                steps = @(
                    [ordered]@{
                        id = 'start-vm'
                        name = 'Start a simulated VM'
                        provider = 'VMware'
                        action = 'StartVM'
                        parameters = [ordered]@{
                            vmNames = @([string]$vm.Name)
                        }
                    }
                )
            }
            ConvertTo-Yaml -Data $runbookDefinition |
                Set-Content -LiteralPath $runbookPath

            $result = Invoke-DrRunbook -Path $runbookPath

            $result.Status | Should -Be 'Succeeded' -Because $result.Steps[0].Message
            $result.Steps[0].Status | Should -Be 'Succeeded' -Because $result.Steps[0].Message
            (Get-VM -Id $vm.Id -Server $server -ErrorAction Stop).PowerState |
                Should -Be 'PoweredOn'
        }
        finally {
            if ($null -ne $server) {
                Disconnect-VIServer -Server $server -Force -Confirm:$false
            }
        }
    }
}
