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

Describe 'Spoke CIDR single source of truth (F5)' {
    It 'firewall spoke source ranges come from spokeVnetAddressSpace' {
        (Get-ModuleDeployment -Template $main -Name 'azure-firewall').properties.parameters.spokeAddressPrefixes.value |
            Should -Be "[parameters('spokeVnetAddressSpace')]"
    }

    It 'spoke VNet address space comes from spokeVnetAddressSpace' {
        (Get-ModuleDeployment -Template $main -Name 'spoke-network').properties.parameters.vnetAddressSpace.value |
            Should -Be "[parameters('spokeVnetAddressSpace')]"
    }

    It 'private endpoint sources are derived from the App Service and management subnet prefixes' {
        $value = (Get-ModuleDeployment -Template $main -Name 'spoke-network').properties.parameters.approvedPrivateEndpointSourceCidrs.value
        $value | Should -Match 'appServiceIntegrationSubnetAddressPrefix'
        $value | Should -Match 'virtualMachineSubnetAddressPrefix'
        $value | Should -Match 'additionalPrivateEndpointSourceCidrs'
    }

    It 'no longer exposes approvedPrivateEndpointSourceCidrs' {
        $main.parameters.PSObject.Properties.Name | Should -Not -Contain 'approvedPrivateEndpointSourceCidrs'
    }
}

Describe 'Firewall threat intelligence wiring (F9)' {
    It 'uses Deny in prod and Alert elsewhere' {
        (Get-ModuleDeployment -Template $main -Name 'azure-firewall').properties.parameters.threatIntelMode |
            Should -Be "[if(equals(parameters('environmentType'), 'prod'), createObject('value', 'Deny'), createObject('value', 'Alert'))]"
    }
}

Describe 'Key Vault wiring (F4)' {
    It 'enables template deployment for the composed stack so az.getSecret() references resolve' {
        (Get-ModuleDeployment -Template $main -Name 'key-vault').properties.parameters.enabledForTemplateDeployment.value | Should -BeTrue
    }
}

Describe 'Storage RBAC wiring (F11)' {
    It 'passes the container name from the storage module output' {
        (Get-ModuleDeployment -Template $main -Name 'network-integration').properties.parameters.storageContainerName.value |
            Should -Match "outputs.blobContainerName"
    }
}
