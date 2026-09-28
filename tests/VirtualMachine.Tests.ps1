BeforeAll {
    Import-Module (Join-Path $PSScriptRoot 'Bicep.TestHelpers.psm1') -Force
    $template = Get-BicepTemplate -RelativePath 'modules/virtualMachine.bicep'
}

Describe 'VM NIC NSG management access (F1)' {
    It 'exposes managementSourceCidrs defaulting to an empty list' {
        $template.parameters.PSObject.Properties.Name | Should -Contain 'managementSourceCidrs'
        @($template.parameters.managementSourceCidrs.defaultValue).Count | Should -Be 0
    }
}

Describe 'VM monitoring (F3)' {
    BeforeAll {
        $diagnostics = Get-TemplateResource -Template $template -Type 'Microsoft.Insights/diagnosticSettings' | Select-Object -First 1
        $dcr = Get-TemplateResource -Template $template -Type 'Microsoft.Insights/dataCollectionRules' | Select-Object -First 1
        $association = Get-TemplateResource -Template $template -Type 'Microsoft.Insights/dataCollectionRuleAssociations' | Select-Object -First 1
        $agent = Get-TemplateResource -Template $template -Type 'Microsoft.Compute/virtualMachines/extensions' | Select-Object -First 1
    }

    It 'sends only metrics through the VM diagnostic setting (VMs expose no log categories)' {
        $diagnostics.properties.PSObject.Properties.Name | Should -Not -Contain 'logs'
        $diagnostics.properties.metrics[0].category | Should -Be 'AllMetrics'
    }

    It 'installs the Azure Monitor Agent' {
        $agent.properties.publisher | Should -Be 'Microsoft.Azure.Monitor'
        $agent.properties.enableAutomaticUpgrade | Should -BeTrue
    }

    It 'sends guest logs and performance counters to the workspace through a DCR' {
        $dcr.properties.destinations.logAnalytics[0].workspaceResourceId | Should -Be "[parameters('logAnalyticsWorkspaceId')]"
    }

    It 'associates the DCR with the VM' {
        $association.scope | Should -Match 'virtualMachines'
    }

    It 'outputs the DCR ID' {
        $template.outputs.PSObject.Properties.Name | Should -Contain 'dataCollectionRuleId'
    }

    It 'uses Azure Monitor counter paths with a leading backslash' {
        # dataSources compiles to the expression '[union(variables(...), variables(...))]' rather than
        # an inline object, so the literal counter text lives in the performanceCounterSource variable.
        $dcrText = $template.variables.performanceCounterSource | ConvertTo-Json -Depth 10
        $dcrText | Should -Match ([regex]::Escape('\\Processor(*)\\% Processor Time'))
    }
}
