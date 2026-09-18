@description('Azure region for the Log Analytics workspace.')
param location string

@description('Globally unique Log Analytics workspace name within the resource group.')
@minLength(4)
@maxLength(63)
param workspaceName string

@description('Number of days to retain workspace data.')
param retentionInDays int = 30

// Central workspace for platform, network, storage, and application diagnostics.
resource logAnalyticsWorkspace 'Microsoft.OperationalInsights/workspaces@2026-03-01' = {
  name: workspaceName
  location: location
  properties: {
    retentionInDays: retentionInDays
    sku: {
      name: 'PerGB2018'
    }
  }
}

output id string = logAnalyticsWorkspace.id
output name string = logAnalyticsWorkspace.name
