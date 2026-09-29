BeforeAll {
    $modulePath = Join-Path $PSScriptRoot '../src/DrOrchestrator/DrOrchestrator.psd1'
    Import-Module $modulePath -Force
    $script:runbookPath = Join-Path $PSScriptRoot '../runbooks/site-recovery.yml'
}

Describe 'Module contract' {
    It 'has a valid manifest and exports only the documented commands' {
        $manifest = Test-ModuleManifest -Path $modulePath
        $commands = @(Get-Command -Module DrOrchestrator | Select-Object -ExpandProperty Name)

        $manifest.Version | Should -Be '0.2.1'
        (($commands | Sort-Object) -join ',') | Should -Be (
            'Export-DrReport,Get-DrExecutionOrder,Get-DrRecoveryPlan,Import-DrRunbook,Invoke-DrRunbook'
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

Describe 'Recovery planning' {
    BeforeAll {
        $script:citrixRunbookPath = Join-Path $PSScriptRoot '../runbooks/citrix-site-recovery.yml'
    }

    It 'derives the sequential estimate and the critical path from step durations' {
        $plan = Import-DrRunbook -Path $citrixRunbookPath | Get-DrRecoveryPlan

        $plan.SequentialEstimateSeconds | Should -Be 2730
        $plan.CriticalPathSeconds | Should -Be 1890
        ($plan.CriticalPath -join ',') | Should -Be (
            'start-ad,check-ad-ldap,start-sql,check-sql,start-delivery-controllers,check-delivery-controller,start-vdas,wait-vda-tools'
        )
        $plan.MissingDurations | Should -BeNullOrEmpty
        ($plan.Steps | Where-Object Id -eq 'check-gateway').Level | Should -Be 8
        ($plan.Steps | Where-Object Id -eq 'start-netscaler').OnCriticalPath | Should -BeFalse
    }

    It 'counts steps without a duration as zero and reports them' {
        $path = Join-Path $TestDrive 'partial.yml'
        @(
            'name: Partial'
            'version: 1'
            'steps:'
            '  - id: a'
            '    name: A'
            '    provider: VMware'
            '    action: StartVM'
            '    expectedDurationSeconds: 60'
            '    parameters: { vmNames: [vm-a] }'
            '  - id: b'
            '    name: B'
            '    provider: VMware'
            '    action: StartVM'
            '    dependsOn: [a]'
            '    parameters: { vmNames: [vm-b] }'
        ) | Set-Content -LiteralPath $path

        $plan = Import-DrRunbook -Path $path | Get-DrRecoveryPlan
        $plan.CriticalPathSeconds | Should -Be 60
        @($plan.MissingDurations) | Should -Be @('b')
    }

    It 'rejects a duration that is not a whole number of seconds' {
        $path = Join-Path $TestDrive 'bad-duration.yml'
        @(
            'name: Bad'
            'version: 1'
            'steps:'
            '  - id: a'
            '    name: A'
            '    provider: VMware'
            '    action: StartVM'
            '    expectedDurationSeconds: 1.5'
            '    parameters: { vmNames: [vm-a] }'
        ) | Set-Content -LiteralPath $path

        { Import-DrRunbook -Path $path } | Should -Throw '*expectedDurationSeconds must be a whole number*'
    }

    It 'keeps independent branches running when a shared service fails' {
        $execution = Import-DrRunbook -Path $citrixRunbookPath |
            Invoke-DrRunbook -Simulation -InjectFailureStepId start-license

        $status = @{}
        foreach ($step in $execution.Steps) { $status[$step.Id] = $step.Status }
        $execution.Status | Should -Be 'Failed'
        $status['start-license'] | Should -Be 'Failed'
        $status['start-delivery-controllers'] | Should -Be 'Blocked'
        $status['check-sql'] | Should -Be 'Succeeded'
        $status['check-smb'] | Should -Be 'Succeeded'
        $status['start-netscaler'] | Should -Be 'Succeeded'
    }
}

Describe 'Runbook Viewer contract' {
    BeforeAll {
        $script:repositoryRoot = Split-Path -Parent $PSScriptRoot
    }

    It 'publishes JSON runbooks that match the YAML sources' {
        foreach ($source in Get-ChildItem -Path (Join-Path $repositoryRoot 'runbooks') -Filter '*.yml') {
            $generated = Join-Path $TestDrive ($source.BaseName + '.json')
            & (Join-Path $repositoryRoot 'scripts/Export-DrRunbookJson.ps1') -Path $source.FullName -OutputPath $generated | Out-Null
            $published = Join-Path $repositoryRoot "site/runbooks/$($source.BaseName).json"
            (Get-Content -LiteralPath $generated -Raw) -replace "`r`n", "`n" |
                Should -BeExactly ((Get-Content -LiteralPath $published -Raw) -replace "`r`n", "`n")
        }
    }

    It 'keeps the shared viewer fixtures in sync with the engine' {
        $generated = Join-Path $TestDrive 'viewer-cases.json'
        & (Join-Path $PSScriptRoot 'Update-ViewerFixtures.ps1') -OutputPath $generated
        (Get-Content -LiteralPath $generated -Raw) -replace "`r`n", "`n" |
            Should -BeExactly ((Get-Content -LiteralPath (Join-Path $PSScriptRoot 'fixtures/viewer-cases.json') -Raw) -replace "`r`n", "`n")
    }
}

