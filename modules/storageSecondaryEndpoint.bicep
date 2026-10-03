// Warm-standby read access to the primary region's RA-GZRS storage through its read-only secondary endpoint.

@description('Azure region for the private endpoint (the warm-standby region).')
param location string

@description('Resource ID of the primary region storage account (RA-GZRS).')
param primaryStorageAccountId string

@description('Primary region storage account name, used for deterministic naming.')
@minLength(3)
@maxLength(24)
param primaryStorageAccountName string

@description('Private endpoint subnet in the warm-standby spoke.')
param privateEndpointSubnetId string

@description('Shared privatelink.blob zone resource ID; the secondary endpoint registers as <account>-secondary.')
param blobPrivateDnsZoneId string

resource secondaryEndpoint 'Microsoft.Network/privateEndpoints@2024-07-01' = {
  name: '${primaryStorageAccountName}-secondary-pe'
  location: location
  properties: {
    privateLinkServiceConnections: [
      {
        name: 'blob-secondary'
        properties: {
          privateLinkServiceId: primaryStorageAccountId
          groupIds: [
            'blob_secondary'
          ]
        }
      }
    ]
    subnet: {
      id: privateEndpointSubnetId
    }
  }
}

resource secondaryEndpointDns 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2024-07-01' = {
  parent: secondaryEndpoint
  name: 'default'
  properties: {
    privateDnsZoneConfigs: [
      {
        name: 'blob-secondary'
        properties: {
          privateDnsZoneId: blobPrivateDnsZoneId
        }
      }
    ]
  }
}

output id string = secondaryEndpoint.id
