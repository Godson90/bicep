BeforeAll {
    Import-Module (Join-Path $PSScriptRoot 'Bicep.TestHelpers.psm1') -Force
    $template = Get-BicepTemplate -RelativePath 'modules/privateDnsZoneLinks.bicep'
    $links = Get-TemplateResource -Template $template -Type 'Microsoft.Network/privateDnsZones/virtualNetworkLinks' | Select-Object -First 1
}

Describe 'Private DNS zone links' {
    It 'creates one link per virtual network' {
        $links.copy.count | Should -Be "[length(parameters('virtualNetworks'))]"
        $links.properties.virtualNetwork.id | Should -Be "[parameters('virtualNetworks')[copyIndex()].id]"
    }

    It 'names each link after its VNet so links from several regions never collide' {
        $links.name | Should -Match "format\('\{0\}-link', parameters\('virtualNetworks'\)\[copyIndex\(\)\]\.name\)"
    }

    It 'links for resolution only (private endpoint zone groups own the records)' {
        $links.properties.registrationEnabled | Should -BeExactly $false
    }

    It 'does not create the zone (the global layer owns zones)' {
        @(Get-TemplateResource -Template $template -Type 'Microsoft.Network/privateDnsZones').Count | Should -Be 0
    }
}
