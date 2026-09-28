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

@description('Days that deleted blobs and containers are recoverable. Point-in-time restore covers one day less.')
@minValue(7)
@maxValue(365)
param blobSoftDeleteRetentionDays int = 14

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
    networkAcls: {
      defaultAction: 'Deny'
      bypass: 'AzureServices'
    }
  }
  resource service 'blobServices' = {
    name: 'default'
    properties: {
      isVersioningEnabled: true
      changeFeed: {
        enabled: true
        retentionInDays: blobSoftDeleteRetentionDays
      }
      deleteRetentionPolicy: {
        enabled: true
        days: blobSoftDeleteRetentionDays
      }
      containerDeleteRetentionPolicy: {
        enabled: true
        days: blobSoftDeleteRetentionDays
      }
      restorePolicy: {
        enabled: true
        days: blobSoftDeleteRetentionDays - 1
      }
    }

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

// Blob read, write, and delete audit logs; account-level settings expose metrics only.
resource blobDiagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  scope: storageAccount::service
  name: 'blob-diagnostics'
  properties: {
    workspaceId: logAnalyticsWorkspaceId
    logs: [
      {
        categoryGroup: 'allLogs'
        enabled: true
      }
    ]
    metrics: [
      {
        category: 'Transaction'
        enabled: true
      }
    ]
  }
}

output id string = storageAccount.id
output name string = storageAccount.name
output blobContainerName string = storageAccount::service::blob.name
