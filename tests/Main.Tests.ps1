BeforeAll {
    Import-Module (Join-Path $PSScriptRoot 'Bicep.TestHelpers.psm1') -Force
    $main = Get-BicepTemplate -RelativePath 'main.bicep'
}

Describe 'Management access wiring (F1)' {
    It 'passes managementSourceCidrs to <_>' -ForEach 'spoke-network', 'virtual-machine' {
        $deployment = Get-ModuleDeployment -Template $main -Name $_
        $deployment.properties.parameters.managementSourceCidrs.value | Should -Be "[parameters('managementSourceCidrs')]"
    }
}
