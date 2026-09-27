function New-DrStepResult {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSUseShouldProcessForStateChangingFunctions',
        '',
        Justification = 'This function only creates an in-memory result object.'
    )]
    param(
        [Parameter(Mandatory)]
        [bool]$Success,

        [Parameter(Mandatory)]
        [string]$Message
    )

    return [pscustomobject]@{
        Success = $Success
        Message = $Message
    }
}

function Invoke-DrVmwareStep {
    param(
        [Parameter(Mandatory)]
        [psobject]$Step
    )

    if (-not (Get-Module -Name VMware.VimAutomation.Core -ListAvailable)) {
        throw 'VCF PowerCLI is required for VMware steps. Install VCF.PowerCLI and connect with Connect-VIServer first.'
    }

    $serverName = [string]$Step.Parameters.server
    if ([string]::IsNullOrWhiteSpace($serverName)) {
        $serverName = $env:DR_VCENTER_SERVER
    }

    # Get-VIServer is an alias for Connect-VIServer and can trigger a credential
    # prompt. Read PowerCLI's connection variables instead so missing sessions
    # always fail explicitly.
    $connectedServers = @(
        Get-Variable -Name DefaultVIServers -Scope Global -ValueOnly -ErrorAction SilentlyContinue |
            Where-Object IsConnected
    )
    if ($connectedServers.Count -eq 0) {
        $connectedServers = @(
            Get-Variable -Name DefaultVIServer -Scope Global -ValueOnly -ErrorAction SilentlyContinue |
                Where-Object IsConnected
        )
    }
    if ([string]::IsNullOrWhiteSpace($serverName)) {
        $server = $connectedServers | Select-Object -First 1
    }
    else {
        $server = $connectedServers |
            Where-Object {
                $_.Name -eq $serverName -or
                $_.ServiceUri.Host -eq $serverName
            } |
            Select-Object -First 1
    }

    if ($null -eq $server) {
        throw 'No authenticated vCenter session found. Connect with Connect-VIServer before executing VMware steps.'
    }

    $vmNames = @($Step.Parameters.vmNames | ForEach-Object { [string]$_ })
    if ($vmNames.Count -eq 0) {
        throw "VMware action '$($Step.Action)' requires parameters.vmNames."
    }

    foreach ($vmName in $vmNames) {
        $vm = Get-VM -Name $vmName -Server $server -ErrorAction Stop
        switch -CaseSensitive ($Step.Action) {
            'StartVM' {
                if ($vm.PowerState -ne 'PoweredOn') {
                    Start-VM -VM $vm -Confirm:$false -ErrorAction Stop | Out-Null
                }
            }
            'WaitForTools' {
                $timeoutSeconds = [int]$Step.Parameters.timeoutSeconds
                if ($timeoutSeconds -lt 1) {
                    $timeoutSeconds = 300
                }
                Wait-Tools -VM $vm -TimeoutSeconds $timeoutSeconds -ErrorAction Stop | Out-Null
            }
            'TestVM' {
                if ($vm.PowerState -ne 'PoweredOn') {
                    throw "VM '$vmName' is not powered on."
                }
            }
            default {
                throw "Unsupported VMware action '$($Step.Action)'."
            }
        }
    }

    return New-DrStepResult -Success $true -Message "VMware action '$($Step.Action)' completed for $($vmNames -join ', ')."
}

function Invoke-DrWindowsStep {
    param(
        [Parameter(Mandatory)]
        [psobject]$Step
    )

    switch -CaseSensitive ($Step.Action) {
        'StartService' {
            $computerName = [string]$Step.Parameters.computerName
            $serviceName = [string]$Step.Parameters.serviceName
            if ([string]::IsNullOrWhiteSpace($computerName) -or [string]::IsNullOrWhiteSpace($serviceName)) {
                throw 'StartService requires parameters.computerName and parameters.serviceName.'
            }

            $startService = {
                param($RemoteServiceName)
                $service = Get-Service -Name $RemoteServiceName -ErrorAction Stop
                if ($service.Status -ne 'Running') {
                    Start-Service -Name $RemoteServiceName -ErrorAction Stop
                    (Get-Service -Name $RemoteServiceName).WaitForStatus('Running', [TimeSpan]::FromSeconds(60))
                }
            }
            Invoke-Command -ComputerName $computerName -ArgumentList $serviceName -ScriptBlock $startService -ErrorAction Stop | Out-Null
            return New-DrStepResult -Success $true -Message "Service '$serviceName' is running on '$computerName'."
        }
        'TestTcpPort' {
            $computerName = [string]$Step.Parameters.computerName
            $port = [int]$Step.Parameters.port
            $timeoutSeconds = [int]$Step.Parameters.timeoutSeconds
            if ([string]::IsNullOrWhiteSpace($computerName) -or $port -lt 1 -or $port -gt 65535) {
                throw 'TestTcpPort requires a computerName and a valid port (1-65535).'
            }
            if ($timeoutSeconds -lt 1) {
                $timeoutSeconds = 5
            }

            $client = [System.Net.Sockets.TcpClient]::new()
            try {
                $connectTask = $client.ConnectAsync($computerName, $port)
                if (-not $connectTask.Wait([TimeSpan]::FromSeconds($timeoutSeconds))) {
                    throw "Timed out connecting to '$computerName' on TCP port $port."
                }
                $connectTask.GetAwaiter().GetResult()
            }
            finally {
                $client.Dispose()
            }
            return New-DrStepResult -Success $true -Message "TCP port $port is reachable on '$computerName'."
        }
        'TestHttp' {
            $uri = [string]$Step.Parameters.uri
            if ([string]::IsNullOrWhiteSpace($uri)) {
                throw 'TestHttp requires parameters.uri.'
            }
            $timeoutSeconds = [int]$Step.Parameters.timeoutSeconds
            if ($timeoutSeconds -lt 1) {
                $timeoutSeconds = 10
            }

            $response = Invoke-WebRequest -Uri $uri -TimeoutSec $timeoutSeconds -ErrorAction Stop
            if ([int]$response.StatusCode -ge 400) {
                throw "HTTP health check returned status $($response.StatusCode) for '$uri'."
            }
            return New-DrStepResult -Success $true -Message "HTTP health check passed for '$uri' (status $($response.StatusCode))."
        }
        default {
            throw "Unsupported Windows action '$($Step.Action)'."
        }
    }
}

function Invoke-DrProviderStep {
    param(
        [Parameter(Mandatory)]
        [psobject]$Step,

        [Parameter(Mandatory)]
        [bool]$Simulation,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [System.Collections.Generic.HashSet[string]]$InjectedFailures
    )

    if ($Simulation) {
        if ($InjectedFailures.Contains([string]$Step.Id)) {
            return New-DrStepResult -Success $false -Message "Injected simulation failure at step '$($Step.Id)'."
        }
        return New-DrStepResult -Success $true -Message "Simulated '$($Step.Action)' using the $($Step.Provider) provider."
    }

    switch -CaseSensitive ($Step.Provider) {
        'VMware' { return Invoke-DrVmwareStep -Step $Step }
        'Windows' { return Invoke-DrWindowsStep -Step $Step }
        default { throw "Unsupported provider '$($Step.Provider)'." }
    }
}
