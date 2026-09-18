

@description('Virtual network name')
@minLength(2)
@maxLength(64)
param vnetName string = uniqueString(resourceGroup().id)

@description('Virtual network location')
param location string = resourceGroup().location

@description('Array containing defenstack vnet address space(s)')
param vnetAddressSpace array = [
  '10.0.0.0/16'
]

@description('Array containing DNS servers for defenstack')
param dnsServer array = []

@description('Array containing subnets to be created within the vnet')
param subnets array = [
  {
    name: 'private-endpoints'
    addressPrefix: '10.0.1.0/24'
    privateEndpointNetworkPolicies: 'NetworkSecurityGroupEnabled'
    privateLinkServiceNetworkPolicies: 'Enabled'
  }
  {
    name: 'appservice-integration'
    addressPrefix: '10.0.2.0/24'
    delegation: 'Microsoft.Web/serverFarms'
    privateEndpointNetworkPolicies: 'Disabled'
    privateLinkServiceNetworkPolicies: 'Enabled'
  }
  {
    name: 'virtual-machines'
    addressPrefix: '10.0.3.0/24'
    privateEndpointNetworkPolicies: 'Disabled'
    privateLinkServiceNetworkPolicies: 'Enabled'
  }
]

@description('Name of the private endpoint subnet.')
param privateEndpointSubnetName string = 'private-endpoints'

@description('Name of the App Service integration subnet.')
param appServiceIntegrationSubnetName string = 'appservice-integration'

@description('Name of the virtual machine subnet.')
param virtualMachineSubnetName string = 'virtual-machines'

@description('Enable delete lock')
param enableDeleteLock bool = false

@description('Enable diagnostic logs')
param enableDiagnostics bool = true

@description('Storage account resource id. Only required if enableDiagnostics is set to true.')
param diagnosticStorageAccountId string = ''

@description('Log analytics workspace resource id. Only required if enableDiagnostics is set to true.')
param logAnalyticsWorkspaceId string = ''

var lockName = '${vnet.name}-lck'
var diagnosticName = '${vnet.name}-dgs'

// Spoke VNet containing the private endpoint and App Service integration subnets.
resource vnet 'Microsoft.Network/virtualNetworks@2025-09-01' = {
  name: vnetName
  location: location
  properties: {
    addressSpace: {
      addressPrefixes: vnetAddressSpace
    }
    dhcpOptions: empty(dnsServer) ? null : {
      dnsServers: dnsServer
    }
    subnets: [for subnet in subnets: {
      name: subnet.name
      properties: {
        addressPrefix: subnet.addressPrefix
        delegations: contains(subnet, 'delegation') ? [
          {
            name: '${subnet.name}-delegation'
            properties: {
              serviceName: subnet.delegation
            }
          }
        ] : []
        natGateway: contains(subnet, 'natGatewayId') ? {
          id: subnet.natGatewayId
        } : null
        networkSecurityGroup: contains(subnet, 'nsgId') ? {
          id: subnet.nsgId
        } : null
        routeTable: contains(subnet, 'udrId') ? {
          id: subnet.udrId
        } : null
        privateEndpointNetworkPolicies: subnet.privateEndpointNetworkPolicies
        privateLinkServiceNetworkPolicies: subnet.privateLinkServiceNetworkPolicies
        serviceEndpoints: subnet.?serviceEndpoints
      }
    }]
  }
}

// Optional VNet diagnostics, enabled only when a workspace destination is supplied.
resource diagnostics 'microsoft.insights/diagnosticSettings@2021-05-01-preview' = if (enableDiagnostics && !empty(logAnalyticsWorkspaceId)) {
  scope: vnet
  name: diagnosticName
  properties: {
    workspaceId: empty(logAnalyticsWorkspaceId) ? null : logAnalyticsWorkspaceId
    storageAccountId: empty(diagnosticStorageAccountId) ? null : diagnosticStorageAccountId
    logs: [
      {
        category: 'VMProtectionAlerts'
        enabled: true
      }
    ]
    metrics: [
      {
        category: 'AllMetrics'
        enabled: true
      }
    ]
  }
}

// Production deletion protection for the spoke VNet.
resource lock 'Microsoft.Authorization/locks@2020-05-01' = if (enableDeleteLock) {
  scope: vnet
  name: lockName
  properties: {
    level: 'CanNotDelete'
  }
}

output name string = vnet.name
output id string = vnet.id
output subnetIds array = [for subnet in subnets: resourceId('Microsoft.Network/virtualNetworks/subnets', vnet.name, subnet.name)]
output privateEndpointSubnetId string = resourceId('Microsoft.Network/virtualNetworks/subnets', vnet.name, privateEndpointSubnetName)
output appServiceIntegrationSubnetId string = resourceId('Microsoft.Network/virtualNetworks/subnets', vnet.name, appServiceIntegrationSubnetName)
output virtualMachineSubnetId string = resourceId('Microsoft.Network/virtualNetworks/subnets', vnet.name, virtualMachineSubnetName)
