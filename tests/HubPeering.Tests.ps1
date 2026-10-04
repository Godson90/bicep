BeforeAll {
    Import-Module (Join-Path $PSScriptRoot 'Bicep.TestHelpers.psm1') -Force
    $template = Get-BicepTemplate -RelativePath 'modules/hubPeering.bicep'
    $peering = Get-TemplateResource -Template $template -Type 'Microsoft.Network/virtualNetworks/virtualNetworkPeerings' | Select-Object -First 1
}

Describe 'Hub-to-hub global peering (Phase 6, brought forward from Phase 8)' {
    It 'peers this region''s hub with the other region''s hub' {
        $peering.name | Should -Be "[format('{0}/{1}', parameters('localVnetName'), parameters('peeringName'))]"
        $peering.properties.remoteVirtualNetwork.id | Should -Be "[parameters('remoteVnetId')]"
        $peering.properties.allowVirtualNetworkAccess | Should -BeExactly $true
    }

    It 'accepts traffic forwarded by the other region''s firewall' {
        $peering.properties.allowForwardedTraffic | Should -BeExactly $true
    }

    It 'never shares or uses a VPN gateway across regions (both hubs own one)' {
        $peering.properties.allowGatewayTransit | Should -BeExactly $false
        $peering.properties.useRemoteGateways | Should -BeExactly $false
    }
}
