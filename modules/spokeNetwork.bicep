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

@description('CIDR ranges allowed to reach private endpoints over HTTPS. The caller derives these from subnet prefixes so they cannot drift.')
param approvedPrivateEndpointSourceCidrs array

@description('Private endpoint subnet name.')
param privateEndpointSubnetName string = 'private-endpoints'

@description('App Service integration subnet name.')
param appServiceIntegrationSubnetName string = 'appservice-integration'

@description('Private endpoint subnet address prefix.')
param privateEndpointSubnetAddressPrefix string = '10.0.1.0/24'

@description('App Service integration subnet address prefix.')
param appServiceIntegrationSubnetAddressPrefix string = '10.0.2.0/24'

@description('Virtual machine subnet name.')
param virtualMachineSubnetName string = 'management'

@description('Virtual machine subnet address prefix.')
param virtualMachineSubnetAddressPrefix string = '10.0.3.0/24'

@description('Apply a CanNotDelete lock to the spoke VNet.')
param enableDeleteLock bool = false

@description('CIDR ranges allowed to reach management VMs over SSH (22) and RDP (3389), such as AzureBastionSubnet or the P2S VPN client pool. An empty list denies all administrative inbound traffic.')
param managementSourceCidrs array = []

@description('CIDR ranges allowed to reach only the AMPLS private endpoint (its application security group) over HTTPS: the local AzureFirewallSubnet in the region that hosts the endpoint, which SNATs the other region\'s Azure Monitor traffic (Phase 6). An empty list adds no rule.')
param monitorPeerSourceCidrs array = []

var appServiceRouteTableName = '${vnetName}-appservice-egress-rt'
var virtualMachineRouteTableName = '${vnetName}-${virtualMachineSubnetName}-egress-rt'
var privateEndpointNsgName = '${vnetName}-${privateEndpointSubnetName}-nsg'
var appServiceIntegrationNsgName = '${vnetName}-${appServiceIntegrationSubnetName}-nsg'
var virtualMachineNsgName = '${vnetName}-${virtualMachineSubnetName}-nsg'
var amplsAsgName = '${vnetName}-ampls-asg'

// Administrative inbound is only rendered when approved management sources are supplied. This subnet allow is the
// outer bound on who may ever connect; the jump host's NIC NSG denies SSH and RDP until a JIT grant (ADR-028).
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
// No spoke subnet opens SSH/RDP sessions to other hosts (PSRule Azure.NSG.LateralTraversal).
var denyLateralTraversalRule = {
  name: 'deny-ssh-rdp-outbound'
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
// The peer region's monitoring traffic arrives from the local firewall's SNAT address; it may reach the AMPLS
// endpoint alone, never the subnet's other private endpoints (ADR-022).
var peerMonitoringRule = {
  name: 'allow-peer-monitoring-https'
  properties: {
    priority: 110
    access: 'Allow'
    direction: 'Inbound'
    protocol: 'Tcp'
    sourceAddressPrefixes: monitorPeerSourceCidrs
    sourcePortRange: '*'
    destinationApplicationSecurityGroups: [
      {
        id: amplsAsg.id
      }
    ]
    destinationPortRange: '443'
  }
}
var peerMonitoringInboundRules = empty(monitorPeerSourceCidrs) ? [] : [
  peerMonitoringRule
]

// Membership marks the AMPLS private endpoint as the only target of the peer monitoring rule. Free of charge.
resource amplsAsg 'Microsoft.Network/applicationSecurityGroups@2024-07-01' = {
  name: amplsAsgName
  location: location
}

// NSG for the private endpoint subnet; source CIDRs are explicit deployment inputs.
resource privateEndpointNsg 'Microsoft.Network/networkSecurityGroups@2024-07-01' = {
  name: privateEndpointNsgName
  location: location
  properties: {
    securityRules: concat([
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
    ], peerMonitoringInboundRules, [
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
      denyLateralTraversalRule
    ])
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
      denyLateralTraversalRule
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
      denyLateralTraversalRule
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
        defaultOutboundAccess: false
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
        defaultOutboundAccess: false
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
output amplsAsgId string = amplsAsg.id
