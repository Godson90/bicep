BeforeAll {
    Import-Module (Join-Path $PSScriptRoot 'Bicep.TestHelpers.psm1') -Force
    $scriptPath = Get-RepoPath 'scripts/Approve-FrontDoorPrivateEndpoints.ps1'
    $appId = '/subscriptions/22222222-2222-2222-2222-222222222222/resourceGroups/rg-defenstack-dev-wus3/providers/Microsoft.Web/sites/app-defenstack-dev-wus3-abc123'
    $fdProfile = 'afd-defenstack-dev'
    $fdRg = 'rg-defenstack-dev-global'

    # Shadows the Azure CLI with a stateful fake: $global:FakeConnections holds the primary app's connections
    # (additional apps can be seeded through -AdditionalByAppId); $global:FakeOrigins holds the whole origin
    # group's origins (az afd origin list is not filtered per app, so every app in the loop sees the same list
    # and the script itself picks out the one whose sharedPrivateLinkResource.privateLink.id matches).
    # 'approve' flips a connection to Approved and, unless -OriginFlipsOnApproval is $false, flips the matching
    # origin to Approved too, modeling Front Door eventually catching up. Every call is recorded in $global:AzCalls.
    function New-Origin([string]$Name, [string]$Status, [string]$ForAppId = $appId) {
        [pscustomobject]@{
            name       = $Name
            properties = [pscustomobject]@{
                sharedPrivateLinkResource = [pscustomobject]@{
                    status      = $Status
                    privateLink = [pscustomobject]@{ id = $ForAppId }
                }
            }
        }
    }

    function Set-FakeConnections(
        [object[]]$Connections,
        [hashtable]$AdditionalByAppId = @{},
        [object[]]$Origins = @(),
        [bool]$OriginFlipsOnApproval = $true
    ) {
        $global:AzCalls = [System.Collections.Generic.List[string]]::new()
        $global:FakeConnections = [System.Collections.Generic.List[object]]::new()
        foreach ($c in $Connections) { $global:FakeConnections.Add($c) }

        $global:FakeConnectionsByApp = @{ $appId = $global:FakeConnections }
        foreach ($key in $AdditionalByAppId.Keys) {
            $list = [System.Collections.Generic.List[object]]::new()
            foreach ($c in $AdditionalByAppId[$key]) { $list.Add($c) }
            $global:FakeConnectionsByApp[$key] = $list
        }

        $global:FakeOrigins = [System.Collections.Generic.List[object]]::new()
        foreach ($o in $Origins) { $global:FakeOrigins.Add($o) }
        $global:FakeOriginFlipsOnApproval = $OriginFlipsOnApproval

        function global:az {
            $joined = $args -join ' '
            $global:AzCalls.Add($joined)
            $global:LASTEXITCODE = 0
            if ($joined -like 'network private-endpoint-connection list*') {
                $reqId = $args[[array]::IndexOf($args, '--id') + 1]
                $list = $global:FakeConnectionsByApp[$reqId]
                if (-not $list) { $list = @() }
                return (ConvertTo-Json -InputObject @($list) -Depth 6)
            }
            if ($joined -like 'network private-endpoint-connection approve*') {
                $id = $args[[array]::IndexOf($args, '--id') + 1]
                $description = $args[[array]::IndexOf($args, '--description') + 1]
                foreach ($appKey in $global:FakeConnectionsByApp.Keys) {
                    foreach ($c in $global:FakeConnectionsByApp[$appKey]) {
                        if ($c.id -eq $id) {
                            $c.properties.privateLinkServiceConnectionState.status = 'Approved'
                            $c.properties.privateLinkServiceConnectionState.description = $description
                        }
                    }
                }
                if ($global:FakeOriginFlipsOnApproval) {
                    $forAppId = ($id -split '/privateEndpointConnections/')[0]
                    foreach ($o in $global:FakeOrigins) {
                        if ($o.properties.sharedPrivateLinkResource.privateLink.id -ieq $forAppId) {
                            $o.properties.sharedPrivateLinkResource.status = 'Approved'
                        }
                    }
                }
                return ''
            }
            if ($joined -like 'afd origin list*') {
                return (ConvertTo-Json -InputObject @($global:FakeOrigins) -Depth 6)
            }
            return ''
        }
    }

    function Remove-FakeConnections {
        Remove-Item -Path Function:\az -ErrorAction SilentlyContinue
        Remove-Variable -Name FakeConnections -Scope Global -ErrorAction SilentlyContinue
        Remove-Variable -Name FakeConnectionsByApp -Scope Global -ErrorAction SilentlyContinue
        Remove-Variable -Name FakeOrigins -Scope Global -ErrorAction SilentlyContinue
        Remove-Variable -Name FakeOriginFlipsOnApproval -Scope Global -ErrorAction SilentlyContinue
        Remove-Variable -Name AzCalls -Scope Global -ErrorAction SilentlyContinue
        Remove-Variable -Name ListCallCount -Scope Global -ErrorAction SilentlyContinue
    }

    function New-Connection(
        [string]$Name,
        [string]$Status,
        [string]$Description,
        [string]$ForAppId = $appId,
        [string]$PrivateEndpointId
    ) {
        if (-not $PrivateEndpointId) {
            $PrivateEndpointId = "$ForAppId-privateEndpoints-pe-$Name"
        }
        [pscustomobject]@{
            id         = "$ForAppId/privateEndpointConnections/$Name"
            name       = $Name
            properties = [pscustomobject]@{
                privateLinkServiceConnectionState = [pscustomobject]@{ status = $Status; description = $Description }
                privateEndpoint                   = [pscustomobject]@{ id = $PrivateEndpointId }
            }
        }
    }

    function Get-Approvals { @($global:AzCalls | Where-Object { $_ -like 'network private-endpoint-connection approve*' }) }
}

Describe 'Approve-FrontDoorPrivateEndpoints.ps1 (Phase 4)' {
    AfterEach { Remove-FakeConnections }

    It 'exists, parses, and supports -WhatIf, with the Front Door origin parameters' {
        $scriptPath | Should -Exist
        $tokens = $null; $errors = $null
        [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$tokens, [ref]$errors) | Out-Null
        $errors | Should -BeNullOrEmpty
        $command = Get-Command $scriptPath
        $command.Parameters.Keys | Should -Contain 'WhatIf'
        $command.Parameters.Keys | Should -Contain 'FrontDoorProfileName'
        $command.Parameters.Keys | Should -Contain 'FrontDoorResourceGroupName'
        $command.Parameters.Keys | Should -Contain 'OriginGroupName'
        $command.Parameters['FrontDoorProfileName'].Attributes.Mandatory | Should -Contain $true
        $command.Parameters['FrontDoorResourceGroupName'].Attributes.Mandatory | Should -Contain $true
    }

    It 'rejects an ID that is not an App Service' {
        { & $scriptPath -AppServiceId '/subscriptions/22222222-2222-2222-2222-222222222222/resourceGroups/rg/providers/Microsoft.KeyVault/vaults/kv' -FrontDoorProfileName $fdProfile -FrontDoorResourceGroupName $fdRg } |
            Should -Throw '*does not match*'
    }

    It 'approves a pending Front Door connection and keeps the request message as the description prefix' {
        Set-FakeConnections -Connections @(New-Connection 'fd-1' 'Pending' 'defenstack-frontdoor') -Origins @(New-Origin 'app-wus3' 'Pending')
        & $scriptPath -AppServiceId $appId -FrontDoorProfileName $fdProfile -FrontDoorResourceGroupName $fdRg -TimeoutSeconds 0 | Out-Null
        $approvals = @(Get-Approvals)
        $approvals.Count | Should -Be 1
        $approvals[0] | Should -BeLike "*--id $appId/privateEndpointConnections/fd-1 *"
        $global:FakeConnections[0].properties.privateLinkServiceConnectionState.description | Should -BeLike 'defenstack-frontdoor*'
    }

    It 'never approves a pending connection with a different request message' {
        Set-FakeConnections -Connections @(
            New-Connection 'fd-1' 'Approved' 'defenstack-frontdoor approved by Approve-FrontDoorPrivateEndpoints.ps1'
            New-Connection 'someone-else' 'Pending' 'please approve me'
        ) -Origins @(New-Origin 'app-wus3' 'Approved')
        & $scriptPath -AppServiceId $appId -FrontDoorProfileName $fdProfile -FrontDoorResourceGroupName $fdRg -TimeoutSeconds 0 -WarningVariable warnings -WarningAction SilentlyContinue | Out-Null
        Get-Approvals | Should -BeNullOrEmpty
        $global:FakeConnections[1].properties.privateLinkServiceConnectionState.status | Should -Be 'Pending'
        ($warnings -join ' ') | Should -Match 'someone-else'
    }

    It 'returns without approving when the Front Door connection is already approved' {
        Set-FakeConnections -Connections @(New-Connection 'fd-1' 'Approved' 'defenstack-frontdoor approved by Approve-FrontDoorPrivateEndpoints.ps1') -Origins @(New-Origin 'app-wus3' 'Approved')
        { & $scriptPath -AppServiceId $appId -FrontDoorProfileName $fdProfile -FrontDoorResourceGroupName $fdRg -TimeoutSeconds 0 | Out-Null } | Should -Not -Throw
        Get-Approvals | Should -BeNullOrEmpty
    }

    It 'fails when no Front Door connection is approved before the timeout (origin exists but never reaches Approved)' {
        Set-FakeConnections -Connections @() -Origins @(New-Origin 'app-wus3' 'Pending')
        { & $scriptPath -AppServiceId $appId -FrontDoorProfileName $fdProfile -FrontDoorResourceGroupName $fdRg -TimeoutSeconds 0 | Out-Null } | Should -Throw '*no Front Door private endpoint connection was approved*'
    }

    It 'makes no approval under -WhatIf' {
        Set-FakeConnections -Connections @(New-Connection 'fd-1' 'Pending' 'defenstack-frontdoor')
        & $scriptPath -AppServiceId $appId -FrontDoorProfileName $fdProfile -FrontDoorResourceGroupName $fdRg -WhatIf | Out-Null
        Get-Approvals | Should -BeNullOrEmpty
    }

    It 'fails when the Azure CLI cannot list connections' {
        Set-FakeConnections -Connections @()
        function global:az { $global:LASTEXITCODE = 1; return '' }
        { & $scriptPath -AppServiceId $appId -FrontDoorProfileName $fdProfile -FrontDoorResourceGroupName $fdRg -TimeoutSeconds 0 | Out-Null } | Should -Throw '*Unable to list private endpoint connections*'
    }

    It 'approves the Front Door connection and leaves an unrelated connection untouched (regression: JSON array unrolling on PS 5.1)' {
        Set-FakeConnections -Connections @(
            New-Connection 'fd-1' 'Pending' 'defenstack-frontdoor'
            New-Connection 'unrelated' 'Approved' 'some other service'
        ) -Origins @(New-Origin 'app-wus3' 'Pending')
        & $scriptPath -AppServiceId $appId -FrontDoorProfileName $fdProfile -FrontDoorResourceGroupName $fdRg -TimeoutSeconds 0 | Out-Null
        $approvals = @(Get-Approvals)
        $approvals.Count | Should -Be 1
        $approvals[0] | Should -BeLike "*--id $appId/privateEndpointConnections/fd-1 *"
        $global:FakeConnections[1].properties.privateLinkServiceConnectionState.status | Should -Be 'Approved'
        $global:FakeConnections[1].properties.privateLinkServiceConnectionState.description | Should -Be 'some other service'
    }

    It 'includes the private endpoint id in the approval output' {
        Set-FakeConnections -Connections @(New-Connection 'fd-1' 'Pending' 'defenstack-frontdoor' -PrivateEndpointId '/subscriptions/22222222-2222-2222-2222-222222222222/resourceGroups/rg-defenstack-dev-wus3/providers/Microsoft.Network/privateEndpoints/pe-fd-1') -Origins @(New-Origin 'app-wus3' 'Pending')
        $output = & $scriptPath -AppServiceId $appId -FrontDoorProfileName $fdProfile -FrontDoorResourceGroupName $fdRg -TimeoutSeconds 0
        ($output -join ' ') | Should -Match ([regex]::Escape('(private endpoint /subscriptions/22222222-2222-2222-2222-222222222222/resourceGroups/rg-defenstack-dev-wus3/providers/Microsoft.Network/privateEndpoints/pe-fd-1)'))
    }

    It 'refuses to approve when a Front Door connection is already approved and another pending connection shares the same request message (possible spoofing)' {
        Set-FakeConnections -Connections @(
            New-Connection 'fd-1' 'Approved' 'defenstack-frontdoor approved by Approve-FrontDoorPrivateEndpoints.ps1'
            New-Connection 'fd-2' 'Pending' 'defenstack-frontdoor'
        )
        { & $scriptPath -AppServiceId $appId -FrontDoorProfileName $fdProfile -FrontDoorResourceGroupName $fdRg -TimeoutSeconds 0 | Out-Null } | Should -Throw '*fd-2*'
        Get-Approvals | Should -BeNullOrEmpty
    }

    It 'refuses to approve when more than one pending connection shares the same request message (possible spoofing)' {
        Set-FakeConnections -Connections @(
            New-Connection 'fd-1' 'Pending' 'defenstack-frontdoor'
            New-Connection 'fd-2' 'Pending' 'defenstack-frontdoor'
        )
        { & $scriptPath -AppServiceId $appId -FrontDoorProfileName $fdProfile -FrontDoorResourceGroupName $fdRg -TimeoutSeconds 0 | Out-Null } | Should -Throw '*fd-1*'
        Get-Approvals | Should -BeNullOrEmpty
    }

    It 'approves a Front Door connection that appears a few polls after the deployment' {
        Set-FakeConnections -Connections @()
        $global:ListCallCount = 0
        function global:az {
            $joined = $args -join ' '
            $global:AzCalls.Add($joined)
            $global:LASTEXITCODE = 0
            if ($joined -like 'network private-endpoint-connection list*') {
                $global:ListCallCount++
                if ($global:ListCallCount -ge 2 -and $global:FakeConnections.Count -eq 0) {
                    $global:FakeConnections.Add((New-Connection 'fd-1' 'Pending' 'defenstack-frontdoor'))
                }
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
                $global:FakeOrigins.Add((New-Origin 'app-wus3' 'Approved'))
                return ''
            }
            if ($joined -like 'afd origin list*') {
                return (ConvertTo-Json -InputObject @($global:FakeOrigins) -Depth 6)
            }
            return ''
        }
        $global:FakeOrigins = [System.Collections.Generic.List[object]]::new()
        & $scriptPath -AppServiceId $appId -FrontDoorProfileName $fdProfile -FrontDoorResourceGroupName $fdRg -TimeoutSeconds 5 -PollIntervalSeconds 1 | Out-Null
        (Get-Approvals).Count | Should -Be 1
    }

    It 'approves Front Door connections on two apps given as separate IDs' {
        $appId2 = '/subscriptions/22222222-2222-2222-2222-222222222222/resourceGroups/rg-defenstack-dev-wus3/providers/Microsoft.Web/sites/app-defenstack-dev-wus3-def456'
        Set-FakeConnections -Connections @(New-Connection 'fd-1' 'Pending' 'defenstack-frontdoor') -AdditionalByAppId @{
            $appId2 = @(New-Connection -Name 'fd-2' -Status 'Pending' -Description 'defenstack-frontdoor' -ForAppId $appId2)
        } -Origins @(
            New-Origin -Name 'app-wus3' -Status 'Pending' -ForAppId $appId
            New-Origin -Name 'app-eus' -Status 'Pending' -ForAppId $appId2
        )
        & $scriptPath -AppServiceId @($appId, $appId2) -FrontDoorProfileName $fdProfile -FrontDoorResourceGroupName $fdRg -TimeoutSeconds 0 | Out-Null
        (Get-Approvals).Count | Should -Be 2
    }

    It 'fails when the Azure CLI cannot approve a connection' {
        Set-FakeConnections -Connections @(New-Connection 'fd-1' 'Pending' 'defenstack-frontdoor')
        function global:az {
            $joined = $args -join ' '
            $global:AzCalls.Add($joined)
            if ($joined -like 'network private-endpoint-connection list*') {
                $global:LASTEXITCODE = 0
                return (ConvertTo-Json -InputObject @($global:FakeConnections) -Depth 6)
            }
            if ($joined -like 'network private-endpoint-connection approve*') {
                $global:LASTEXITCODE = 1
                return ''
            }
            $global:LASTEXITCODE = 0
            return ''
        }
        { & $scriptPath -AppServiceId $appId -FrontDoorProfileName $fdProfile -FrontDoorResourceGroupName $fdRg -TimeoutSeconds 0 | Out-Null } | Should -Throw '*Approving private endpoint connection*'
    }

    Context 'Front Door origin status is the source of truth for success (final review A)' {
        It 'succeeds only once the matching Front Door origin reports its private link Approved' {
            Set-FakeConnections -Connections @(New-Connection 'fd-1' 'Pending' 'defenstack-frontdoor') -Origins @(New-Origin 'app-wus3' 'Pending')
            $output = & $scriptPath -AppServiceId $appId -FrontDoorProfileName $fdProfile -FrontDoorResourceGroupName $fdRg -TimeoutSeconds 0
            (Get-Approvals).Count | Should -Be 1
            ($output -join ' ') | Should -Match "Front Door origin 'app-wus3' reports its private link Approved"
        }

        It 'throws a distinct message when the connection it approved does not bring the origin to Approved (possible spoofed request)' {
            Set-FakeConnections -Connections @(New-Connection 'fd-1' 'Pending' 'defenstack-frontdoor') -Origins @(New-Origin 'app-wus3' 'Pending') -OriginFlipsOnApproval $false
            { & $scriptPath -AppServiceId $appId -FrontDoorProfileName $fdProfile -FrontDoorResourceGroupName $fdRg -TimeoutSeconds 2 -PollIntervalSeconds 1 | Out-Null } |
                Should -Throw '*did not bring Front Door*origin*to Approved*may not be Front Door*'
            (Get-Approvals).Count | Should -Be 1
        }

        It 'succeeds without approving anything when a manually approved connection lacks the prefix but the origin already reports Approved' {
            Set-FakeConnections -Connections @(New-Connection 'fd-1' 'Approved' 'approved manually by an operator') -Origins @(New-Origin 'app-wus3' 'Approved')
            { & $scriptPath -AppServiceId $appId -FrontDoorProfileName $fdProfile -FrontDoorResourceGroupName $fdRg -TimeoutSeconds 0 | Out-Null } | Should -Not -Throw
            Get-Approvals | Should -BeNullOrEmpty
        }

        It 'throws a distinct message when no Front Door origin references the App Service' {
            Set-FakeConnections -Connections @(New-Connection 'fd-1' 'Pending' 'defenstack-frontdoor') -Origins @()
            { & $scriptPath -AppServiceId $appId -FrontDoorProfileName $fdProfile -FrontDoorResourceGroupName $fdRg -TimeoutSeconds 0 | Out-Null } |
                Should -Throw "*no Front Door origin in $fdProfile/app references this App Service*"
        }

        It 'fails when the Azure CLI cannot list Front Door origins' {
            Set-FakeConnections -Connections @(New-Connection 'fd-1' 'Pending' 'defenstack-frontdoor')
            function global:az {
                $joined = $args -join ' '
                $global:AzCalls.Add($joined)
                if ($joined -like 'network private-endpoint-connection list*') {
                    $global:LASTEXITCODE = 0
                    $reqId = $args[[array]::IndexOf($args, '--id') + 1]
                    $list = $global:FakeConnectionsByApp[$reqId]
                    if (-not $list) { $list = @() }
                    return (ConvertTo-Json -InputObject @($list) -Depth 6)
                }
                if ($joined -like 'network private-endpoint-connection approve*') {
                    $global:LASTEXITCODE = 0
                    return ''
                }
                if ($joined -like 'afd origin list*') {
                    $global:LASTEXITCODE = 1
                    return ''
                }
                $global:LASTEXITCODE = 0
                return ''
            }
            { & $scriptPath -AppServiceId $appId -FrontDoorProfileName $fdProfile -FrontDoorResourceGroupName $fdRg -TimeoutSeconds 0 | Out-Null } |
                Should -Throw '*Unable to list Front Door origins*'
        }

        It 'does not approve a pending connection whose request message differs only in case (case-sensitive match)' {
            Set-FakeConnections -Connections @(New-Connection 'fd-1' 'Pending' 'DEFENSTACK-FRONTDOOR') -Origins @(New-Origin 'app-wus3' 'Pending')
            { & $scriptPath -AppServiceId $appId -FrontDoorProfileName $fdProfile -FrontDoorResourceGroupName $fdRg -TimeoutSeconds 0 -WarningAction SilentlyContinue | Out-Null } |
                Should -Throw '*no Front Door private endpoint connection was approved*'
            Get-Approvals | Should -BeNullOrEmpty
        }
    }
}
