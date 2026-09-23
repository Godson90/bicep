@description('Azure region for the storage account.')
param location string

@description('Globally unique storage account name.')
@minLength(3)
@maxLength(24)
param storageAccountName string

@description('Storage redundancy SKU selected for the deployment environment.')
param storageAccountSkuName string

@description('Log Analytics workspace resource ID for storage diagnostics.')
param logAnalyticsWorkspaceId string

// Private, OAuth-first storage account used by the application.
resource storageAccount 'Microsoft.Storage/storageAccounts@2026-04-01' = {
  name: storageAccountName
  location: location
  sku: {
    name: storageAccountSkuName
  }
  kind: 'StorageV2'
  properties: {
    accessTier: 'Hot'
    allowBlobPublicAccess: false
    allowSharedKeyAccess: false
    defaultToOAuthAuthentication: true
    minimumTlsVersion: 'TLS1_2'
    publicNetworkAccess: 'Disabled'
    supportsHttpsTrafficOnly: true
  }
  resource service 'blobServices' = {
    name: 'default'

    // Application container for deployment-managed blob data.
    resource blob 'containers' = {
      name: 'def-blob'
    }
  }
}

// Storage access and platform activity are sent to the central workspace.
resource storageDiagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  scope: storageAccount
  name: 'storage-diagnostics'
  properties: {
    workspaceId: logAnalyticsWorkspaceId
    metrics: [
      {
        category: 'AllMetrics'
        enabled: true
      }
    ]
  }
}

output id string = storageAccount.id
output name string = storageAccount.name
