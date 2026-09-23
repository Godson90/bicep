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

@description('Spoke VNet resource ID.')
param spokeVnetId string

@description('Hub VNet resource ID.')
param hubVnetId string

@description('Subnet resource ID for private endpoints.')
param privateEndpointSubnetId string

@description('Key Vault resource ID.')
param keyVaultId string

@description('Key Vault name used for deterministic private endpoint naming.')
@minLength(3)
@maxLength(24)
param keyVaultName string

// Private DNS zone for Storage Blob private endpoints.
resource storagePrivateDnsZone 'Microsoft.Network/privateDnsZones@2024-06-01' = {
  name: 'privatelink.blob.${environment().suffixes.storage}'
  location: 'global'
}

// Private DNS zone for App Service private endpoints.
resource appServicePrivateDnsZone 'Microsoft.Network/privateDnsZones@2024-06-01' = {
  name: 'privatelink.azurewebsites.net'
  location: 'global'
}

// Private DNS zone for Key Vault private endpoints.
resource keyVaultPrivateDnsZone 'Microsoft.Network/privateDnsZones@2024-06-01' = {
  name: 'privatelink.vaultcore.azure.net'
  location: 'global'
}

// Link Storage DNS resolution to the spoke VNet.
resource storagePrivateDnsLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2024-06-01' = {
  parent: storagePrivateDnsZone
  name: 'storage-link'
  location: 'global'
  properties: {
    registrationEnabled: false
    virtualNetwork: {
      id: spokeVnetId
    }
  }
}

// Link Storage DNS resolution to the hub VNet.
resource storagePrivateDnsHubLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2024-06-01' = {
  parent: storagePrivateDnsZone
  name: 'hub-storage-link'
  location: 'global'
  properties: {
    registrationEnabled: false
    virtualNetwork: {
      id: hubVnetId
    }
  }
}

// Link App Service DNS resolution to the spoke VNet.
resource appServicePrivateDnsLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2024-06-01' = {
  parent: appServicePrivateDnsZone
  name: 'appservice-link'
  location: 'global'
  properties: {
    registrationEnabled: false
    virtualNetwork: {
      id: spokeVnetId
    }
  }
}

// Link App Service DNS resolution to the hub VNet.
resource appServicePrivateDnsHubLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2024-06-01' = {
  parent: appServicePrivateDnsZone
  name: 'hub-appservice-link'
  location: 'global'
  properties: {
    registrationEnabled: false
    virtualNetwork: {
      id: hubVnetId
    }
  }
}

// Link Key Vault DNS resolution to the spoke VNet.
resource keyVaultPrivateDnsLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2024-06-01' = {
  parent: keyVaultPrivateDnsZone
  name: 'keyvault-link'
  location: 'global'
  properties: {
    registrationEnabled: false
    virtualNetwork: {
      id: spokeVnetId
    }
  }
}

// Link Key Vault DNS resolution to the hub VNet.
resource keyVaultPrivateDnsHubLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2024-06-01' = {
  parent: keyVaultPrivateDnsZone
  name: 'hub-keyvault-link'
  location: 'global'
  properties: {
    registrationEnabled: false
    virtualNetwork: {
      id: hubVnetId
    }
  }
}

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

// Attach the Storage private DNS zone to its private endpoint.
resource storagePrivateDnsZoneGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2024-07-01' = {
  parent: storagePrivateEndpoint
  name: 'default'
  properties: {
    privateDnsZoneConfigs: [
      {
        name: 'blob'
        properties: {
          privateDnsZoneId: storagePrivateDnsZone.id
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

// Attach the App Service private DNS zone to its private endpoint.
resource appServicePrivateDnsZoneGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2024-07-01' = {
  parent: appServicePrivateEndpoint
  name: 'default'
  properties: {
    privateDnsZoneConfigs: [
      {
        name: 'appservice'
        properties: {
          privateDnsZoneId: appServicePrivateDnsZone.id
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

// Attach the Key Vault private DNS zone to its private endpoint.
resource keyVaultPrivateDnsZoneGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2024-07-01' = {
  parent: keyVaultPrivateEndpoint
  name: 'default'
  properties: {
    privateDnsZoneConfigs: [
      {
        name: 'vault'
        properties: {
          privateDnsZoneId: keyVaultPrivateDnsZone.id
        }
      }
    ]
  }
}

output storagePrivateEndpointId string = storagePrivateEndpoint.id
output appServicePrivateEndpointId string = appServicePrivateEndpoint.id
