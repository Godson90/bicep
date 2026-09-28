import { virtualNetworkReference } from 'types.bicep'

@description('Existing private DNS zone name in this resource group.')
param zoneName string

@description('Virtual networks that resolve this zone. Each gets one link named <vnet>-link.')
param virtualNetworks virtualNetworkReference[]

resource zone 'Microsoft.Network/privateDnsZones@2024-06-01' existing = {
  name: zoneName
}

// Resolution-only links: private endpoints register records through their DNS zone groups.
resource links 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2024-06-01' = [for vnet in virtualNetworks: {
  parent: zone
  name: '${vnet.name}-link'
  location: 'global'
  properties: {
    registrationEnabled: false
    virtualNetwork: {
      id: vnet.id
    }
  }
}]
