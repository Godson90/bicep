@description('Azure region for the spoke network resources.')
param location string

@description('Spoke virtual network name.')
@minLength(2)
@maxLength(64)
param vnetName string

@description('Non-overlapping spoke address space.')
param vnetAddressSpace array = [
  '10.0.0.0/16'
]

@description('Firewall private IP used for App Service egress and VNet DNS proxy traffic.')
param firewallPrivateIp string

@description('Log Analytics workspace resource ID for VNet diagnostics.')
param logAnalyticsWorkspaceId string

@description('CIDR ranges allowed to reach private endpoints over HTTPS.')
param approvedPrivateEndpointSourceCidrs array = [
  '10.0.2.0/24'
]

@description('Private endpoint subnet name.')
param privateEndpointSubnetName string = 'private-endpoints'

@description('App Service integration subnet name.')
param appServiceIntegrationSubnetName string = 'appservice-integration'

@description('Private endpoint subnet address prefix.')
param privateEndpointSubnetAddressPrefix string = '10.0.1.0/24'

@description('App Service integration subnet address prefix.')
param appServiceIntegrationSubnetAddressPrefix string = '10.0.2.0/24'

@description('Virtual machine subnet name.')
param virtualMachineSubnetName string = 'virtual-machines'

@description('Virtual machine subnet address prefix.')
param virtualMachineSubnetAddressPrefix string = '10.0.3.0/24'

@description('Apply a CanNotDelete lock to the spoke VNet.')
param enableDeleteLock bool = false

@description('CIDR ranges allowed to reach management VMs over SSH (22) and RDP (3389), such as AzureBastionSubnet or the P2S VPN client pool. An empty list denies all administrative inbound traffic.')
param managementSourceCidrs array = []

var appServiceRouteTableName = '${vnetName}-appservice-egress-rt'
var virtualMachineRouteTableName = '${vnetName}-${virtualMachineSubnetName}-egress-rt'
var privateEndpointNsgName = '${vnetName}-${privateEndpointSubnetName}-nsg'
var appServiceIntegrationNsgName = '${vnetName}-${appServiceIntegrationSubnetName}-nsg'
var virtualMachineNsgName = '${vnetName}-${virtualMachineSubnetName}-nsg'

// Administrative inbound is only rendered when approved management sources are supplied.
var managementInboundRules = empty(managementSourceCidrs) ? [] : [
  {
    name: 'allow-management-ssh-rdp'
    properties: {
      priority: 100
      access: 'Allow'
      direction: 'Inbound'
      protocol: 'Tcp'
      sourceAddressPrefixes: managementSourceCidrs
      sourcePortRange: '*'
      destinationAddressPrefix: virtualMachineSubnetAddressPrefix
      destinationPortRanges: [
        '22'
        '3389'
      ]
    }
  }
]

// NSG for the private endpoint subnet; source CIDRs are explicit deployment inputs.
resource privateEndpointNsg 'Microsoft.Network/networkSecurityGroups@2024-07-01' = {
  name: privateEndpointNsgName
  location: location
  properties: {
    securityRules: [
      {
        name: 'allow-approved-https'
        properties: {
          priority: 100
          access: 'Allow'
          direction: 'Inbound'
          protocol: 'Tcp'
          sourceAddressPrefixes: approvedPrivateEndpointSourceCidrs
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '443'
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
    ]
  }
}

// NSG for the delegated App Service integration subnet.
resource appServiceIntegrationNsg 'Microsoft.Network/networkSecurityGroups@2024-07-01' = {
  name: appServiceIntegrationNsgName
  location: location
  properties: {
    securityRules: [
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
    ]
  }
}

// Route only App Service integration egress through Azure Firewall.
resource appServiceRouteTable 'Microsoft.Network/routeTables@2024-07-01' = {
  name: appServiceRouteTableName
  location: location
  properties: {
    disableBgpRoutePropagation: true
    routes: [
      {
        name: 'default-through-firewall'
        properties: {
          addressPrefix: '0.0.0.0/0'
          nextHopType: 'VirtualAppliance'
          nextHopIpAddress: firewallPrivateIp
        }
      }
    ]
  }
}

// Dedicated NSG for the management subnet; denies everything except approved admin sources.
resource virtualMachineNsg 'Microsoft.Network/networkSecurityGroups@2024-07-01' = {
  name: virtualMachineNsgName
  location: location
  properties: {
    securityRules: concat(managementInboundRules, [
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
    ])
  }
}

// Route management subnet egress through Azure Firewall; gateway routes are not propagated.
resource virtualMachineRouteTable 'Microsoft.Network/routeTables@2024-07-01' = {
  name: virtualMachineRouteTableName
  location: location
  properties: {
    disableBgpRoutePropagation: true
    routes: [
      {
        name: 'default-through-firewall'
        properties: {
          addressPrefix: '0.0.0.0/0'
          nextHopType: 'VirtualAppliance'
          nextHopIpAddress: firewallPrivateIp
        }
      }
    ]
  }
}

module vnet 'vnet.bicep' = {
  params: {
    vnetName: vnetName
    location: location
    vnetAddressSpace: vnetAddressSpace
    dnsServer: [
      firewallPrivateIp
    ]
    subnets: [
      {
        name: privateEndpointSubnetName
        addressPrefix: privateEndpointSubnetAddressPrefix
        nsgId: privateEndpointNsg.id
        privateEndpointNetworkPolicies: 'NetworkSecurityGroupEnabled'
        privateLinkServiceNetworkPolicies: 'Enabled'
      }
      {
        name: appServiceIntegrationSubnetName
        addressPrefix: appServiceIntegrationSubnetAddressPrefix
        delegation: 'Microsoft.Web/serverFarms'
        nsgId: appServiceIntegrationNsg.id
        udrId: appServiceRouteTable.id
        privateEndpointNetworkPolicies: 'Disabled'
        privateLinkServiceNetworkPolicies: 'Enabled'
      }
      {
        name: virtualMachineSubnetName
        addressPrefix: virtualMachineSubnetAddressPrefix
        nsgId: virtualMachineNsg.id
        udrId: virtualMachineRouteTable.id
        privateEndpointNetworkPolicies: 'Disabled'
        privateLinkServiceNetworkPolicies: 'Enabled'
      }
    ]
    privateEndpointSubnetName: privateEndpointSubnetName
    appServiceIntegrationSubnetName: appServiceIntegrationSubnetName
    virtualMachineSubnetName: virtualMachineSubnetName
    enableDeleteLock: enableDeleteLock
    enableDiagnostics: true
    logAnalyticsWorkspaceId: logAnalyticsWorkspaceId
  }
}

output id string = vnet.outputs.id
output name string = vnet.outputs.name
output privateEndpointSubnetId string = vnet.outputs.privateEndpointSubnetId
output appServiceIntegrationSubnetId string = vnet.outputs.appServiceIntegrationSubnetId
output virtualMachineSubnetId string = resourceId('Microsoft.Network/virtualNetworks/subnets', vnet.outputs.name, virtualMachineSubnetName)
