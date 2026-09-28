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

    It '<Name> builds against main.bicep' -ForEach $paramFiles {
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
        Test-InsideSixteen $plan.hubAddressSpace[0] @($plan.firewallSubnetPrefix) | Should -BeTrue
        Test-InsideSixteen $plan.spokeAddressSpace[0] @($plan.privateEndpointSubnetPrefix, $plan.appServiceIntegrationSubnetPrefix, $plan.managementSubnetPrefix) | Should -BeTrue
    }
}
