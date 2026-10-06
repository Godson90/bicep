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

    It 'uses RA-GZRS in the prod primary region, GRS in the warm standby and LRS in dev (Phase 5)' {
        (Get-StampModuleParameters 'storage').storageAccountSkuName |
            Should -Be "[if(variables('isProd'), if(variables('isPrimary'), createObject('value', 'Standard_RAGZRS'), createObject('value', 'Standard_GRS')), createObject('value', 'Standard_LRS'))]"
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

    It 'outputs the private-endpoint subnet that hosts the AMPLS endpoint in the primary region (Phase 6)' {
        $stamp.outputs.privateEndpointSubnetId.value | Should -Be "[reference('spokeNetwork').outputs.privateEndpointSubnetId.value]"
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

Describe 'Region stamp ingress output (Phase 4)' {
    It 'outputs the App Service resource ID for the Front Door Private Link origin' {
        $stamp.outputs.appServiceId.value | Should -Be "[reference('appService').outputs.appServiceAppId.value]"
    }
}

Describe 'Region stamp hub peering (Phase 6)' {
    It 'takes an optional hub peering plan, absent by default (dev, or prod without DR)' {
        $stamp.parameters.hubPeering.nullable | Should -BeExactly $true
        $stamp.parameters.hubPeering.'$ref' | Should -Be '#/definitions/hubPeeringPlan'
    }

    It 'routes the other region''s spoke from AzureFirewallSubnet to the other firewall' {
        $hub = Get-StampModuleParameters 'hub-network'
        $hub.remoteSpokeAddressPrefixes.value | Should -Match "tryGet\(parameters\('hubPeering'\), 'remoteSpokeAddressPrefixes'\)"
        $hub.remoteFirewallPrivateIp.value | Should -Match "tryGet\(parameters\('hubPeering'\), 'remoteFirewallPrivateIp'\)"
    }

    It 'passes the Azure Monitor role and prefixes to the firewall rules' {
        $firewall = Get-StampModuleParameters 'azure-firewall'
        $firewall.monitorPeeringRole.value | Should -Be "[variables('monitorPeeringRole')]"
        $firewall.monitorClientPrefixes.value | Should -Match "tryGet\(parameters\('hubPeering'\), 'monitorClientPrefixes'\)"
        $firewall.monitorPrivateEndpointPrefixes.value | Should -Match "tryGet\(parameters\('hubPeering'\), 'monitorPrivateEndpointPrefixes'\)"
        $stamp.variables.monitorPeeringRole | Should -Match "tryGet\(parameters\('hubPeering'\), 'monitorRole'\), 'None'\)"
    }

    It 'lets the local firewall reach the AMPLS endpoint only in the region that hosts it (it SNATs peer traffic)' {
        $stamp.variables.peerTrafficSourceCidrs |
            Should -Be "[if(equals(variables('monitorPeeringRole'), 'Host'), createArray(parameters('addressPlan').firewallSubnetPrefix), createArray())]"
        (Get-StampModuleParameters 'spoke-network').monitorPeerSourceCidrs.value | Should -Be "[variables('peerTrafficSourceCidrs')]"
    }

    It 'never adds the firewall subnet to the approved-https sources, which reach every private endpoint (final review I-1)' {
        $value = (Get-StampModuleParameters 'spoke-network').approvedPrivateEndpointSourceCidrs.value
        $value | Should -Not -Match 'peerTrafficSourceCidrs'
        $value | Should -Not -Match 'firewallSubnetPrefix'
    }

    It 'outputs the spoke''s AMPLS application security group for the endpoint (final review I-1)' {
        $stamp.outputs.monitorAsgId.value | Should -Be "[reference('spokeNetwork').outputs.amplsAsgId.value]"
    }
}

Describe 'Region stamp jump host data collection endpoint (final review I-2)' {
    It 'outputs the jump host DCE ID when the VM is deployed in this stamp, else an empty string' {
        $stamp.outputs.dataCollectionEndpointId.value |
            Should -Be "[if(and(parameters('enableVirtualMachine'), variables('isPrimary')), reference('virtualMachine').outputs.dataCollectionEndpointId.value, '')]"
    }
}

Describe 'Region stamp flow logs (Phase 6)' {
    BeforeAll {
        $flowLogs = Get-ModuleDeployment -Template $stamp -Name "[format('flow-logs-{0}-{1}', parameters('environmentName'), parameters('regionCode'))]"
    }

    It 'names the flow-log account and identity per environment and region' {
        $stamp.variables.names.flowLogStorageAccount | Should -Be "[format('stfl{0}{1}', parameters('regionCode'), variables('nameSuffix'))]"
        $stamp.variables.names.flowLogIdentity | Should -Match "parameters\('environmentName'\), parameters\('regionCode'\)"
    }

    It 'keeps flow logs zone-redundant in prod and locally redundant in dev' {
        (Get-StampModuleParameters 'flow-log-storage').storageAccountSkuName |
            Should -Be "[if(variables('isProd'), createObject('value', 'Standard_ZRS'), createObject('value', 'Standard_LRS'))]"
    }

    It 'deploys the flow logs into NetworkWatcherRG, where the region''s Network Watcher lives' {
        $flowLogs.resourceGroup | Should -Be 'NetworkWatcherRG'
        $flowLogs.properties.parameters.location.value | Should -Be "[parameters('location')]"
    }

    It 'logs both the hub and the spoke VNet' {
        $value = @($flowLogs.properties.parameters.virtualNetworks.value)
        $value[0].name | Should -Be "[variables('names').hubVnet]"
        $value[0].id | Should -Be "[reference('hubNetwork').outputs.id.value]"
        $value[1].name | Should -Be "[variables('names').spokeVnet]"
        $value[1].id | Should -Be "[reference('spokeNetwork').outputs.id.value]"
    }

    It 'writes with the flow-log identity to the flow-log account and analyses into the central workspace' {
        $parameters = $flowLogs.properties.parameters
        $parameters.storageAccountId.value | Should -Be "[reference('flowLogStorage').outputs.id.value]"
        $parameters.identityId.value | Should -Be "[reference('flowLogStorage').outputs.identityId.value]"
        $parameters.logAnalyticsWorkspaceId.value | Should -Be "[parameters('logAnalyticsWorkspaceId')]"
    }
}

Describe 'Region stamp alerts (Phase 6)' {
    BeforeAll {
        $alertParameters = Get-StampModuleParameters 'metric-alerts'
        $rules = @($alertParameters.rules.value)
    }

    It 'names the alerts per environment and region and notifies the shared action group' {
        $alertParameters.namePrefix.value | Should -Be "[format('alert-defenstack-{0}-{1}', parameters('environmentName'), parameters('regionCode'))]"
        $alertParameters.actionGroupId.value | Should -Be "[parameters('actionGroupId')]"
        $stamp.parameters.PSObject.Properties.Name | Should -Contain 'alertThresholds'
    }

    It 'defines exactly the seven regional rules' {
        @($rules | ForEach-Object { $_.name }) -join ',' |
            Should -Be 'firewall-health,firewall-snat-ports,app-http-5xx,app-health-check,key-vault-availability,key-vault-forbidden,vpn-p2s-connections'
    }

    It 'alerts on <Metric> <Operator> <Threshold> (<Aggregation>) at Sev<Severity> as <Name>' -ForEach @(
        @{ Name = 'firewall-health'; Metric = 'FirewallHealth'; Namespace = 'Microsoft.Network/azureFirewalls'; Operator = 'LessThan'; Threshold = '90'; Aggregation = 'Average'; Severity = 1; Resource = "[reference('azureFirewall').outputs.id.value]" }
        @{ Name = 'firewall-snat-ports'; Metric = 'SNATPortUtilization'; Namespace = 'Microsoft.Network/azureFirewalls'; Operator = 'GreaterThan'; Threshold = '80'; Aggregation = 'Maximum'; Severity = 2; Resource = "[reference('azureFirewall').outputs.id.value]" }
        @{ Name = 'app-http-5xx'; Metric = 'Http5xx'; Namespace = 'Microsoft.Web/sites'; Operator = 'GreaterThan'; Threshold = "[string(parameters('alertThresholds').appServiceHttp5xx)]"; Aggregation = 'Total'; Severity = 2; Resource = "[reference('appService').outputs.appServiceAppId.value]" }
        @{ Name = 'app-health-check'; Metric = 'HealthCheckStatus'; Namespace = 'Microsoft.Web/sites'; Operator = 'LessThan'; Threshold = '100'; Aggregation = 'Average'; Severity = 1; Resource = "[reference('appService').outputs.appServiceAppId.value]" }
        @{ Name = 'key-vault-availability'; Metric = 'Availability'; Namespace = 'Microsoft.KeyVault/vaults'; Operator = 'LessThan'; Threshold = '99.9'; Aggregation = 'Average'; Severity = 2; Resource = "[reference('keyVault').outputs.id.value]" }
        @{ Name = 'key-vault-forbidden'; Metric = 'ServiceApiResult'; Namespace = 'Microsoft.KeyVault/vaults'; Operator = 'GreaterThan'; Threshold = "[string(parameters('alertThresholds').keyVaultForbidden)]"; Aggregation = 'Count'; Severity = 3; Resource = "[reference('keyVault').outputs.id.value]" }
        @{ Name = 'vpn-p2s-connections'; Metric = 'P2SConnectionCount'; Namespace = 'Microsoft.Network/virtualNetworkGateways'; Operator = 'GreaterThan'; Threshold = "[string(parameters('alertThresholds').vpnP2sConnections)]"; Aggregation = 'Maximum'; Severity = 3; Resource = "[if(parameters('deployAdminAccess'), reference('vpnGateway').outputs.id.value, '')]" }
    ) {
        $rule = $rules | Where-Object { $_.name -eq $Name }
        $rule | Should -Not -BeNullOrEmpty
        $rule.metricName | Should -BeExactly $Metric
        $rule.metricNamespace | Should -BeExactly $Namespace
        $rule.operator | Should -Be $Operator
        $rule.threshold | Should -Be $Threshold
        $rule.timeAggregation | Should -Be $Aggregation
        $rule.severity | Should -Be $Severity
        $rule.resourceId | Should -Be $Resource
        $rule.description | Should -Not -BeNullOrEmpty
    }

    It 'counts only Key Vault results with status code 403' {
        $rule = $rules | Where-Object { $_.name -eq 'key-vault-forbidden' }
        @($rule.dimensions).Count | Should -Be 1
        $rule.dimensions[0].name | Should -Be 'StatusCode'
        $rule.dimensions[0].operator | Should -Be 'Include'
        @($rule.dimensions[0].values) | Should -Be @('403')
    }

    It 'creates the VPN alert only where the gateway exists' {
        ($rules | Where-Object { $_.name -eq 'vpn-p2s-connections' }).deploy | Should -Be "[parameters('deployAdminAccess')]"
        foreach ($rule in $rules | Where-Object { $_.name -ne 'vpn-p2s-connections' }) {
            $rule.PSObject.Properties.Name | Should -Not -Contain 'deploy' -Because $rule.name
        }
    }
}

Describe 'Region stamp backup (Phase 8)' {
    BeforeAll {
        $vaultModule = Get-ModuleDeployment -Template $stamp -Name 'recovery-services-vault'
        $vaultParameters = $vaultModule.properties.parameters
    }

    It 'deploys one Recovery Services vault in every stamp, named rsv-defenstack-<env>-<region>' {
        $vaultModule.PSObject.Properties.Name | Should -Not -Contain 'condition'
        $stamp.variables.names.recoveryServicesVault | Should -Be "[format('rsv-defenstack-{0}-{1}', parameters('environmentName'), parameters('regionCode'))]"
        $vaultParameters.vaultName.value | Should -Be "[variables('names').recoveryServicesVault]"
        $vaultParameters.location.value | Should -Be "[parameters('location')]"
        $vaultParameters.logAnalyticsWorkspaceId.value | Should -Be "[parameters('logAnalyticsWorkspaceId')]"
    }

    It 'locks the vault in prod only' {
        $vaultParameters.enableDeleteLock.value | Should -Be "[variables('isProd')]"
    }

    It 'protects the jump host only in the stamp where it exists' {
        $vaultParameters.virtualMachineId |
            Should -Be "[if(and(parameters('enableVirtualMachine'), variables('isPrimary')), createObject('value', reference('virtualMachine').outputs.id.value), createObject('value', ''))]"
    }

    It 'outputs the vault ID and name for the alert processing rule and runbook 08' {
        $stamp.outputs.recoveryServicesVaultId.value | Should -Be "[reference('recoveryServicesVault').outputs.id.value]"
        $stamp.outputs.recoveryServicesVaultName.value | Should -Be "[variables('names').recoveryServicesVault]"
    }
}
