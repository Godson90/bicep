BeforeAll {
    Import-Module (Join-Path $PSScriptRoot 'Bicep.TestHelpers.psm1') -Force
    $template = Get-BicepTemplate -RelativePath 'modules/networkIntegration.bicep'
    $peerings = Get-TemplateResource -Template $template -Type 'Microsoft.Network/virtualNetworks/virtualNetworkPeerings'
    $hubToSpoke = $peerings | Where-Object { $_.name -like "*'hub-to-spoke')]" }
    $spokeToHub = $peerings | Where-Object { $_.name -like "*'spoke-to-hub')]" }
    $roleAssignment = Get-TemplateResource -Template $template -Type 'Microsoft.Authorization/roleAssignments' | Select-Object -First 1
}

Describe 'App Service storage RBAC scope (F11)' {
    It 'assigns Storage Blob Data Contributor at container scope, not account scope' {
        $roleAssignment.scope | Should -Match 'containers'
    }

    It 'includes the container in the deterministic assignment name' {
        $roleAssignment.name | Should -Match 'storageContainerName'
    }
}

Describe 'Gateway transit (Phase 3)' {
    It 'is off by default (the spoke peering fails when the hub has no gateway)' {
        $template.parameters.useHubGateway.defaultValue | Should -BeExactly $false
    }

    It 'offers the hub gateway to the spoke and lets the spoke use it when enabled' {
        $hubToSpoke.properties.allowGatewayTransit | Should -Be "[parameters('useHubGateway')]"
        $hubToSpoke.properties.useRemoteGateways | Should -BeExactly $false
        $spokeToHub.properties.useRemoteGateways | Should -Be "[parameters('useHubGateway')]"
        $spokeToHub.properties.allowGatewayTransit | Should -BeExactly $false
    }
}
