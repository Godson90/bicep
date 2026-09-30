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

@description('Address prefix for the exact-case AzureBastionSubnet. It must be at least /26 and contained in addressSpace.')
param bastionSubnetAddressPrefix string

@description('Address prefix for the exact-case GatewaySubnet. It must be at least /27 and contained in addressSpace.')
param gatewaySubnetAddressPrefix string

@description('Azure Firewall private IP. The GatewaySubnet route table sends spoke traffic from VPN clients to it, and the hub (and so every VPN client) uses its DNS proxy.')
param firewallPrivateIp string

@description('Spoke address prefixes that VPN client traffic must reach through the firewall.')
param spokeAddressPrefixes array

@description('Management subnet prefixes Bastion may open SSH/RDP sessions to.')
param bastionTargetAddressPrefixes array

@description('Apply a CanNotDelete lock to the hub VNet.')
param enableDeleteLock bool = false

var firewallSubnetName = 'AzureFirewallSubnet'
var bastionSubnetName = 'AzureBastionSubnet'
var gatewaySubnetName = 'GatewaySubnet'
var bastionNsgName = '${vnetName}-bastion-nsg'
var gatewayRouteTableName = '${vnetName}-gateway-rt'

// Rules Microsoft requires on AzureBastionSubnet; SSH/RDP egress is narrowed to the management subnets.
resource bastionNsg 'Microsoft.Network/networkSecurityGroups@2024-07-01' = {
  name: bastionNsgName
  location: location
  properties: {
    securityRules: [
      {
        name: 'allow-https-inbound'
        properties: {
          priority: 100
          access: 'Allow'
          direction: 'Inbound'
          protocol: 'Tcp'
          sourceAddressPrefix: 'Internet'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '443'
        }
      }
      {
        name: 'allow-gateway-manager-inbound'
        properties: {
          priority: 110
          access: 'Allow'
          direction: 'Inbound'
          protocol: 'Tcp'
          sourceAddressPrefix: 'GatewayManager'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '443'
        }
      }
      {
        name: 'allow-load-balancer-inbound'
        properties: {
          priority: 120
          access: 'Allow'
          direction: 'Inbound'
          protocol: 'Tcp'
          sourceAddressPrefix: 'AzureLoadBalancer'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '443'
        }
      }
      {
        name: 'allow-bastion-host-communication-inbound'
        properties: {
          priority: 130
          access: 'Allow'
          direction: 'Inbound'
          protocol: '*'
          sourceAddressPrefix: 'VirtualNetwork'
          sourcePortRange: '*'
          destinationAddressPrefix: 'VirtualNetwork'
          destinationPortRanges: [
            '8080'
            '5701'
          ]
        }
      }
      {
        name: 'deny-unsolicited-inbound'
        properties: {
          priority: 4096
          access: 'Deny'
          direction: 'Inbound'
          protocol: '*'
          sourceAddressPrefix: '*'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '*'
        }
      }
      {
        name: 'allow-ssh-rdp-to-management-outbound'
        properties: {
          priority: 100
          access: 'Allow'
          direction: 'Outbound'
          protocol: 'Tcp'
          sourceAddressPrefix: '*'
          sourcePortRange: '*'
          destinationAddressPrefixes: bastionTargetAddressPrefixes
          destinationPortRanges: [
            '22'
            '3389'
          ]
        }
      }
      {
        name: 'allow-azure-cloud-outbound'
        properties: {
          priority: 110
          access: 'Allow'
          direction: 'Outbound'
          protocol: 'Tcp'
          sourceAddressPrefix: '*'
          sourcePortRange: '*'
          destinationAddressPrefix: 'AzureCloud'
          destinationPortRange: '443'
        }
      }
      {
        name: 'allow-bastion-host-communication-outbound'
        properties: {
          priority: 120
          access: 'Allow'
          direction: 'Outbound'
          protocol: '*'
          sourceAddressPrefix: 'VirtualNetwork'
          sourcePortRange: '*'
          destinationAddressPrefix: 'VirtualNetwork'
          destinationPortRanges: [
            '8080'
            '5701'
          ]
        }
      }
      {
        name: 'allow-session-information-outbound'
        properties: {
          priority: 130
          access: 'Allow'
          direction: 'Outbound'
          protocol: '*'
          sourceAddressPrefix: '*'
          sourcePortRange: '*'
          destinationAddressPrefix: 'Internet'
          destinationPortRange: '80'
        }
      }
      {
        name: 'deny-other-ssh-rdp-outbound'
        properties: {
          priority: 4000
          access: 'Deny'
          direction: 'Outbound'
          protocol: '*'
          sourceAddressPrefix: '*'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRanges: [
            '22'
            '3389'
          ]
        }
      }
    ]
  }
}

// VPN client traffic to the spoke goes through the firewall. BGP propagation stays on: GatewaySubnet requires it.
resource gatewayRouteTable 'Microsoft.Network/routeTables@2024-07-01' = {
  name: gatewayRouteTableName
  location: location
  properties: {
    disableBgpRoutePropagation: false
    routes: [for (prefix, i) in spokeAddressPrefixes: {
      name: 'spoke-${i}-through-firewall'
      properties: {
        addressPrefix: prefix
        nextHopType: 'VirtualAppliance'
        nextHopIpAddress: firewallPrivateIp
      }
    }]
  }
}

// Dedicated hub network hosting the firewall, Bastion and the VPN gateway. The Bastion and gateway
// subnets always exist (they are free) so turning admin access on or off never reshapes the VNet.
resource hubVnet 'Microsoft.Network/virtualNetworks@2025-09-01' = {
  name: vnetName
  location: location
  properties: {
    addressSpace: {
      addressPrefixes: addressSpace
    }
    // VPN clients receive the hub DNS servers, so they resolve privatelink zones through the firewall DNS proxy (ADR-005).
    dhcpOptions: {
      dnsServers: [
        firewallPrivateIp
      ]
    }
    subnets: [
      {
        name: firewallSubnetName
        properties: {
          addressPrefix: firewallSubnetAddressPrefix
        }
      }
      {
        name: bastionSubnetName
        properties: {
          addressPrefix: bastionSubnetAddressPrefix
          networkSecurityGroup: {
            id: bastionNsg.id
          }
        }
      }
      {
        name: gatewaySubnetName
        properties: {
          addressPrefix: gatewaySubnetAddressPrefix
          routeTable: {
            id: gatewayRouteTable.id
          }
        }
      }
    ]
  }
}

resource hubVnetLock 'Microsoft.Authorization/locks@2020-05-01' = if (enableDeleteLock) {
  scope: hubVnet
  name: '${vnetName}-lck'
  properties: {
    level: 'CanNotDelete'
  }
}

output id string = hubVnet.id
output name string = hubVnet.name
output firewallSubnetId string = resourceId('Microsoft.Network/virtualNetworks/subnets', hubVnet.name, firewallSubnetName)
output bastionSubnetId string = resourceId('Microsoft.Network/virtualNetworks/subnets', hubVnet.name, bastionSubnetName)
output gatewaySubnetId string = resourceId('Microsoft.Network/virtualNetworks/subnets', hubVnet.name, gatewaySubnetName)
