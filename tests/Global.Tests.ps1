BeforeAll {
    Import-Module (Join-Path $PSScriptRoot 'Bicep.TestHelpers.psm1') -Force
    $template = Get-BicepTemplate -RelativePath 'modules/global.bicep'
    $zones = Get-TemplateResource -Template $template -Type 'Microsoft.Network/privateDnsZones' | Select-Object -First 1
    $locks = Get-TemplateResource -Template $template -Type 'Microsoft.Authorization/locks' | Select-Object -First 1
    $monitoring = Get-ModuleDeployment -Template $template -Name 'monitoring'
    $zoneKeys = 'agentsvc', 'blob', 'monitor', 'ods', 'oms', 'sites', 'vault'
}

Describe 'Global layer private DNS zones' {
    It 'creates one zone for every name in the shared zone set, so a new zone needs no new resource' {
        $zones.copy.count | Should -Be "[length(items(parameters('privateDnsZoneNames')))]"
        $zones.name | Should -Be "[items(parameters('privateDnsZoneNames'))[copyIndex()].value]"
        $zones.location | Should -Be 'global'
    }

    It 'locks every zone only when deletion protection is requested, keeping the existing per-group lock names' {
        $locks.copy.count | Should -Be "[length(items(parameters('privateDnsZoneNames')))]"
        $locks.condition | Should -Be "[parameters('enableDeleteLock')]"
        $locks.name | Should -Be "[format('{0}-zone-lck', items(parameters('privateDnsZoneNames'))[copyIndex()].key)]"
        $locks.properties.level | Should -Be 'CanNotDelete'
    }

    It 'outputs the zone IDs keyed by private endpoint group' {
        $template.outputs.privateDnsZoneIds.value | Should -Match "^\[toObject\(items\(parameters\('privateDnsZoneNames'\)\)"
        $template.outputs.privateDnsZoneIds.value | Should -Match "resourceId\('Microsoft.Network/privateDnsZones'"
    }

    It 'types the zone set with the application and Azure Monitor (AMPLS) groups (Phase 6)' {
        $properties = $template.definitions.privateDnsZoneSet.properties.PSObject.Properties.Name
        @($properties | Sort-Object) | Should -Be @($zoneKeys)
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
