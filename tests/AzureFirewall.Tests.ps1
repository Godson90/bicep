BeforeAll {
    Import-Module (Join-Path $PSScriptRoot 'Bicep.TestHelpers.psm1') -Force
    $template = Get-BicepTemplate -RelativePath 'modules/azureFirewall.bicep'
    $firewall = Get-TemplateResource -Template $template -Type 'Microsoft.Network/azureFirewalls' | Select-Object -First 1
    $publicIp = Get-TemplateResource -Template $template -Type 'Microsoft.Network/publicIPAddresses' | Select-Object -First 1
    $policy = Get-TemplateResource -Template $template -Type 'Microsoft.Network/firewallPolicies' | Select-Object -First 1
    $ruleGroups = Get-TemplateResource -Template $template -Type 'Microsoft.Network/firewallPolicies/ruleCollectionGroups'
    $diagnostics = Get-TemplateResource -Template $template -Type 'Microsoft.Insights/diagnosticSettings' | Select-Object -First 1
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

Describe 'Azure Firewall threat protection (F9)' {
    It 'defaults threat intelligence to Deny' {
        $template.parameters.threatIntelMode.defaultValue | Should -Be 'Deny'
        $policy.properties.threatIntelMode | Should -Be "[parameters('threatIntelMode')]"
    }
}

Describe 'Azure Firewall logging (F9)' {
    It 'writes to resource-specific (dedicated) Log Analytics tables' {
        $diagnostics.properties.logAnalyticsDestinationType | Should -Be 'Dedicated'
    }
}

Describe 'Azure Monitor egress' {
    It 'allows spoke traffic to the AzureMonitor service tag on 443' {
        $rules = @($ruleGroups.properties.ruleCollections.rules | Where-Object { $_.ruleType -eq 'NetworkRule' })
        $monitorRule = $rules | Where-Object { @($_.destinationAddresses) -contains 'AzureMonitor' }
        $monitorRule | Should -Not -BeNullOrEmpty
        @($monitorRule.destinationPorts) | Should -Contain '443'
    }
}
