BeforeAll {
    Import-Module (Join-Path $PSScriptRoot 'Bicep.TestHelpers.psm1') -Force
    $stamp = Get-BicepTemplate -RelativePath 'modules/regionStamp.bicep'
    function Get-StampModuleParameters([string]$Name) {
        (Get-ModuleDeployment -Template $stamp -Name $Name).properties.parameters
    }
}

Describe 'Region stamp naming' {
    It 'names every resource with environment and region so stamps never collide' {
        foreach ($key in 'hubVnet', 'spokeVnet', 'firewall', 'firewallPolicy', 'firewallPublicIp', 'appServicePlan', 'appService') {
            $stamp.variables.names.$key | Should -Match "parameters\('environmentName'\), parameters\('regionCode'\)"
        }
    }

    It 'derives globally unique names from subscription, environment, and region' {
        $stamp.variables.nameSuffix | Should -Be "[uniqueString(subscription().id, parameters('environmentName'), parameters('location'))]"
        $stamp.variables.names.storageAccount | Should -Be "[format('st{0}{1}', parameters('regionCode'), variables('nameSuffix'))]"
        $stamp.variables.names.keyVault | Should -Be "[format('kv-{0}-{1}', parameters('regionCode'), variables('nameSuffix'))]"
    }

    It 'passes the stamp names to the modules' {
        (Get-StampModuleParameters 'app-service').appServicePlanName.value | Should -Be "[variables('names').appServicePlan]"
        (Get-StampModuleParameters 'azure-firewall').firewallName.value | Should -Be "[variables('names').firewall]"
    }
}

Describe 'Region stamp availability' {
    It 'deploys the firewall and its public IP across zones 1-3 in every stamp' {
        @($stamp.variables.availabilityZones) -join ',' | Should -Be '1,2,3'
        (Get-StampModuleParameters 'azure-firewall').availabilityZones.value | Should -Be "[variables('availabilityZones')]"
    }

    It 'makes the App Service plan zone-redundant with 3 instances only in the prod primary region' {
        $parameters = Get-StampModuleParameters 'app-service'
        $parameters.zoneRedundant.value | Should -Be "[and(variables('isProd'), variables('isPrimary'))]"
        $parameters.instanceCount | Should -Be "[if(and(variables('isProd'), variables('isPrimary')), createObject('value', 3), createObject('value', 1))]"
    }

    It 'uses geo-redundant storage in prod and locally redundant storage in dev' {
        (Get-StampModuleParameters 'storage').storageAccountSkuName |
            Should -Be "[if(variables('isProd'), createObject('value', 'Standard_GRS'), createObject('value', 'Standard_LRS'))]"
    }

    It 'deploys the optional management VM in the primary region only' {
        (Get-ModuleDeployment -Template $stamp -Name 'virtual-machine').condition |
            Should -Be "[and(parameters('enableVirtualMachine'), variables('isPrimary'))]"
    }
}

Describe 'Region stamp wiring carried from Phase 0' {
    It 'passes managementSourceCidrs to <_> (F1)' -ForEach 'spoke-network', 'virtual-machine' {
        (Get-StampModuleParameters $_).managementSourceCidrs.value | Should -Be "[parameters('managementSourceCidrs')]"
    }

    It 'uses the address plan spoke range for both the spoke VNet and firewall sources (F5)' {
        (Get-StampModuleParameters 'azure-firewall').spokeAddressPrefixes.value | Should -Be "[parameters('addressPlan').spokeAddressSpace]"
        (Get-StampModuleParameters 'spoke-network').vnetAddressSpace.value | Should -Be "[parameters('addressPlan').spokeAddressSpace]"
    }

    It 'derives private endpoint sources from the App Service and management subnet prefixes (F5)' {
        $value = (Get-StampModuleParameters 'spoke-network').approvedPrivateEndpointSourceCidrs.value
        $value | Should -Match "addressPlan'\)\.appServiceIntegrationSubnetPrefix"
        $value | Should -Match "addressPlan'\)\.managementSubnetPrefix"
        $value | Should -Match 'additionalPrivateEndpointSourceCidrs'
    }

    It 'uses firewall threat intelligence Deny in prod and Alert in dev (F9)' {
        (Get-StampModuleParameters 'azure-firewall').threatIntelMode |
            Should -Be "[if(variables('isProd'), createObject('value', 'Deny'), createObject('value', 'Alert'))]"
    }

    It 'enables Key Vault template deployment so az.getSecret() references resolve (F4)' {
        (Get-StampModuleParameters 'key-vault').enabledForTemplateDeployment.value | Should -BeExactly $true
    }

    It 'passes the container name from the storage module output (F11)' {
        (Get-StampModuleParameters 'network-integration').storageContainerName.value | Should -Match 'outputs.blobContainerName'
    }

    It 'registers private endpoints in the shared zones from the global layer' {
        (Get-StampModuleParameters 'private-connectivity').privateDnsZoneIds.value | Should -Be "[parameters('privateDnsZoneIds')]"
    }

    It 'locks the spoke VNet in prod only' {
        (Get-StampModuleParameters 'spoke-network').enableDeleteLock.value | Should -Be "[variables('isProd')]"
    }
}

Describe 'Region stamp outputs' {
    It 'exposes the VNets the entry point links to the shared DNS zones' {
        foreach ($output in 'hubVnetName', 'hubVnetId', 'spokeVnetName', 'spokeVnetId', 'appServiceHostName') {
            $stamp.outputs.PSObject.Properties.Name | Should -Contain $output
        }
    }
}
