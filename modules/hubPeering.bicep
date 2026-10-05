// One side of the hub-to-hub global peering (prod with DR). main.bicep deploys it once in each region's resource group.

@description('This region\'s hub VNet name, in this resource group.')
@minLength(2)
@maxLength(64)
param localVnetName string

@description('Resource ID of the other region\'s hub VNet.')
param remoteVnetId string

@description('Peering name, for example hub-to-eus-hub.')
@minLength(1)
@maxLength(80)
param peeringName string

resource hubVnet 'Microsoft.Network/virtualNetworks@2025-09-01' existing = {
  name: localVnetName
}

// Spoke traffic crosses the peering after a firewall has forwarded it, so forwarded traffic is accepted. Each hub
// owns its own VPN gateway, so the peering neither offers nor uses a remote gateway.
resource hubToHubPeering 'Microsoft.Network/virtualNetworks/virtualNetworkPeerings@2024-07-01' = {
  parent: hubVnet
  name: peeringName
  properties: {
    allowVirtualNetworkAccess: true
    allowForwardedTraffic: true
    allowGatewayTransit: false
    useRemoteGateways: false
    remoteVirtualNetwork: {
      id: remoteVnetId
    }
  }
}

output id string = hubToHubPeering.id
