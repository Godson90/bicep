// VNet flow logs with Traffic Analytics. Deployed into NetworkWatcherRG, which holds the subscription's single
// Network Watcher per region (NetworkWatcher_<region>); the watcher is referenced, never created.
import { virtualNetworkReference } from 'types.bicep'

@description('Azure region of the VNets, their Network Watcher and the flow-log storage account.')
param location string

@description('VNets to record. Each gets one flow log named <vnet>-flowlog.')
param virtualNetworks virtualNetworkReference[]

@description('Flow-log storage account resource ID, in the same region as the VNets.')
param storageAccountId string

@description('User-assigned identity resource ID with Storage Blob Data Contributor on the flow-log account.')
param identityId string

@description('Central Log Analytics workspace resource ID that receives Traffic Analytics.')
param logAnalyticsWorkspaceId string

@description('Days of flow records kept in the storage account.')
@minValue(1)
@maxValue(365)
param retentionDays int = 90

@description('Traffic Analytics processing interval in minutes.')
@allowed([
  10
  60
])
param trafficAnalyticsIntervalMinutes int = 10

resource networkWatcher 'Microsoft.Network/networkWatchers@2024-07-01' existing = {
  name: 'NetworkWatcher_${location}'
}

// Traffic Analytics needs the workspace's customer ID and region as well as its resource ID.
resource workspace 'Microsoft.OperationalInsights/workspaces@2026-03-01' existing = {
  name: last(split(logAnalyticsWorkspaceId, '/'))
  scope: resourceGroup(split(logAnalyticsWorkspaceId, '/')[2], split(logAnalyticsWorkspaceId, '/')[4])
}

// Shared key is disabled on the account, so the flow logs write with the user-assigned identity.
resource flowLogs 'Microsoft.Network/networkWatchers/flowLogs@2024-07-01' = [for vnet in virtualNetworks: {
  parent: networkWatcher
  name: '${vnet.name}-flowlog'
  location: location
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${identityId}': {}
    }
  }
  properties: {
    targetResourceId: vnet.id
    storageId: storageAccountId
    enabled: true
    format: {
      type: 'JSON'
      version: 2
    }
    retentionPolicy: {
      enabled: true
      days: retentionDays
    }
    flowAnalyticsConfiguration: {
      networkWatcherFlowAnalyticsConfiguration: {
        enabled: true
        workspaceResourceId: logAnalyticsWorkspaceId
        workspaceId: workspace.properties.customerId
        workspaceRegion: workspace.location
        trafficAnalyticsInterval: trafficAnalyticsIntervalMinutes
      }
    }
  }
}]
