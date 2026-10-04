// Regional destination for VNet flow logs: a dedicated keyless, private storage account and the user-assigned
// identity Network Watcher writes with. Flow-log storage must be in the same region as the VNets it records.

@description('Azure region for the account and identity (the VNets\' region).')
param location string

@description('Globally unique flow-log storage account name.')
@minLength(3)
@maxLength(24)
param storageAccountName string

@description('Storage redundancy SKU for the flow-log account.')
param storageAccountSkuName string

@description('User-assigned managed identity name used by the flow logs.')
@minLength(3)
@maxLength(128)
param identityName string

@description('Days that deleted flow-log blobs and containers stay recoverable.')
@minValue(1)
@maxValue(365)
param softDeleteRetentionDays int = 7

var storageBlobDataContributorRoleId = 'ba92f5b4-2d11-453d-a403-e96b0029c9fe'

// No shared key and no public network access: Network Watcher reaches it as a trusted Azure service and
// authenticates with the identity below (shared-key writes would fail).
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

  // Flow-log retention deletes old blobs; soft delete keeps a short window to recover from a mistaken delete.
  resource blobService 'blobServices' = {
    name: 'default'
    properties: {
      deleteRetentionPolicy: {
        enabled: true
        days: softDeleteRetentionDays
      }
      containerDeleteRetentionPolicy: {
        enabled: true
        days: softDeleteRetentionDays
      }
    }
  }
}

resource flowLogIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: identityName
  location: location
}

// The only permission Network Watcher needs from the identity, scoped to this account alone.
resource flowLogWriter 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storageAccount.id, flowLogIdentity.id, storageBlobDataContributorRoleId)
  scope: storageAccount
  properties: {
    principalId: flowLogIdentity.properties.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', storageBlobDataContributorRoleId)
  }
}

output id string = storageAccount.id
output identityId string = flowLogIdentity.id
