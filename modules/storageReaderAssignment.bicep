// Read-only data access for another region's App Service identity on this region's application container.

@description('Storage account name in this resource group.')
@minLength(3)
@maxLength(24)
param storageAccountName string

@description('Blob container the reader may read.')
@minLength(3)
@maxLength(63)
param storageContainerName string

@description('Principal ID of the App Service managed identity that reads the container.')
param readerPrincipalId string

@description('Name of the App Service that owns the identity, used to make the assignment GUID deterministic.')
@minLength(2)
@maxLength(60)
param readerAppServiceName string

var storageBlobDataReaderRoleId = '2a2b9908-6ea1-4ae2-8e65-a410df84e7d1'

resource storageAccount 'Microsoft.Storage/storageAccounts@2026-04-01' existing = {
  name: storageAccountName

  resource blobService 'blobServices' existing = {
    name: 'default'

    resource container 'containers' existing = {
      name: storageContainerName
    }
  }
}

resource readerAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storageAccount.id, storageContainerName, readerAppServiceName, storageBlobDataReaderRoleId)
  scope: storageAccount::blobService::container
  properties: {
    principalId: readerPrincipalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', storageBlobDataReaderRoleId)
  }
}
