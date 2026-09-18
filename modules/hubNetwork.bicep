@description('Azure region for the hub network.')
param location string

@description('Hub virtual network name.')
@minLength(2)
@maxLength(64)
param vnetName string

@description('Non-overlapping hub address space.')
param addressSpace array

@description('Address prefix for the exact-case AzureFirewallSubnet. It must be at least /26 and contained in addressSpace.')
param firewallSubnetAddressPrefix string

var firewallSubnetName = 'AzureFirewallSubnet'

// Dedicated hub network hosting the centralized firewall.
resource hubVnet 'Microsoft.Network/virtualNetworks@2025-09-01' = {
  name: vnetName
  location: location
  properties: {
    addressSpace: {
      addressPrefixes: addressSpace
    }
    subnets: [
      {
        name: firewallSubnetName
        properties: {
          addressPrefix: firewallSubnetAddressPrefix
        }
      }
    ]
  }
}

output id string = hubVnet.id
output name string = hubVnet.name
output firewallSubnetId string = resourceId('Microsoft.Network/virtualNetworks/subnets', hubVnet.name, firewallSubnetName)
