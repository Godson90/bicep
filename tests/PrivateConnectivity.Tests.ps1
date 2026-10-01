BeforeAll {
    Import-Module (Join-Path $PSScriptRoot 'Bicep.TestHelpers.psm1') -Force
    $template = Get-BicepTemplate -RelativePath 'modules/privateConnectivity.bicep'
    $zoneGroups = Get-TemplateResource -Template $template -Type 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups'
}

Describe 'Region private connectivity' {
    It 'creates private endpoints for blob, App Service, and Key Vault' {
        @(Get-TemplateResource -Template $template -Type 'Microsoft.Network/privateEndpoints').Count | Should -Be 3
    }

    It 'no longer creates private DNS zones or VNet links (moved to the global layer)' {
        @(Get-TemplateResource -Template $template -Type 'Microsoft.Network/privateDnsZones').Count | Should -Be 0
        @(Get-TemplateResource -Template $template -Type 'Microsoft.Network/privateDnsZones/virtualNetworkLinks').Count | Should -Be 0
    }

    It 'registers each endpoint in the shared zone for its group' {
        $zoneIds = @($zoneGroups | ForEach-Object { $_.properties.privateDnsZoneConfigs[0].properties.privateDnsZoneId })
        foreach ($key in 'blob', 'sites', 'vault') {
            $zoneIds | Should -Contain "[parameters('privateDnsZoneIds').$key]"
        }
    }
}
