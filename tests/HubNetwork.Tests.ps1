BeforeAll {
    Import-Module (Join-Path $PSScriptRoot 'Bicep.TestHelpers.psm1') -Force
    $template = Get-BicepTemplate -RelativePath 'modules/hubNetwork.bicep'
    $lock = Get-TemplateResource -Template $template -Type 'Microsoft.Authorization/locks' | Select-Object -First 1
}

Describe 'Hub network deletion protection (Phase 2)' {
    It 'locks the hub VNet only when requested' {
        $template.parameters.enableDeleteLock.defaultValue | Should -BeExactly $false
        $lock.condition | Should -Be "[parameters('enableDeleteLock')]"
        $lock.properties.level | Should -Be 'CanNotDelete'
        $lock.scope | Should -Be "[resourceId('Microsoft.Network/virtualNetworks', parameters('vnetName'))]"
    }
}
