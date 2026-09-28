BeforeAll {
    Import-Module (Join-Path $PSScriptRoot 'Bicep.TestHelpers.psm1') -Force
    $template = Get-BicepTemplate -RelativePath 'modules/keyVault.bicep'
    $vault = Get-TemplateResource -Template $template -Type 'Microsoft.KeyVault/vaults' | Select-Object -First 1
    $privateConnectivity = Get-BicepTemplate -RelativePath 'modules/privateConnectivity.bicep'
}

Describe 'Key Vault template deployment access (F4)' {
    It 'is off by default for standalone reuse' {
        $template.parameters.enabledForTemplateDeployment.defaultValue | Should -BeExactly $false
        $vault.properties.enabledForTemplateDeployment | Should -Be "[parameters('enabledForTemplateDeployment')]"
    }

    It 'keeps public network access disabled' {
        $vault.properties.publicNetworkAccess | Should -Be 'Disabled'
    }

    It 'bypasses the firewall for trusted Azure services only when template deployment is enabled, otherwise denies by default' {
        $vault.properties.networkAcls.bypass | Should -Match 'enabledForTemplateDeployment'
        $vault.properties.networkAcls.bypass | Should -Match 'AzureServices'
        $vault.properties.networkAcls.defaultAction | Should -Be 'Deny'
    }
}

Describe 'Private connectivity outputs (F12)' {
    It 'outputs the Key Vault private endpoint ID' {
        $privateConnectivity.outputs.PSObject.Properties.Name | Should -Contain 'keyVaultPrivateEndpointId'
    }
}
