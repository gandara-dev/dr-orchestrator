BeforeAll {
    $modulePath = Join-Path $PSScriptRoot '../src/DrOrchestrator/DrOrchestrator.psd1'
    Import-Module $modulePath -Force
    $script:runbookPath = Join-Path $PSScriptRoot '../runbooks/site-recovery.yml'
}

Describe 'Module contract' {
    It 'has a valid manifest and exports only the documented commands' {
        $manifest = Test-ModuleManifest -Path $modulePath
        $commands = @(Get-Command -Module DrOrchestrator | Select-Object -ExpandProperty Name)

        $manifest.Version | Should -Be '0.1.2'
        (($commands | Sort-Object) -join ',') | Should -Be (
            'Export-DrReport,Get-DrExecutionOrder,Import-DrRunbook,Invoke-DrRunbook'
        )
    }

    It 'provides synopsis help for every exported command' {
        foreach ($command in Get-Command -Module DrOrchestrator) {
            (Get-Help $command.Name).Synopsis | Should -Not -BeNullOrEmpty
        }
    }
}

Describe 'Runbook loading and dependency ordering' {
    It 'loads the sample YAML and returns steps in dependency order' {
        $runbook = Import-DrRunbook -Path $runbookPath
        $orderedIds = @(Get-DrExecutionOrder -Runbook $runbook | ForEach-Object Id)

        ($orderedIds -join ',') | Should -Be 'start-ad,check-ad-ldap,start-sql,check-sql,start-delivery-controllers,check-delivery-controller,start-storefront,check-storefront,start-vdas'
    }

    It 'rejects a dependency cycle' {
        $cyclicRunbook = [pscustomobject]@{
            Steps = @(
                [pscustomobject]@{ Id = 'a'; DependsOn = @('b') }
                [pscustomobject]@{ Id = 'b'; DependsOn = @('a') }
            )
        }

        { Get-DrExecutionOrder -Runbook $cyclicRunbook } | Should -Throw '*Dependency cycle*'
    }

    It 'rejects an unknown dependency while importing' {
        $path = Join-Path $TestDrive 'unknown-dependency.yml'
        @'
name: Invalid
version: 1
steps:
  - id: service
    name: Start service
    provider: Windows
    action: StartService
    dependsOn: [missing]
    parameters:
      computerName: host.example.test
      serviceName: ExampleService
'@ | Set-Content -LiteralPath $path

        { Import-DrRunbook -Path $path } | Should -Throw "*unknown step 'missing'*"
    }

    It 'rejects an action that is not supported by its provider' {
        $path = Join-Path $TestDrive 'unsupported-action.yml'
        @'
name: Invalid action
version: 1
steps:
  - id: invalid
    name: Invalid action
    provider: VMware
    action: TestHttp
    parameters:
      uri: https://example.test/
'@ | Set-Content -LiteralPath $path

        { Import-DrRunbook -Path $path } | Should -Throw "*unsupported action 'TestHttp'*"
    }

    It 'rejects a step with missing required action parameters' {
        $path = Join-Path $TestDrive 'missing-parameters.yml'
        @'
name: Missing parameters
version: 1
steps:
  - id: start-vm
    name: Start a VM
    provider: VMware
    action: StartVM
'@ | Set-Content -LiteralPath $path

        { Import-DrRunbook -Path $path } | Should -Throw '*requires parameters.vmNames*'
    }
}

Describe 'Runbook simulation' {
    It 'completes all steps without external infrastructure' {
        $result = Invoke-DrRunbook -Path $runbookPath -Simulation

        $result.Status | Should -Be 'Succeeded'
        $result.Simulation | Should -BeTrue
        @($result.Steps).Count | Should -Be 9
        @($result.Steps | Where-Object Status -ne 'Succeeded').Count | Should -Be 0
        $result.ElapsedMilliseconds | Should -BeGreaterOrEqual 0
    }

    It 'fails an injected step and blocks its dependents while continuing independent work' {
        $path = Join-Path $TestDrive 'independent-steps.yml'
        @'
name: Independent branches
version: 1
steps:
  - id: first
    name: First branch
    provider: VMware
    action: StartVM
    parameters:
      vmNames: [vm-first]
  - id: dependent
    name: Dependent branch
    provider: Windows
    action: TestTcpPort
    dependsOn: [first]
    parameters:
      computerName: service.example.test
      port: 443
  - id: independent
    name: Independent branch
    provider: VMware
    action: StartVM
    parameters:
      vmNames: [vm-independent]
'@ | Set-Content -LiteralPath $path

        $result = Invoke-DrRunbook -Path $path -Simulation -InjectFailureStepId first

        $result.Status | Should -Be 'Failed'
        $result.Steps[0].Status | Should -Be 'Failed'
        $result.Steps[1].Status | Should -Be 'Blocked'
        $result.Steps[2].Status | Should -Be 'Succeeded'
    }
}

Describe 'Report export' {
    It 'writes Markdown and HTML reports with the execution timeline' {
        $execution = Invoke-DrRunbook -Path $runbookPath -Simulation
        $files = Export-DrReport -Execution $execution -OutputDirectory (Join-Path $TestDrive 'reports')

        Test-Path $files.MarkdownPath | Should -BeTrue
        Test-Path $files.HtmlPath | Should -BeTrue
        (Get-Content $files.MarkdownPath -Raw) | Should -Match 'Measured elapsed time'
        (Get-Content $files.HtmlPath -Raw) | Should -Match '<table>'
    }

    It 'HTML-encodes runbook-controlled text' {
        $execution = Invoke-DrRunbook -Path $runbookPath -Simulation
        $execution.Steps[0].Name = '<script>alert(1)</script>'
        $files = Export-DrReport -Execution $execution -OutputDirectory (Join-Path $TestDrive 'escaped-report')
        $html = Get-Content $files.HtmlPath -Raw

        $html | Should -Not -Match '<script>alert\(1\)</script>'
        $html | Should -Match '&lt;script&gt;'
    }
}
