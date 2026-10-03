@description('Azure region for the Log Analytics workspace.')
param location string

@description('Globally unique Log Analytics workspace name within the resource group.')
@minLength(4)
@maxLength(63)
param workspaceName string

@description('Number of days to retain workspace data. 90 days matches the retention included with Microsoft Sentinel.')
@minValue(30)
@maxValue(730)
param retentionInDays int = 90

@description('Region that holds the workspace replica for regional failover. Empty disables replication (sends enabled: false).')
param replicationLocation string = ''

@description('Apply a CanNotDelete lock to the workspace.')
param enableDeleteLock bool = false

// Central workspace for platform, network, storage, and application diagnostics. Agents and queries reach it
// only through the Azure Monitor Private Link Scope; diagnostic settings use Azure's internal path (F10, Phase 6).
resource logAnalyticsWorkspace 'Microsoft.OperationalInsights/workspaces@2026-03-01' = {
  name: workspaceName
  location: location
  properties: {
    retentionInDays: retentionInDays
    publicNetworkAccessForIngestion: 'Disabled'
    publicNetworkAccessForQuery: 'Disabled'
    sku: {
      name: 'PerGB2018'
    }
    replication: {
      enabled: !empty(replicationLocation)
      location: empty(replicationLocation) ? null : replicationLocation
    }
  }
}

resource workspaceLock 'Microsoft.Authorization/locks@2020-05-01' = if (enableDeleteLock) {
  scope: logAnalyticsWorkspace
  name: '${workspaceName}-lck'
  properties: {
    level: 'CanNotDelete'
  }
}

output id string = logAnalyticsWorkspace.id
output name string = logAnalyticsWorkspace.name
