BeforeAll {
    Import-Module (Join-Path $PSScriptRoot 'Bicep.TestHelpers.psm1') -Force
    $template = Get-BicepTemplate -RelativePath 'modules/firewallPolicyRules.bicep'
    $groups = Get-TemplateResource -Template $template -Type 'Microsoft.Network/firewallPolicies/ruleCollectionGroups'
    function Get-Group([string]$Name) {
        $groups | Where-Object { $_.name -like "*'$Name')]" }
    }
    $dns = Get-Group 'dns-egress'
    $admin = Get-Group 'admin-access'
    $platform = Get-Group 'platform-egress'
    $approved = Get-Group 'approved-https-egress'
}

Describe 'Baseline firewall rules (ADR-010)' {
    It 'defines the dns-egress, admin-access, platform-egress and approved-https-egress groups at priorities 100, 120, 150, 200 (plus the Phase 6 cross-region group)' {
        $groups.Count | Should -Be 5
        $dns.properties.priority | Should -Be 100
        $admin.properties.priority | Should -Be 120
        $platform.properties.priority | Should -Be 150
        $approved.properties.priority | Should -Be 200
    }

    It 'updates the groups one at a time (a policy rejects concurrent rule collection group updates)' {
        @($dns.PSObject.Properties.Name) | Should -Not -Contain 'dependsOn'
        @($admin.dependsOn) | Should -Contain "[resourceId('Microsoft.Network/firewallPolicies/ruleCollectionGroups', parameters('firewallPolicyName'), 'dns-egress')]"
        @($platform.dependsOn) | Should -Contain "[resourceId('Microsoft.Network/firewallPolicies/ruleCollectionGroups', parameters('firewallPolicyName'), 'admin-access')]"
        @($approved.dependsOn) | Should -Contain "[resourceId('Microsoft.Network/firewallPolicies/ruleCollectionGroups', parameters('firewallPolicyName'), 'platform-egress')]"
    }

    It 'allows spoke DNS to the Azure resolver through the proxy' {
        $rule = $dns.properties.ruleCollections[0].rules[0]
        @($rule.destinationAddresses) | Should -Contain '168.63.129.16'
        @($rule.destinationPorts) | Should -Contain '53'
        $rule.sourceAddresses | Should -Be "[parameters('spokeAddressPrefixes')]"
    }

    It 'allows spoke traffic to the AzureMonitor and AzureResourceManager service tags on 443' {
        $rule = $dns.properties.ruleCollections[1].rules[0]
        @($rule.destinationAddresses) | Should -Contain 'AzureMonitor'
        @($rule.destinationAddresses) | Should -Contain 'AzureResourceManager'
        @($rule.destinationPorts) | Should -Contain '443'
    }
}

Describe 'Admin sessions from VPN clients (Phase 3)' {
    BeforeAll {
        $rule = $admin.properties.ruleCollections[0].rules[0]
    }

    It 'is always deployed so enabling admin access never reorders the group chain' {
        $admin.PSObject.Properties.Name | Should -Not -Contain 'condition'
    }

    It 'allows only SSH and RDP from the VPN client pools to the management subnet' {
        $admin.properties.ruleCollections[0].action.type | Should -Be 'Allow'
        $rule.ruleType | Should -Be 'NetworkRule'
        @($rule.ipProtocols) -join ',' | Should -Be 'TCP'
        $rule.sourceAddresses | Should -Be "[parameters('vpnClientAddressPrefixes')]"
        $rule.destinationAddresses | Should -Be "[parameters('managementAddressPrefixes')]"
        @($rule.destinationPorts) -join ',' | Should -Be '22,3389'
    }
}

Describe 'Entra ID sign-in egress for the jump host (Phase 3)' {
    BeforeAll {
        $collection = $platform.properties.ruleCollections | Where-Object { $_.name -eq 'entra-login' }
        $rule = $collection.rules[0]
    }

    It 'allows the Entra login endpoints from the management subnet only, over HTTPS' {
        $rule.sourceAddresses | Should -Be "[parameters('managementAddressPrefixes')]"
        @($rule.protocols.protocolType) -join ',' | Should -Be 'Https'
    }

    It 'derives the login host from the cloud environment instead of hardcoding it' {
        $template.variables.entraLoginHost | Should -Be "[split(environment().authentication.loginEndpoint, '/')[2]]"
        @($rule.targetFqdns) | Should -Contain "[variables('entraLoginHost')]"
        @($rule.targetFqdns) | Should -Contain "[format('device.{0}', variables('entraLoginHost'))]"
    }

    It 'allows the device registration, pas.windows.net and extension package endpoints' {
        foreach ($fqdn in 'pas.windows.net', 'packages.microsoft.com', 'enterpriseregistration.windows.net') {
            @($rule.targetFqdns) | Should -Contain $fqdn
        }
    }
}

Describe 'Defender for Endpoint egress for the jump host (Phase 7)' {
    BeforeAll {
        $collection = $platform.properties.ruleCollections | Where-Object { $_.name -eq 'defender-for-endpoint' }
        $rule = @($collection.rules | Where-Object { $_.name -eq 'defender-for-endpoint' })
    }

    It 'allows the Defender for Endpoint streamlined endpoint from the management subnet only, over HTTPS 443' {
        $collection.action.type | Should -Be 'Allow'
        $rule.Count | Should -Be 1
        $rule[0].ruleType | Should -Be 'ApplicationRule'
        $rule[0].sourceAddresses | Should -Be "[parameters('managementAddressPrefixes')]"
        @($rule[0].protocols.protocolType) -join ',' | Should -Be 'Https'
        @($rule[0].protocols.port) -join ',' | Should -Be '443'
        @($rule[0].targetFqdns) -join ',' | Should -BeExactly '*.endpoint.security.microsoft.com'
    }

    It 'leaves TLS unterminated, since the policy does no TLS inspection (ADR-011)' {
        $rule[0].PSObject.Properties.Name | Should -Not -Contain 'terminateTLS'
    }

    It 'is present in every stamp, since every stamp has a management subnet' {
        $platform.PSObject.Properties.Name | Should -Not -Contain 'condition'
        $firewallTemplate = Get-BicepTemplate -RelativePath 'modules/azureFirewall.bicep'
        $rulesModule = Get-ModuleDeployment -Template $firewallTemplate -Name 'firewall-policy-rules'
        $rulesModule.PSObject.Properties.Name | Should -Not -Contain 'condition'
        $rulesModule.properties.parameters.managementAddressPrefixes.value | Should -Be "[parameters('managementAddressPrefixes')]"
        $stampTemplate = Get-BicepTemplate -RelativePath 'modules/regionStamp.bicep'
        $firewallModule = Get-TemplateResourceBySymbol -Template $stampTemplate -Symbol 'azureFirewall'
        $firewallModule.PSObject.Properties.Name | Should -Not -Contain 'condition'
        @($firewallModule.properties.parameters.managementAddressPrefixes.value) | Should -Be @("[parameters('addressPlan').managementSubnetPrefix]")
        (Get-TemplateResourceBySymbol -Template $stampTemplate -Symbol 'spokeNetwork').properties.parameters.virtualMachineSubnetAddressPrefix.value |
            Should -Be "[parameters('addressPlan').managementSubnetPrefix]"
    }
}

Describe 'OS update egress for management VMs only' {
    BeforeAll {
        $rules = @($platform.properties.ruleCollections[0].rules)
        $windows = $rules | Where-Object { $_.name -eq 'windows-update' }
        $ubuntu = $rules | Where-Object { $_.name -eq 'ubuntu-archives' }
    }

    It 'sources every OS update rule from the management subnet, never the whole spoke' {
        foreach ($rule in $rules) {
            $rule.sourceAddresses | Should -Be "[parameters('managementAddressPrefixes')]"
        }
    }

    It 'allows Windows Update through its FQDN tag' {
        @($windows.fqdnTags) | Should -Contain 'WindowsUpdate'
    }

    It 'allows the Ubuntu archives over HTTP and HTTPS' {
        @($ubuntu.targetFqdns) | Should -Contain 'archive.ubuntu.com'
        @($ubuntu.targetFqdns) | Should -Contain 'security.ubuntu.com'
        @($ubuntu.targetFqdns) | Should -Contain 'azure.archive.ubuntu.com'
        @($ubuntu.protocols.port) -join ',' | Should -Be '80,443'
    }
}

Describe 'Application allowlist' {
    It 'is deployed only when allowedOutboundFqdns is not empty' {
        $approved.condition | Should -Be "[not(empty(parameters('allowedOutboundFqdns')))]"
        $approved.properties.ruleCollections[0].rules[0].targetFqdns | Should -Be "[parameters('allowedOutboundFqdns')]"
    }
}

Describe 'Cross-region Azure Monitor traffic over the hub peering (Phase 6)' {
    BeforeAll {
        $crossRegion = Get-Group 'cross-region-monitoring'
        $collections = @($crossRegion.properties.ruleCollections)
        $hostCollection = $collections | Where-Object { $_.name -eq 'peer-spoke-to-azure-monitor' }
        $clientCollection = $collections | Where-Object { $_.name -eq 'spoke-to-peer-azure-monitor' }
    }

    It 'is deployed only when this region takes part (role Host or Client), after every other group' {
        $template.parameters.monitorPeeringRole.defaultValue | Should -Be 'None'
        @($template.parameters.monitorPeeringRole.allowedValues) -join ',' | Should -Be 'None,Host,Client'
        $crossRegion.condition | Should -Be "[not(equals(parameters('monitorPeeringRole'), 'None'))]"
        $crossRegion.properties.priority | Should -Be 250
        @($crossRegion.dependsOn) | Should -Contain "[resourceId('Microsoft.Network/firewallPolicies/ruleCollectionGroups', parameters('firewallPolicyName'), 'platform-egress')]"
        @($crossRegion.dependsOn) | Should -Contain "[resourceId('Microsoft.Network/firewallPolicies/ruleCollectionGroups', parameters('firewallPolicyName'), 'approved-https-egress')]"
    }

    It 'renders exactly one collection, chosen by role' {
        $crossRegion.properties.ruleCollections | Should -Match "^\[if\(equals\(parameters\('monitorPeeringRole'\), 'Host'\)"
    }

    It 'Host (owns the AMPLS endpoint): allows the other region''s spoke subnets to Azure Monitor FQDNs as an application rule, which SNATs for a symmetric return path' {
        $rule = $template.variables.monitorHostCollection.rules[0]
        $rule.ruleType | Should -Be 'ApplicationRule'
        $rule.sourceAddresses | Should -Be "[parameters('monitorClientPrefixes')]"
        @($rule.protocols.protocolType) -join ',' | Should -Be 'Https'
        @($rule.protocols.port) -join ',' | Should -Be '443'
        $expected = @('*.applicationinsights.azure.com', '*.monitor.azure.com', '*.ods.opinsights.azure.com', '*.oms.opinsights.azure.com', '*.agentsvc.azure-automation.net') | Sort-Object
        (@($rule.targetFqdns) | Sort-Object) -join ',' | Should -BeExactly ($expected -join ',')
    }

    It 'Client (forwards to the peer region): allows only its spoke subnets to the AMPLS endpoint subnet on TCP 443 as a network rule' {
        $rule = $template.variables.monitorClientCollection.rules[0]
        $rule.ruleType | Should -Be 'NetworkRule'
        @($rule.ipProtocols) -join ',' | Should -Be 'TCP'
        $rule.sourceAddresses | Should -Be "[parameters('monitorClientPrefixes')]"
        $rule.destinationAddresses | Should -Be "[parameters('monitorPrivateEndpointPrefixes')]"
        @($rule.destinationPorts) -join ',' | Should -Be '443'
    }

    It 'allows, never denies' {
        $template.variables.monitorHostCollection.action.type | Should -Be 'Allow'
        $template.variables.monitorClientCollection.action.type | Should -Be 'Allow'
    }
}
