BeforeAll {
    Import-Module (Join-Path $PSScriptRoot 'Bicep.TestHelpers.psm1') -Force
    $template = Get-BicepTemplate -RelativePath 'modules/azureFirewall.bicep'
    $firewall = Get-TemplateResource -Template $template -Type 'Microsoft.Network/azureFirewalls' | Select-Object -First 1
    $publicIp = Get-TemplateResource -Template $template -Type 'Microsoft.Network/publicIPAddresses' | Select-Object -First 1
    $policy = Get-TemplateResource -Template $template -Type 'Microsoft.Network/firewallPolicies' | Select-Object -First 1
    $diagnostics = Get-TemplateResource -Template $template -Type 'Microsoft.Insights/diagnosticSettings' | Select-Object -First 1
    $locks = Get-TemplateResource -Template $template -Type 'Microsoft.Authorization/locks'
    $rules = Get-ModuleDeployment -Template $template -Name 'firewall-policy-rules'
}

Describe 'Azure Firewall availability (F9)' {
    It 'accepts availability zones for the firewall and public IP, defaulting to none for in-place safety' {
        @($template.parameters.availabilityZones.defaultValue).Count | Should -Be 0
        $firewall.zones | Should -Match 'availabilityZones'
        $publicIp.zones | Should -Match 'availabilityZones'
    }

    It 'declares the firewall SKU explicitly' {
        $firewall.properties.sku.name | Should -Be 'AZFW_VNet'
    }
}

Describe 'Azure Firewall Premium (Phase 2)' {
    It 'defaults the firewall and its policy to the Premium tier, from one parameter' {
        $template.parameters.firewallTier.defaultValue | Should -Be 'Premium'
        $firewall.properties.sku.tier | Should -Be "[parameters('firewallTier')]"
        $policy.properties.sku.tier | Should -Be "[parameters('firewallTier')]"
    }

    It 'enables IDPS on Premium policies only, defaulting to Deny' {
        $template.parameters.idpsMode.defaultValue | Should -Be 'Deny'
        $policy.properties.intrusionDetection | Should -Be "[if(variables('isPremium'), createObject('mode', parameters('idpsMode')), null())]"
    }
}

Describe 'Azure Firewall threat protection (F9)' {
    It 'defaults threat intelligence to Deny' {
        $template.parameters.threatIntelMode.defaultValue | Should -Be 'Deny'
        $policy.properties.threatIntelMode | Should -Be "[parameters('threatIntelMode')]"
    }
}

Describe 'Azure Firewall rules wiring (ADR-010)' {
    It 'takes its rule collection groups from the shared rules module' {
        $rules.properties.parameters.firewallPolicyName.value | Should -Be "[parameters('firewallPolicyName')]"
        $rules.properties.parameters.managementAddressPrefixes.value | Should -Be "[parameters('managementAddressPrefixes')]"
        @(Get-TemplateResource -Template $template -Type 'Microsoft.Network/firewallPolicies/ruleCollectionGroups').Count | Should -Be 0
    }

    It 'attaches the firewall only after every rule collection group exists' {
        @($firewall.dependsOn) | Should -Contain "[resourceId('Microsoft.Resources/deployments', 'firewall-policy-rules')]"
    }
}

Describe 'Azure Firewall logging (F9)' {
    It 'writes to resource-specific (dedicated) Log Analytics tables' {
        $diagnostics.properties.logAnalyticsDestinationType | Should -Be 'Dedicated'
    }
}

Describe 'Azure Firewall deletion protection (Phase 2)' {
    It 'locks the firewall, its policy and its public IP only when requested' {
        $locks.Count | Should -Be 3
        foreach ($lock in $locks) {
            $lock.condition | Should -Be "[parameters('enableDeleteLock')]"
            $lock.properties.level | Should -Be 'CanNotDelete'
        }
        $template.parameters.enableDeleteLock.defaultValue | Should -BeExactly $false
    }
}
