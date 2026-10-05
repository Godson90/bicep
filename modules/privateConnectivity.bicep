import { privateDnsZoneSet } from 'types.bicep'

@description('Azure region for private endpoint resources.')
param location string

@description('Storage account resource ID.')
param storageAccountId string

@description('Storage account name used for deterministic private endpoint naming.')
@minLength(3)
@maxLength(24)
param storageAccountName string

@description('App Service resource ID.')
param appServiceId string

@description('App Service name used for deterministic private endpoint naming.')
@minLength(2)
@maxLength(60)
param appServiceName string

@description('Subnet resource ID for private endpoints.')
param privateEndpointSubnetId string

@description('Key Vault resource ID.')
param keyVaultId string

@description('Key Vault name used for deterministic private endpoint naming.')
@minLength(3)
@maxLength(24)
param keyVaultName string

@description('Resource IDs of the shared private DNS zones created by the global layer.')
param privateDnsZoneIds privateDnsZoneSet

// Private endpoint for Blob service access.
resource storagePrivateEndpoint 'Microsoft.Network/privateEndpoints@2024-07-01' = {
  name: '${storageAccountName}-pe'
  location: location
  properties: {
    privateLinkServiceConnections: [
      {
        name: 'blob'
        properties: {
          privateLinkServiceId: storageAccountId
          groupIds: [
            'blob'
          ]
        }
      }
    ]
    subnet: {
      id: privateEndpointSubnetId
    }
  }
}

// Register the Storage private endpoint in the shared blob zone.
resource storagePrivateDnsZoneGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2024-07-01' = {
  parent: storagePrivateEndpoint
  name: 'default'
  properties: {
    privateDnsZoneConfigs: [
      {
        name: 'blob'
        properties: {
          privateDnsZoneId: privateDnsZoneIds.blob
        }
      }
    ]
  }
}

// Private endpoint for private App Service access.
resource appServicePrivateEndpoint 'Microsoft.Network/privateEndpoints@2024-07-01' = {
  name: '${appServiceName}-pe'
  location: location
  properties: {
    privateLinkServiceConnections: [
      {
        name: 'appservice'
        properties: {
          privateLinkServiceId: appServiceId
          groupIds: [
            'sites'
          ]
        }
      }
    ]
    subnet: {
      id: privateEndpointSubnetId
    }
  }
}

// Register the App Service private endpoint in the shared sites zone.
resource appServicePrivateDnsZoneGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2024-07-01' = {
  parent: appServicePrivateEndpoint
  name: 'default'
  properties: {
    privateDnsZoneConfigs: [
      {
        name: 'appservice'
        properties: {
          privateDnsZoneId: privateDnsZoneIds.sites
        }
      }
    ]
  }
}

// Private endpoint for Key Vault secret access.
resource keyVaultPrivateEndpoint 'Microsoft.Network/privateEndpoints@2024-07-01' = {
  name: '${keyVaultName}-pe'
  location: location
  properties: {
    privateLinkServiceConnections: [
      {
        name: 'vault'
        properties: {
          privateLinkServiceId: keyVaultId
          groupIds: [
            'vault'
          ]
        }
      }
    ]
    subnet: {
      id: privateEndpointSubnetId
    }
  }
}

// Register the Key Vault private endpoint in the shared vault zone.
resource keyVaultPrivateDnsZoneGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2024-07-01' = {
  parent: keyVaultPrivateEndpoint
  name: 'default'
  properties: {
    privateDnsZoneConfigs: [
      {
        name: 'vault'
        properties: {
          privateDnsZoneId: privateDnsZoneIds.vault
        }
      }
    ]
  }
}

output storagePrivateEndpointId string = storagePrivateEndpoint.id
output appServicePrivateEndpointId string = appServicePrivateEndpoint.id
output keyVaultPrivateEndpointId string = keyVaultPrivateEndpoint.id
