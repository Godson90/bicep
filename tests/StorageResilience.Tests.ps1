BeforeAll {
    Import-Module (Join-Path $PSScriptRoot 'Bicep.TestHelpers.psm1') -Force
    $endpointTemplate = Get-BicepTemplate -RelativePath 'modules/storageSecondaryEndpoint.bicep'
    $endpoint = Get-TemplateResource -Template $endpointTemplate -Type 'Microsoft.Network/privateEndpoints' | Select-Object -First 1
    $endpointDns = Get-TemplateResource -Template $endpointTemplate -Type 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups' | Select-Object -First 1
    $readerTemplate = Get-BicepTemplate -RelativePath 'modules/storageReaderAssignment.bicep'
    $reader = Get-TemplateResource -Template $readerTemplate -Type 'Microsoft.Authorization/roleAssignments' | Select-Object -First 1
    $stamp = Get-BicepTemplate -RelativePath 'modules/regionStamp.bicep'
    $main = Get-BicepTemplate -RelativePath 'main.bicep'
}

Describe 'Storage redundancy (Phase 5)' {
    It 'uses RA-GZRS in the prod primary region, GRS in the warm standby and LRS in dev' {
        (Get-ModuleDeployment -Template $stamp -Name 'storage').properties.parameters.storageAccountSkuName |
            Should -Be "[if(variables('isProd'), if(variables('isPrimary'), createObject('value', 'Standard_RAGZRS'), createObject('value', 'Standard_GRS')), createObject('value', 'Standard_LRS'))]"
    }
}

Describe 'Warm-standby read endpoint on the primary geo-replica (Phase 5)' {
    It 'connects to the primary account through its read-only blob_secondary sub-resource' {
        $connection = $endpoint.properties.privateLinkServiceConnections[0]
        $connection.properties.privateLinkServiceId | Should -Be "[parameters('primaryStorageAccountId')]"
        @($connection.properties.groupIds) | Should -Be @('blob_secondary')
        $endpoint.name | Should -Be "[format('{0}-secondary-pe', parameters('primaryStorageAccountName'))]"
    }

    It 'registers the <account>-secondary name in the shared blob zone' {
        $endpointDns.properties.privateDnsZoneConfigs[0].properties.privateDnsZoneId | Should -Be "[parameters('blobPrivateDnsZoneId')]"
    }

    It 'is deployed only by a stamp that is given a primary account (the warm standby)' {
        $module = Get-ModuleDeployment -Template $stamp -Name 'storage-secondary-endpoint'
        $module.condition | Should -Be "[not(empty(parameters('primaryStorageAccountId')))]"
        $module.properties.parameters.privateEndpointSubnetId.value | Should -Be "[reference('spokeNetwork').outputs.privateEndpointSubnetId.value]"
        $module.properties.parameters.blobPrivateDnsZoneId.value | Should -Be "[parameters('privateDnsZoneIds').blob]"
        $stamp.parameters.primaryStorageAccountId.defaultValue | Should -Be ''
    }

    It 'is wired from the primary stamp outputs into the secondary stamp only' {
        $secondary = Get-TemplateResourceBySymbol -Template $main -Symbol 'secondaryStamp'
        $primary = Get-TemplateResourceBySymbol -Template $main -Symbol 'primaryStamp'
        $secondary.properties.parameters.primaryStorageAccountId.value | Should -Be "[reference('primaryStamp').outputs.storageAccountId.value]"
        $secondary.properties.parameters.primaryStorageAccountName.value | Should -Be "[reference('primaryStamp').outputs.storageAccountName.value]"
        $primary.properties.parameters.PSObject.Properties.Name | Should -Not -Contain 'primaryStorageAccountId'
    }

    It 'outputs what main needs from each stamp' {
        foreach ($output in 'storageAccountId', 'storageContainerName', 'appServicePrincipalId') {
            $stamp.outputs.PSObject.Properties.Name | Should -Contain $output
        }
    }
}

Describe 'Warm-standby read-only data access (Phase 5)' {
    It 'grants Storage Blob Data Reader, never a write role, at container scope' {
        $readerTemplate.variables.storageBlobDataReaderRoleId | Should -Be '2a2b9908-6ea1-4ae2-8e65-a410df84e7d1'
        $reader.properties.roleDefinitionId | Should -Match 'storageBlobDataReaderRoleId'
        $reader.scope | Should -Match 'containers'
        $reader.properties.principalType | Should -Be 'ServicePrincipal'
    }

    It 'is assigned in the primary resource group to the warm-standby App Service identity, only with the secondary region' {
        $module = Get-TemplateResourceBySymbol -Template $main -Symbol 'secondaryStorageReader'
        $module.condition | Should -Be "[parameters('deploySecondaryRegion')]"
        $module.resourceGroup | Should -Be "[variables('primaryResourceGroupName')]"
        $module.properties.parameters.readerPrincipalId.value | Should -Be "[reference('secondaryStamp').outputs.appServicePrincipalId.value]"
        $module.properties.parameters.storageAccountName.value | Should -Be "[reference('primaryStamp').outputs.storageAccountName.value]"
    }
}

Describe 'Replication rule baseline (Phase 5)' {
    It 'no longer excludes Azure.Storage.UseReplication globally' {
        Get-Content (Get-RepoPath 'ps-rule.yaml') -Raw | Should -Not -Match 'Azure\.Storage\.UseReplication'
    }

    It 'suppresses it only for locally redundant (dev) accounts' {
        $text = Get-Content (Get-RepoPath '.ps-rule/Suppression.Rule.yaml') -Raw
        $text | Should -Match 'DefenStack\.DevLocallyRedundantStorage'
        $text | Should -Match 'field: sku\.name\s+equals: Standard_LRS'
    }
}
