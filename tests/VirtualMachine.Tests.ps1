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
