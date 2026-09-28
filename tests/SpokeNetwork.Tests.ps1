BeforeAll {
    Import-Module (Join-Path $PSScriptRoot 'Bicep.TestHelpers.psm1') -Force
    $template = Get-BicepTemplate -RelativePath 'modules/spokeNetwork.bicep'
    $routeTables = Get-TemplateResource -Template $template -Type 'Microsoft.Network/routeTables'
    $vnetModule = Get-TemplateResource -Template $template -Type 'Microsoft.Resources/deployments' | Select-Object -First 1
    # Subnet order in spokeNetwork.bicep: 0 private-endpoints, 1 appservice-integration, 2 virtual-machines.
    $subnets = @($vnetModule.properties.parameters.subnets.value)
}

Describe 'Spoke routing (F2)' {
    It 'has one route table for App Service and one for the management subnet' {
        $routeTables.Count | Should -Be 2
    }

    It 'disables BGP route propagation on every spoke route table so gateway routes cannot bypass the firewall' {
        foreach ($routeTable in $routeTables) {
            $routeTable.properties.disableBgpRoutePropagation | Should -BeTrue
        }
    }
}

Describe 'Management subnet isolation (F1)' {
    It 'uses its own NSG, not the App Service integration NSG' {
        $subnets[2].nsgId | Should -Not -Be $subnets[1].nsgId
    }

    It 'uses its own route table, not the App Service route table' {
        $subnets[2].udrId | Should -Not -Be $subnets[1].udrId
    }

    It 'defaults to no management source CIDRs (deny all admin inbound)' {
        @($template.parameters.managementSourceCidrs.defaultValue).Count | Should -Be 0
    }
}
