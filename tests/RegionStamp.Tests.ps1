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
    It 'passes the admin source ranges (Bastion subnet, VPN pool, extra managementSourceCidrs) to <_> (F1, Phase 3)' -ForEach 'spoke-network', 'virtual-machine' {
        (Get-StampModuleParameters $_).managementSourceCidrs.value | Should -Be "[variables('adminSourceCidrs')]"
    }

    It 'uses the address plan spoke range for both the spoke VNet and firewall sources (F5)' {
        (Get-StampModuleParameters 'azure-firewall').spokeAddressPrefixes.value | Should -Be "[parameters('addressPlan').spokeAddressSpace]"
        (Get-StampModuleParameters 'spoke-network').vnetAddressSpace.value | Should -Be "[parameters('addressPlan').spokeAddressSpace]"
    }

    It 'derives private endpoint sources from the App Service and management subnet prefixes (F5)' {
        $value = (Get-StampModuleParameters 'spoke-network').approvedPrivateEndpointSourceCidrs.value
        $value | Should -Match "addressPlan'\)\.appServiceIntegrationSubnetPrefix"
        $value | Should -Match "addressPlan'\)\.managementSubnetPrefix"
        $value | Should -Match "addressPlan'\)\.vpnClientAddressPool"
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

Describe 'Region stamp firewall security (Phase 2)' {
    It 'deploys Azure Firewall Premium in every stamp' {
        (Get-StampModuleParameters 'azure-firewall').firewallTier.value | Should -Be 'Premium'
    }

    It 'runs IDPS in Deny in prod and Alert in dev' {
        (Get-StampModuleParameters 'azure-firewall').idpsMode |
            Should -Be "[if(variables('isProd'), createObject('value', 'Deny'), createObject('value', 'Alert'))]"
    }

    It 'limits OS update egress to the management subnet' {
        @((Get-StampModuleParameters 'azure-firewall').managementAddressPrefixes.value) | Should -Be @("[parameters('addressPlan').managementSubnetPrefix]")
    }

    It 'locks the hub VNet, Key Vault and firewall resources in prod only (<_>)' -ForEach 'hub-network', 'key-vault', 'azure-firewall' {
        (Get-StampModuleParameters $_).enableDeleteLock.value | Should -Be "[variables('isProd')]"
    }
}

Describe 'Region stamp admin access (Phase 3)' {
    It 'derives admin sources from the Bastion subnet and VPN client pool, plus any extra managementSourceCidrs' {
        $stamp.variables.adminSourceCidrs |
            Should -Be "[concat(createArray(parameters('addressPlan').bastionSubnetPrefix, parameters('addressPlan').vpnClientAddressPool), parameters('managementSourceCidrs'))]"
    }

    It 'deploys <_> only when deployAdminAccess is true' -ForEach 'bastion', 'vpn-gateway' {
        (Get-ModuleDeployment -Template $stamp -Name $_).condition | Should -Be "[parameters('deployAdminAccess')]"
        $stamp.parameters.deployAdminAccess.defaultValue | Should -BeExactly $false
    }

    It 'uses VpnGw2AZ in prod and VpnGw1AZ in dev' {
        (Get-StampModuleParameters 'vpn-gateway').skuName |
            Should -Be "[if(variables('isProd'), createObject('value', 'VpnGw2AZ'), createObject('value', 'VpnGw1AZ'))]"
    }

    It 'deploys <_> after the firewall, whose DNS proxy the hub uses' -ForEach 'bastion', 'vpn-gateway' {
        @((Get-ModuleDeployment -Template $stamp -Name $_).dependsOn) | Should -Contain 'azureFirewall'
    }

    It 'spreads <_> across zones 1-3' -ForEach 'bastion', 'vpn-gateway' {
        (Get-StampModuleParameters $_).availabilityZones.value | Should -Be "[variables('availabilityZones')]"
    }

    It 'gives the gateway the region VPN client pool' {
        (Get-StampModuleParameters 'vpn-gateway').vpnClientAddressPool.value | Should -Be "[parameters('addressPlan').vpnClientAddressPool]"
    }

    It 'routes GatewaySubnet spoke traffic to the first usable firewall address, computed before the firewall exists' {
        $stamp.variables.firewallPrivateIp | Should -Be "[cidrHost(parameters('addressPlan').firewallSubnetPrefix, 3)]"
        $hub = Get-StampModuleParameters 'hub-network'
        $hub.firewallPrivateIp.value | Should -Be "[variables('firewallPrivateIp')]"
        $hub.spokeAddressPrefixes.value | Should -Be "[parameters('addressPlan').spokeAddressSpace]"
        @((Get-ModuleDeployment -Template $stamp -Name 'hub-network').dependsOn) | Should -Not -Contain 'azureFirewall'
    }

    It 'lets Bastion reach only the management subnet' {
        @((Get-StampModuleParameters 'hub-network').bastionTargetAddressPrefixes.value) | Should -Be @("[parameters('addressPlan').managementSubnetPrefix]")
    }

    It 'passes the Bastion and gateway subnet prefixes from the address plan' {
        $hub = Get-StampModuleParameters 'hub-network'
        $hub.bastionSubnetAddressPrefix.value | Should -Be "[parameters('addressPlan').bastionSubnetPrefix]"
        $hub.gatewaySubnetAddressPrefix.value | Should -Be "[parameters('addressPlan').gatewaySubnetPrefix]"
    }

    It 'allows the VPN client pool through the firewall admin-access rules' {
        @((Get-StampModuleParameters 'azure-firewall').vpnClientAddressPrefixes.value) | Should -Be @("[parameters('addressPlan').vpnClientAddressPool]")
    }

    It 'turns on gateway transit only with admin access, after the gateway is provisioned' {
        (Get-StampModuleParameters 'network-integration').useHubGateway.value | Should -Be "[parameters('deployAdminAccess')]"
        @((Get-ModuleDeployment -Template $stamp -Name 'network-integration').dependsOn) | Should -Contain 'vpnGateway'
    }

    It 'passes the admin group to the management VM' {
        (Get-StampModuleParameters 'virtual-machine').adminGroupObjectId.value | Should -Be "[parameters('adminGroupObjectId')]"
    }

    It 'outputs the Bastion and gateway names (empty without admin access) and the expected firewall IP' {
        $stamp.outputs.bastionName.value | Should -Be "[if(parameters('deployAdminAccess'), variables('names').bastion, '')]"
        $stamp.outputs.vpnGatewayName.value | Should -Be "[if(parameters('deployAdminAccess'), variables('names').vpnGateway, '')]"
        $stamp.outputs.expectedFirewallPrivateIp.value | Should -Be "[variables('firewallPrivateIp')]"
    }

    It 'names Bastion and the gateway with environment and region' {
        foreach ($key in 'bastion', 'bastionPublicIp', 'vpnGateway', 'vpnGatewayPublicIp') {
            $stamp.variables.names.$key | Should -Match "parameters\('environmentName'\), parameters\('regionCode'\)"
        }
    }
}
