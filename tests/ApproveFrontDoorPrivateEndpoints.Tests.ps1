BeforeAll {
    Import-Module (Join-Path $PSScriptRoot 'Bicep.TestHelpers.psm1') -Force
    $scriptPath = Get-RepoPath 'scripts/Approve-FrontDoorPrivateEndpoints.ps1'
    $appId = '/subscriptions/22222222-2222-2222-2222-222222222222/resourceGroups/rg-defenstack-dev-wus3/providers/Microsoft.Web/sites/app-defenstack-dev-wus3-abc123'

    # Shadows the Azure CLI with a stateful fake: $global:FakeConnections holds the app's connections;
    # 'approve' flips one to Approved, and every call is recorded in $global:AzCalls.
    function Set-FakeConnections([object[]]$Connections) {
        $global:AzCalls = [System.Collections.Generic.List[string]]::new()
        $global:FakeConnections = [System.Collections.Generic.List[object]]::new()
        foreach ($c in $Connections) { $global:FakeConnections.Add($c) }
        function global:az {
            $joined = $args -join ' '
            $global:AzCalls.Add($joined)
            $global:LASTEXITCODE = 0
            if ($joined -like 'network private-endpoint-connection list*') {
                return (ConvertTo-Json -InputObject @($global:FakeConnections) -Depth 6)
            }
            if ($joined -like 'network private-endpoint-connection approve*') {
                $id = $args[[array]::IndexOf($args, '--id') + 1]
                $description = $args[[array]::IndexOf($args, '--description') + 1]
                foreach ($c in $global:FakeConnections) {
                    if ($c.id -eq $id) {
                        $c.properties.privateLinkServiceConnectionState.status = 'Approved'
                        $c.properties.privateLinkServiceConnectionState.description = $description
                    }
                }
                return ''
            }
            return ''
        }
    }

    function Remove-FakeConnections {
        Remove-Item -Path Function:\az -ErrorAction SilentlyContinue
        Remove-Variable -Name FakeConnections -Scope Global -ErrorAction SilentlyContinue
    }

    function New-Connection([string]$Name, [string]$Status, [string]$Description) {
        [pscustomobject]@{
            id         = "$appId/privateEndpointConnections/$Name"
            name       = $Name
            properties = [pscustomobject]@{
                privateLinkServiceConnectionState = [pscustomobject]@{ status = $Status; description = $Description }
            }
        }
    }

    function Get-Approvals { @($global:AzCalls | Where-Object { $_ -like 'network private-endpoint-connection approve*' }) }
}

Describe 'Approve-FrontDoorPrivateEndpoints.ps1 (Phase 4)' {
    AfterEach { Remove-FakeConnections }

    It 'exists, parses, and supports -WhatIf' {
        $scriptPath | Should -Exist
        $tokens = $null; $errors = $null
        [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$tokens, [ref]$errors) | Out-Null
        $errors | Should -BeNullOrEmpty
        (Get-Command $scriptPath).Parameters.Keys | Should -Contain 'WhatIf'
    }

    It 'rejects an ID that is not an App Service' {
        { & $scriptPath -AppServiceId '/subscriptions/22222222-2222-2222-2222-222222222222/resourceGroups/rg/providers/Microsoft.KeyVault/vaults/kv' } |
            Should -Throw '*does not match*'
    }

    It 'approves a pending Front Door connection and keeps the request message as the description prefix' {
        Set-FakeConnections @(New-Connection 'fd-1' 'Pending' 'defenstack-frontdoor')
        & $scriptPath -AppServiceId $appId -TimeoutSeconds 0 | Out-Null
        $approvals = @(Get-Approvals)
        $approvals.Count | Should -Be 1
        $approvals[0] | Should -BeLike "*--id $appId/privateEndpointConnections/fd-1 *"
        $global:FakeConnections[0].properties.privateLinkServiceConnectionState.description | Should -BeLike 'defenstack-frontdoor*'
    }

    It 'never approves a pending connection with a different request message' {
        Set-FakeConnections @(
            New-Connection 'fd-1' 'Approved' 'defenstack-frontdoor approved by Approve-FrontDoorPrivateEndpoints.ps1'
            New-Connection 'someone-else' 'Pending' 'please approve me'
        )
        & $scriptPath -AppServiceId $appId -TimeoutSeconds 0 -WarningVariable warnings -WarningAction SilentlyContinue | Out-Null
        Get-Approvals | Should -BeNullOrEmpty
        $global:FakeConnections[1].properties.privateLinkServiceConnectionState.status | Should -Be 'Pending'
        ($warnings -join ' ') | Should -Match 'someone-else'
    }

    It 'returns without approving when the Front Door connection is already approved' {
        Set-FakeConnections @(New-Connection 'fd-1' 'Approved' 'defenstack-frontdoor approved by Approve-FrontDoorPrivateEndpoints.ps1')
        { & $scriptPath -AppServiceId $appId -TimeoutSeconds 0 | Out-Null } | Should -Not -Throw
        Get-Approvals | Should -BeNullOrEmpty
    }

    It 'fails when no Front Door connection is approved before the timeout' {
        Set-FakeConnections @()
        { & $scriptPath -AppServiceId $appId -TimeoutSeconds 0 | Out-Null } | Should -Throw '*no Front Door private endpoint connection was approved*'
    }

    It 'makes no approval under -WhatIf' {
        Set-FakeConnections @(New-Connection 'fd-1' 'Pending' 'defenstack-frontdoor')
        & $scriptPath -AppServiceId $appId -WhatIf | Out-Null
        Get-Approvals | Should -BeNullOrEmpty
    }

    It 'fails when the Azure CLI cannot list connections' {
        Set-FakeConnections @()
        function global:az { $global:LASTEXITCODE = 1; return '' }
        { & $scriptPath -AppServiceId $appId -TimeoutSeconds 0 | Out-Null } | Should -Throw '*Unable to list private endpoint connections*'
    }
}
