BeforeAll {
    Import-Module (Join-Path $PSScriptRoot 'Bicep.TestHelpers.psm1') -Force
    $template = Get-BicepTemplate -RelativePath 'modules/global.bicep'
    $zones = Get-TemplateResource -Template $template -Type 'Microsoft.Network/privateDnsZones'
    $locks = Get-TemplateResource -Template $template -Type 'Microsoft.Authorization/locks'
    $monitoring = Get-ModuleDeployment -Template $template -Name 'monitoring'
}

Describe 'Global layer private DNS zones' {
    It 'creates exactly the blob, sites, and vault zones named by the entry point' {
        $zones.Count | Should -Be 3
        foreach ($key in 'blob', 'sites', 'vault') {
            @($zones.name) | Should -Contain "[parameters('privateDnsZoneNames').$key]"
        }
    }

    It 'locks every zone only when deletion protection is requested' {
        $locks.Count | Should -Be 3
        foreach ($lock in $locks) {
            $lock.condition | Should -Be "[parameters('enableDeleteLock')]"
            $lock.properties.level | Should -Be 'CanNotDelete'
        }
    }

    It 'outputs the zone IDs keyed by private endpoint group' {
        @($template.outputs.privateDnsZoneIds.value.PSObject.Properties.Name) | Should -Be @('blob', 'sites', 'vault')
    }
}

Describe 'Global layer workspace' {
    It 'passes replication and deletion protection through to the monitoring module' {
        $monitoring.properties.parameters.replicationLocation.value | Should -Be "[parameters('workspaceReplicationLocation')]"
        $monitoring.properties.parameters.enableDeleteLock.value | Should -Be "[parameters('enableDeleteLock')]"
    }

    It 'disables workspace replication by default' {
        $template.parameters.workspaceReplicationLocation.defaultValue | Should -BeExactly ''
    }
}
