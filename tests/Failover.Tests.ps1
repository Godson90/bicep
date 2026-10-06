BeforeAll {
    Import-Module (Join-Path $PSScriptRoot 'Bicep.TestHelpers.psm1') -Force
    $failover = Get-BicepTemplate -RelativePath 'failover.bicep'
    $main = Get-BicepTemplate -RelativePath 'main.bicep'
    $planTemplate = Get-BicepTemplate -RelativePath 'modules/failover/appServicePlanScale.bicep'
    $plan = Get-TemplateResource -Template $planTemplate -Type 'Microsoft.Web/serverfarms' | Select-Object -First 1
    $appServiceTemplate = Get-BicepTemplate -RelativePath 'modules/appService.bicep'
    $deployments = @(Get-TemplateResource -Template $failover -Type 'Microsoft.Resources/deployments')
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
    $failoverJson = (& bicep build (Get-RepoPath 'failover.bicep') --stdout) -join "`n"

    # Module names are expressions here, so find each deployment by its name prefix.
    function Get-FailoverModule([string]$Prefix) {
        $found = @($deployments | Where-Object { $_.name.StartsWith("[format('$Prefix-{0}'") })
        if ($found.Count -ne 1) { throw "Expected one '$Prefix' deployment, found $($found.Count)." }
        $found[0]
    }
}

Describe 'Failover entry point (Phase 8)' {
    It 'is a subscription-scope template at the repository root' {
        Get-RepoPath 'failover.bicep' | Should -Exist
        $failover.'$schema' | Should -Match 'subscriptionDeploymentTemplate\.json'
    }

    It 'is never deployed by main.bicep or the pipeline (operator only during a declared outage, ADR-032)' {
        Get-Content (Get-RepoPath 'main.bicep') -Raw | Should -Not -Match 'failover\.bicep'
        $deploy = Get-Content (Get-RepoPath '.github/workflows/deploy.yml') -Raw
        $deploy | Should -Not -Match 'failover\.bicep\b'
    }

    It 'is armed by failoverActive, true by default, and every module waits on it' {
        $failover.parameters.failoverActive.type | Should -Be 'bool'
        $failover.parameters.failoverActive.defaultValue | Should -BeTrue
        $deployments.Count | Should -Be 4
        foreach ($deployment in $deployments) {
            $deployment.condition | Should -Be "[parameters('failoverActive')]" -Because $deployment.name
        }
    }

    It 'serves prod in East US only' {
        @($failover.parameters.environmentName.allowedValues) | Should -Be @('prod')
        @($failover.parameters.location.allowedValues) | Should -Be @('eastus')
        $failover.variables.regionCode | Should -Be 'eus'
        $failover.variables.resourceGroupName | Should -Be "[format('rg-defenstack-{0}-{1}', parameters('environmentName'), variables('regionCode'))]"
        $failover.variables.globalResourceGroupName | Should -Be "[format('rg-defenstack-{0}-global', parameters('environmentName'))]"
    }

    It 'deploys every module into the East US resource group, and nothing else at all' {
        @($failover.resources).Count | Should -Be $deployments.Count
        foreach ($deployment in $deployments) {
            $deployment.resourceGroup | Should -Be "[variables('resourceGroupName')]" -Because $deployment.name
            $deployment.PSObject.Properties.Name | Should -Not -Contain 'subscriptionId' -Because $deployment.name
            $deployment.PSObject.Properties.Name | Should -Not -Contain 'scope' -Because $deployment.name
        }
    }

    It 'targets nothing in West US 3: the region appears only in the default primary storage account ID' {
        $withoutAccountId = $failoverJson | ConvertFrom-Json
        $withoutAccountId.parameters.PSObject.Properties.Remove('primaryStorageAccountId')
        $rest = $withoutAccountId | ConvertTo-Json -Depth 100
        $rest | Should -Not -Match 'wus3'
        $rest | Should -Not -Match 'westus3'
        $failover.parameters.primaryStorageAccountId.defaultValue | Should -Match "^\[resourceId\(subscription\(\)\.subscriptionId, .*'Microsoft\.Storage/storageAccounts'"
    }

    It 'uses the West US 3 account ID only as the blob endpoint target and its name, never as a deployment scope' {
        $references = @($deployments | Where-Object { [regex]::Unescape(($_.properties.parameters | ConvertTo-Json -Depth 100 -Compress)) -match "parameters\('primaryStorageAccountId'\)" })
        $references.Count | Should -Be 1
        $references[0].name | Should -Match "^\[format\('failover-storage-private-endpoint-\{0\}'"
        $references[0].properties.parameters.storageAccountId.value | Should -Be "[parameters('primaryStorageAccountId')]"
        $references[0].resourceGroup | Should -Be "[variables('resourceGroupName')]"
        $failover.variables.names.storagePrivateEndpoint | Should -Match "parameters\('primaryStorageAccountId'\)"
        $endpoint = Get-TemplateResource -Template $references[0].properties.template -Type 'Microsoft.Network/privateEndpoints' | Select-Object -First 1
        $endpoint.properties.privateLinkServiceConnections[0].properties.privateLinkServiceId | Should -Be "[parameters('storageAccountId')]"
    }

    It 'names the shared zones exactly as main.bicep does, so the endpoint re-points the live records' {
        $expected = $main.variables.privateDnsZoneNames
        $actual = $failover.variables.privateDnsZoneNames
        foreach ($key in 'blob', 'sites', 'vault', 'monitor', 'oms', 'ods', 'agentsvc') {
            $actual.$key | Should -BeExactly $expected.$key -Because $key
        }
    }

    It 'uses the same region code as main.bicep' {
        $main.variables.regionCodes.eastus | Should -Be $failover.variables.regionCode
    }
}

Describe 'Failover: App Service plan scale-out (Phase 8)' {
    BeforeAll {
        $module = Get-FailoverModule 'failover-app-service-plan'
    }

    It 'scales to the prod primary capacity, 3 by default' {
        $failover.parameters.appServicePlanCapacity.defaultValue | Should -Be 3
        $failover.parameters.appServicePlanCapacity.minValue | Should -Be 1
        $failover.parameters.appServicePlanCapacity.maxValue | Should -Be 30
        $module.properties.parameters.capacity.value | Should -Be "[parameters('appServicePlanCapacity')]"
    }

    It 'patches the existing East US plan by name' {
        $module.properties.parameters.appServicePlanName.value | Should -Be "[variables('names').appServicePlan]"
        $failover.variables.names.appServicePlan | Should -Be "[format('asp-defenstack-{0}-{1}', parameters('environmentName'), variables('regionCode'))]"
        $module.properties.parameters.location.value | Should -Be "[parameters('location')]"
    }

    It 'keeps the prod SKU that appService.bicep gives every prod plan (P2V3, PremiumV3)' {
        $appServiceTemplate.variables.appServicePlanSkuName | Should -Match "'prod'\), 'P2V3'"
        $appServiceTemplate.variables.appServicePlanSkuTier | Should -Match "'prod'\), 'PremiumV3'"
        $plan.sku.name | Should -Be 'P2V3'
        $plan.sku.tier | Should -Be 'PremiumV3'
        $plan.sku.capacity | Should -Be "[parameters('capacity')]"
    }

    It 'uses the plan API version of appService.bicep and leaves the warm-standby plan zonal settings unchanged' {
        $appServicePlan = Get-TemplateResource -Template $appServiceTemplate -Type 'Microsoft.Web/serverfarms' | Select-Object -First 1
        $plan.apiVersion | Should -Be $appServicePlan.apiVersion
        $plan.properties.zoneRedundant | Should -BeExactly $false
        @($plan.properties.PSObject.Properties.Name) | Should -Be @('zoneRedundant')
    }

    It 'touches only the plan, never the application' {
        @(Get-TemplateResource -Template $planTemplate -Type 'Microsoft.Web/sites').Count | Should -Be 0
        $planTemplate.parameters.capacity.minValue | Should -Be 1
        $planTemplate.parameters.capacity.maxValue | Should -Be 30
    }
}

Describe 'Failover: East US Bastion (Phase 8)' {
    BeforeAll {
        $module = Get-FailoverModule 'failover-bastion'
    }

    It 'reuses modules/bastion.bicep with the stamp names the governance allowlist already permits' {
        $module.properties.parameters.bastionName.value | Should -Be "[variables('names').bastion]"
        $failover.variables.names.bastion | Should -Be "[format('bas-defenstack-{0}-{1}', parameters('environmentName'), variables('regionCode'))]"
        $module.properties.parameters.publicIpName.value | Should -Be "[variables('names').bastionPublicIp]"
        $failover.variables.names.bastionPublicIp | Should -Be "[format('pip-bas-defenstack-{0}-{1}', parameters('environmentName'), variables('regionCode'))]"
        @(Get-TemplateResource -Template $module.properties.template -Type 'Microsoft.Network/bastionHosts').Count | Should -Be 1
    }

    It 'places Bastion in the existing AzureBastionSubnet of the East US hub' {
        $module.properties.parameters.subnetId.value | Should -Match "Microsoft\.Network/virtualNetworks/subnets"
        $module.properties.parameters.subnetId.value | Should -Match "'AzureBastionSubnet'"
        $module.properties.parameters.subnetId.value | Should -Match "variables\('resourceGroupName'\)"
        $module.properties.parameters.subnetId.value | Should -Match "variables\('names'\)\.hubVnet"
        $failover.variables.names.hubVnet | Should -Be "[format('vnet-defenstack-{0}-{1}-hub', parameters('environmentName'), variables('regionCode'))]"
    }

    It 'spreads Bastion across three zones, as the stamp does, and logs to the shared workspace' {
        @($module.properties.parameters.availabilityZones.value) | Should -Be @('1', '2', '3')
        $module.properties.parameters.logAnalyticsWorkspaceId.value | Should -Match "Microsoft\.OperationalInsights/workspaces"
        $module.properties.parameters.logAnalyticsWorkspaceId.value | Should -Match "format\('log-defenstack-\{0\}'"
    }

    It 'produces a public IP name that governance.bicep allows for prod East US' {
        [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
        $governance = Get-BicepTemplate -RelativePath 'governance.bicep'
        ($governance.functions[0].members.publicIpNames.output.value -join "`n") | Should -Match ([regex]::Escape("format('pip-bas-defenstack-{0}-{1}'"))
        @($governance.parameters.environmentRegions.defaultValue.prod) | Should -Contain 'eastus'
    }
}

Describe 'Failover: East US Azure Monitor private endpoint (Phase 8)' {
    BeforeAll {
        $module = Get-FailoverModule 'failover-monitor-private-endpoint'
    }

    It 'reuses modules/monitorPrivateEndpoint.bicep with a region-specific endpoint name' {
        $module.properties.parameters.privateEndpointName.value | Should -Be "[variables('names').monitorPrivateEndpoint]"
        $failover.variables.names.monitorPrivateEndpoint | Should -Be "[format('ampls-defenstack-{0}-{1}-pe', parameters('environmentName'), variables('regionCode'))]"
        $module.properties.parameters.location.value | Should -Be "[parameters('location')]"
    }

    It 'connects to the existing environment scope in the global resource group' {
        $module.properties.parameters.privateLinkScopeName.value | Should -Be "[format('ampls-defenstack-{0}', parameters('environmentName'))]"
        $module.properties.parameters.privateLinkScopeId.value | Should -Match "Microsoft\.Insights/privateLinkScopes"
        $module.properties.parameters.privateLinkScopeId.value | Should -Match "variables\('globalResourceGroupName'\)"
    }

    It 'sits in the East US spoke private-endpoint subnet and joins its AMPLS application security group' {
        $module.properties.parameters.privateEndpointSubnetId.value | Should -Match "'private-endpoints'"
        $module.properties.parameters.privateEndpointSubnetId.value | Should -Match "variables\('resourceGroupName'\)"
        $module.properties.parameters.privateEndpointSubnetId.value | Should -Match "variables\('names'\)\.spokeVnet"
        $failover.variables.names.spokeVnet | Should -Be "[format('vnet-defenstack-{0}-{1}-spoke', parameters('environmentName'), variables('regionCode'))]"
        $module.properties.parameters.applicationSecurityGroupId.value | Should -Match "Microsoft\.Network/applicationSecurityGroups"
        $module.properties.parameters.applicationSecurityGroupId.value | Should -Match "variables\('names'\)\.amplsAsg"
        # spokeNetwork.bicep names the ASG '<spoke VNet>-ampls-asg'.
        $failover.variables.names.amplsAsg | Should -Be "[format('vnet-defenstack-{0}-{1}-spoke-ampls-asg', parameters('environmentName'), variables('regionCode'))]"
        (Get-Content (Get-RepoPath 'modules/spokeNetwork.bicep') -Raw) | Should -Match ([regex]::Escape("var amplsAsgName = '`${vnetName}-ampls-asg'"))
    }

    It 'writes its records into the shared zones of the global resource group, re-pointing Azure Monitor to East US' {
        $module.properties.parameters.privateDnsZoneIds.value | Should -Match "Microsoft\.Network/privateDnsZones"
        $module.properties.parameters.privateDnsZoneIds.value | Should -Match "variables\('globalResourceGroupName'\)"
        $module.properties.parameters.privateDnsZoneIds.value | Should -Match "variables\('privateDnsZoneNames'\)"
    }
}

Describe 'Failover: East US blob private endpoint to the primary storage account (Phase 8)' {
    BeforeAll {
        $module = Get-FailoverModule 'failover-storage-private-endpoint'
        $endpointTemplate = Get-BicepTemplate -RelativePath 'modules/failover/storagePrivateEndpoint.bicep'
        $endpoint = Get-TemplateResource -Template $endpointTemplate -Type 'Microsoft.Network/privateEndpoints' | Select-Object -First 1
        $zoneGroup = Get-TemplateResource -Template $endpointTemplate -Type 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups' | Select-Object -First 1
        $stamp = Get-BicepTemplate -RelativePath 'modules/regionStamp.bicep'
        $connectivity = Get-BicepTemplate -RelativePath 'modules/privateConnectivity.bicep'
        $primaryEndpoint = Get-TemplateResource -Template $connectivity -Type 'Microsoft.Network/privateEndpoints' |
            Where-Object { $_.properties.privateLinkServiceConnections[0].properties.groupIds -contains 'blob' } | Select-Object -First 1
        $primaryZoneGroup = Get-TemplateResource -Template $connectivity -Type 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups' |
            Where-Object { $_.properties.privateDnsZoneConfigs[0].name -eq 'blob' } | Select-Object -First 1
    }

    It 'defaults the account ID to the prod primary account, named as main.bicep and regionStamp.bicep name it' {
        $failover.parameters.primaryStorageAccountId.type | Should -Be 'string'
        $failover.parameters.primaryStorageAccountId.defaultValue | Should -BeExactly "[resourceId(subscription().subscriptionId, format('rg-defenstack-{0}-wus3', parameters('environmentName')), 'Microsoft.Storage/storageAccounts', format('stwus3{0}', uniqueString(subscription().id, parameters('environmentName'), 'westus3')))]"
        # The parts it hard-codes: the primary region, its code, the regional resource group and the account formula.
        $main.parameters.primaryLocation.defaultValue | Should -Be 'westus3'
        $main.variables.regionCodes.westus3 | Should -Be 'wus3'
        $main.variables.primaryResourceGroupName | Should -Be "[format('rg-defenstack-{0}-{1}', parameters('environmentName'), variables('primaryRegionCode'))]"
        $stamp.variables.nameSuffix | Should -Be "[uniqueString(subscription().id, parameters('environmentName'), parameters('location'))]"
        $stamp.variables.names.storageAccount | Should -Be "[format('st{0}{1}', parameters('regionCode'), variables('nameSuffix'))]"
    }

    It 'is named after the account with an -eus-pe suffix, distinct from its own -pe and the standby''s -secondary-pe endpoints' {
        $failover.variables.names.storagePrivateEndpoint | Should -BeExactly "[format('{0}-{1}-pe', last(split(parameters('primaryStorageAccountId'), '/')), variables('regionCode'))]"
        $module.properties.parameters.privateEndpointName.value | Should -Be "[variables('names').storagePrivateEndpoint]"
        $endpoint.name | Should -Be "[parameters('privateEndpointName')]"
        $primaryEndpoint.name | Should -Be "[format('{0}-pe', parameters('storageAccountName'))]"
        $secondary = Get-BicepTemplate -RelativePath 'modules/storageSecondaryEndpoint.bicep'
        (Get-TemplateResource -Template $secondary -Type 'Microsoft.Network/privateEndpoints' | Select-Object -First 1).name | Should -Be "[format('{0}-secondary-pe', parameters('primaryStorageAccountName'))]"
    }

    It 'connects to the account''s blob sub-resource, as the primary stamp''s storage endpoint does' {
        $module.properties.parameters.storageAccountId.value | Should -Be "[parameters('primaryStorageAccountId')]"
        $connection = $endpoint.properties.privateLinkServiceConnections[0]
        $connection.name | Should -Be 'blob'
        @($connection.properties.groupIds) | Should -Be @('blob')
        $endpoint.apiVersion | Should -Be $primaryEndpoint.apiVersion
        $connection.name | Should -Be $primaryEndpoint.properties.privateLinkServiceConnections[0].name
        @($connection.properties.groupIds) | Should -Be @($primaryEndpoint.properties.privateLinkServiceConnections[0].properties.groupIds)
    }

    It 'sits in the East US spoke private-endpoint subnet' {
        $module.properties.parameters.location.value | Should -Be "[parameters('location')]"
        $module.properties.parameters.privateEndpointSubnetId.value | Should -Match "'private-endpoints'"
        $module.properties.parameters.privateEndpointSubnetId.value | Should -Match "variables\('resourceGroupName'\)"
        $module.properties.parameters.privateEndpointSubnetId.value | Should -Match "variables\('names'\)\.spokeVnet"
        $endpoint.properties.subnet.id | Should -Be "[parameters('privateEndpointSubnetId')]"
    }

    It 'registers in the shared privatelink.blob zone of the global resource group, overwriting the account''s record' {
        $module.properties.parameters.blobPrivateDnsZoneId.value | Should -BeExactly "[resourceId(subscription().subscriptionId, variables('globalResourceGroupName'), 'Microsoft.Network/privateDnsZones', variables('privateDnsZoneNames').blob)]"
        $zoneGroup.name | Should -Match "'default'"
        @($zoneGroup.properties.privateDnsZoneConfigs).Count | Should -Be 1
        $zoneGroup.properties.privateDnsZoneConfigs[0].name | Should -Be $primaryZoneGroup.properties.privateDnsZoneConfigs[0].name
        $zoneGroup.properties.privateDnsZoneConfigs[0].properties.privateDnsZoneId | Should -Be "[parameters('blobPrivateDnsZoneId')]"
        $zoneGroup.apiVersion | Should -Be $primaryZoneGroup.apiVersion
    }

    It 'grants no data role: the write role stays a manual, PIM-gated runbook step (ADR-020)' {
        @(Get-TemplateResource -Template $endpointTemplate -Type 'Microsoft.Authorization/roleAssignments').Count | Should -Be 0
        $failoverJson | Should -Not -Match 'Microsoft\.Authorization/roleAssignments'
        $failoverJson | Should -Not -Match 'ba92f5b4-2d11-453d-a403-e96b0029c9fe'
    }
}

Describe 'Failover outputs (Phase 8)' {
    It 'reports what it deployed, or empty strings when disarmed' {
        foreach ($output in 'resourceGroupName', 'appServicePlanName', 'bastionName', 'monitorPrivateEndpointId', 'storagePrivateEndpointId') {
            $failover.outputs.PSObject.Properties.Name | Should -Contain $output
        }
        $failover.outputs.bastionName.value | Should -Match "^\[if\(parameters\('failoverActive'\)"
        $failover.outputs.monitorPrivateEndpointId.value | Should -Match "^\[if\(parameters\('failoverActive'\)"
        $failover.outputs.storagePrivateEndpointId.value | Should -Match "^\[if\(parameters\('failoverActive'\)"
    }
}

Describe 'Failover parameter file (Phase 8)' {
    BeforeAll {
        $text = Get-Content (Get-RepoPath 'params/failover.bicepparam') -Raw
        [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
        $built = (& bicep build-params (Get-RepoPath 'params/failover.bicepparam') --stdout) -join "`n" | ConvertFrom-Json
        $parameters = ($built.parametersJson | ConvertFrom-Json).parameters
    }

    It 'is armed for prod East US at the primary capacity' {
        $parameters.environmentName.value | Should -Be 'prod'
        $parameters.location.value | Should -Be 'eastus'
        $parameters.appServicePlanCapacity.value | Should -Be 3
        $parameters.failoverActive.value | Should -BeTrue
    }

    It 'leaves the primary storage account ID to the template default, which a parameter file cannot compute' {
        $parameters.PSObject.Properties.Name | Should -Not -Contain 'primaryStorageAccountId'
        $text | Should -Match 'primaryStorageAccountId is not set here'
        $text | Should -Match '<account>-eus-pe'
    }

    It 'points the operator at runbook 08' {
        $text | Should -Match 'runbook 08'
    }
}
