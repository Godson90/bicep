BeforeDiscovery {
    $repoRoot = Split-Path -Parent $PSScriptRoot
    $paramFiles = Get-ChildItem -Path (Join-Path $repoRoot 'params') -Filter '*.bicepparam' -ErrorAction SilentlyContinue |
        ForEach-Object { @{ Name = $_.Name; FullName = $_.FullName } }
}

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot 'Bicep.TestHelpers.psm1') -Force

    function Get-BuiltParameters([string]$RelativePath) {
        [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
        $built = (& bicep build-params (Get-RepoPath $RelativePath) --stdout) -join "`n" | ConvertFrom-Json
        ($built.parametersJson | ConvertFrom-Json).parameters
    }

    # True when every prefix in $Prefixes shares the first two octets of $Space (all ranges here are /16 spaces).
    function Test-InsideSixteen([string]$Space, [string[]]$Prefixes) {
        $root = ($Space -split '\.')[0..1] -join '.'
        -not ($Prefixes | Where-Object { -not $_.StartsWith("$root.") })
    }

    $dev = Get-BuiltParameters 'params/dev.bicepparam'
    $prod = Get-BuiltParameters 'params/prod.bicepparam'
}

Describe 'Committed parameter files' {
    It 'includes dev and prod parameter files' {
        Get-RepoPath 'params/dev.bicepparam' | Should -Exist
        Get-RepoPath 'params/prod.bicepparam' | Should -Exist
    }

    It 'binds dev and prod to main.bicep, governance to governance.bicep and failover to failover.bicep (Phases 7-8)' {
        Get-Content (Get-RepoPath 'params/dev.bicepparam') -TotalCount 1 | Should -Be "using '../main.bicep'"
        Get-Content (Get-RepoPath 'params/prod.bicepparam') -TotalCount 1 | Should -Be "using '../main.bicep'"
        Get-Content (Get-RepoPath 'params/governance.bicepparam') -TotalCount 1 | Should -Be "using '../governance.bicep'"
        Get-Content (Get-RepoPath 'params/failover.bicepparam') -TotalCount 1 | Should -Be "using '../failover.bicep'"
    }

    It '<Name> builds against its template' -ForEach $paramFiles {
        $output = & bicep build-params $FullName --stdout 2>&1
        $LASTEXITCODE | Should -Be 0 -Because ($output -join [Environment]::NewLine)
    }

    It '<Name> contains no az.getSecret references (secrets belong in *.local.bicepparam)' -ForEach $paramFiles {
        Get-Content $FullName -Raw | Should -Not -Match 'getSecret'
    }
}

Describe 'Environment topology' {
    It 'runs dev in the primary region only' {
        $dev.environmentName.value | Should -Be 'dev'
        $dev.deploySecondaryRegion.value | Should -BeExactly $false
    }

    It 'runs prod in both regions with a secondary address plan' {
        $prod.environmentName.value | Should -Be 'prod'
        $prod.deploySecondaryRegion.value | Should -BeExactly $true
        $prod.secondaryAddressPlan.value | Should -Not -BeNullOrEmpty
    }
}

Describe 'Address plan' {
    It 'uses the spec ranges for prod (WUS3 hub 10.1/16, spoke 10.0/16; EUS hub 10.11/16, spoke 10.10/16)' {
        $prod.primaryAddressPlan.value.hubAddressSpace[0] | Should -Be '10.1.0.0/16'
        $prod.primaryAddressPlan.value.spokeAddressSpace[0] | Should -Be '10.0.0.0/16'
        $prod.secondaryAddressPlan.value.hubAddressSpace[0] | Should -Be '10.11.0.0/16'
        $prod.secondaryAddressPlan.value.spokeAddressSpace[0] | Should -Be '10.10.0.0/16'
    }

    It 'gives dev its own ranges so dev and prod never overlap' {
        $prodRanges = @($prod.primaryAddressPlan.value.hubAddressSpace + $prod.primaryAddressPlan.value.spokeAddressSpace +
            $prod.secondaryAddressPlan.value.hubAddressSpace + $prod.secondaryAddressPlan.value.spokeAddressSpace)
        foreach ($range in @($dev.primaryAddressPlan.value.hubAddressSpace + $dev.primaryAddressPlan.value.spokeAddressSpace)) {
            $prodRanges | Should -Not -Contain $range
        }
    }

    It 'keeps every subnet inside its VNet in <_> plans' -ForEach 'dev-primary', 'prod-primary', 'prod-secondary' {
        $plan = switch ($_) {
            'dev-primary' { $dev.primaryAddressPlan.value }
            'prod-primary' { $prod.primaryAddressPlan.value }
            'prod-secondary' { $prod.secondaryAddressPlan.value }
        }
        Test-InsideSixteen $plan.hubAddressSpace[0] @($plan.firewallSubnetPrefix, $plan.bastionSubnetPrefix, $plan.gatewaySubnetPrefix) | Should -BeTrue
        Test-InsideSixteen $plan.spokeAddressSpace[0] @($plan.privateEndpointSubnetPrefix, $plan.appServiceIntegrationSubnetPrefix, $plan.managementSubnetPrefix) | Should -BeTrue
    }
}

Describe 'Admin access address plan (Phase 3)' {
    BeforeAll {
        $plans = @($dev.primaryAddressPlan.value, $prod.primaryAddressPlan.value, $prod.secondaryAddressPlan.value)
    }

    It 'sizes the hub subnets for Azure (Bastion /26, GatewaySubnet /27) in <_> plans' -ForEach 'dev-primary', 'prod-primary', 'prod-secondary' {
        $plan = switch ($_) {
            'dev-primary' { $dev.primaryAddressPlan.value }
            'prod-primary' { $prod.primaryAddressPlan.value }
            'prod-secondary' { $prod.secondaryAddressPlan.value }
        }
        $plan.bastionSubnetPrefix | Should -Match '/26$'
        $plan.gatewaySubnetPrefix | Should -Match '/27$'
        @(@($plan.firewallSubnetPrefix, $plan.bastionSubnetPrefix, $plan.gatewaySubnetPrefix) | Select-Object -Unique) | Should -HaveCount 3
    }

    It 'uses the spec pool 172.16.200.0/24 for the prod primary region' {
        $prod.primaryAddressPlan.value.vpnClientAddressPool | Should -Be '172.16.200.0/24'
    }

    It 'gives every region and environment its own VPN client pool' {
        @($plans | ForEach-Object { $_.vpnClientAddressPool } | Select-Object -Unique) | Should -HaveCount 3
    }

    It 'keeps every VPN client pool outside every VNet (clients must never overlap Azure ranges)' {
        $vnetRoots = @($plans | ForEach-Object { @($_.hubAddressSpace) + @($_.spokeAddressSpace) } | ForEach-Object { ($_ -split '\.')[0..1] -join '.' })
        foreach ($plan in $plans) {
            $poolRoot = ($plan.vpnClientAddressPool -split '\.')[0..1] -join '.'
            $vnetRoots | Should -Not -Contain $poolRoot
        }
    }
}

Describe 'Front Door custom domain (Phase 4)' {
    It 'leaves the custom domain empty in <_> until the external DNS records exist (runbook 04)' -ForEach 'dev', 'prod' {
        $parameters = if ($_ -eq 'dev') { $dev } else { $prod }
        $parameters.customDomainHostName.value | Should -Be ''
    }
}

Describe 'Governance parameters (Phase 7)' {
    BeforeAll {
        $savedEmails = $env:SECURITY_CONTACT_EMAILS
        $governanceText = Get-Content (Get-RepoPath 'params/governance.bicepparam') -Raw
    }

    AfterAll {
        $env:SECURITY_CONTACT_EMAILS = $savedEmails
    }

    It 'commits no contact address; the operator sets SECURITY_CONTACT_EMAILS (runbook 07)' {
        $governanceText | Should -Not -Match '[A-Za-z0-9._-]+@[A-Za-z0-9-]+\.'
        $governanceText | Should -Match ([regex]::Escape("readEnvironmentVariable('SECURITY_CONTACT_EMAILS', '')"))
    }

    It 'turns an unset SECURITY_CONTACT_EMAILS into an empty list, which the template refuses (minLength 1)' {
        $env:SECURITY_CONTACT_EMAILS = $null
        $parameters = Get-BuiltParameters 'params/governance.bicepparam'
        @($parameters.securityContactEmails.value).Count | Should -Be 0
    }

    It 'splits SECURITY_CONTACT_EMAILS on semicolons, trimming spaces and dropping empty entries' {
        $env:SECURITY_CONTACT_EMAILS = ' secops@example.com ; ;cloud-admins@example.com;'
        $parameters = Get-BuiltParameters 'params/governance.bicepparam'
        @($parameters.securityContactEmails.value) | Should -Be @('secops@example.com', 'cloud-admins@example.com')
    }

    It 'keeps the default 5000 GB malware scanning cap' {
        $parameters = Get-BuiltParameters 'params/governance.bicepparam'
        $parameters.malwareScanCapGbPerMonth.value | Should -Be 5000
    }

    It 'starts audit-first for dev and prod (ADR-027)' {
        $parameters = Get-BuiltParameters 'params/governance.bicepparam'
        $parameters.denyEnforcement.value | Should -Be 'DoNotEnforce'
        @($parameters.environments.value) -join ',' | Should -Be 'dev,prod'
    }

    It 'gives the legacy waiver a real yyyy-MM-dd expiry' {
        $parameters = Get-BuiltParameters 'params/governance.bicepparam'
        $parameters.legacyResourceGroupName.value | Should -Be 'defenStack'
        $expires = $parameters.legacyWaiverExpiresOn.value
        $expires | Should -Match '^\d{4}-\d{2}-\d{2}$'
        { [datetime]::ParseExact($expires, 'yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture) } | Should -Not -Throw
    }

    It 'grants JIT requests to the same admin group each environment file signs in with (runbook 03)' {
        $parameters = Get-BuiltParameters 'params/governance.bicepparam'
        foreach ($pair in @(@{ Name = 'dev'; File = $dev }, @{ Name = 'prod'; File = $prod })) {
            $expected = if ($pair.File.PSObject.Properties.Name -contains 'adminGroupObjectId') { $pair.File.adminGroupObjectId.value } else { '' }
            $parameters.adminGroupObjectIds.value.($pair.Name) | Should -BeExactly $expected -Because $pair.Name
        }
    }

    It 'mirrors the environment parameter files in the governance region layout' {
        $governance = Get-BicepTemplate -RelativePath 'governance.bicep'
        $main = Get-BicepTemplate -RelativePath 'main.bicep'
        $layout = $governance.parameters.environmentRegions.defaultValue
        # Dev runs the primary only; prod adds the secondary. Neither file overrides the region defaults.
        $dev.deploySecondaryRegion.value | Should -BeExactly $false
        $prod.deploySecondaryRegion.value | Should -BeExactly $true
        foreach ($parameters in $dev, $prod) {
            $parameters.PSObject.Properties.Name | Should -Not -Contain 'primaryLocation'
            $parameters.PSObject.Properties.Name | Should -Not -Contain 'secondaryLocation'
        }
        @($layout.dev) -join ',' | Should -Be $main.parameters.primaryLocation.defaultValue
        @($layout.prod) -join ',' | Should -Be "$($main.parameters.primaryLocation.defaultValue),$($main.parameters.secondaryLocation.defaultValue)"
    }
}
