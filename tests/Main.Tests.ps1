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
    It 'defines the three zone names once' {
        @($main.variables.privateDnsZoneNames.PSObject.Properties.Name) -join ',' | Should -Be 'blob,sites,vault'
        $main.variables.privateDnsZoneNames.sites | Should -Be 'privatelink.azurewebsites.net'
        $main.variables.privateDnsZoneNames.vault | Should -Be 'privatelink.vaultcore.azure.net'
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
}
