@description('Hub VNet name.')
@minLength(2)
@maxLength(64)
param hubVnetName string

@description('Hub VNet resource ID. Creates an explicit deployment dependency.')
param hubVnetId string

@description('Spoke VNet name.')
@minLength(2)
@maxLength(64)
param spokeVnetName string

@description('Spoke VNet resource ID. Creates an explicit deployment dependency.')
param spokeVnetId string

@description('Storage account name receiving the application identity role assignment.')
@minLength(3)
@maxLength(24)
param storageAccountName string

@description('Storage account resource ID. Creates an explicit deployment dependency.')
param storageAccountId string

@description('App Service managed identity principal ID.')
param appServicePrincipalId string

@description('App Service name used to make the role assignment GUID deterministic.')
@minLength(2)
@maxLength(60)
param appServiceName string

@description('Allow forwarded traffic across the hub/spoke peering for firewall service chaining.')
param allowForwardedTraffic bool = true

resource hubVnet 'Microsoft.Network/virtualNetworks@2025-09-01' existing = {
  name: hubVnetName
}

resource spokeVnet 'Microsoft.Network/virtualNetworks@2025-09-01' existing = {
  name: spokeVnetName
}

resource storageAccount 'Microsoft.Storage/storageAccounts@2026-04-01' existing = {
  name: storageAccountName
}

// Hub-side peering for centralized firewall service chaining.
resource hubToSpokePeering 'Microsoft.Network/virtualNetworks/virtualNetworkPeerings@2024-07-01' = {
  parent: hubVnet
  name: 'hub-to-spoke'
  properties: {
    allowVirtualNetworkAccess: true
    allowForwardedTraffic: allowForwardedTraffic
    allowGatewayTransit: false
    useRemoteGateways: false
    remoteVirtualNetwork: {
      id: spokeVnetId
    }
  }
}

// Spoke-side reciprocal peering.
resource spokeToHubPeering 'Microsoft.Network/virtualNetworks/virtualNetworkPeerings@2024-07-01' = {
  parent: spokeVnet
  name: 'spoke-to-hub'
  properties: {
    allowVirtualNetworkAccess: true
    allowForwardedTraffic: allowForwardedTraffic
    allowGatewayTransit: false
    useRemoteGateways: false
    remoteVirtualNetwork: {
      id: hubVnetId
    }
  }
}

// Least-privilege data-plane access for the App Service managed identity.
resource storageBlobDataContributor 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storageAccountId, appServiceName, 'Storage Blob Data Contributor')
  scope: storageAccount
  properties: {
    principalId: appServicePrincipalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'ba92f5b4-2d11-453d-a403-e96b0029c9fe')
  }
}
