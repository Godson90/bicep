BeforeAll {
    Import-Module (Join-Path $PSScriptRoot 'Bicep.TestHelpers.psm1') -Force
    $template = Get-BicepTemplate -RelativePath 'modules/networkIntegration.bicep'
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
