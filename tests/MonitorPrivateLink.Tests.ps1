BeforeAll {
    Import-Module (Join-Path $PSScriptRoot 'Bicep.TestHelpers.psm1') -Force
    $scopeTemplate = Get-BicepTemplate -RelativePath 'modules/monitorPrivateLinkScope.bicep'
    $scope = Get-TemplateResource -Template $scopeTemplate -Type 'Microsoft.Insights/privateLinkScopes' | Select-Object -First 1
    $scopedResources = Get-TemplateResource -Template $scopeTemplate -Type 'Microsoft.Insights/privateLinkScopes/scopedResources' | Select-Object -First 1
    $endpointTemplate = Get-BicepTemplate -RelativePath 'modules/monitorPrivateEndpoint.bicep'
    $endpoint = Get-TemplateResource -Template $endpointTemplate -Type 'Microsoft.Network/privateEndpoints' | Select-Object -First 1
    $zoneGroup = Get-TemplateResource -Template $endpointTemplate -Type 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups' | Select-Object -First 1
}

Describe 'Azure Monitor Private Link Scope (Phase 6)' {
    It 'is a global resource' {
        $scope.location | Should -Be 'global'
    }

    It 'accepts ingestion and queries from connected networks only through private links (PrivateOnly)' {
        $scope.properties.accessModeSettings.ingestionAccessMode | Should -Be 'PrivateOnly'
        $scope.properties.accessModeSettings.queryAccessMode | Should -Be 'PrivateOnly'
    }

    It 'pins the GA API version 2021-09-01' {
        $scope.apiVersion | Should -Be '2021-09-01'
        $scopedResources.apiVersion | Should -Be '2021-09-01'
    }

    It 'links one scoped resource per resource ID, named after the linked resource' {
        $scopedResources.copy.count | Should -Be "[length(parameters('scopedResourceIds'))]"
        $scopedResources.properties.linkedResourceId | Should -Be "[parameters('scopedResourceIds')[copyIndex()]]"
        $scopedResources.name | Should -Match "last\(split\(parameters\('scopedResourceIds'\)\[copyIndex\(\)\], '/'\)\)"
    }

    It 'outputs the scope ID and name' {
        $scopeTemplate.outputs.PSObject.Properties.Name | Should -Contain 'id'
        $scopeTemplate.outputs.PSObject.Properties.Name | Should -Contain 'name'
    }
}

Describe 'AMPLS private endpoint (Phase 6)' {
    It 'connects to the scope through the azuremonitor group' {
        $connection = $endpoint.properties.privateLinkServiceConnections[0]
        $connection.properties.privateLinkServiceId | Should -Be "[parameters('privateLinkScopeId')]"
        @($connection.properties.groupIds) | Should -Be @('azuremonitor')
    }

    It 'uses the existing <resource>-pe naming and the private-endpoint subnet passed in' {
        $endpoint.name | Should -Be "[parameters('privateEndpointName')]"
        $endpointTemplate.parameters.privateEndpointName.defaultValue | Should -Be "[format('{0}-pe', parameters('privateLinkScopeName'))]"
        $endpoint.properties.subnet.id | Should -Be "[parameters('privateEndpointSubnetId')]"
    }

    It 'takes an optional endpoint name, so failover.bicep can add a second endpoint in East US (Phase 8)' {
        $endpointTemplate.parameters.privateEndpointName.type | Should -Be 'string'
    }

    It 'describes its parameters for both callers, not only the primary region (Phase 8)' {
        foreach ($parameter in $endpointTemplate.parameters.PSObject.Properties) {
            $parameter.Value.metadata.description | Should -Not -Match 'primary (region|spoke)' -Because $parameter.Name
        }
    }

    It 'keeps the Phase 6 endpoint byte-identical: main.bicep passes no name, so the default name (the scope name plus -pe) applies' {
        $main = Get-BicepTemplate -RelativePath 'main.bicep'
        $caller = Get-TemplateResourceBySymbol -Template $main -Symbol 'monitorPrivateEndpoint'
        $caller.properties.parameters.PSObject.Properties.Name | Should -Not -Contain 'privateEndpointName'
        $caller.properties.parameters.privateLinkScopeName.value | Should -Be "[reference('monitorPrivateLinkScope').outputs.name.value]"
        $embedded = $caller.properties.template
        $embedded.parameters.privateEndpointName.defaultValue | Should -Be "[format('{0}-pe', parameters('privateLinkScopeName'))]"
        $embeddedEndpoint = Get-TemplateResource -Template $embedded -Type 'Microsoft.Network/privateEndpoints' | Select-Object -First 1
        $embeddedEndpoint.name | Should -Be "[parameters('privateEndpointName')]"
        # Every other property of the Phase 6 endpoint and its zone group is unchanged.
        @($embeddedEndpoint.properties.PSObject.Properties.Name) -join ',' | Should -Be 'privateLinkServiceConnections,subnet,applicationSecurityGroups'
        $embeddedEndpoint.properties.privateLinkServiceConnections[0].name | Should -Be 'azuremonitor'
        $embeddedEndpoint.properties.subnet.id | Should -Be "[parameters('privateEndpointSubnetId')]"
        $embeddedEndpoint.properties.applicationSecurityGroups[0].id | Should -Be "[parameters('applicationSecurityGroupId')]"
    }

    It 'joins the AMPLS application security group, the only destination the peer firewall may reach (final review I-1)' {
        $endpointTemplate.parameters.applicationSecurityGroupId.type | Should -Be 'string'
        @($endpoint.properties.applicationSecurityGroups).Count | Should -Be 1
        $endpoint.properties.applicationSecurityGroups[0].id | Should -Be "[parameters('applicationSecurityGroupId')]"
    }

    It 'registers records in the four Azure Monitor zones and the shared blob zone' {
        $zoneGroup.name | Should -Match "'default'\)\]$"
        $zoneIds = @($zoneGroup.properties.privateDnsZoneConfigs | ForEach-Object { $_.properties.privateDnsZoneId })
        $zoneIds.Count | Should -Be 5
        foreach ($key in 'monitor', 'oms', 'ods', 'agentsvc', 'blob') {
            $zoneIds | Should -Contain "[parameters('privateDnsZoneIds').$key]"
        }
    }
}
