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

// One set of private DNS zones for all regions; each region links its hub and spoke VNets.
resource blobZone 'Microsoft.Network/privateDnsZones@2024-06-01' = {
  name: privateDnsZoneNames.blob
  location: 'global'
}

resource sitesZone 'Microsoft.Network/privateDnsZones@2024-06-01' = {
  name: privateDnsZoneNames.sites
  location: 'global'
}

resource vaultZone 'Microsoft.Network/privateDnsZones@2024-06-01' = {
  name: privateDnsZoneNames.vault
  location: 'global'
}

resource blobZoneLock 'Microsoft.Authorization/locks@2020-05-01' = if (enableDeleteLock) {
  scope: blobZone
  name: 'blob-zone-lck'
  properties: {
    level: 'CanNotDelete'
  }
}

resource sitesZoneLock 'Microsoft.Authorization/locks@2020-05-01' = if (enableDeleteLock) {
  scope: sitesZone
  name: 'sites-zone-lck'
  properties: {
    level: 'CanNotDelete'
  }
}

resource vaultZoneLock 'Microsoft.Authorization/locks@2020-05-01' = if (enableDeleteLock) {
  scope: vaultZone
  name: 'vault-zone-lck'
  properties: {
    level: 'CanNotDelete'
  }
}

output logAnalyticsWorkspaceId string = monitoring.outputs.id
output privateDnsZoneIds privateDnsZoneSet = {
  blob: blobZone.id
  sites: sitesZone.id
  vault: vaultZone.id
}
