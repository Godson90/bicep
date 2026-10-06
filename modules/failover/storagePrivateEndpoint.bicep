// Write access to the prod primary app storage account from the East US warm standby during a declared outage
// (Phase 8, runbook 08). The account's own <account>-pe endpoint sits in the West US 3 spoke, which is unreachable,
// so this endpoint gives the East US spoke a blob path to the account after its failover. It mirrors the storage
// endpoint of privateConnectivity.bicep; a test pins the parity. Its zone group overwrites the account's A record in
// the shared blob zone; failback deletes this endpoint and the next pipeline deploy restores the West US 3 record.

@description('Azure region for the private endpoint (the warm-standby region).')
param location string

@description('Resource ID of the prod primary app storage account.')
param storageAccountId string

@description('Private endpoint name. It must differ from <account>-pe and <account>-secondary-pe.')
@minLength(2)
@maxLength(80)
param privateEndpointName string

@description('Private endpoint subnet in the warm-standby spoke.')
param privateEndpointSubnetId string

@description('Shared privatelink.blob zone resource ID.')
param blobPrivateDnsZoneId string

resource storagePrivateEndpoint 'Microsoft.Network/privateEndpoints@2024-07-01' = {
  name: privateEndpointName
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

// Registers the endpoint in the shared blob zone, re-pointing <account>.privatelink.blob to East US.
resource storagePrivateDnsZoneGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2024-07-01' = {
  parent: storagePrivateEndpoint
  name: 'default'
  properties: {
    privateDnsZoneConfigs: [
      {
        name: 'blob'
        properties: {
          privateDnsZoneId: blobPrivateDnsZoneId
        }
      }
    ]
  }
}

output id string = storagePrivateEndpoint.id
output name string = storagePrivateEndpoint.name
