BeforeAll {
    Import-Module (Join-Path $PSScriptRoot 'Bicep.TestHelpers.psm1') -Force
    $main = Get-BicepTemplate -RelativePath 'main.bicep'
    $global = Get-TemplateResourceBySymbol -Template $main -Symbol 'global'
    $primary = Get-TemplateResourceBySymbol -Template $main -Symbol 'primaryStamp'
    $secondary = Get-TemplateResourceBySymbol -Template $main -Symbol 'secondaryStamp'
    $dnsLinks = Get-TemplateResourceBySymbol -Template $main -Symbol 'privateDnsLinks'
}

Describe 'Subscription-scope entry point' {
    It 'targets the subscription' {
        $main.'$schema' | Should -Match 'subscriptionDeploymentTemplate\.json'
    }

    It 'accepts only dev and prod environments' {
        @($main.parameters.environmentName.allowedValues) -join ',' | Should -Be 'dev,prod'
    }

    It 'maps each allowed region to a short code used in names' {
        @($main.parameters.primaryLocation.allowedValues) -join ',' | Should -Be 'westus3,eastus'
        $main.variables.regionCodes.westus3 | Should -Be 'wus3'
        $main.variables.regionCodes.eastus | Should -Be 'eus'
    }

    It 'names resource groups rg-defenstack-<env>-global and rg-defenstack-<env>-<region>' {
        $main.variables.globalResourceGroupName | Should -Be "[format('rg-defenstack-{0}-global', parameters('environmentName'))]"
        $main.variables.primaryResourceGroupName | Should -Be "[format('rg-defenstack-{0}-{1}', parameters('environmentName'), variables('primaryRegionCode'))]"
    }
}

Describe 'Composition' {
    It 'deploys the global layer into the global resource group' {
        $global.resourceGroup | Should -Be "[variables('globalResourceGroupName')]"
    }

    It 'replicates the workspace to the secondary region only for prod with DR enabled' {
        $global.properties.parameters.workspaceReplicationLocation |
            Should -Be "[if(and(variables('isProd'), parameters('deploySecondaryRegion')), createObject('value', parameters('secondaryLocation')), createObject('value', ''))]"
    }

    It 'deploys the primary stamp as primary into the primary resource group' {
        $primary.resourceGroup | Should -Be "[variables('primaryResourceGroupName')]"
        $primary.properties.parameters.regionRole.value | Should -Be 'primary'
        $primary.properties.parameters.addressPlan.value | Should -Be "[parameters('primaryAddressPlan')]"
    }

    It 'deploys the secondary stamp only when deploySecondaryRegion is true' {
        $secondary.condition | Should -Be "[parameters('deploySecondaryRegion')]"
        $secondary.resourceGroup | Should -Be "[variables('secondaryResourceGroupName')]"
        $secondary.properties.parameters.regionRole.value | Should -Be 'secondary'
    }

    It 'feeds both stamps the shared workspace and DNS zone IDs' {
        foreach ($stamp in $primary, $secondary) {
            $stamp.properties.parameters.logAnalyticsWorkspaceId.value | Should -Be "[reference('global').outputs.logAnalyticsWorkspaceId.value]"
            $stamp.properties.parameters.privateDnsZoneIds.value | Should -Be "[reference('global').outputs.privateDnsZoneIds.value]"
        }
    }
}

Describe 'Shared private DNS' {
    It 'defines the zone names once: three application zones and four Azure Monitor (AMPLS) zones' {
        @($main.variables.privateDnsZoneNames.PSObject.Properties.Name) -join ',' | Should -Be 'blob,sites,vault,monitor,oms,ods,agentsvc'
        $main.variables.privateDnsZoneNames.sites | Should -Be 'privatelink.azurewebsites.net'
        $main.variables.privateDnsZoneNames.vault | Should -Be 'privatelink.vaultcore.azure.net'
    }

    It 'adds the AMPLS zone <Key> = <Zone> (Phase 6)' -ForEach @(
        @{ Key = 'monitor'; Zone = 'privatelink.monitor.azure.com' }
        @{ Key = 'oms'; Zone = 'privatelink.oms.opinsights.azure.com' }
        @{ Key = 'ods'; Zone = 'privatelink.ods.opinsights.azure.com' }
        @{ Key = 'agentsvc'; Zone = 'privatelink.agentsvc.azure-automation.net' }
    ) {
        $main.variables.privateDnsZoneNames.$Key | Should -BeExactly $Zone
    }

    It 'links every zone in the global resource group' {
        $dnsLinks.copy.count | Should -Be "[length(items(variables('privateDnsZoneNames')))]"
        $dnsLinks.resourceGroup | Should -Be "[variables('globalResourceGroupName')]"
    }

    It 'links the hub and spoke VNets of the primary and (when deployed) the secondary stamp' {
        $value = $dnsLinks.properties.parameters.virtualNetworks.value
        foreach ($output in 'hubVnetId', 'spokeVnetId') {
            $value | Should -Match "reference\('primaryStamp'\)\.outputs\.$output"
            $value | Should -Match "reference\('secondaryStamp'\)\.outputs\.$output"
        }
        $value | Should -Match "parameters\('deploySecondaryRegion'\)"
    }
}

Describe 'Admin access (Phase 3)' {
    It 'deploys admin access in the primary region by default and keeps the warm standby off until failover' {
        $main.parameters.deployPrimaryAdminAccess.defaultValue | Should -BeExactly $true
        $main.parameters.deploySecondaryAdminAccess.defaultValue | Should -BeExactly $false
        $primary.properties.parameters.deployAdminAccess.value | Should -Be "[parameters('deployPrimaryAdminAccess')]"
        $secondary.properties.parameters.deployAdminAccess.value | Should -Be "[parameters('deploySecondaryAdminAccess')]"
    }

    It 'passes the admin group to the primary stamp only (the jump host is primary-only)' {
        $main.parameters.adminGroupObjectId.defaultValue | Should -Be ''
        $primary.properties.parameters.adminGroupObjectId.value | Should -Be "[parameters('adminGroupObjectId')]"
        $secondary.properties.parameters.PSObject.Properties.Name | Should -Not -Contain 'adminGroupObjectId'
    }

    It 'outputs what runbook 03 needs to connect' {
        foreach ($output in 'primaryResourceGroupName', 'primaryBastionName', 'primaryVpnGatewayName', 'primaryFirewallPrivateIp') {
            $main.outputs.PSObject.Properties.Name | Should -Contain $output
        }
    }
}

Describe 'Public ingress (Phase 4)' {
    BeforeAll {
        $frontDoor = Get-TemplateResourceBySymbol -Template $main -Symbol 'frontDoor'
        $frontDoorParameters = $frontDoor.properties.parameters
    }

    It 'deploys one Front Door per environment into the global resource group, after both stamps' {
        $frontDoor.resourceGroup | Should -Be "[variables('globalResourceGroupName')]"
        $frontDoor.name | Should -Be "[format('front-door-{0}', parameters('environmentName'))]"
        @($frontDoor.dependsOn) | Should -Contain 'primaryStamp'
        @($frontDoor.dependsOn) | Should -Contain 'secondaryStamp'
    }

    It 'names the profile, endpoint and WAF policy with the environment' {
        $frontDoorParameters.profileName.value | Should -Be "[format('afd-defenstack-{0}', parameters('environmentName'))]"
        $frontDoorParameters.endpointName.value | Should -Be "[format('fde-defenstack-{0}', parameters('environmentName'))]"
        $frontDoorParameters.wafPolicyName.value | Should -Be "[format('wafdefenstack{0}', parameters('environmentName'))]"
    }

    It 'puts the primary App Service first (priority 1) and the warm standby second, only when deployed' {
        $value = $frontDoorParameters.origins.value
        $value | Should -Match "^\[concat\(createArray\(createObject\('name', format\('app-\{0\}', variables\('primaryRegionCode'\)\)"
        $value | Should -Match "reference\('primaryStamp'\)\.outputs\.appServiceId\.value"
        $value | Should -Match "if\(parameters\('deploySecondaryRegion'\), createArray\(createObject\('name', format\('app-\{0\}', variables\('secondaryRegionCode'\)\)"
        $value | Should -Match "reference\('secondaryStamp'\)\.outputs\.appServiceId\.value"
        $value.IndexOf('primaryStamp') | Should -BeLessThan $value.IndexOf('secondaryStamp')
    }

    It 'probes the App Service health check path and locks Front Door in prod only' {
        $frontDoorParameters.healthProbePath.value | Should -Be "[parameters('healthCheckPath')]"
        $frontDoorParameters.enableDeleteLock.value | Should -Be "[variables('isProd')]"
    }

    It 'takes an optional custom domain, empty by default' {
        $main.parameters.customDomainHostName.defaultValue | Should -Be ''
        $frontDoorParameters.customDomainHostName.value | Should -Be "[parameters('customDomainHostName')]"
    }

    It 'outputs the endpoint hostname, the TXT validation token, the request message and every App Service ID for approval' {
        foreach ($output in 'frontDoorEndpointHostName', 'frontDoorCustomDomainValidationToken', 'frontDoorPrivateLinkRequestMessage', 'appServiceIds') {
            $main.outputs.PSObject.Properties.Name | Should -Contain $output
        }
        $main.outputs.appServiceIds.type | Should -Be 'array'
        $main.outputs.appServiceIds.value | Should -Match "if\(parameters\('deploySecondaryRegion'\)"
    }

    It 'outputs the Front Door profile name and the global resource group name, so the pipeline can poll the origin group (final review A)' {
        foreach ($output in 'frontDoorProfileName', 'globalResourceGroupName') {
            $main.outputs.PSObject.Properties.Name | Should -Contain $output
        }
        $main.outputs.frontDoorProfileName.value | Should -Be "[reference('frontDoor').outputs.profileName.value]"
        $main.outputs.globalResourceGroupName.value | Should -Be "[variables('globalResourceGroupName')]"
    }
}

Describe 'Azure Monitor Private Link Scope (Phase 6)' {
    BeforeAll {
        $scope = Get-TemplateResourceBySymbol -Template $main -Symbol 'monitorPrivateLinkScope'
        $endpoint = Get-TemplateResourceBySymbol -Template $main -Symbol 'monitorPrivateEndpoint'
    }

    It 'deploys one scope per environment into the global resource group' {
        $scope.resourceGroup | Should -Be "[variables('globalResourceGroupName')]"
        $scope.properties.parameters.scopeName.value | Should -Be "[format('ampls-defenstack-{0}', parameters('environmentName'))]"
    }

    It 'scopes the workspace and the primary App Insights component, plus the secondary component only when deployed' {
        $value = $scope.properties.parameters.scopedResourceIds.value
        $value | Should -Match "^\[concat\(createArray\(reference\('global'\)\.outputs\.logAnalyticsWorkspaceId\.value, reference\('primaryStamp'\)\.outputs\.appInsightsId\.value\)"
        $value | Should -Match "if\(parameters\('deploySecondaryRegion'\), createArray\(reference\('secondaryStamp'\)\.outputs\.appInsightsId\.value\), createArray\(\)\)"
    }

    It 'puts the single azuremonitor endpoint in the primary spoke private-endpoint subnet' {
        $endpoint.resourceGroup | Should -Be "[variables('primaryResourceGroupName')]"
        $endpoint.properties.parameters.location.value | Should -Be "[parameters('primaryLocation')]"
        $endpoint.properties.parameters.privateEndpointSubnetId.value | Should -Be "[reference('primaryStamp').outputs.privateEndpointSubnetId.value]"
        $endpoint.properties.parameters.privateDnsZoneIds.value | Should -Be "[reference('global').outputs.privateDnsZoneIds.value]"
    }

    It 'creates the endpoint after the scope holds its resources, so the DNS records cover them all' {
        $endpoint.properties.parameters.privateLinkScopeId.value | Should -Be "[reference('monitorPrivateLinkScope').outputs.id.value]"
        @($endpoint.dependsOn) | Should -Contain 'monitorPrivateLinkScope'
    }

    It 'outputs the scope name for runbook 06' {
        $main.outputs.monitorPrivateLinkScopeName.value | Should -Be "[reference('monitorPrivateLinkScope').outputs.name.value]"
    }
}

Describe 'Hub-to-hub peering and firewall routing (Phase 6)' {
    BeforeAll {
        $primaryPeering = Get-TemplateResourceBySymbol -Template $main -Symbol 'primaryHubPeering'
        $secondaryPeering = Get-TemplateResourceBySymbol -Template $main -Symbol 'secondaryHubPeering'
    }

    It 'peers the hubs both ways only when the secondary region is deployed' {
        foreach ($peering in $primaryPeering, $secondaryPeering) {
            $peering.condition | Should -Be "[parameters('deploySecondaryRegion')]"
        }
        $primaryPeering.resourceGroup | Should -Be "[variables('primaryResourceGroupName')]"
        $secondaryPeering.resourceGroup | Should -Be "[variables('secondaryResourceGroupName')]"
    }

    It 'points each hub at the other hub' {
        $primaryPeering.properties.parameters.localVnetName.value | Should -Be "[reference('primaryStamp').outputs.hubVnetName.value]"
        $primaryPeering.properties.parameters.remoteVnetId.value | Should -Be "[reference('secondaryStamp').outputs.hubVnetId.value]"
        $primaryPeering.properties.parameters.peeringName.value | Should -Be "[format('hub-to-{0}-hub', variables('secondaryRegionCode'))]"
        $secondaryPeering.properties.parameters.localVnetName.value | Should -Be "[reference('secondaryStamp').outputs.hubVnetName.value]"
        $secondaryPeering.properties.parameters.remoteVnetId.value | Should -Be "[reference('primaryStamp').outputs.hubVnetId.value]"
        $secondaryPeering.properties.parameters.peeringName.value | Should -Be "[format('hub-to-{0}-hub', variables('primaryRegionCode'))]"
    }

    It 'creates the two sides one after the other' {
        @($secondaryPeering.dependsOn) | Should -Contain 'primaryHubPeering'
    }

    It 'makes the primary (AMPLS endpoint) region the Host and the secondary the Client, only with DR' {
        $primary.properties.parameters.hubPeering | Should -Match "^\[if\(parameters\('deploySecondaryRegion'\), createObject\('value', createObject\("
        $primary.properties.parameters.hubPeering | Should -Match "'monitorRole', 'Host'"
        $primary.properties.parameters.hubPeering | Should -Match "createObject\('value', null\(\)\)\)\]$"
        $secondary.properties.parameters.hubPeering.value.monitorRole | Should -Be 'Client'
    }

    It 'routes each region''s firewall to the other firewall at the first usable address of its AzureFirewallSubnet' {
        $primary.properties.parameters.hubPeering | Should -Match "'remoteFirewallPrivateIp', cidrHost\(parameters\('secondaryAddressPlan'\)\.firewallSubnetPrefix, 3\)"
        $primary.properties.parameters.hubPeering | Should -Match "'remoteSpokeAddressPrefixes', parameters\('secondaryAddressPlan'\)\.spokeAddressSpace"
        $secondary.properties.parameters.hubPeering.value.remoteFirewallPrivateIp | Should -Be "[cidrHost(parameters('primaryAddressPlan').firewallSubnetPrefix, 3)]"
        $secondary.properties.parameters.hubPeering.value.remoteSpokeAddressPrefixes | Should -Be "[parameters('primaryAddressPlan').spokeAddressSpace]"
        $secondary.properties.parameters.hubPeering.value.monitorClientPrefixes | Should -Be "[variables('monitorClientPrefixes')]"
        $primary.properties.parameters.hubPeering | Should -Match "'monitorClientPrefixes', variables\('monitorClientPrefixes'\)"
    }

    It 'allows only the East US App Service and management subnets to the primary private-endpoint subnet' {
        $main.variables.monitorClientPrefixes |
            Should -Be "[if(parameters('deploySecondaryRegion'), createArray(parameters('secondaryAddressPlan').appServiceIntegrationSubnetPrefix, parameters('secondaryAddressPlan').managementSubnetPrefix), createArray())]"
        @($main.variables.monitorPrivateEndpointPrefixes) | Should -Be @("[parameters('primaryAddressPlan').privateEndpointSubnetPrefix]")
    }
}

Describe 'Subscription Activity Log (Phase 6)' {
    BeforeAll {
        $activityLog = Get-TemplateResourceBySymbol -Template $main -Symbol 'activityLog'
    }

    It 'deploys at subscription scope, not into a resource group' {
        $activityLog.PSObject.Properties.Name | Should -Not -Contain 'resourceGroup'
        $activityLog.PSObject.Properties.Name | Should -Not -Contain 'condition'
    }

    It 'names the setting per environment, so dev and prod can share one subscription' {
        $activityLog.properties.parameters.settingName.value | Should -Be "[format('activity-log-defenstack-{0}', parameters('environmentName'))]"
        $activityLog.name | Should -Be "[format('activity-log-{0}', parameters('environmentName'))]"
    }

    It 'sends the Activity Log to the shared workspace' {
        $activityLog.properties.parameters.logAnalyticsWorkspaceId.value | Should -Be "[reference('global').outputs.logAnalyticsWorkspaceId.value]"
    }
}
