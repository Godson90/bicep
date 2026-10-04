import { privateDnsZoneSet } from 'types.bicep'

@description('Azure region for the Log Analytics workspace (the primary region).')
param location string

@description('Log Analytics workspace name.')
@minLength(4)
@maxLength(63)
param workspaceName string

@description('Private DNS zone names shared by every region stamp.')
param privateDnsZoneNames privateDnsZoneSet

@description('Region that receives the workspace replica. Empty disables workspace replication.')
param workspaceReplicationLocation string = ''

@description('Apply CanNotDelete locks to the shared DNS zones and the workspace.')
param enableDeleteLock bool = false

// Central workspace for every region's diagnostics.
module monitoring 'monitoring.bicep' = {
  name: 'monitoring'
  params: {
    location: location
    workspaceName: workspaceName
    replicationLocation: workspaceReplicationLocation
    enableDeleteLock: enableDeleteLock
  }
}

// One set of private DNS zones for all regions; each region links its hub and spoke VNets. The set holds the
// application zones (blob, sites, vault) and, from Phase 6, the Azure Monitor Private Link Scope zones.
resource zones 'Microsoft.Network/privateDnsZones@2024-06-01' = [for zone in items(privateDnsZoneNames): {
  name: zone.value
  location: 'global'
}]

resource zoneLocks 'Microsoft.Authorization/locks@2020-05-01' = [for (zone, i) in items(privateDnsZoneNames): if (enableDeleteLock) {
  scope: zones[i]
  name: '${zone.key}-zone-lck'
  properties: {
    level: 'CanNotDelete'
  }
}]

output logAnalyticsWorkspaceId string = monitoring.outputs.id
output privateDnsZoneIds privateDnsZoneSet = toObject(
  items(privateDnsZoneNames),
  zone => zone.key,
  zone => resourceId('Microsoft.Network/privateDnsZones', zone.value)
)
