BeforeAll {
    Import-Module (Join-Path $PSScriptRoot 'Bicep.TestHelpers.psm1') -Force
    $template = Get-BicepTemplate -RelativePath 'modules/bastion.bicep'
    $bastion = Get-TemplateResource -Template $template -Type 'Microsoft.Network/bastionHosts' | Select-Object -First 1
    $publicIp = Get-TemplateResource -Template $template -Type 'Microsoft.Network/publicIPAddresses' | Select-Object -First 1
    $diagnostics = Get-TemplateResource -Template $template -Type 'Microsoft.Insights/diagnosticSettings' | Select-Object -First 1
}

Describe 'Azure Bastion (Phase 3)' {
    It 'uses the Standard SKU so native client and IP-based connect work' {
        $bastion.sku.name | Should -Be 'Standard'
        $bastion.properties.enableTunneling | Should -BeExactly $true
        $bastion.properties.enableIpConnect | Should -BeExactly $true
    }

    It 'spreads Bastion and its public IP across the requested zones' {
        $bastion.zones | Should -Be "[if(empty(parameters('availabilityZones')), null(), parameters('availabilityZones'))]"
        $publicIp.zones | Should -Be "[if(empty(parameters('availabilityZones')), null(), parameters('availabilityZones'))]"
        $publicIp.sku.name | Should -Be 'Standard'
    }

    It 'sends the session audit logs to the central workspace' {
        $diagnostics.properties.workspaceId | Should -Be "[parameters('logAnalyticsWorkspaceId')]"
        $diagnostics.properties.logs[0].categoryGroup | Should -Be 'allLogs'
    }
}
