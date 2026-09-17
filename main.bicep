param location string = 'WestUS3'
param storageAccountName string = 'dfsk${uniqueString(resourceGroup().id)}'
param appServiceAppName string = 'defenstack-mvp${uniqueString(resourceGroup().id)}'
@allowed(
  [
    'prod'
    'dev'
    'test'
  ]
)
param environmentType string // Parameters for different environment deployment
var storageAccountSkuName = (environmentType == 'prod') ? 'Standard_GRS' : 'Standard_LRS'

// Storage account creation
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
    publicNetworkAccess: 'Disabled'
    supportsHttpsTrafficOnly: true
  }
  resource service 'blobServices' = {
    name: 'default'

    resource blob 'containers' = {
      name: 'def-blob'
    }
  }
}

// invoking the appService module 
module appService 'modules/appService.bicep' = {
  name: 'appService'
  params: {
    location: location
    appServiceAppName: appServiceAppName
    environmentType: environmentType
  }
}

output appServiceAppHostName string = appService.outputs.appServiceAppHostName
