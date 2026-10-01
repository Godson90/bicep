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
    It 'defines the dns-egress, admin-access, platform-egress and approved-https-egress groups at priorities 100, 120, 150, 200' {
        $groups.Count | Should -Be 4
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
