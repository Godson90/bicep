BeforeAll {
    Import-Module (Join-Path $PSScriptRoot 'Bicep.TestHelpers.psm1') -Force
    $governance = Get-BicepTemplate -RelativePath 'governance.bicep'
    $plansTemplate = Get-BicepTemplate -RelativePath 'modules/governance/defenderPlans.bicep'
    $pricings = Get-TemplateResource -Template $plansTemplate -Type 'Microsoft.Security/pricings' | Select-Object -First 1
    $contactsTemplate = Get-BicepTemplate -RelativePath 'modules/governance/securityContacts.bicep'
    $contact = Get-TemplateResource -Template $contactsTemplate -Type 'Microsoft.Security/securityContacts' | Select-Object -First 1

    function Get-Plan([string]$Name) {
        @($plansTemplate.variables.plans | Where-Object { $_.name -eq $Name })[0]
    }
}

Describe 'Governance entry point (Phase 7)' {
    It 'is a subscription-scope template at the repository root' {
        Get-RepoPath 'governance.bicep' | Should -Exist
        $governance.'$schema' | Should -Match 'subscriptionDeploymentTemplate\.json'
    }

    It 'is never deployed by main.bicep or the pipeline (operator only, ADR-026)' {
        Get-Content (Get-RepoPath 'main.bicep') -Raw | Should -Not -Match 'governance'
        $deploy = Get-Content (Get-RepoPath '.github/workflows/deploy.yml') -Raw
        $deploy | Should -Not -Match 'governance\.bicep\b'
        $deploy | Should -Not -Match '--template-file'
    }

    It 'requires at least one security contact address' {
        $governance.parameters.securityContactEmails.type | Should -Be 'array'
        $governance.parameters.securityContactEmails.minLength | Should -Be 1
        $governance.parameters.securityContactEmails.PSObject.Properties.Name | Should -Not -Contain 'defaultValue'
    }

    It 'caps on-upload malware scanning at 5000 GB per storage account per month by default' {
        $governance.parameters.malwareScanCapGbPerMonth.defaultValue | Should -Be 5000
        $governance.parameters.malwareScanCapGbPerMonth.minValue | Should -Be -1
    }

    It 'deploys the Defender plans with the malware scanning cap' {
        $module = Get-TemplateResourceBySymbol -Template $governance -Symbol 'defenderPlans'
        $module.properties.parameters.malwareScanCapGbPerMonth.value | Should -Be "[parameters('malwareScanCapGbPerMonth')]"
        $module.PSObject.Properties.Name | Should -Not -Contain 'resourceGroup'
    }

    It 'deploys the security contact with the contact addresses' {
        $module = Get-TemplateResourceBySymbol -Template $governance -Symbol 'securityContacts'
        $module.properties.parameters.emails.value | Should -Be "[parameters('securityContactEmails')]"
        $module.PSObject.Properties.Name | Should -Not -Contain 'resourceGroup'
    }
}

Describe 'Defender for Cloud plans (Phase 7)' {
    It 'deploys at subscription scope with the GA pricings API' {
        $plansTemplate.'$schema' | Should -Match 'subscriptionDeploymentTemplate\.json'
        $pricings.apiVersion | Should -Be '2024-01-01'
    }

    It 'updates one plan at a time, since parallel pricing updates conflict' {
        $pricings.copy.mode | Should -Be 'serial'
        $pricings.copy.batchSize | Should -Be 1
        $pricings.copy.count | Should -Be "[length(variables('plans'))]"
    }

    It 'enables exactly the spec plans: Servers, App Service, Storage, Key Vault, Resource Manager and Defender CSPM' {
        @($plansTemplate.variables.plans | ForEach-Object { $_.name }) -join ',' |
            Should -Be 'VirtualMachines,AppServices,StorageAccounts,KeyVaults,Arm,CloudPosture'
    }

    It 'sets every plan to Standard' {
        foreach ($plan in $plansTemplate.variables.plans) {
            $plan.properties.pricingTier | Should -Be 'Standard' -Because $plan.name
        }
        $pricings.properties | Should -Be "[variables('plans')[copyIndex()].properties]"
        $pricings.name | Should -Be "[variables('plans')[copyIndex()].name]"
    }

    It 'runs Defender for Servers Plan 2 with agentless VM scanning and no MDE direct onboarding' {
        $plan = Get-Plan 'VirtualMachines'
        $plan.properties.subPlan | Should -Be 'P2'
        @($plan.properties.extensions | ForEach-Object { $_.name }) | Should -Be @('AgentlessVmScanning')
        $plan.properties.extensions[0].isEnabled | Should -BeExactly 'True'
    }

    It 'runs Defender for Storage V2 with capped on-upload malware scanning and sensitive data discovery' {
        $plan = Get-Plan 'StorageAccounts'
        $plan.properties.subPlan | Should -Be 'DefenderForStorageV2'
        @($plan.properties.extensions | ForEach-Object { $_.name }) -join ',' | Should -Be 'OnUploadMalwareScanning,SensitiveDataDiscovery'
        foreach ($extension in $plan.properties.extensions) {
            $extension.isEnabled | Should -BeExactly 'True' -Because $extension.name
        }
        $malware = @($plan.properties.extensions | Where-Object { $_.name -eq 'OnUploadMalwareScanning' })[0]
        $malware.additionalExtensionProperties.CapGBPerMonthPerStorageAccount | Should -Be "[string(parameters('malwareScanCapGbPerMonth'))]"
    }

    It 'leaves <_> on the Azure default sub-plan with no extensions' -ForEach 'AppServices', 'KeyVaults', 'Arm', 'CloudPosture' {
        $plan = Get-Plan $_
        $plan.properties.PSObject.Properties.Name | Should -Not -Contain 'subPlan'
        $plan.properties.PSObject.Properties.Name | Should -Not -Contain 'extensions'
    }

    It 'does not manage the retired legacy agent auto-provisioning setting' {
        Get-TemplateResource -Template $plansTemplate -Type 'Microsoft.Security/autoProvisioningSettings' | Should -BeNullOrEmpty
    }

    It 'defaults the malware scanning cap to 5000 GB and allows -1 for no cap' {
        $plansTemplate.parameters.malwareScanCapGbPerMonth.defaultValue | Should -Be 5000
        $plansTemplate.parameters.malwareScanCapGbPerMonth.minValue | Should -Be -1
    }
}

Describe 'Defender for Cloud security contact (Phase 7)' {
    It 'is the subscription singleton named default' {
        $contactsTemplate.'$schema' | Should -Match 'subscriptionDeploymentTemplate\.json'
        $contact.name | Should -Be 'default'
    }

    It 'pins 2023-12-01-preview, the latest version; the type has no GA version (ADR-029)' {
        $contact.apiVersion | Should -Be '2023-12-01-preview'
    }

    It 'emails every address, semicolon-separated, and requires at least one' {
        $contact.properties.isEnabled | Should -BeExactly $true
        $contact.properties.emails | Should -Be "[join(parameters('emails'), ';')]"
        $contactsTemplate.parameters.emails.minLength | Should -Be 1
    }

    It 'also notifies subscription Owners' {
        $contact.properties.notificationsByRole.state | Should -Be 'On'
        @($contact.properties.notificationsByRole.roles) | Should -Be @('Owner')
    }

    It 'emails alerts of severity High only' {
        $sources = @($contact.properties.notificationsSources)
        $sources.Count | Should -Be 1
        $sources[0].sourceType | Should -Be 'Alert'
        $sources[0].minimalSeverity | Should -Be 'High'
    }
}

Describe 'Governance policy parameters (Phase 7)' {
    It 'goes live audit-first: every deny assignment follows denyEnforcement, default DoNotEnforce (ADR-027)' {
        $governance.parameters.denyEnforcement.defaultValue | Should -Be 'DoNotEnforce'
        @($governance.parameters.denyEnforcement.allowedValues) -join ',' | Should -Be 'DoNotEnforce,Default'
        $module = Get-TemplateResourceBySymbol -Template $governance -Symbol 'policies'
        $module.properties.parameters.denyEnforcement.value | Should -Be "[parameters('denyEnforcement')]"
    }

    It 'covers dev and prod by default, dev in West US 3 only and prod in both regions' {
        @($governance.parameters.environments.defaultValue) -join ',' | Should -Be 'dev,prod'
        @($governance.parameters.environments.allowedValues | Sort-Object) -join ',' | Should -Be 'dev,prod'
        @($governance.parameters.environmentRegions.defaultValue.dev) -join ',' | Should -Be 'westus3'
        @($governance.parameters.environmentRegions.defaultValue.prod) -join ',' | Should -Be 'westus3,eastus'
    }

    It 'allows West US 3, East US and global for resources, and the two regions for resource groups' {
        @($governance.variables.platformLocations) -join ',' | Should -Be 'westus3,eastus'
        $module = Get-TemplateResourceBySymbol -Template $governance -Symbol 'policies'
        $module.properties.parameters.allowedLocations.value | Should -Be "[concat(variables('platformLocations'), createArray('global'))]"
        $module.properties.parameters.allowedResourceGroupLocations.value | Should -Be "[variables('platformLocations')]"
    }

    It 'waives the legacy defenStack resource group by default, until a dated expiry' {
        $governance.parameters.legacyResourceGroupName.defaultValue | Should -Be 'defenStack'
        $governance.parameters.legacyWaiverExpiresOn.minLength | Should -Be 10
        $governance.parameters.legacyWaiverExpiresOn.maxLength | Should -Be 10
    }
}

Describe 'Name parity with the workload templates (Phase 7)' {
    BeforeAll {
        $main = Get-BicepTemplate -RelativePath 'main.bicep'
        $stamp = Get-BicepTemplate -RelativePath 'modules/regionStamp.bicep'
        $vpnTemplate = Get-BicepTemplate -RelativePath 'modules/vpnGateway.bicep'
        $exemptionTemplate = Get-BicepTemplate -RelativePath 'modules/governance/flowLogStorageExemption.bicep'
        $publicIpFunction = $governance.functions[0].members.publicIpNames
    }

    It 'uses the same region codes as main.bicep' {
        ($governance.variables.regionCodes | ConvertTo-Json -Compress) | Should -Be ($main.variables.regionCodes | ConvertTo-Json -Compress)
    }

    It 'names regional resource groups exactly as main.bicep does' {
        $main.variables.primaryResourceGroupName | Should -Be "[format('rg-defenstack-{0}-{1}', parameters('environmentName'), variables('primaryRegionCode'))]"
        $governance.variables.stamps | Should -Match ([regex]::Escape("'resourceGroupName', format('rg-defenstack-{0}-{1}', lambdaVariables('environmentName'), variables('regionCodes')[lambdaVariables('location')])"))
        $governance.variables.stamps | Should -Match ([regex]::Escape("'regionCode', variables('regionCodes')[lambdaVariables('location')]"))
    }

    It 'hands each stamp the full region name as location, as main.bicep does (the name hash uses it)' {
        $primary = Get-TemplateResourceBySymbol -Template $main -Symbol 'primaryStamp'
        $primary.properties.parameters.location.value | Should -Be "[parameters('primaryLocation')]"
        $primary.properties.parameters.regionCode.value | Should -Be "[variables('primaryRegionCode')]"
        $governance.variables.stamps | Should -Match ([regex]::Escape("'location', lambdaVariables('location')"))
    }

    It 'hands the secondary stamp its full region name and region code, in a resource group named as governance names it' {
        $secondary = Get-TemplateResourceBySymbol -Template $main -Symbol 'secondaryStamp'
        $secondary.properties.parameters.location.value | Should -Be "[parameters('secondaryLocation')]"
        $secondary.properties.parameters.regionCode.value | Should -Be "[variables('secondaryRegionCode')]"
        $secondary.resourceGroup | Should -Be "[variables('secondaryResourceGroupName')]"
        $main.variables.secondaryResourceGroupName | Should -Be "[format('rg-defenstack-{0}-{1}', parameters('environmentName'), variables('secondaryRegionCode'))]"
        $governance.variables.stamps | Should -Match ([regex]::Escape("format('rg-defenstack-{0}-{1}', lambdaVariables('environmentName'), variables('regionCodes')[lambdaVariables('location')])"))
    }

    It 'allows the <Key> public IP name exactly as regionStamp.bicep builds it' -ForEach @(
        @{ Key = 'firewallPublicIp' }
        @{ Key = 'bastionPublicIp' }
    ) {
        $expression = $stamp.variables.names.$Key
        $expression | Should -Match "parameters\('environmentName'\), parameters\('regionCode'\)\)\]$"
        @($publicIpFunction.output.value) | Should -Contain $expression
    }

    It 'allows both active-active VPN gateway public IPs (prefix -1 and -2, as vpnGateway.bicep appends)' {
        $prefix = $stamp.variables.names.vpnGatewayPublicIp
        $prefix | Should -Be "[format('pip-vpng-defenstack-{0}-{1}', parameters('environmentName'), parameters('regionCode'))]"
        @($vpnTemplate.variables.instances) -join ',' | Should -Be '1,2'
        $vpnIps = Get-TemplateResource -Template $vpnTemplate -Type 'Microsoft.Network/publicIPAddresses' | Select-Object -First 1
        $vpnIps.name | Should -Be "[format('{0}-{1}', parameters('publicIpNamePrefix'), variables('instances')[copyIndex()])]"
        foreach ($instance in 1, 2) {
            @($publicIpFunction.output.value) | Should -Contain "[format('pip-vpng-defenstack-{0}-{1}-$instance', parameters('environmentName'), parameters('regionCode'))]"
        }
        @($publicIpFunction.output.value).Count | Should -Be 4
    }

    It 'only the firewall, Bastion and VPN gateway modules create public IPs, so the allowlist is complete' {
        $files = @(Get-ChildItem (Get-RepoPath 'modules') -Filter '*.bicep' -Recurse) + @(Get-ChildItem (Get-RepoPath '.') -Filter '*.bicep')
        $declarations = @{}
        foreach ($file in $files) {
            $count = [regex]::Matches((Get-Content $file.FullName -Raw), "'Microsoft\.Network/publicIPAddresses@").Count
            if ($count -gt 0) { $declarations[$file.Name] = $count }
        }
        @($declarations.Keys | Sort-Object) -join ',' | Should -Be 'azureFirewall.bicep,bastion.bicep,vpnGateway.bicep'
        foreach ($owner in 'azureFirewall.bicep', 'bastion.bicep', 'vpnGateway.bicep') {
            # One declaration each; vpnGateway.bicep's copy loop over -1 and -2 is pinned above.
            $declarations[$owner] | Should -Be 1 -Because $owner
        }
    }

    It 'computes the flow-log account name with the same formula as regionStamp.bicep' {
        $exemptionTemplate.variables.nameSuffix | Should -BeExactly $stamp.variables.nameSuffix
        $exemptionTemplate.variables.flowLogStorageAccountName | Should -BeExactly $stamp.variables.names.flowLogStorageAccount
        $stamp.variables.nameSuffix | Should -Be "[uniqueString(subscription().id, parameters('environmentName'), parameters('location'))]"
    }
}

Describe 'Policy assignments (Phase 7)' {
    BeforeAll {
        $policyTemplate = Get-BicepTemplate -RelativePath 'modules/governance/policies.bicep'
        $assignments = @(Get-TemplateResource -Template $policyTemplate -Type 'Microsoft.Authorization/policyAssignments')
        $definition = Get-TemplateResource -Template $policyTemplate -Type 'Microsoft.Authorization/policyDefinitions' | Select-Object -First 1
        $publicNetwork = Get-TemplateResourceBySymbol -Template $policyTemplate -Symbol 'publicNetworkAccess'

        function Get-Assignment([string]$Symbol) {
            Get-TemplateResourceBySymbol -Template $policyTemplate -Symbol $Symbol
        }
    }

    It 'deploys at subscription scope with the GA policy APIs' {
        $policyTemplate.'$schema' | Should -Match 'subscriptionDeploymentTemplate\.json'
        foreach ($assignment in $assignments) {
            $assignment.apiVersion | Should -Be '2025-11-01' -Because $assignment.name
        }
        $definition.apiVersion | Should -Be '2025-11-01'
    }

    It 'assigns the Microsoft cloud security benchmark initiative, enforced (its policies only audit)' {
        $mcsb = Get-Assignment 'cloudSecurityBenchmark'
        $mcsb.properties.policyDefinitionId | Should -Be "[tenantResourceId('Microsoft.Authorization/policySetDefinitions', '1f3afdf9-d0c9-4c3d-847f-89da613e70a8')]"
        $mcsb.properties.enforcementMode | Should -Be 'Default'
        $mcsb.properties.PSObject.Properties.Name | Should -Not -Contain 'parameters'
    }

    It 'denies public network access on <Name>' -ForEach @(
        @{ Name = 'storage accounts'; Id = 'b2982f36-99f2-4db5-8eff-283140c09693' }
        @{ Name = 'Key Vault'; Id = '405c5871-3e91-4644-8a63-58e19d68ff5b' }
        @{ Name = 'App Service apps'; Id = '1b5ef780-c53c-4a64-87f3-bb9c8c8094ba' }
        @{ Name = 'App Service app slots'; Id = '701a595d-38fb-4a66-ae6d-fb3735217622' }
        @{ Name = 'Function apps'; Id = '969ac98b-88a8-449f-883c-2e9adb123127' }
        @{ Name = 'Function app slots'; Id = '11c82d0c-db9f-4d7b-97c5-f3f9aa957da2' }
    ) {
        @($policyTemplate.variables.publicNetworkAccessPolicies | ForEach-Object { $_.definitionId }) | Should -Contain $Id
    }

    It 'gives every public network access assignment effect Deny under denyEnforcement' {
        @($policyTemplate.variables.publicNetworkAccessPolicies).Count | Should -Be 6
        $publicNetwork.copy.count | Should -Be "[length(variables('publicNetworkAccessPolicies'))]"
        $publicNetwork.properties.policyDefinitionId | Should -Be "[tenantResourceId('Microsoft.Authorization/policyDefinitions', variables('publicNetworkAccessPolicies')[copyIndex()].definitionId)]"
        $publicNetwork.properties.parameters.effect.value | Should -Be 'Deny'
        $publicNetwork.properties.enforcementMode | Should -Be "[parameters('denyEnforcement')]"
    }

    It 'lists storage first, since the flow-log exemption takes the first assignment' {
        $policyTemplate.variables.publicNetworkAccessPolicies[0].definitionId | Should -Be 'b2982f36-99f2-4db5-8eff-283140c09693'
        $policyTemplate.outputs.storagePublicNetworkAssignmentId.value | Should -Match "variables\('publicNetworkAccessPolicies'\)\[0\]\.name"
    }

    It 'restricts resource locations under denyEnforcement' {
        $locations = Get-Assignment 'allowedLocationsAssignment'
        $locations.properties.policyDefinitionId | Should -Be "[tenantResourceId('Microsoft.Authorization/policyDefinitions', 'e56962a6-4747-49cd-b67b-bf8b01975c4c')]"
        $locations.properties.parameters.listOfAllowedLocations.value | Should -Be "[parameters('allowedLocations')]"
        $locations.properties.enforcementMode | Should -Be "[parameters('denyEnforcement')]"
    }

    It 'restricts resource group locations under denyEnforcement' {
        $groups = Get-Assignment 'allowedResourceGroupLocationsAssignment'
        $groups.properties.policyDefinitionId | Should -Be "[tenantResourceId('Microsoft.Authorization/policyDefinitions', 'e765b5de-1225-4ba3-bd56-1ac6695af988')]"
        $groups.properties.parameters.listOfAllowedLocations.value | Should -Be "[parameters('allowedResourceGroupLocations')]"
        $groups.properties.enforcementMode | Should -Be "[parameters('denyEnforcement')]"
    }

    It 'sets no effect on the location policies, whose effect is Deny already' {
        foreach ($symbol in 'allowedLocationsAssignment', 'allowedResourceGroupLocationsAssignment') {
            (Get-Assignment $symbol).properties.parameters.PSObject.Properties.Name | Should -Not -Contain 'effect'
        }
    }

    It 'tells the blocked caller why, on every deny assignment' {
        foreach ($symbol in 'publicNetworkAccess', 'allowedLocationsAssignment', 'allowedResourceGroupLocationsAssignment', 'publicIpAssignment') {
            @((Get-Assignment $symbol).properties.nonComplianceMessages).Count | Should -Be 1 -Because $symbol
            (Get-Assignment $symbol).properties.nonComplianceMessages[0].message | Should -Match 'runbook 07' -Because $symbol
        }
    }

    It 'audits missing diagnostic settings with AuditIfNotExists only, enforced, with no identity' {
        $diagnostics = Get-Assignment 'diagnosticSettingsAudit'
        $diagnostics.properties.policyDefinitionId | Should -Be "[tenantResourceId('Microsoft.Authorization/policyDefinitions', '7f89b1eb-583c-429a-8828-af049802c1d9')]"
        $diagnostics.properties.parameters.listOfResourceTypes.value | Should -Be "[parameters('diagnosticResourceTypes')]"
        $diagnostics.properties.enforcementMode | Should -Be 'Default'
        foreach ($assignment in $assignments) {
            $assignment.PSObject.Properties.Name | Should -Not -Contain 'identity' -Because $assignment.name
        }
        Get-TemplateResource -Template $policyTemplate -Type 'Microsoft.PolicyInsights/remediations' | Should -BeNullOrEmpty
    }

    It 'records governance.bicep as the owner of every assignment (PSRule Azure.Policy.AssignmentAssignedBy)' {
        $policyTemplate.variables.assignmentMetadata.assignedBy | Should -Match 'governance\.bicep'
        foreach ($assignment in $assignments) {
            $assignment.properties.metadata | Should -Be "[variables('assignmentMetadata')]" -Because $assignment.name
        }
    }

    It 'names every assignment defenstack-* within the 64-character limit' {
        $names = @($policyTemplate.variables.publicNetworkAccessPolicies | ForEach-Object { $_.name }) +
            @($assignments | Where-Object { $_.name -notmatch '^\[' } | ForEach-Object { $_.name })
        $names.Count | Should -Be 11
        foreach ($name in $names) {
            $name | Should -Match '^defenstack-[a-z0-9-]+$'
            $name.Length | Should -BeLessOrEqual 64
        }
        @($names | Select-Object -Unique).Count | Should -Be $names.Count
    }

    It 'outputs the nine deny assignment IDs for the legacy waiver' {
        $policyTemplate.outputs.denyAssignmentIds.value | Should -Match "map\(variables\('publicNetworkAccessPolicies'\)"
        foreach ($symbol in 'allowedLocationsAssignment', 'allowedResourceGroupLocationsAssignment', 'publicIpAssignment') {
            $name = (Get-Assignment $symbol).name
            $policyTemplate.outputs.denyAssignmentIds.value | Should -Match ([regex]::Escape("'$name')"))
        }
    }
}

Describe 'Custom public IP allowlist policy (Phase 7)' {
    BeforeAll {
        $policyTemplate = Get-BicepTemplate -RelativePath 'modules/governance/policies.bicep'
        $definition = Get-TemplateResource -Template $policyTemplate -Type 'Microsoft.Authorization/policyDefinitions' | Select-Object -First 1
        $assignment = Get-TemplateResourceBySymbol -Template $policyTemplate -Symbol 'publicIpAssignment'
    }

    It 'is a custom definition named defenstack-deny-public-ip-except-allowlist' {
        $definition.name | Should -Be 'defenstack-deny-public-ip-except-allowlist'
        $definition.properties.policyType | Should -Be 'Custom'
        $definition.properties.mode | Should -Be 'Indexed'
        $definition.properties.parameters.allowedNames.type | Should -Be 'Array'
    }

    It 'denies any public IP whose name is not in allowedNames' {
        $conditions = @($definition.properties.policyRule.if.allOf)
        $conditions.Count | Should -Be 2
        $conditions[0].field | Should -Be 'type'
        $conditions[0].equals | Should -Be 'Microsoft.Network/publicIPAddresses'
        $conditions[1].field | Should -Be 'name'
        # Bicep escapes the leading [ so ARM hands the expression to Azure Policy unevaluated.
        $conditions[1].notIn | Should -Be "[[parameters('allowedNames')]"
        $definition.properties.policyRule.then.effect | Should -Be 'deny'
    }

    It 'is assigned with the computed allowlist under denyEnforcement' {
        $assignment.properties.policyDefinitionId | Should -Be "[subscriptionResourceId('Microsoft.Authorization/policyDefinitions', 'defenstack-deny-public-ip-except-allowlist')]"
        $assignment.properties.parameters.allowedNames.value | Should -Be "[parameters('allowedPublicIpNames')]"
        $assignment.properties.enforcementMode | Should -Be "[parameters('denyEnforcement')]"
        $governancePolicies = Get-TemplateResourceBySymbol -Template $governance -Symbol 'policies'
        $governancePolicies.properties.parameters.allowedPublicIpNames.value | Should -Be "[variables('allowedPublicIpNames')]"
        $governance.variables.allowedPublicIpNames | Should -Be "[flatten(map(variables('stamps'), lambda('stamp', __bicep.publicIpNames(lambdaVariables('stamp').environmentName, lambdaVariables('stamp').regionCode))))]"
    }
}

Describe 'Diagnostic settings audit scope (Phase 7)' {
    It 'audits exactly the resource types whose modules send logs and metrics to the workspace' {
        @($governance.variables.diagnosticResourceTypes | Sort-Object) -join ',' | Should -Be (@(
                'Microsoft.Cdn/profiles'
                'Microsoft.KeyVault/vaults'
                'Microsoft.Network/azureFirewalls'
                'Microsoft.Network/bastionHosts'
                'Microsoft.Network/virtualNetworkGateways'
                'Microsoft.Storage/storageAccounts/blobServices'
                'Microsoft.Web/sites'
            ) -join ',')
        $module = Get-TemplateResourceBySymbol -Template $governance -Symbol 'policies'
        $module.properties.parameters.diagnosticResourceTypes.value | Should -Be "[variables('diagnosticResourceTypes')]"
    }
}

Describe 'Policy exemptions (Phase 7)' {
    BeforeAll {
        $exemptionTemplate = Get-BicepTemplate -RelativePath 'modules/governance/flowLogStorageExemption.bicep'
        $flowLogExemption = Get-TemplateResource -Template $exemptionTemplate -Type 'Microsoft.Authorization/policyExemptions' | Select-Object -First 1
        $waiverTemplate = Get-BicepTemplate -RelativePath 'modules/governance/legacyWaiver.bicep'
        $waiver = Get-TemplateResource -Template $waiverTemplate -Type 'Microsoft.Authorization/policyExemptions' | Select-Object -First 1
        $flowLogModule = Get-TemplateResourceBySymbol -Template $governance -Symbol 'flowLogExemptions'
        $waiverModule = Get-TemplateResourceBySymbol -Template $governance -Symbol 'legacyWaiver'
    }

    It 'pins 2026-01-01-preview, the latest version; exemptions have no GA version (ADR-029)' {
        $flowLogExemption.apiVersion | Should -Be '2026-01-01-preview'
        $waiver.apiVersion | Should -Be '2026-01-01-preview'
    }

    It 'exempts each flow-log account from the storage public network access assignment as Mitigated (ADR-023)' {
        $flowLogExemption.scope | Should -Be "[resourceId('Microsoft.Storage/storageAccounts', variables('flowLogStorageAccountName'))]"
        $flowLogExemption.properties.exemptionCategory | Should -Be 'Mitigated'
        $flowLogExemption.properties.policyAssignmentId | Should -Be "[parameters('policyAssignmentId')]"
        $flowLogExemption.properties.description | Should -Match 'ADR-023'
        $flowLogExemption.properties.PSObject.Properties.Name | Should -Not -Contain 'expiresOn'
    }

    It 'creates one flow-log exemption per environment and region, in the regional resource group' {
        $flowLogModule.copy.count | Should -Be "[length(variables('stamps'))]"
        $flowLogModule.resourceGroup | Should -Be "[variables('stamps')[copyIndex()].resourceGroupName]"
        $flowLogModule.properties.parameters.environmentName.value | Should -Be "[variables('stamps')[copyIndex()].environmentName]"
        $flowLogModule.properties.parameters.location.value | Should -Be "[variables('stamps')[copyIndex()].location]"
        $flowLogModule.properties.parameters.regionCode.value | Should -Be "[variables('stamps')[copyIndex()].regionCode]"
        $flowLogModule.properties.parameters.policyAssignmentId.value | Should -Be "[reference('policies').outputs.storagePublicNetworkAssignmentId.value]"
    }

    It 'waives every deny assignment on the legacy resource group, only when one is named' {
        $waiverModule.condition | Should -Be "[not(empty(parameters('legacyResourceGroupName')))]"
        $waiverModule.resourceGroup | Should -Be "[parameters('legacyResourceGroupName')]"
        $waiverModule.properties.parameters.policyAssignmentIds.value | Should -Be "[reference('policies').outputs.denyAssignmentIds.value]"
        $waiverModule.properties.parameters.expiresOn.value | Should -Be "[parameters('legacyWaiverExpiresOn')]"
    }

    It 'makes each legacy waiver a dated Waiver that points to runbook 01a' {
        $waiver.copy.count | Should -Be "[length(parameters('policyAssignmentIds'))]"
        $waiver.properties.exemptionCategory | Should -Be 'Waiver'
        $waiver.properties.policyAssignmentId | Should -Be "[parameters('policyAssignmentIds')[copyIndex()]]"
        $waiver.properties.expiresOn | Should -Be "[format('{0}T23:59:59Z', parameters('expiresOn'))]"
        $waiver.properties.description | Should -Match 'runbook 01a'
        $waiver.name | Should -Be "[format('defenstack-legacy-waiver-{0}', replace(last(split(parameters('policyAssignmentIds')[copyIndex()], '/')), 'defenstack-', ''))]"
    }

    It 'keeps every legacy waiver name, built from the nine deny assignment names, within the 64-character limit' {
        $policyTemplate = Get-BicepTemplate -RelativePath 'modules/governance/policies.bicep'
        $denyNames = @($policyTemplate.variables.publicNetworkAccessPolicies | ForEach-Object { $_.name }) +
            @('allowedLocationsAssignment', 'allowedResourceGroupLocationsAssignment', 'publicIpAssignment' | ForEach-Object { (Get-TemplateResourceBySymbol -Template $policyTemplate -Symbol $_).name })
        $denyNames.Count | Should -Be 9
        # The same formula as legacyWaiver.bicep: the assignment name without its defenstack- prefix.
        $waiverNames = @($denyNames | ForEach-Object { 'defenstack-legacy-waiver-' + $_.Replace('defenstack-', '') })
        foreach ($name in $waiverNames) {
            $name | Should -Match '^defenstack-legacy-waiver-[a-z0-9-]+$'
            $name.Length | Should -BeLessOrEqual 64 -Because $name
        }
        @($waiverNames | Select-Object -Unique).Count | Should -Be 9
        ($waiverNames | Measure-Object -Property Length -Maximum).Maximum | Should -Be 58
    }

    It 'keeps the flow-log exemption name within the 64-character limit' {
        $flowLogExemption.name | Should -BeExactly 'defenstack-flow-log-storage-public-network'
        $flowLogExemption.name.Length | Should -BeLessOrEqual 64
    }
}

Describe 'Defender for Storage on the flow-log accounts (Phase 7, ADR-026)' {
    BeforeAll {
        $exemptionTemplate = Get-BicepTemplate -RelativePath 'modules/governance/flowLogStorageExemption.bicep'
        $storageSettings = @(Get-TemplateResource -Template $exemptionTemplate -Type 'Microsoft.Security/defenderForStorageSettings')
        $flowLogModule = Get-TemplateResourceBySymbol -Template $governance -Symbol 'flowLogExemptions'
    }

    It 'overrides the subscription settings once on each flow-log account, with the GA API' {
        $storageSettings.Count | Should -Be 1
        $storageSettings[0].apiVersion | Should -Be '2025-01-01'
        $storageSettings[0].name | Should -Be 'current'
        $storageSettings[0].scope | Should -Be "[resourceId('Microsoft.Storage/storageAccounts', variables('flowLogStorageAccountName'))]"
        $flowLogModule.copy.count | Should -Be "[length(variables('stamps'))]"
    }

    It 'keeps Defender for Storage on but turns off on-upload malware scanning and sensitive data discovery' {
        $properties = $storageSettings[0].properties
        $properties.isEnabled | Should -BeExactly $true
        $properties.overrideSubscriptionLevelSettings | Should -BeExactly $true
        $properties.malwareScanning.onUpload.isEnabled | Should -BeExactly $false
        $properties.sensitiveDataDiscovery.isEnabled | Should -BeExactly $false
    }
}

Describe 'JIT requester role (Phase 7, ADR-028)' {
    BeforeAll {
        $roleTemplate = Get-BicepTemplate -RelativePath 'modules/governance/jitRequesterRole.bicep'
        $role = Get-TemplateResource -Template $roleTemplate -Type 'Microsoft.Authorization/roleDefinitions' | Select-Object -First 1
        $assignmentTemplate = Get-BicepTemplate -RelativePath 'modules/governance/jitRequesterAssignment.bicep'
        $assignment = Get-TemplateResource -Template $assignmentTemplate -Type 'Microsoft.Authorization/roleAssignments' | Select-Object -First 1
        $roleModule = Get-TemplateResourceBySymbol -Template $governance -Symbol 'jitRequesterRole'
        $assignmentModule = Get-TemplateResourceBySymbol -Template $governance -Symbol 'jitRequesterAssignments'
    }

    It 'defines the DefenStack JIT Requester custom role at subscription scope, with a deterministic name' {
        $roleTemplate.'$schema' | Should -Match 'subscriptionDeploymentTemplate\.json'
        $role.apiVersion | Should -Be '2022-04-01'
        $role.name | Should -Be "[guid(subscription().id, 'DefenStack JIT Requester')]"
        $role.properties.roleName | Should -BeExactly 'DefenStack JIT Requester'
        $role.properties.type | Should -Be 'CustomRole'
        @($role.properties.assignableScopes) | Should -Be @('[subscription().id]')
        $role.properties.description | Should -Match 'ADR-028'
    }

    It 'grants only reading and initiating JIT requests plus the reads the request needs' {
        $role.properties.permissions[0].actions | Should -Be "[variables('roleActions')]"
        @($roleTemplate.variables.roleActions) -join ',' | Should -Be (@(
                'Microsoft.Security/locations/jitNetworkAccessPolicies/read'
                'Microsoft.Security/locations/jitNetworkAccessPolicies/initiate/action'
                'Microsoft.Security/locations/jitNetworkAccessPolicies/*/read'
                'Microsoft.Compute/virtualMachines/read'
                'Microsoft.Network/networkInterfaces/read'
                'Microsoft.Network/networkInterfaces/*/read'
                'Microsoft.Network/publicIPAddresses/read'
            ) -join ',')
        @($role.properties.permissions[0].dataActions).Count | Should -Be 0
    }

    It 'never grants a write, a delete or a wildcard action outside a read' {
        foreach ($action in $roleTemplate.variables.roleActions) {
            $action | Should -Match '(/read|/initiate/action)$' -Because $action
            $action | Should -Not -Match '/write$|/delete$'
            ($action -replace '/\*/read$', '/read') | Should -Not -Match '\*' -Because $action
        }
    }

    It 'outputs the role definition ID for the assignments' {
        $roleTemplate.outputs.roleDefinitionId.value | Should -Be "[subscriptionResourceId('Microsoft.Authorization/roleDefinitions', guid(subscription().id, 'DefenStack JIT Requester'))]"
        $governance.outputs.jitRequesterRoleDefinitionId.value | Should -Be "[reference('jitRequesterRole').outputs.roleDefinitionId.value]"
        $roleModule.PSObject.Properties.Name | Should -Not -Contain 'resourceGroup'
    }

    It 'takes one admin group per environment, empty by default (same groups as runbook 03)' {
        $governance.parameters.adminGroupObjectIds.'$ref' | Should -Be '#/definitions/environmentAdminGroups'
        $governance.parameters.adminGroupObjectIds.defaultValue.dev | Should -BeExactly ''
        $governance.parameters.adminGroupObjectIds.defaultValue.prod | Should -BeExactly ''
    }

    It 'marks the first region of each environment as its primary stamp' {
        $governance.variables.stamps | Should -Match ([regex]::Escape("lambda('location', 'index', createObject("))
        $governance.variables.stamps | Should -Match ([regex]::Escape("'isPrimary', equals(lambdaVariables('index'), 0)"))
    }

    It 'assigns the role only at primary stamps, where the jump host runs, and only for environments with a group' {
        $governance.variables.jumpHostStamps | Should -Be "[filter(variables('stamps'), lambda('stamp', and(lambdaVariables('stamp').isPrimary, not(empty(parameters('adminGroupObjectIds')[lambdaVariables('stamp').environmentName])))))]"
        $stampTemplate = Get-BicepTemplate -RelativePath 'modules/regionStamp.bicep'
        (Get-TemplateResourceBySymbol -Template $stampTemplate -Symbol 'virtualMachine').condition |
            Should -Be "[and(parameters('enableVirtualMachine'), variables('isPrimary'))]"
    }

    It 'assigns the role to the environment admin group in each jump host resource group' {
        $assignmentModule.copy.count | Should -Be "[length(variables('jumpHostStamps'))]"
        $assignmentModule.resourceGroup | Should -Be "[variables('jumpHostStamps')[copyIndex()].resourceGroupName]"
        $assignmentModule.name | Should -Be "[format('governance-jit-requester-{0}-{1}', variables('jumpHostStamps')[copyIndex()].environmentName, variables('jumpHostStamps')[copyIndex()].regionCode)]"
        $assignmentModule.properties.parameters.principalId.value | Should -Be "[parameters('adminGroupObjectIds')[variables('jumpHostStamps')[copyIndex()].environmentName]]"
        $assignmentModule.properties.parameters.roleDefinitionId.value | Should -Be "[reference('jitRequesterRole').outputs.roleDefinitionId.value]"
    }

    It 'gives each assignment a deterministic GUID name and assigns it to a group' {
        $assignment.apiVersion | Should -Be '2022-04-01'
        $assignment.name | Should -Be "[guid(resourceGroup().id, parameters('principalId'), parameters('roleDefinitionId'))]"
        $assignment.properties.principalType | Should -Be 'Group'
        $assignment.properties.principalId | Should -Be "[parameters('principalId')]"
        $assignment.properties.roleDefinitionId | Should -Be "[parameters('roleDefinitionId')]"
        $assignmentTemplate.parameters.principalId.minLength | Should -Be 36
    }
}
